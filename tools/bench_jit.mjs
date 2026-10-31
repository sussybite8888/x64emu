// Interpreter against JIT on the same microbenchmarks.
//
// Each case is run twice in a fresh machine and the throughputs compared.  The
// compiled-block statistics are printed alongside, because a case that shows no
// gain because nothing was compiled is a different problem from one that shows
// no gain despite being fully compiled.
import { assemble, newMachine, setupLongMode } from '../tests/harness.mjs';
import { Jit } from '../src/js/jit.js';

const CASES = [
  { id: 0, name: 'register ALU' },
  { id: 1, name: 'memory' },
  { id: 2, name: 'branches' },
  { id: 3, name: 'mixed' },
  { id: 4, name: 'string (rep movsq)' },
  { id: 5, name: 'dispatch only (nop)' },
  { id: 6, name: 'add reg,reg only' },
  { id: 7, name: 'mov reg,reg (no flags)' },
  { id: 8, name: 'lea (addressing only)' },
];

const code = assemble('bench', 0x100000);

async function once(id, useJit) {
  const m = await newMachine({ ramSize: 64 * 1024 * 1024 });
  m.writeBytes(0x100000, code);
  setupLongMode(m, { entry: 0x100000 });
  m.setReg(15, id);
  const jit = useJit ? new Jit(m) : null;
  if (jit) m.exports.jit_enable(1);

  const t0 = process.hrtime.bigint();
  let guard = 0;
  while (!m.halted && guard++ < 20000) {
    m.run(5_000_000);
    if (jit) jit.drain();
  }
  const ns = Number(process.hrtime.bigint() - t0);
  const instrs = Number(m.exports.get_cycles());
  return { mips: instrs / (ns / 1e9) / 1e6, jit, halted: m.halted };
}

// Interleaved and repeated: the two configurations see the same machine load,
// and the best of several runs is far less noisy than a single one on a box
// that is doing anything else.
const REPS = 3;
const rows = [];
for (const c of CASES) {
  let base = 0, withJit = 0, stats = null;
  for (let i = 0; i < REPS; i++) {
    const a = await once(c.id, false);
    const b = await once(c.id, true);
    base = Math.max(base, a.mips);
    withJit = Math.max(withJit, b.mips);
    stats = b.jit;
  }
  rows.push({ name: c.name, base, withJit, stats });
}

const w = Math.max(...rows.map((r) => r.name.length));
console.log(`\n  ${'case'.padEnd(w)}   interp      jit   speedup   blocks  instrs`);
for (const r of rows) {
  console.log(`  ${r.name.padEnd(w)}  ${r.base.toFixed(1).padStart(6)}   ` +
    `${r.withJit.toFixed(1).padStart(6)}    ${(r.withJit / r.base).toFixed(2)}x   ` +
    `${String(r.stats.compiled).padStart(6)}  ${String(r.stats.instrs).padStart(6)}`);
}
const gm = Math.exp(rows.reduce((a, r) => a + Math.log(r.withJit / r.base), 0) / rows.length);
console.log(`\n  geometric mean speedup: ${gm.toFixed(2)}x\n`);
