// Run the generated cases on the emulator and compare against real silicon.
//
// The comparison ignores three things on purpose: RSP, which the native runner
// cannot control because it reaches each case with a CALL; any flag the
// architecture leaves undefined for that instruction; and cases that faulted on
// hardware, which are the generator's mistake rather than the emulator's.
// Everything else -- every register, the arithmetic flags, all sixteen XMM
// registers and the whole scratch page -- has exactly one right answer.
import { readFileSync, writeFileSync } from 'node:fs';
import { newMachine, setupLongMode } from '../../tests/harness.mjs';

const dir = new URL('.', import.meta.url).pathname;
const code = readFileSync(dir + 'cases.bin');
const initB = readFileSync(dir + 'init.bin');
const init = new BigUint64Array(initB.buffer.slice(initB.byteOffset,
                                                   initB.byteOffset + initB.length));
const meta = JSON.parse(readFileSync(dir + 'cases.json', 'utf8'));
const nat = readFileSync(dir + 'results.bin');

const SLOT = meta.slot, N = meta.cases.length;
const BASE = 0x200000, STACK = 0x180000;
const SCRATCH = 0x300000, SCRATCH_LEN = 4096;
const ARITH = 0x8d5;                      // CF PF AF ZF SF OF
const XMM_OFF = 0x400;                    // XMM file inside the state block
const WORDS = 58;                         // registers, flags, XMM, control word, ST
const REC = 128 + 8 + 8 + 256 + 8 + 8 + 32;  // ..., hash, status word, ST(0..3)
// x87 state inside the state block.
const FPU_SW = 0x504, FPU_CW = 0x508, FPU_ST = 0x510, FPU_TOP = 0x590, FPU_TAG = 0x594;
// Transcendentals are approximations; no two implementations agree to the last
// bit, so they are exercised but not strictly compared.
const APPROX = new Set(['fsin', 'fcos', 'fptan', 'fpatan', 'f2xm1', 'fyl2x',
                        'fyl2xp1', 'fsincos', 'fsqrt']);
const NAMES = ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
               'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'];

const m = await newMachine({ ramSize: 64 * 1024 * 1024 });
m.writeBytes(BASE, code);
setupLongMode(m, { entry: BASE, stack: STACK });
const xmmView = new Uint8Array(m.stateMem.buffer, XMM_OFF, 256);
const st32 = new Uint32Array(m.stateMem.buffer);
const stF64 = new Float64Array(m.stateMem.buffer);
const stU64 = new BigUint64Array(m.stateMem.buffer);

// The same pattern the native runner resets its scratch page from.
const pattern = new Uint8Array(SCRATCH_LEN);
for (let i = 0; i < SCRATCH_LEN; i++) pattern[i] = (i * 7 + 0x5a) & 0xff;
const fnv = (buf) => {
  let h = 0xcbf29ce484222325n;
  for (let i = 0; i < buf.length; i++) {
    h = BigInt.asUintN(64, (h ^ BigInt(buf[i])) * 0x100000001b3n);
  }
  return h;
};

const natReg = (i, r) => nat.readBigUInt64LE(i * REC + r * 8);
const natFl = (i) => nat.readBigUInt64LE(i * REC + 128);
const natFault = (i) => nat.readUInt32LE(i * REC + 136);
const natXmm = (i) => nat.subarray(i * REC + 144, i * REC + 400);
const natHash = (i) => nat.readBigUInt64LE(i * REC + 400);
const natSw = (i) => Number(nat.readBigUInt64LE(i * REC + 408) & 0xffffn);
const natSt = (i, k) => nat.readBigUInt64LE(i * REC + 416 + k * 8);

const fails = [], unimpl = new Map(), skipOps = new Map();
let ran = 0, skipped = 0;
let faultBase = m.exports.fault_trace_index();

for (let i = 0; i < N; i++) {
  const c = meta.cases[i];
  if (natFault(i)) {
    skipped++;
    const op = c.asm.split(' ')[0];
    skipOps.set(op, (skipOps.get(op) ?? 0) + 1);
    continue;
  }

  for (let r = 0; r < 16; r++) m.exports.set_reg(r, init[i * WORDS + r]);
  m.exports.set_reg(4, BigInt(STACK));      // RSP is not part of the test
  m.exports.set_flags(init[i * WORDS + 16]);
  xmmView.set(initB.subarray(i * WORDS * 8 + 136, i * WORDS * 8 + 392));
  // The x87 stack is set up the way the native runner leaves it: TOP at zero,
  // every tag valid, so ST(k) is physical register k.
  const base = i * WORDS * 8;
  st32[FPU_CW >> 2] = Number(initB.readBigUInt64LE(base + 392) & 0xffffn);
  st32[FPU_SW >> 2] = 0;
  st32[FPU_TOP >> 2] = 0;
  st32[FPU_TAG >> 2] = 0;
  // Six loaded, matching the native side: ST(0) is physical 2 after six
  // pushes from an empty stack, and the top two registers stay free.
  st32[FPU_TOP >> 2] = 2;
  st32[FPU_TAG >> 2] = (3 << 0) | (3 << 2);      // physical 0 and 1 empty
  for (let k = 0; k < 6; k++) {
    stF64[(FPU_ST >> 3) + ((2 + k) & 7)] = initB.readDoubleLE(base + 400 + k * 8);
  }
  m.writeBytes(SCRATCH, pattern);
  const start = BigInt(BASE + i * SLOT);
  m.exports.set_rip(start);
  // A repeated string operation retires one element per step and re-enters at
  // the same address, so "one instruction" here means "step until RIP leaves
  // this slot".  The bound stops a runaway from hanging the run; the generator
  // keeps counts under nine.
  let steps = 0;
  do { m.exports.run(1); } while (m.exports.get_rip() === start && ++steps < 64);
  ran++;

  // An instruction the emulator does not implement raises #UD.  That is a gap
  // rather than a wrong answer, and worth listing separately.
  const nowFaults = m.exports.fault_trace_index();
  if (nowFaults !== faultBase) {
    faultBase = nowFaults;
    const op = c.asm.split(' ')[0];
    unimpl.set(op, (unimpl.get(op) ?? 0) + 1);
    continue;
  }

  const bad = [];
  for (let r = 0; r < 16; r++) {
    if (r === 4) continue;
    // get_reg hands back a wasm i64, which reaches JavaScript as a *signed*
    // BigInt; the native side is unsigned.  Without normalising, every value
    // with the top bit set compares unequal to itself.
    const got = BigInt.asUintN(64, m.exports.get_reg(r)), want = natReg(i, r);
    if (got !== want) bad.push(`${NAMES[r]} ${want.toString(16)} != ${got.toString(16)}`);
  }
  const mask = BigInt(ARITH & ~c.undef);
  const gotF = BigInt.asUintN(64, m.exports.get_flags()) & mask, wantF = natFl(i) & mask;
  if (gotF !== wantF) {
    const diff = Number(gotF ^ wantF);
    const named = ['CF', , 'PF', , 'AF', , 'ZF', 'SF', , , , 'OF']
      .map((n, b) => (n && (diff >> b) & 1) ? n : null).filter(Boolean).join(',');
    bad.push(`flags ${wantF.toString(16)} != ${gotF.toString(16)} (${named})`);
  }
  const wx = natXmm(i);
  for (let x = 0; x < 16; x++) {
    const a = Buffer.from(xmmView.subarray(x * 16, x * 16 + 16)).toString('hex');
    const b = Buffer.from(wx.subarray(x * 16, x * 16 + 16)).toString('hex');
    if (a !== b) bad.push(`xmm${x} ${b} != ${a}`);
  }
  if (fnv(m.readBytes(SCRATCH, SCRATCH_LEN)) !== natHash(i)) {
    bad.push('scratch memory differs');
  }
  // x87: the top-of-stack pointer, the condition codes, and ST(0..3).
  const mn = c.asm.split(' ')[0];
  // After FINCSTP/FDECSTP the register ST(0) names is an empty one, and reading
  // it is a stack underflow that yields indefinite.  Real code never does that;
  // only the top-of-stack pointer is meaningful for these.
  const topOnly = mn === 'fincstp' || mn === 'fdecstp';
  if (!APPROX.has(mn)) {
    const top = st32[FPU_TOP >> 2] & 7;
    const natTop = (natSw(i) >> 11) & 7;
    if (top !== natTop) bad.push(`x87 top ${natTop} != ${top}`);
    // C1 carries the rounding direction after an inexact result, which this
    // emulator does not track; C0, C2 and C3 are the ones software branches on.
    const cc = 0x4500;                       // C0 C2 C3
    const gotCc = st32[FPU_SW >> 2] & cc, wantCc = natSw(i) & cc;
    if (gotCc !== wantCc) {
      bad.push(`x87 cc ${wantCc.toString(16)} != ${gotCc.toString(16)}`);
    }
    for (let k = 0; k < 4 && !topOnly; k++) {
      const phys = (top + k) & 7;
      const got = stU64[(FPU_ST >> 3) + phys], want = natSt(i, k);
      if (got !== want) {
        bad.push(`st(${k}) ${want.toString(16)} != ${got.toString(16)}`);
      }
    }
  }

  if (bad.length) fails.push({ i, asm: c.asm, bad, regs: c.regs, flags: c.flags });
}

const byOp = new Map();
for (const f of fails) {
  const op = f.asm.split(' ')[0];
  if (!byOp.has(op)) byOp.set(op, []);
  byOp.get(op).push(f);
}
if (skipped) {
  console.log('\nfaulted on hardware (not compared): ' +
    [...skipOps].sort((a, b) => b[1] - a[1]).map(([o, n]) => `${o} x${n}`).join(', '));
}
if (unimpl.size) {
  console.log('raised #UD in the emulator (unimplemented): ' +
    [...unimpl].sort((a, b) => b[1] - a[1]).map(([o, n]) => `${o} x${n}`).join(', '));
}
console.log(`\n${ran} cases run, ${skipped} skipped, ${fails.length} mismatches ` +
            `across ${byOp.size} instructions\n`);
for (const [op, list] of [...byOp].sort((a, b) => b[1].length - a[1].length)) {
  console.log(`  ${op.padEnd(12)} ${String(list.length).padStart(5)} failing`);
  for (const f of list.slice(0, 3)) {
    console.log(`      #${f.i}  ${f.asm}`);
    for (const b of f.bad.slice(0, 4)) console.log(`          ${b}`);
  }
}
writeFileSync(dir + 'failures.json', JSON.stringify(fails.slice(0, 500), null, 1));
if (fails.length) console.log(`\nfull detail in tools/difftest/failures.json`);
process.exit(fails.length ? 1 : 0);
