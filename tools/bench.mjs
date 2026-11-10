// Microbenchmark harness: runs each loop in tests/asm/bench.s and reports the
// interpreter's throughput on it.
import { assemble, newMachine, setupLongMode } from '../tests/harness.mjs';

const CASES = [
  { id: 0, name: 'register ALU' },
  { id: 1, name: 'memory' },
  { id: 2, name: 'branches' },
  { id: 3, name: 'mixed' },
  // REP MOVS and STOS move up to a page per step, so retired instructions
  // say nothing about this one; it is measured by bytes moved.
  { id: 4, name: 'string (rep movsq)', bytes: 200 * 10000 * 8 },
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
  const mbs = c.bytes ? c.bytes / (ns / 1e9) / 1e6 : null;
  results.push({ name: c.name, instrs, mips, mbs, halted: m.halted });
}

const width = Math.max(...results.map((r) => r.name.length));
console.log('');
for (const r of results) {
  const rate = r.mbs !== null ? `${r.mbs.toFixed(0).padStart(7)} MB/s` : `${r.mips.toFixed(1).padStart(7)} MIPS`;
  console.log(`  ${r.name.padEnd(width)}  ${rate}` +
              (r.mbs !== null ? '' : `   (${(r.instrs / 1e6).toFixed(1)}M instrs)`) +
              (r.halted ? '' : '  [did not finish]'));
}
const timed = results.filter((r) => r.mbs === null);
const total = timed.reduce((a, r) => a + r.mips, 0) / timed.length;
console.log(`  ${'average'.padEnd(width)}  ${total.toFixed(1).padStart(7)} MIPS\n`);
