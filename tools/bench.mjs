// Microbenchmark harness: runs each loop in tests/asm/bench.s and reports the
// interpreter's throughput on it.
import { assemble, newMachine, setupLongMode } from '../tests/harness.mjs';

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
const results = [];

for (const c of CASES) {
  const m = await newMachine({ ramSize: 64 * 1024 * 1024 });
  m.writeBytes(0x100000, code);
  setupLongMode(m, { entry: 0x100000 });
  m.setReg(15, c.id);                      // r15 selects the loop

  const t0 = process.hrtime.bigint();
  let guard = 0;
  while (!m.halted && guard++ < 20000) m.run(5_000_000);
  const ns = Number(process.hrtime.bigint() - t0);

  const instrs = Number(m.exports.get_cycles());
  const mips = instrs / (ns / 1e9) / 1e6;
  results.push({ name: c.name, instrs, mips, halted: m.halted });
}

const width = Math.max(...results.map((r) => r.name.length));
console.log('');
for (const r of results) {
  console.log(`  ${r.name.padEnd(width)}  ${r.mips.toFixed(1).padStart(7)} MIPS` +
              `   (${(r.instrs / 1e6).toFixed(1)}M instrs)` +
              (r.halted ? '' : '  [did not finish]'));
}
const total = results.reduce((a, r) => a + r.mips, 0) / results.length;
console.log(`  ${'average'.padEnd(width)}  ${total.toFixed(1).padStart(7)} MIPS\n`);
