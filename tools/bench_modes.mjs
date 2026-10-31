// The same loops timed in real, protected-32 and long mode.  Everything else in
// the benchmark suite runs in long mode only, which hides whatever the other
// two cost -- and those are the modes a PC actually boots through.
import { assemble, newMachine, setupLongMode } from '../tests/harness.mjs';
import { CS, SS, DS, ES, FS, GS, SEG_CODE64, SEG_CODE32, SEG_CODE16,
         SEG_DATA32, SEG_DATA16 } from '../src/js/machine.js';

const BASE = 0x1000;
const OFF = { m64_alu: 0x00, m64_mem: 0x2a, m32_alu: 0x61,
              m32_mem: 0x8a, m16_alu: 0xc0, m16_mem: 0xeb };
const code = assemble('bench_modes', BASE);

function setupProtected32(m, entry) {
  m.setCR(0, 0x11);                                  // PE | ET, paging off
  m.setSeg(CS, 0x08, 0, -1, SEG_CODE32);
  for (const s of [SS, DS, ES, FS, GS]) m.setSeg(s, 0x10, 0, -1, SEG_DATA32);
  m.rip = entry;
  m.setReg(4, 0x200000);
}

function setupReal16(m, entry) {
  m.setCR(0, 0x10);                                  // paging and PE both off
  m.setSeg(CS, 0, 0, 0xffff, SEG_CODE16);
  for (const s of [SS, DS, ES, FS, GS]) m.setSeg(s, 0, 0, 0xffff, SEG_DATA16);
  m.rip = entry;
  m.setReg(4, 0x7000);
}

const CASES = [
  ['long   ALU',    'm64_alu', setupLongMode],
  ['long   memory', 'm64_mem', setupLongMode],
  ['prot32 ALU',    'm32_alu', setupProtected32],
  ['prot32 memory', 'm32_mem', setupProtected32],
  ['real16 ALU',    'm16_alu', setupReal16],
  ['real16 memory', 'm16_mem', setupReal16],
];

const out = [];
for (const [name, sym, setup] of CASES) {
  const m = await newMachine({ ramSize: 64 * 1024 * 1024 });
  m.writeBytes(BASE, code);
  const entry = BASE + OFF[sym];
  if (setup === setupLongMode) setup(m, { entry, stack: 0x200000 });
  else setup(m, entry);

  const t0 = process.hrtime.bigint();
  let guard = 0;
  while (!m.halted && guard++ < 20000) m.run(5_000_000);
  const ns = Number(process.hrtime.bigint() - t0);
  const instrs = Number(m.exports.get_cycles());
  out.push({ name, mips: instrs / (ns / 1e9) / 1e6, instrs, halted: m.halted });
}
const w = Math.max(...out.map(r => r.name.length));
console.log('');
for (const r of out) {
  console.log(`  ${r.name.padEnd(w)}  ${r.mips.toFixed(1).padStart(7)} MIPS` +
              `  (${(r.instrs / 1e6).toFixed(1)}M)` + (r.halted ? '' : '  [did not finish]'));
}
console.log('');
