// Differential test: every assembly test, run twice, once interpreted and once
// with the JIT compiling whatever it can.
//
// A JIT is only worth having if it is invisible, so the check is not "did the
// program pass" but "did the machine end up in exactly the same state".  Every
// general register, the flags and RIP are compared, because a block that gets
// a flag wrong while still producing the right answer is a bug that would
// surface much later and somewhere else.
//
// The run also fails if the JIT never compiled anything: a differential test
// that silently exercises nothing would pass forever.
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { assemble, newMachine, setupLongMode, captureDebugPort } from './harness.mjs';
import { Jit } from '../src/js/jit.js';
import { CS, SS, DS, ES, FS, GS, SEG_CODE16, SEG_DATA16 } from '../src/js/machine.js';

// Programs that start in real mode, loaded at 0 the way tests/run.mjs does.
// Run as long mode code they execute garbage, which compares nothing useful.
const REAL_MODE = new Set(['t_v86', 't_modes']);
// Platform tests, which tests/run_bios.mjs drives and checks itself: here
// they only have to agree, since they report nothing on the debug port.
const PLATFORM = new Set(['t_disk', 't_mouse', 't_planar', 't_vga']);

const here = dirname(fileURLToPath(import.meta.url));
const NAMES = ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
               'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'];

async function run(name, useJit) {
  const real = REAL_MODE.has(name);
  const code = assemble(name, real ? 0 : 0x100000);
  const m = await newMachine({ ramSize: 64 * 1024 * 1024 });
  if (real) {
    m.writeBytes(0, code);
    m.reset();
    m.setSeg(CS, 0, 0, 0xffff, SEG_CODE16);
    for (const s of [SS, DS, ES, FS, GS]) m.setSeg(s, 0, 0, 0xffff, SEG_DATA16);
    m.rip = 0;
  } else {
    m.writeBytes(0x100000, code);
    setupLongMode(m, { entry: 0x100000 });
  }
  const out = captureDebugPort(m);
  const jit = useJit ? new Jit(m) : null;
  if (jit) { m.exports.jit_enable(1); m.exports.jit_set_threshold(1); m.exports.jit_all_heads(1); }

  let guard = 0;
  while (!m.halted && guard++ < 200000) {
    m.run(200000);
    // Compiling between slices keeps the guest's own execution untouched: a
    // block is only ever installed while the core is not inside one.
    if (jit) jit.drain();
  }
  return {
    regs: NAMES.map((_, i) => m.exports.get_reg(i)),
    flags: m.exports.get_flags(),
    rip: m.exports.get_rip(),
    halted: m.halted,
    out: out.join(),
    stats: jit && { compiled: jit.compiled, rejected: jit.rejected, instrs: jit.instrs },
  };
}

const files = readdirSync(join(here, 'asm'))
  .filter((f) => f.endsWith('.s') && !f.startsWith('bench'))
  .map((f) => f.replace(/\.s$/, ''))
  .sort();

let fails = 0, totalBlocks = 0, totalInstrs = 0;
for (const name of files) {
  const a = await run(name, false);
  const b = await run(name, true);
  const diffs = [];
  for (let i = 0; i < NAMES.length; i++) {
    if (a.regs[i] !== b.regs[i]) {
      diffs.push(`${NAMES[i]} ${a.regs[i].toString(16)} -> ${b.regs[i].toString(16)}`);
    }
  }
  if (a.flags !== b.flags) diffs.push(`flags ${a.flags.toString(16)} -> ${b.flags.toString(16)}`);
  if (a.rip !== b.rip) diffs.push(`rip ${a.rip.toString(16)} -> ${b.rip.toString(16)}`);
  if (a.halted !== b.halted) diffs.push(`halted ${a.halted} -> ${b.halted}`);
  if (String(a.out) !== String(b.out)) diffs.push(`output ${a.out} -> ${b.out}`);
  // Agreeing is not enough if both runs went wrong the same way: the program
  // reports 0 on the debug port when its own checks pass.
  const last = String(b.out).split(',').at(-1);
  if (!PLATFORM.has(name) && last !== '0') {
    diffs.push(`program reported ${last || 'nothing'} under the JIT`);
  }

  totalBlocks += b.stats.compiled;
  totalInstrs += b.stats.instrs;
  if (diffs.length) {
    fails++;
    console.log(`FAIL  ${name}  (${b.stats.compiled} blocks)`);
    for (const d of diffs) console.log(`        ${d}`);
  } else {
    console.log(`PASS  ${name}  (${b.stats.compiled} blocks, ` +
                `${b.stats.instrs} instrs compiled, ${b.stats.rejected} rejected)`);
  }
}

console.log('');
if (!totalBlocks) {
  console.log('FAIL: the JIT never compiled a single block, so nothing was compared');
  process.exit(1);
}
console.log(`${totalBlocks} blocks compiled across the suite, ` +
            `covering ${totalInstrs} instructions`);
console.log(fails ? `${fails} test(s) diverged` : 'interpreter and JIT agree everywhere');
process.exit(fails ? 1 : 0);
