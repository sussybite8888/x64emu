// Test runner.  Cases marked `real` boot from 16-bit real mode at physical 0;
// the rest are dropped into a ready-made long-mode environment.
import { assemble, newMachine, setupLongMode, captureDebugPort } from './harness.mjs';
import { CS, SS, DS, ES, FS, GS, SEG_CODE16, SEG_DATA16 } from '../src/js/machine.js';

const CASES = [
  { name: 't_arith64', mode: 'long' },
  { name: 't_modes', mode: 'real' },
  { name: 't_paging', mode: 'long' },
  { name: 't_x87', mode: 'long' },
  { name: 't_align', mode: 'long' },
  { name: 't_npx', mode: 'long' },
  { name: 't_fisttp', mode: 'long' },
  { name: 't_x87round', mode: 'long' },
  { name: 't_ssef', mode: 'long' },
  { name: 't_huff', mode: 'long' },
  { name: 't_bitops', mode: 'long' },
  { name: 't_partial', mode: 'long' },
  { name: 't_sse2', mode: 'long' },
  { name: 't_alu', mode: 'long' },
  { name: 't_logic', mode: 'long' },
  { name: 't_shift', mode: 'long' },
  { name: 't_rot', mode: 'long' },
  { name: 't_mul', mode: 'long' },
  { name: 't_div', mode: 'long' },
  { name: 't_setcc', mode: 'long' },
  { name: 't_cmov', mode: 'long' },
  { name: 't_bit', mode: 'long' },
  { name: 't_string', mode: 'long' },
  { name: 't_cmpxchg', mode: 'long' },
  { name: 't_movsse', mode: 'long' },
  { name: 't_lar', mode: 'long' },
  { name: 't_v86', mode: 'real' },
  { name: 't_sse2int', mode: 'long' },
  { name: 't_fxsave', mode: 'long' },
  { name: 't_mmx', mode: 'long' },
];

let failures = 0;

for (const c of CASES) {
  const base = c.mode === 'real' ? 0 : 0x100000;
  const code = assemble(c.name, base);
  const m = await newMachine();
  const out = captureDebugPort(m);

  if (c.mode === 'real') {
    m.writeBytes(0, code);
    m.reset();
    m.setSeg(CS, 0, 0, 0xffff, SEG_CODE16);
    for (const s of [SS, DS, ES, FS, GS]) m.setSeg(s, 0, 0, 0xffff, SEG_DATA16);
    m.rip = 0;
  } else {
    m.writeBytes(0x100000, code);
    setupLongMode(m, { entry: 0x100000 });
  }

  let reason = -1;
  for (let i = 0; i < 500 && !m.halted; i++) {
    reason = m.run(200000);
    if (reason === 3 || reason === 2) break;
  }

  const status = out.length ? out[out.length - 1] : 'no output';
  const ok = status === 0;
  if (!ok) failures++;
  console.log(
    `${ok ? 'PASS' : 'FAIL'}  ${c.name}` +
    (ok ? '' : `  (check #${status}, rip=0x${m.rip.toString(16)}, ` +
               `mode=${m.mode}, exit=${reason}, instrs=${m.instructionsRun})`)
  );
}

console.log(failures ? `\n${failures} failing` : '\nall tests passed');
process.exit(failures ? 1 : 0);
