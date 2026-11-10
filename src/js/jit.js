// A JIT for the interpreter: x86 basic blocks compiled to WebAssembly.
//
// The core counts how often each branch target is reached and publishes the
// hot ones; this compiles a run of instructions starting there into a wasm
// function and hands it back through the shared table.  From then on the core
// reaches that run with a single call_indirect.
//
// BLOCKS ARE PHYSICAL
//   A block is keyed on the physical address of its first byte and on what
//   decides how those bytes behave (mode, virtual-8086, stack width).  RIP is
//   computed relative to wherever the block was entered, so the same code
//   reached through another mapping or CS base runs unchanged, and a CR3 load
//   -- every task switch -- costs nothing.  A store to a page with compiled
//   code on it bumps that page's generation in the core, which retires every
//   block built from it.
//
// ANY INSTRUCTION CAN BE IN A BLOCK
//   Instructions this file knows how to compile are emitted inline.  Anything
//   else it can still measure is executed in place by the interpreter (j_step),
//   after which the block checks that execution went where it expected and
//   carries on.  Only bytes it cannot even decode the length of end a block.
//   That makes an unsupported opcode a few nanoseconds lost rather than the end
//   of compilation, and the set below can grow one instruction at a time.
//
// FLAGS ARE DEFERRED
//   An arithmetic instruction leaves its operands in locals instead of
//   computing six flags.  Most of those are overwritten by the next
//   instruction before anything reads them; a conditional branch usually reads
//   its condition straight from the operands (a CMP/JL is a signed compare).
//   Flags are only produced when they have to exist: at a block exit, before
//   the interpreter runs an instruction, and on the way out of a fault, where
//   they must be exactly what they were before the faulting instruction.
//
// MEMORY IS INLINE
//   Every access does the segment limit check and a lookup in the JIT TLB --
//   the translation cache the interpreter shares -- in a few wasm instructions,
//   and only calls into the core on a miss.  A write entry never exists for a
//   page with compiled code on it, so a store that could modify code always
//   takes the slow path, where the core notices.
import { buildModule, Func, I32, I64 } from './wasm_emit.js';

// Helper functions the generated code calls, in the order it indexes them.
const HELPERS = [
  { name: 'j_step', params: [], results: [I32] },
  { name: 'j_rd', params: [I32, I64, I32], results: [I64] },
  { name: 'j_wr', params: [I32, I64, I32, I64], results: [I32] },
  { name: 'j_lrd', params: [I64, I32], results: [I64] },
  { name: 'j_lwr', params: [I64, I32, I64], results: [I32] },
  { name: 'j_flags', params: [I32, I64, I64, I32], results: [] },
  { name: 'j_cond', params: [I32], results: [I32] },
  { name: 'j_alu', params: [I32, I64, I64, I32], results: [I64] },
  { name: 'j_shift', params: [I32, I64, I32, I32], results: [I64] },
];
const H = Object.fromEntries(HELPERS.map((h, i) => [h.name, i]));

// Imported globals, in index order.
const GLOBALS = [
  ['g_rip', I64], ['g_rip0', I64], ['g_rsp0', I64], ['g_fault', I32], ['g_flags', I64],
  ['g_tsc', I64], ['g_exit', I32], ['g_budget', I32], ['g_tlbbits', I32],
];
const G = Object.fromEntries(GLOBALS.map(([n], i) => [n, i]));

// State block layout (see parts 00 and 85 of the core).
const SEG_BASE = (s) => 0x100 + s * 32 + 8;
const SEG_FASTLIM = (s) => 0x1c0 + s * 8;
const JTLB_R = 0x10000;
const JTLB_W = 0x20000;
const IRQ_LINE = 0xd8;
const RSP = 4;

const ES = 0, CS = 1, SS = 2, DS = 3, FS = 4, GS = 5;
const LINEAR = -1;                 // a long mode stack access: no segment at all

// Deferred flag producers, numbered as j_flags expects them.
const F_NONE = 0, F_ADD = 1, F_SUB = 2, F_LOGIC = 3, F_INC = 4, F_DEC = 5;

const DISABLED = new Set(
  (globalThis.process?.env?.X64EMU_JIT_OFF ?? '').split(',').filter(Boolean));

const MAX_INSTRS = 96;
// Blocks kept before everything is thrown away and compilation starts over.
// Each is a function in a module V8 keeps alive; this bounds the memory.
const MAX_BLOCKS = 60000;

/** Thrown to stop a block before an instruction that cannot be measured. */
class Unsupported extends Error {}

// ---------------------------------------------------------------------------
//  Instruction lengths
// ---------------------------------------------------------------------------
//  For every opcode: whether a ModRM byte follows and what immediate does.
//  This is all the decoder needs to step over an instruction it hands to the
//  interpreter.  null means "cannot measure": the block ends before it.
const IB = 1, IW = 2, IZ = 3, IV = 4, IMOFFS = 5, IFAR = 6, IENTER = 7, IGRP3 = 8;
const ONE = new Array(256).fill(null);
const TWO = new Array(256).fill(null);
const def = (table, ops, modrm, imm = 0) => { for (const o of ops) table[o] = { modrm, imm }; };
const range = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => a + i);

for (let x = 0; x < 8; x++) {
  def(ONE, [x * 8, x * 8 + 1, x * 8 + 2, x * 8 + 3], true);
  def(ONE, [x * 8 + 4], false, IB);
  def(ONE, [x * 8 + 5], false, IZ);
}
def(ONE, [0x06, 0x07, 0x0e, 0x16, 0x17, 0x1e, 0x1f, 0x27, 0x2f, 0x37, 0x3f], false);
def(ONE, range(0x40, 0x5f), false);
def(ONE, [0x60, 0x61], false);
def(ONE, [0x62, 0x63], true);
def(ONE, [0x68], false, IZ);
def(ONE, [0x69], true, IZ);
def(ONE, [0x6a], false, IB);
def(ONE, [0x6b], true, IB);
def(ONE, range(0x6c, 0x6f), false);
def(ONE, range(0x70, 0x7f), false, IB);
def(ONE, [0x80, 0x82, 0x83], true, IB);
def(ONE, [0x81], true, IZ);
def(ONE, range(0x84, 0x8f), true);
def(ONE, range(0x90, 0x99), false);
def(ONE, [0x9a], false, IFAR);
def(ONE, range(0x9b, 0x9f), false);
def(ONE, range(0xa0, 0xa3), false, IMOFFS);
def(ONE, range(0xa4, 0xa7), false);
def(ONE, [0xa8], false, IB);
def(ONE, [0xa9], false, IZ);
def(ONE, range(0xaa, 0xaf), false);
def(ONE, range(0xb0, 0xb7), false, IB);
def(ONE, range(0xb8, 0xbf), false, IV);
def(ONE, [0xc0, 0xc1], true, IB);
def(ONE, [0xc2, 0xca], false, IW);
def(ONE, [0xc3, 0xc9, 0xcb, 0xcc, 0xce, 0xcf], false);
def(ONE, [0xc4, 0xc5], true);
def(ONE, [0xc6], true, IB);
def(ONE, [0xc7], true, IZ);
def(ONE, [0xc8], false, IENTER);
def(ONE, [0xcd, 0xd4, 0xd5], false, IB);
def(ONE, range(0xd0, 0xd3), true);
def(ONE, [0xd6, 0xd7], false);
def(ONE, range(0xd8, 0xdf), true);
def(ONE, range(0xe0, 0xe7), false, IB);
def(ONE, [0xe8, 0xe9], false, IZ);
def(ONE, [0xea], false, IFAR);
def(ONE, [0xeb], false, IB);
def(ONE, range(0xec, 0xef), false);
def(ONE, [0xf1, 0xf4, 0xf5], false);
def(ONE, [0xf6, 0xf7], true, IGRP3);
def(ONE, range(0xf8, 0xfd), false);
def(ONE, [0xfe, 0xff], true);

def(TWO, [0x00, 0x01, 0x02, 0x03, 0x0d], true);
def(TWO, [0x05, 0x06, 0x07, 0x08, 0x09, 0x0b], false);
def(TWO, range(0x10, 0x17), true);
def(TWO, range(0x18, 0x1f), true);
def(TWO, range(0x20, 0x23), true);
def(TWO, range(0x28, 0x2f), true);
def(TWO, range(0x30, 0x35), false);
def(TWO, range(0x40, 0x4f), true);
def(TWO, range(0x50, 0x6f), true);
def(TWO, range(0x70, 0x73), true, IB);
def(TWO, range(0x74, 0x76), true);
def(TWO, [0x77], false);
def(TWO, [0x7e, 0x7f], true);
def(TWO, range(0x80, 0x8f), false, IZ);
def(TWO, range(0x90, 0x9f), true);
def(TWO, [0xa0, 0xa1, 0xa2, 0xa8, 0xa9, 0xaa], false);
def(TWO, [0xa3, 0xa5, 0xab, 0xad, 0xae, 0xaf], true);
def(TWO, [0xa4, 0xac], true, IB);
def(TWO, range(0xb0, 0xb9), true);
def(TWO, [0xba], true, IB);
def(TWO, range(0xbb, 0xc1), true);
def(TWO, [0xc2, 0xc4, 0xc5, 0xc6], true, IB);
def(TWO, [0xc3, 0xc7], true);
def(TWO, range(0xc8, 0xcf), false);
def(TWO, range(0xd0, 0xff), true);

// Instructions that leave the block when the interpreter runs them, so there
// is no point decoding past them.
const ENDS_ONE = new Set([0x9a, 0xc2, 0xc3, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf, 0xea, 0xe0,
                          0xe1, 0xe2, 0xe3, 0xe8, 0xe9, 0xeb, 0xf4, 0x9d, 0xfb]);
const ENDS_TWO = new Set([0x05, 0x07, 0x34, 0x35, 0x00, 0x01, 0x22, 0x30, 0xa1, 0xa9]);

// ---------------------------------------------------------------------------
//  Decoding
// ---------------------------------------------------------------------------
//  Operand and address defaults follow the mode as $cache_mode_defaults sets
//  them: 16-bit code defaults to 2/2, 32-bit protected to 4/4, long mode 4/8.
const DEFAULTS = {
  0: { defOp: 2, defAddr: 2 },
  1: { defOp: 2, defAddr: 2 },
  2: { defOp: 4, defAddr: 4 },
  3: { defOp: 4, defAddr: 8 },
};

class Decoder {
  constructor(u8, start, end, ctx) {
    this.u8 = u8;
    this.p = start;
    this.end = end;           // first byte past the page
    this.ctx = ctx;
  }

  byte() {
    if (this.p >= this.end) throw new Unsupported('page');
    return this.u8[this.p++];
  }

  /** Little-endian immediate, sign-extended to a 64-bit BigInt. */
  simm(n) {
    let v = 0n;
    for (let i = 0; i < n; i++) v |= BigInt(this.byte()) << BigInt(i * 8);
    return BigInt.asIntN(n * 8, v);
  }

  modrm(ins) {
    const ctx = this.ctx;
    const b = this.byte();
    const mod = b >> 6, rmLow = b & 7, ext = (b >> 3) & 7;
    const rex = ins.rex;
    const m = { mod, ext, reg: ext | (((rex >> 2) & 1) << 3), mem: mod !== 3 };
    if (mod === 3) {
      m.rm = rmLow | ((rex & 1) << 3);
      return m;
    }
    if (ins.addrsize === 2) {
      // The 16-bit forms: seven fixed register pairs, BP-based ones on SS.
      const FORMS = [[3, 6, DS], [3, 7, DS], [5, 6, SS], [5, 7, SS],
                     [6, -1, DS], [7, -1, DS], [5, -1, SS], [3, -1, DS]];
      let [base, index, seg] = FORMS[rmLow];
      let disp = 0n;
      if (rmLow === 6 && mod === 0) { base = -1; seg = DS; disp = this.simm(2); }
      if (mod === 1) disp += this.simm(1);
      if (mod === 2) disp += this.simm(2);
      Object.assign(m, { base, index, scale: 0, disp, seg, riprel: false, a16: true });
      return m;
    }
    let base = -1, index = -1, scale = 0, disp = 0n, seg = DS, riprel = false;
    if (rmLow === 4) {
      const sib = this.byte();
      scale = sib >> 6;
      const idx = ((sib >> 3) & 7) | (((rex >> 1) & 1) << 3);
      if (idx !== 4) index = idx;
      if ((sib & 7) === 5 && mod === 0) {
        disp = this.simm(4);
      } else {
        base = (sib & 7) | ((rex & 1) << 3);
        if ((base & 7) === 4 || (base & 7) === 5) seg = SS;
      }
    } else if (rmLow === 5 && mod === 0) {
      disp = this.simm(4);
      if (ctx.mode === 3) riprel = true;
    } else {
      base = rmLow | ((rex & 1) << 3);
      if (rmLow === 5) seg = SS;
    }
    if (mod === 1) disp += this.simm(1);
    if (mod === 2) disp += this.simm(4);
    Object.assign(m, { base, index, scale, disp, seg, riprel, a16: false });
    return m;
  }

  /** Decode one instruction; throws Unsupported if it cannot be measured. */
  one() {
    const ctx = this.ctx;
    const start = this.p;
    const long = ctx.mode === 3;
    let rex = 0, op66 = false, seg = -1, rep = 0, lock = false;
    let opsize = ctx.defOp, addrsize = ctx.defAddr;
    let b;
    for (;;) {
      b = this.byte();
      if (long && (b & 0xf0) === 0x40) { rex = b; if (b & 8) opsize = 8; continue; }
      if (b === 0x66) { rex = 0; op66 = true; if (opsize !== 8) opsize = ctx.defOp === 2 ? 4 : 2; continue; }
      if (b === 0x67) { rex = 0; addrsize = long ? 4 : (ctx.defAddr === 2 ? 4 : 2); continue; }
      if (b === 0x26) { rex = 0; seg = ES; continue; }
      if (b === 0x2e) { rex = 0; seg = CS; continue; }
      if (b === 0x36) { rex = 0; seg = SS; continue; }
      if (b === 0x3e) { rex = 0; seg = DS; continue; }
      if (b === 0x64) { rex = 0; seg = FS; continue; }
      if (b === 0x65) { rex = 0; seg = GS; continue; }
      if (b === 0xf0) { rex = 0; lock = true; continue; }
      if (b === 0xf2) { rex = 0; rep = 2; continue; }
      if (b === 0xf3) { rex = 0; rep = 3; continue; }
      break;
    }
    if (this.p - start > 14) throw new Unsupported('prefixes');
    // In 64-bit mode only FS and GS overrides mean anything.
    if (long && seg >= 0 && seg < FS) seg = -1;

    let two = false, op = b;
    if (b === 0x0f) { two = true; op = this.byte(); }
    const fmt = (two ? TWO : ONE)[op];
    if (!fmt) throw new Unsupported(`opcode ${two ? '0f ' : ''}${op.toString(16)}`);
    // VEX in long mode, and the three-byte maps, are not implemented by the
    // interpreter either.
    if (!two && long && (op === 0xc4 || op === 0xc5)) throw new Unsupported('vex');

    const ins = { start, two, op, rex, op66, seg, rep, lock, opsize, addrsize, long,
                  d64: long ? (op66 ? 2 : 8) : opsize };
    if (fmt.modrm) ins.m = this.modrm(ins);
    const zsize = opsize === 2 ? 2 : 4;
    switch (fmt.imm) {
      case IB: ins.imm = this.simm(1); break;
      case IW: ins.imm = this.simm(2); break;
      case IZ: ins.imm = this.simm(zsize); break;
      case IV: ins.imm = opsize === 8 ? this.simm(8) : this.simm(opsize); break;
      case IMOFFS: ins.imm = BigInt.asUintN(addrsize * 8, this.simm(addrsize)); break;
      case IFAR: ins.imm = this.simm(zsize); ins.imm2 = this.simm(2); break;
      case IENTER: ins.imm = this.simm(2); ins.imm2 = this.simm(1); break;
      case IGRP3:
        if (ins.m.ext < 2) ins.imm = this.simm(op === 0xf6 ? 1 : zsize);
        break;
      default: break;
    }
    ins.len = this.p - start;
    return ins;
  }
}

// ---------------------------------------------------------------------------
//  The compiler
// ---------------------------------------------------------------------------
export class Jit {
  /**
   * @param {Machine} machine
   * @param {{maxInstrs?: number}} opts  maxInstrs: 1 compiles one instruction
   *   per block, which is how the hardware-checked instruction tests run each
   *   case through compiled code
   */
  constructor(machine, opts = {}) {
    this.m = machine;
    this.maxInstrs = opts.maxInstrs ?? MAX_INSTRS;
    this.slots = 0;              // next free index in the shared table
    this.compiled = 0;           // blocks compiled
    this.reinstalled = 0;
    this.rejected = 0;
    this.instrs = 0;             // guest instructions covered by compiled code
    this.interpInstrs = 0;       // ... of which the interpreter runs in place
    this.modules = 0;
    this.resets = 0;
    this.reasons = new Map();
    this.lastDrained = 0;
    this.known = new Map();      // `${pa}:${kg}` -> { slot, regions, ranges }
    // Per physical page, the exact bytes compiled instructions occupy, for the
    // generation they were compiled at: {gen, bits: one bit per byte}.
    this.codeBytes = new Map();
    machine.jitPrecise = (pa, len) => this.precise(pa, len);
  }

  /** Does a store of `len` bytes at `pa` touch compiled instructions? */
  precise(pa, len) {
    const page = Math.floor(pa / 4096);
    const e = this.codeBytes.get(page);
    if (!e || e.gen !== this.m.exports.jit_page_gen(BigInt(pa))) return 1;
    const off = pa - page * 4096;
    for (let i = off; i < Math.min(off + len, 4096); i++) {
      if (e.bits[i >> 3] & (1 << (i & 7))) return 1;
    }
    return 0;
  }

  /** Record the bytes a block's instructions occupy, at generation `gen`. */
  markBytes(pa, gen, ranges) {
    const page = Math.floor(pa / 4096);
    let e = this.codeBytes.get(page);
    if (!e || e.gen !== gen) {
      e = { gen, bits: new Uint8Array(512) };
      this.codeBytes.set(page, e);
    }
    for (const [off, len] of ranges) {
      for (let i = off; i < Math.min(off + len, 4096); i++) e.bits[i >> 3] |= 1 << (i & 7);
    }
  }

  /** Compile everything the core has flagged as hot since the last call. */
  drain() {
    const x = this.m.exports;
    const total = x.jit_hot_count();
    if (total === this.lastDrained) return 0;
    // The ring holds the most recent 4096; anything older than that was
    // overwritten before it could be drained, and is lost.
    const first = Math.max(this.lastDrained, total - 4096);
    this.lastDrained = total;
    // The ring entries stay readable through a reset, which only rewinds the
    // core's index -- so rewind ours to match, or nothing would be drained
    // again until the core had counted back up past where this left off.
    if (this.slots >= MAX_BLOCKS) { this.resetAll(); this.lastDrained = 0; }

    const plans = [];
    const seen = new Set();
    for (let i = first; i < total; i++) {
      const pa = Number(x.jit_hot_pa(i));
      const kg = x.jit_hot_kg(i);
      const key = `${pa}:${kg}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const known = this.known.get(key);
      if (known !== undefined) {
        if (x.jit_install(BigInt(pa), kg, known.slot, ...known.regions)) {
          this.markBytes(pa, kg >>> 8, known.ranges);
          this.reinstalled++;
        }
        continue;
      }
      const plan = this.plan(pa, kg);
      if (plan) plans.push(plan);
    }
    if (plans.length) this.build(plans);
    x.jit_commit();
    return plans.length;
  }

  /**
   * A relative branch whose target can be placed at compile time.  16-bit
   * code wraps IP at 64 KiB, and where that happens depends on the IP the
   * block is entered at, which is only known at run time.
   */
  noWrap(ins, ctx) {
    return ctx.mode === 3 || ins.opsize === 4;
  }

  /**
   * Compile and install the block at physical address `pa` for the key the
   * CPU is in right now, without waiting for it to get hot.  Returns false if
   * nothing there could be compiled.
   */
  compileNow(pa) {
    const x = this.m.exports;
    const key = x.jit_current_key();
    const kg = (key | (x.jit_page_gen(BigInt(pa)) << 8)) >>> 0;
    const plan = this.plan(pa, kg);
    if (!plan) return false;
    this.build([plan]);
    x.jit_commit();
    return true;
  }

  /** Throw every compiled block away and start again. */
  resetAll() {
    this.m.exports.jit_reset();
    const t = this.m.jitTable;
    for (let i = 0; i < Math.min(this.slots, t.length); i++) t.set(i, null);
    this.slots = 0;
    this.known.clear();
    this.codeBytes.clear();
    this.resets++;
  }

  reject(reason) {
    this.rejected++;
    this.reasons.set(reason, (this.reasons.get(reason) ?? 0) + 1);
    return null;
  }

  plan(pa, kg) {
    const key = kg & 0xff;
    const mode = key & 3;
    const ctx = { mode, long: mode === 3, vm: (key >> 2) & 1, ss32: (key >> 3) & 1,
                  ...DEFAULTS[mode] };
    const u8 = this.m.u8;
    if (pa + 16 > u8.length) return this.reject('not RAM');
    const page = Math.floor(pa / 4096) * 4096;
    const d = new Decoder(u8, pa, page + 4096, ctx);
    const instrs = [];
    const visited = new Set();
    while (instrs.length < this.maxInstrs) {
      let ins;
      if (visited.has(d.p)) break;
      try {
        ins = d.one();
      } catch (err) {
        if (!(err instanceof Unsupported)) throw err;
        if (!instrs.length) return this.reject(err.message);
        break;
      }
      visited.add(ins.start);
      ins.at = ins.start - pa;
      ins.next = ins.at + ins.len;
      classify(ins, ctx);
      instrs.push(ins);
      // A branch back to the block's own entry becomes a loop.
      if ((ins.kind === 'jcc' || ins.kind === 'jmp' || ins.kind === 'loop') &&
          ins.next + Number(ins.imm) === 0 && !DISABLED.has('loops')) {
        ins.backEdge = true;
      }
      // A conditional branch is a side exit: the taken path leaves, and the
      // block carries on down the fall-through path.  That doubles the length
      // of a typical block, and every block entered is a dispatch saved.
      if (ins.kind === 'jcc' && instrs.length < this.maxInstrs - 1 && !DISABLED.has('sideexit')) {
        ins.ends = false;
        ins.sideExit = true;
        continue;
      }
      // An unconditional jump within the page is simply followed.
      if (ins.kind === 'jmp' && !ins.backEdge && this.noWrap(ins, ctx) && !DISABLED.has('follow')) {
        const target = ins.start + ins.len + Number(ins.imm);
        if (target >= page && target < page + 4096 && !visited.has(target)) {
          ins.kind = 'follow';
          ins.ends = false;
          // What comes next is the target, not the bytes after the jump.  If
          // the block ends right here -- the target does not decode, or the
          // block is full -- it must leave for the target.
          ins.next = target - pa;
          d.p = target;
          continue;
        }
      }
      if (ins.ends) break;
    }
    // A block the interpreter would run every instruction of is only overhead.
    if (!instrs.some((ins) => ins.kind !== 'interp')) return this.reject('nothing compiled');
    return { pa, kg, ctx, instrs };
  }

  build(plans) {
    const funcs = plans.map((p, i) => ({ name: `b${i}`, fn: new Block(p).emit() }));
    const bytes = buildModule({
      memories: [{ module: 'env', name: 'state', min: 0 },
                 { module: 'env', name: 'ram', min: 0, index64: true }],
      globals: GLOBALS.map(([name, type]) => ({ module: 'env', name, type, mutable: true })),
      imports: HELPERS.map((h) => ({ module: 'env', ...h })),
      funcs,
    });
    const x = this.m.exports;
    let inst;
    try {
      inst = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
        env: {
          state: this.m.stateMem,
          ram: this.m.memory,
          ...Object.fromEntries(GLOBALS.map(([n]) => [n, x[n]])),
          ...Object.fromEntries(HELPERS.map((h) => [h.name, x[h.name]])),
        },
      });
    } catch (err) {
      // A module that will not compile is a bug in this file, not in the
      // guest, and silently interpreting instead would hide it.
      throw new Error(`JIT produced an invalid module: ${err.message}`);
    }
    this.modules++;
    const t = this.m.jitTable;
    if (this.slots + plans.length > t.length) {
      t.grow(Math.max(plans.length, Math.min(4096, t.length)));
    }
    plans.forEach((p, i) => {
      const slot = this.slots++;
      t.set(slot, inst.exports[`b${i}`]);
      // The 16-byte regions of the page the block's instructions occupy, as
      // four 64-bit masks: a store anywhere else on the page leaves it alone.
      const page = Math.floor(p.pa / 4096) * 4096;
      const regions = [0n, 0n, 0n, 0n];
      const ranges = [];
      for (const ins of p.instrs) {
        const first = (ins.start - page) >> 4, last = (ins.start - page + ins.len - 1) >> 4;
        for (let r = first; r <= Math.min(last, 255); r++) regions[r >> 6] |= 1n << BigInt(r & 63);
        ranges.push([ins.start - page, ins.len]);
      }
      const signed = regions.map((v) => BigInt.asIntN(64, v));
      this.known.set(`${p.pa}:${p.kg}`, { slot, regions: signed, ranges });
      if (x.jit_install(BigInt(p.pa), p.kg, slot, ...signed)) this.markBytes(p.pa, p.kg >>> 8, ranges);
      this.compiled++;
      this.instrs += p.instrs.length;
      this.interpInstrs += p.instrs.filter((ins) => ins.kind === 'interp').length;
    });
  }

  stats() {
    const x = this.m.exports;
    return {
      compiled: this.compiled, reinstalled: this.reinstalled, rejected: this.rejected,
      modules: this.modules, resets: this.resets,
      instrs: this.instrs, interpInstrs: this.interpInstrs,
      lookups: x.jit_lookup_count(), hits: x.jit_hit_count(),
      invalidations: x.jit_inval_count(),
      blocksRun: Number(x.jit_blocks_run()), instrsRun: Number(x.jit_instrs_run()),
    };
  }
}

/**
 * Decide how each instruction will be emitted.  Anything not recognised here
 * runs in the interpreter, in place; `ends` marks instructions after which
 * decoding stops because control goes elsewhere.
 */
function classify(ins, ctx) {
  const { op, two, m } = ins;
  ins.kind = 'interp';
  const plain = !ins.lock;
  if (!two) {
    if (op < 0x40 && (op & 7) < 6 && plain && !ins.rep) {
      ins.kind = (op & 7) < 4 ? 'alu_rm' : 'alu_ai';
      ins.aluop = (op >> 3) & 7;
      ins.size = (op & 1) ? ins.opsize : 1;
    } else if ((op === 0x80 || op === 0x81 || op === 0x83) && plain && !ins.rep) {
      ins.kind = 'alu_mi'; ins.aluop = m.ext; ins.size = op === 0x80 ? 1 : ins.opsize;
    } else if ((op === 0x84 || op === 0x85) && !ins.rep) {
      ins.kind = 'test_rm'; ins.size = op === 0x84 ? 1 : ins.opsize;
    } else if ((op === 0xa8 || op === 0xa9) && !ins.rep) {
      ins.kind = 'test_ai'; ins.size = op === 0xa8 ? 1 : ins.opsize;
    } else if (op >= 0x88 && op <= 0x8b && plain && !ins.rep) {
      ins.kind = 'mov'; ins.size = (op & 1) ? ins.opsize : 1;
    } else if (op === 0x8c && plain && !ins.rep && m.ext <= 5) {
      ins.kind = 'mov_from_seg';
    } else if (op === 0x8d && m.mem && !ins.rep) {
      ins.kind = 'lea';
    } else if (op >= 0xb0 && op <= 0xbf && !ins.rep) {
      ins.kind = 'mov_ri';
      ins.size = op < 0xb8 ? 1 : ins.opsize;
      ins.reg = (op & 7) | ((ins.rex & 1) << 3);
    } else if ((op === 0xc6 || op === 0xc7) && m.ext === 0 && plain && !ins.rep) {
      ins.kind = 'mov_mi'; ins.size = op === 0xc6 ? 1 : ins.opsize;
    } else if (op >= 0xa0 && op <= 0xa3 && plain && !ins.rep) {
      ins.kind = 'mov_moffs'; ins.size = (op & 1) ? ins.opsize : 1;
    } else if (op >= 0x40 && op <= 0x4f && !ctx.long && !ins.rep) {
      ins.kind = 'incdec_r'; ins.reg = op & 7; ins.dec = op >= 0x48; ins.size = ins.opsize;
    } else if ((op === 0xfe || op === 0xff) && m.ext <= 1 && plain && !ins.rep) {
      ins.kind = 'incdec_rm'; ins.dec = m.ext === 1; ins.size = op === 0xfe ? 1 : ins.opsize;
    } else if ((op === 0xf6 || op === 0xf7) && m.ext <= 3 && plain && !ins.rep) {
      ins.size = op === 0xf6 ? 1 : ins.opsize;
      ins.kind = m.ext < 2 ? 'test_mi' : m.ext === 2 ? 'not' : 'neg';
    } else if (op >= 0x50 && op <= 0x57 && !ins.rep) {
      ins.kind = 'push_r'; ins.reg = (op & 7) | ((ins.rex & 1) << 3);
    } else if (op >= 0x58 && op <= 0x5f && !ins.rep) {
      ins.kind = 'pop_r'; ins.reg = (op & 7) | ((ins.rex & 1) << 3);
    } else if ((op === 0x68 || op === 0x6a) && !ins.rep) {
      ins.kind = 'push_imm';
    } else if ((op === 0x60 || op === 0x61) && !ctx.long && !ins.rep && !ins.lock) {
      ins.kind = op === 0x60 ? 'pusha' : 'popa';
    } else if (op === 0x9c && !ctx.vm && !ins.rep && !ins.lock) {
      ins.kind = 'pushf';
    } else if (op === 0x9d && !ctx.vm && !ins.rep && !ins.lock) {
      ins.kind = 'popf'; ins.ends = true;
    } else if ((op === 0xfa || op === 0xfb) && !ins.rep && !ins.lock) {
      ins.kind = op === 0xfa ? 'cli' : 'sti';
      ins.ends = op === 0xfb;
    } else if ([0x06, 0x0e, 0x16, 0x1e].includes(op) && !ctx.long && !ins.rep && !ins.lock) {
      ins.kind = 'push_seg'; ins.sreg = op >> 3;
    } else if (op === 0xff && m.ext === 6 && plain && !ins.rep) {
      ins.kind = 'push_rm';
    } else if (op >= 0x70 && op <= 0x7f) {
      ins.kind = 'jcc'; ins.cc = op & 15; ins.ends = true;
    } else if (op === 0xeb || op === 0xe9) {
      ins.kind = 'jmp'; ins.ends = true;
    } else if (op === 0xe8) {
      ins.kind = 'call'; ins.ends = true;
    } else if ((op === 0xc3 || op === 0xc2) && !ins.lock) {
      ins.kind = 'ret'; ins.ends = true;
    } else if (op === 0xff && (m.ext === 2 || m.ext === 4) && plain) {
      ins.kind = m.ext === 2 ? 'call_rm' : 'jmp_rm'; ins.ends = true;
    } else if ((op === 0xe2 || op === 0xe3) && !ins.rep) {
      ins.kind = op === 0xe2 ? 'loop' : 'jcxz'; ins.ends = true;
    } else if ((op === 0x86 || op === 0x87) && !ins.rep) {
      ins.kind = 'xchg'; ins.size = op === 0x86 ? 1 : ins.opsize;
    } else if (op >= 0x90 && op <= 0x97 && !ins.lock) {
      const r = (op & 7) | ((ins.rex & 1) << 3);
      ins.kind = r === 0 ? 'nop' : 'xchg_ax';
      ins.reg = r;
    } else if (op === 0x98 && !ins.rep) {
      ins.kind = 'cbw';
    } else if (op === 0x99 && !ins.rep) {
      ins.kind = 'cwd';
    } else if ([0xf5, 0xf8, 0xf9, 0xfc, 0xfd].includes(op) && !ins.rep) {
      ins.kind = 'flagop';
    } else if ((op === 0xc0 || op === 0xc1 || (op >= 0xd0 && op <= 0xd3)) && plain && !ins.rep) {
      ins.kind = 'shift'; ins.size = (op & 1) ? ins.opsize : 1;
    } else if (ENDS_ONE.has(op)) {
      ins.ends = true;
    }
  } else {
    if ((op === 0xb6 || op === 0xb7 || op === 0xbe || op === 0xbf) && plain && !ins.rep) {
      ins.kind = op < 0xb8 ? 'movzx' : 'movsx';
      ins.srcSize = (op & 1) ? 2 : 1;
    } else if (op >= 0x80 && op <= 0x8f) {
      ins.kind = 'jcc'; ins.cc = op & 15; ins.ends = true;
    } else if (op >= 0x90 && op <= 0x9f && plain && !ins.rep) {
      ins.kind = 'setcc'; ins.cc = op & 15;
    } else if (op >= 0x40 && op <= 0x4f && plain && !ins.rep) {
      ins.kind = 'cmov'; ins.cc = op & 15;
    } else if ((op === 0xa0 || op === 0xa8) && !ins.rep && !ins.lock) {
      ins.kind = 'push_seg'; ins.sreg = op === 0xa0 ? FS : GS;
    } else if (ENDS_TWO.has(op)) {
      ins.ends = true;
    }
  }
  if (!two && op === 0x63 && ctx.long && ins.kind === 'interp') {
    // MOVSXD: handled by the interpreter for now
  }
  // For narrowing down a miscompilation: X64EMU_JIT_OFF=pusha,popf hands those
  // kinds to the interpreter.
  if (DISABLED.has(ins.kind)) { ins.kind = 'interp'; }
  // Repeated string instructions iterate in the interpreter, but inside the
  // block: it keeps calling back until the count runs out.
  if (ins.kind === 'interp' && ins.rep && !two &&
      ((op >= 0xa4 && op <= 0xa7) || (op >= 0xaa && op <= 0xaf) ||
       (op >= 0x6c && op <= 0x6f))) {
    ins.repLoop = true;
  }
}

// ---------------------------------------------------------------------------
//  Code generation for one block
// ---------------------------------------------------------------------------
class Block {
  constructor(plan) {
    this.plan = plan;
    this.ctx = plan.ctx;
    this.long = plan.ctx.mode === 3;
    this.f = new Func([], [I32], []);
    const f = this.f;
    const L = (t) => f.addLocal(t);
    this.BASE = L(I64);
    this.COUNT = L(I32);
    this.SYNCED = L(I32);
    this.FA = L(I64); this.FB = L(I64); this.FR = L(I64);
    this.RIP0D = L(I64);
    this.EA = L(I64); this.LA = L(I64); this.SLOT = L(I32);
    this.V = L(I64); this.A = L(I64); this.B = L(I64); this.R = L(I64);
    this.ST = L(I32); this.EXITF = L(I32); this.SP = L(I64); this.T = L(I64);
    this.pend = { kind: F_NONE, size: 4 };
    this.slowStore = false;
  }

  // ---- small pieces ---------------------------------------------------------
  maskRip() { if (!this.long) this.f.i64const(0xffffffff).i64and(); }

  /** Push BASE + delta, masked as RIP is. */
  ripAt(delta) {
    const f = this.f;
    f.localGet(this.BASE);
    if (delta) f.i64const(delta).i64add();
    this.maskRip();
  }

  syncTsc() {
    const f = this.f;
    f.globalGet(G.g_tsc).localGet(this.COUNT).localGet(this.SYNCED).i32sub()
      .i64extendI32u().i64add().globalSet(G.g_tsc);
    f.localGet(this.COUNT).localSet(this.SYNCED);
  }

  /** Emit code producing the deferred flags; the state is left as it is. */
  emitFlags() {
    const f = this.f;
    if (this.pend.kind === F_NONE) return;
    f.i32const(this.pend.kind).localGet(this.FA).localGet(this.FB).i32const(this.pend.size)
      .call(H.j_flags);
  }

  /** Produce the deferred flags and forget them. */
  materialize() {
    this.emitFlags();
    this.pend = { kind: F_NONE, size: 4 };
  }

  setPending(kind, size, a, b, r) {
    const f = this.f;
    if (a !== undefined) f.localGet(a).localSet(this.FA);
    if (b !== undefined) f.localGet(b).localSet(this.FB);
    if (r !== undefined) f.localGet(r).localSet(this.FR);
    this.pend = { kind, size };
  }

  /** Leave the block normally: flags produced, RIP already set by the caller. */
  leave() {
    const f = this.f;
    this.emitFlags();
    this.syncTsc();
    f.localGet(this.COUNT).return_();
  }

  leaveAt(delta) {
    this.ripAt(delta);
    this.f.globalSet(G.g_rip);
    this.leave();
  }

  /** The current instruction faulted: report it the way the interpreter does. */
  faultExit(ins) {
    const f = this.f;
    this.emitFlags();
    f.i64const(ins.at).localSet(this.RIP0D);
    f.brTo(this.fexit);
  }

  mask(size) { return size === 8 ? -1n : (1n << BigInt(size * 8)) - 1n; }

  /** Truncate the i64 on the stack to `size` bytes. */
  trunc(size) { if (size !== 8) this.f.i64const(this.mask(size)).i64and(); }

  sext(size) {
    const f = this.f;
    if (size === 1) f.i64extend8s();
    else if (size === 2) f.i64extend16s();
    else if (size === 4) f.i64extend32s();
  }

  // ---- registers ------------------------------------------------------------
  // Without REX, byte registers 4..7 are AH/CH/DH/BH: the high byte of one of
  // the first four registers.
  byteOff(reg, rex) { return (!rex && reg >= 4 && reg < 8) ? (reg - 4) * 8 + 1 : reg * 8; }

  regRead(reg, size, rex) {
    const f = this.f;
    f.i32const(0);
    if (size === 1) f.i64load8u(this.byteOff(reg, rex));
    else if (size === 2) f.i64load16u(reg * 8);
    else if (size === 4) f.i64load32u(reg * 8);
    else f.i64load(reg * 8);
  }

  /** Store a local into a register at `size`, as setregN does. */
  regWrite(reg, size, rex, local) {
    const f = this.f;
    f.i32const(0).localGet(local);
    if (size === 1) f.i64store8(this.byteOff(reg, rex));
    else if (size === 2) f.i64store16(reg * 8);
    else if (size === 4) { f.i64const(0xffffffff).i64and().i64store(reg * 8); }
    else f.i64store(reg * 8);
  }

  // ---- addressing ------------------------------------------------------------
  segOf(ins, m) { return ins.seg >= 0 ? ins.seg : m.seg; }

  /** Compute a memory operand's effective address into EA. */
  ea(ins, m) {
    const f = this.f;
    let have = false;
    if (m.base >= 0) {
      this.regRead(m.base, 8, 1);
      have = true;
    }
    if (m.index >= 0) {
      this.regRead(m.index, 8, 1);
      if (m.scale) f.i64const(m.scale).i64shl();
      if (have) f.i64add();
      have = true;
    }
    if (!have) f.i64const(m.disp);
    else if (m.disp !== 0n) f.i64const(m.disp).i64add();
    if (m.a16) f.i64const(0xffff).i64and();
    else if (ins.addrsize === 4) f.i64const(0xffffffff).i64and();
    // RIP-relative: from the end of the instruction, computed at run time.
    if (m.riprel) { this.ripAt(ins.next); f.i64add(); }
    f.localSet(this.EA);
  }

  /**
   * Linear address of EA in `seg` into LA, branching to `slow` when the
   * access might be outside the segment.  Mirrors $seg_lin.
   */
  linear(seg, size, slow) {
    const f = this.f;
    if (seg === LINEAR) { f.localGet(this.EA).localSet(this.LA); return; }
    if (this.long) {
      f.localGet(this.EA);
      if (seg === FS || seg === GS) f.i32const(0).i64load(SEG_BASE(seg)).i64add();
      f.localSet(this.LA);
      return;
    }
    if (this.ctx.mode !== 0) {
      f.localGet(this.EA);
      if (size > 1) f.i64const(size - 1).i64add();
      f.i32const(0).i64load(SEG_FASTLIM(seg)).i64gtS().brIfTo(slow);
    }
    f.i32const(0).i64load(SEG_BASE(seg)).localGet(this.EA).i64add()
      .i64const(0xffffffff).i64and().localSet(this.LA);
  }

  /** JIT TLB lookup for LA in the given table; branch to `slow` on a miss. */
  tlb(table, size, slow) {
    const f = this.f;
    f.localGet(this.LA).i64const(12).i64shrU().i32wrapI64().i32const(4095).i32and()
      .i32const(4).i32shl().localSet(this.SLOT);
    f.localGet(this.SLOT).i64load(table);
    f.localGet(this.LA).i64const(-4096).i64and().globalGet(G.g_tlbbits).i64extendI32u().i64or();
    f.i64ne().brIfTo(slow);
    if (size > 1) {
      f.localGet(this.LA).i32wrapI64().i32const(4095).i32and().i32const(4096 - size).i32gtU()
        .brIfTo(slow);
    }
  }

  /** Read `size` bytes at EA in `seg`; the value is left on the stack. */
  memRead(ins, seg, size) {
    const f = this.f;
    const done = f.label(); f.block(I64);
    const slow = f.label(); f.block();
    this.linear(seg, size, slow);
    this.tlb(JTLB_R, size, slow);
    f.localGet(this.LA).localGet(this.SLOT).i64load(JTLB_R + 8).i64add().ramLoad(size);
    f.brTo(done);
    f.end();
    if (seg === LINEAR) f.localGet(this.EA).i32const(size).call(H.j_lrd);
    else f.i32const(seg).localGet(this.EA).i32const(size).call(H.j_rd);
    f.globalGet(G.g_fault).if_();
    this.faultExit(ins);
    f.end();
    f.end();
  }

  /** Write local `val` as `size` bytes at EA in `seg`. */
  memWrite(ins, seg, size, val) {
    const f = this.f;
    const done = f.label(); f.block();
    const slow = f.label(); f.block();
    this.linear(seg, size, slow);
    this.tlb(JTLB_W, size, slow);
    f.localGet(this.LA).localGet(this.SLOT).i64load(JTLB_W + 8).i64add().localGet(val)
      .ramStore(size);
    f.brTo(done);
    f.end();
    if (seg === LINEAR) f.localGet(this.EA).i32const(size).localGet(val).call(H.j_lwr);
    else f.i32const(seg).localGet(this.EA).i32const(size).localGet(val).call(H.j_wr);
    f.if_();
    f.globalGet(G.g_fault).if_();
    this.faultExit(ins);
    f.end();
    // The store landed on compiled code -- possibly this block's own.  The
    // instruction completes, then the block leaves.
    f.i32const(1).localSet(this.EXITF);
    f.end();
    f.end();
    this.slowStore = true;
  }

  rmRead(ins, size) {
    const m = ins.m;
    if (!m.mem) { this.regRead(m.rm, size, ins.rex); return; }
    this.ea(ins, m);
    this.memRead(ins, this.segOf(ins, m), size);
  }

  /** Write local `val` to the r/m operand; EA must already be computed. */
  rmWrite(ins, size, val) {
    const m = ins.m;
    if (!m.mem) { this.regWrite(m.rm, size, ins.rex, val); return; }
    this.memWrite(ins, this.segOf(ins, m), size, val);
  }

  // ---- the stack --------------------------------------------------------------
  spMask() { return this.long ? null : this.ctx.ss32 ? 0xffffffffn : 0xffffn; }
  stackSeg() { return this.long ? LINEAR : SS; }

  /** Push local `val` (size bytes); RSP changes only once the store is done. */
  push(ins, val, size) {
    const f = this.f;
    this.regRead(RSP, 8, 1);
    f.i64const(size).i64sub();
    const mask = this.spMask();
    if (mask !== null) f.i64const(mask).i64and();
    f.localTee(this.SP).localSet(this.EA);
    this.memWrite(ins, this.stackSeg(), size, val);
    this.writeSp(this.SP);
  }

  /** Pop `size` bytes into local V. */
  pop(ins, size) {
    const f = this.f;
    this.regRead(RSP, 8, 1);
    const mask = this.spMask();
    if (mask !== null) f.i64const(mask).i64and();
    f.localTee(this.SP).localSet(this.EA);
    this.memRead(ins, this.stackSeg(), size);
    f.localSet(this.V);
    f.localGet(this.SP).i64const(size).i64add().localSet(this.SP);
    this.writeSp(this.SP);
  }

  /** RSP <- local, at the stack's width, as $push and $pop write it. */
  writeSp(local) {
    if (this.long) this.regWrite(RSP, 8, 1, local);
    else if (this.ctx.ss32) this.regWrite(RSP, 4, 1, local);
    else this.regWrite(RSP, 2, 1, local);
  }

  // ---- conditions ------------------------------------------------------------
  /**
   * Leave the truth of condition `cc` on the stack as an i32.  From deferred
   * flags where the answer follows directly from the operands; otherwise the
   * flags are produced and the core is asked.
   */
  cond(cc) {
    const f = this.f;
    const { kind, size } = this.pend;
    const neg = cc & 1;
    const base = cc & ~1;
    const msb = () => {
      f.localGet(this.FR).i64const(size * 8 - 1).i64shrU().i32wrapI64().i32const(1).i32and();
    };
    const zero = () => { f.localGet(this.FR).i64eqz(); };
    let ok = true;
    if (kind === F_SUB) {
      switch (base) {
        case 4: zero(); break;                                                    // Z
        case 2: f.localGet(this.FA).localGet(this.FB).i64ltU(); break;            // B
        case 6: f.localGet(this.FA).localGet(this.FB).i64leU(); break;            // BE
        case 8: msb(); break;                                                     // S
        case 12: f.localGet(this.FA); this.sext(size); f.localGet(this.FB); this.sext(size);
          f.i64ltS(); break;                                                      // L
        case 14: f.localGet(this.FA); this.sext(size); f.localGet(this.FB); this.sext(size);
          f.i64leS(); break;                                                      // LE
        default: ok = false;
      }
    } else if (kind === F_LOGIC) {
      switch (base) {
        case 4: zero(); break;
        case 2: f.i32const(0); break;                     // CF is clear
        case 6: zero(); break;                            // CF|ZF
        case 8: msb(); break;
        case 12: msb(); break;                            // SF != OF, OF clear
        case 14: zero(); msb(); f.i32or(); break;         // ZF | SF
        case 0: f.i32const(0); break;                     // OF is clear
        default: ok = false;
      }
    } else if (kind === F_ADD) {
      switch (base) {
        case 4: zero(); break;
        case 8: msb(); break;
        case 2: f.localGet(this.FR).localGet(this.FA).i64ltU(); break;
        default: ok = false;
      }
    } else if (kind === F_INC || kind === F_DEC) {
      switch (base) {
        case 4: zero(); break;
        case 8: msb(); break;
        default: ok = false;
      }
    } else {
      ok = false;
    }
    if (!ok) {
      this.materialize();
      f.i32const(cc).call(H.j_cond);
      return;
    }
    if (neg) f.i32eqz();
  }

  // ---- the block ---------------------------------------------------------------
  emit() {
    const f = this.f;
    const { instrs } = this.plan;
    f.globalGet(G.g_rip).localSet(this.BASE);
    this.fexit = f.label();
    f.block();
    // A block with a branch back to its own entry runs as a wasm loop.
    const looping = instrs.some((ins) => ins.backEdge);
    if (looping) { this.top = f.label(); f.loop(); }
    let ended = false;
    for (const ins of instrs) {
      f.localGet(this.COUNT).i32const(1).i32add().localSet(this.COUNT);
      this.slowStore = false;
      ended = this.instr(ins);
      if (ended) break;
      if (this.slowStore) {
        f.localGet(this.EXITF).if_();
        this.leaveAt(ins.next);
        f.end();
      }
    }
    if (!ended) this.leaveAt(instrs[instrs.length - 1].next);
    if (looping) f.end();
    f.end();
    // Fault exit: every faulting site arrives here with RIP0D naming the
    // instruction and the flags as they were before it.  RSP is untouched by
    // a faulting instruction, so it is still the value $rsp0 has to hold.
    this.ripAt(0);
    f.localGet(this.RIP0D).i64add();
    this.maskRip();
    f.globalSet(G.g_rip0);
    f.i32const(0).i64load(RSP * 8).globalSet(G.g_rsp0);
    this.syncTsc();
    f.localGet(this.COUNT);
    return f;
  }

  /** Emit one instruction; returns true if the block ends with it. */
  instr(ins) {
    const f = this.f;
    const rex = ins.rex;
    const m = ins.m;
    switch (ins.kind) {
      case 'nop':
        return false;

      case 'mov':
        if (ins.op & 2) {                               // reg <- r/m
          this.rmRead(ins, ins.size);
          f.localSet(this.V);
          this.regWrite(m.reg, ins.size, rex, this.V);
        } else {                                        // r/m <- reg
          if (m.mem) this.ea(ins, m);
          this.regRead(m.reg, ins.size, rex);
          f.localSet(this.V);
          this.rmWrite(ins, ins.size, this.V);
        }
        return false;

      case 'mov_from_seg':
        // The selector: 16 bits to memory, the operand size to a register.
        f.i32const(0).i32load(0x100 + m.ext * 32).i64extendI32u().i64const(0xffff).i64and()
          .localSet(this.V);
        if (m.mem) { this.ea(ins, m); this.rmWrite(ins, 2, this.V); }
        else this.regWrite(m.rm, ins.opsize, rex, this.V);
        return false;

      case 'mov_ri':
        f.i64const(ins.imm).localSet(this.V);
        this.regWrite(ins.reg, ins.size, rex, this.V);
        return false;

      case 'mov_mi':
        if (m.mem) this.ea(ins, m);
        f.i64const(ins.imm).localSet(this.V);
        this.rmWrite(ins, ins.size, this.V);
        return false;

      case 'mov_moffs': {
        // The address is an immediate, on DS unless overridden.
        f.i64const(ins.imm).localSet(this.EA);
        const seg = ins.seg >= 0 ? ins.seg : DS;
        if (ins.op < 0xa2) {
          this.memRead(ins, seg, ins.size);
          f.localSet(this.V);
          this.regWrite(0, ins.size, rex, this.V);
        } else {
          this.regRead(0, ins.size, rex);
          f.localSet(this.V);
          this.memWrite(ins, seg, ins.size, this.V);
        }
        return false;
      }

      case 'lea':
        this.ea(ins, m);
        f.localGet(this.EA);
        this.trunc(ins.opsize);
        f.localSet(this.V);
        this.regWrite(m.reg, ins.opsize, rex, this.V);
        return false;

      case 'movzx':
      case 'movsx':
        this.rmRead(ins, ins.srcSize);
        if (ins.kind === 'movsx') this.sext(ins.srcSize);
        f.localSet(this.V);
        this.regWrite(m.reg, ins.opsize, rex, this.V);
        return false;

      case 'alu_rm': {
        const size = ins.size;
        const dirRM = (ins.op & 7) < 2;                   // r/m is the destination
        if (dirRM) {
          this.rmRead(ins, size); f.localSet(this.A);
          this.regRead(m.reg, size, rex); f.localSet(this.B);
        } else {
          this.regRead(m.reg, size, rex); f.localSet(this.A);
          this.rmRead(ins, size); f.localSet(this.B);
        }
        this.alu(ins, ins.aluop, size, () => {
          if (dirRM) this.rmWrite(ins, size, this.R);
          else this.regWrite(m.reg, size, rex, this.R);
        });
        return false;
      }

      case 'alu_mi':
        this.rmRead(ins, ins.size); f.localSet(this.A);
        f.i64const(ins.imm).localSet(this.B);
        this.alu(ins, ins.aluop, ins.size, () => this.rmWrite(ins, ins.size, this.R));
        return false;

      case 'alu_ai':
        this.regRead(0, ins.size, rex); f.localSet(this.A);
        f.i64const(ins.imm).localSet(this.B);
        this.alu(ins, ins.aluop, ins.size, () => this.regWrite(0, ins.size, rex, this.R));
        return false;

      case 'test_rm':
        this.rmRead(ins, ins.size); f.localSet(this.A);
        this.regRead(m.reg, ins.size, rex); f.localSet(this.B);
        this.alu(ins, 4, ins.size, null);
        return false;

      case 'test_ai':
        this.regRead(0, ins.size, rex); f.localSet(this.A);
        f.i64const(ins.imm).localSet(this.B);
        this.alu(ins, 4, ins.size, null);
        return false;

      case 'test_mi':
        this.rmRead(ins, ins.size); f.localSet(this.A);
        f.i64const(ins.imm).localSet(this.B);
        this.alu(ins, 4, ins.size, null);
        return false;

      case 'not':
        this.rmRead(ins, ins.size);
        f.i64const(-1).i64xor();
        this.trunc(ins.size);
        f.localSet(this.R);
        this.rmWrite(ins, ins.size, this.R);
        return false;

      case 'neg':
        this.rmRead(ins, ins.size); f.localSet(this.B);
        f.i64const(0).localSet(this.A);
        f.i64const(0).localGet(this.B).i64sub();
        this.trunc(ins.size);
        f.localSet(this.R);
        this.rmWrite(ins, ins.size, this.R);
        this.setPending(F_SUB, ins.size, this.A, this.B, this.R);
        return false;

      case 'incdec_r':
      case 'incdec_rm': {
        // INC and DEC keep CF, so whatever was pending has to be real first.
        this.materialize();
        const size = ins.size;
        if (ins.kind === 'incdec_r') this.regRead(ins.reg, size, rex);
        else this.rmRead(ins, size);
        f.localSet(this.A);
        f.localGet(this.A).i64const(ins.dec ? -1 : 1).i64add();
        this.trunc(size);
        f.localSet(this.R);
        if (ins.kind === 'incdec_r') this.regWrite(ins.reg, size, rex, this.R);
        else this.rmWrite(ins, size, this.R);
        this.setPending(ins.dec ? F_DEC : F_INC, size, this.A, undefined, this.R);
        return false;
      }

      case 'push_r':
        this.regRead(ins.reg, ins.d64, rex);
        f.localSet(this.V);
        this.push(ins, this.V, ins.d64);
        return false;

      case 'pop_r':
        this.pop(ins, ins.d64);
        this.regWrite(ins.reg, ins.d64, rex, this.V);
        return false;

      case 'push_imm':
        f.i64const(ins.imm).localSet(this.V);
        this.push(ins, this.V, ins.d64);
        return false;

      case 'push_rm':
        this.rmRead(ins, ins.d64);
        f.localSet(this.T);
        this.push(ins, this.T, ins.d64);
        return false;

      case 'push_seg':
        f.i32const(0).i32load(0x100 + ins.sreg * 32).i64extendI32u().i64const(0xffff).i64and()
          .localSet(this.V);
        this.push(ins, this.V, ins.d64);
        return false;

      case 'pusha':
      case 'popa': {
        // Eight stack accesses against a private stack pointer, which only
        // reaches RSP at the end: a fault part way leaves RSP as it was, which
        // is what the fault path reports as the instruction's starting RSP.
        const s = ins.opsize;
        const mask = this.spMask();
        this.regRead(RSP, 8, 1);
        f.localSet(this.T);                           // the SP PUSHA stores
        this.regRead(RSP, 8, 1);
        f.localSet(this.SP);
        const order = ins.kind === 'pusha' ? [0, 1, 2, 3, 4, 5, 6, 7] : [7, 6, 5, 4, 3, 2, 1, 0];
        for (const r of order) {
          if (ins.kind === 'pusha') {
            f.localGet(this.SP).i64const(s).i64sub();
            if (mask !== null) f.i64const(mask).i64and();
            f.localTee(this.SP).localSet(this.EA);
            if (r === 4) f.localGet(this.T).localSet(this.V);
            else { this.regRead(r, s, 1); f.localSet(this.V); }
            this.memWrite(ins, SS, s, this.V);
          } else {
            f.localGet(this.SP);
            if (mask !== null) f.i64const(mask).i64and();
            f.localSet(this.EA);
            this.memRead(ins, SS, s);
            f.localSet(this.V);
            f.localGet(this.SP).i64const(s).i64add();
            if (mask !== null) f.i64const(mask).i64and();
            f.localSet(this.SP);
            if (r !== 4) this.regWrite(r, s, 1, this.V);
          }
        }
        this.writeSp(this.SP);
        return false;
      }

      case 'pushf':
        this.materialize();
        f.globalGet(G.g_flags).i64const(0x00fcffff).i64and().localSet(this.V);
        this.push(ins, this.V, ins.d64);
        return false;

      case 'popf': {
        // IOPL changes only at CPL 0, IF only at CPL <= IOPL; a 16-bit POPF
        // leaves the upper half alone.  Then $set_flags's own mask.
        this.materialize();
        this.pop(ins, ins.d64);
        f.i64const(0x257fd5).localSet(this.A);
        f.i32const(0).i32load(0xb8).if_();             // CPL != 0
        f.localGet(this.A).i64const(~0x3000n).i64and().localSet(this.A);
        f.end();
        f.i32const(0).i32load(0xb8)
          .globalGet(G.g_flags).i64const(12).i64shrU().i32wrapI64().i32const(3).i32and()
          .i32gtU().if_();                             // CPL > IOPL
        f.localGet(this.A).i64const(~0x200n).i64and().localSet(this.A);
        f.end();
        if (ins.d64 === 2) f.localGet(this.A).i64const(0xffff).i64and().localSet(this.A);
        f.globalGet(G.g_flags).localGet(this.A).i64const(-1).i64xor().i64and()
          .localGet(this.V).localGet(this.A).i64and().i64or()
          .i64const(0x3f7fd5).i64and().i64const(2).i64or().globalSet(G.g_flags);
        this.leaveAt(ins.next);
        return true;
      }

      case 'cli':
      case 'sti': {
        // Allowed in real mode, or at CPL <= IOPL; anything else is a #GP the
        // interpreter raises, so that case hands the instruction over.
        f.i32const(0).i32load(0x90).i32const(1).i32and().i32eqz();           // !CR0.PE
        f.i32const(0).i32load(0xb8)
          .globalGet(G.g_flags).i64const(12).i64shrU().i32wrapI64().i32const(3).i32and()
          .i32leU().i32or();
        f.if_();
        f.globalGet(G.g_flags);
        if (ins.kind === 'cli') f.i64const(~0x200n).i64and();
        else f.i64const(0x200).i64or();
        f.globalSet(G.g_flags);
        // interrupts stay blocked for one instruction after STI
        if (ins.kind === 'sti') f.i32const(0).i32const(1).i32store(0xdc);
        f.else_();
        this.interpOut(ins);
        f.end();
        if (ins.kind === 'sti') { this.leaveAt(ins.next); return true; }
        return false;
      }

      case 'xchg': {
        const size = ins.size;
        this.rmRead(ins, size); f.localSet(this.A);
        this.regRead(m.reg, size, rex); f.localSet(this.B);
        this.rmWrite(ins, size, this.B);
        this.regWrite(m.reg, size, rex, this.A);
        return false;
      }

      case 'xchg_ax': {
        const size = ins.opsize;
        this.regRead(0, size, rex); f.localSet(this.A);
        this.regRead(ins.reg, size, rex); f.localSet(this.B);
        this.regWrite(0, size, rex, this.B);
        this.regWrite(ins.reg, size, rex, this.A);
        return false;
      }

      case 'cbw': {
        const s = ins.opsize;
        this.regRead(0, s / 2 < 1 ? 1 : s / 2, rex);
        this.sext(s / 2);
        f.localSet(this.V);
        this.regWrite(0, s, rex, this.V);
        return false;
      }

      case 'cwd': {
        const s = ins.opsize;
        this.regRead(0, s, rex);
        this.sext(s);
        f.i64const(63).i64shrS().localSet(this.V);
        this.regWrite(2, s, rex, this.V);
        return false;
      }

      case 'flagop': {
        this.materialize();
        f.globalGet(G.g_flags);
        switch (ins.op) {
          case 0xf5: f.i64const(1).i64xor(); break;
          case 0xf8: f.i64const(-2n).i64and(); break;
          case 0xf9: f.i64const(1).i64or(); break;
          case 0xfc: f.i64const(~0x400n).i64and(); break;
          default: f.i64const(0x400).i64or(); break;
        }
        f.globalSet(G.g_flags);
        return false;
      }

      case 'shift': {
        this.materialize();
        const size = ins.size;
        this.rmRead(ins, size);
        f.localSet(this.A);
        f.i32const(m.ext).localGet(this.A);
        if (ins.op === 0xc0 || ins.op === 0xc1) f.i32const(Number(ins.imm & 0xffn));
        else if (ins.op <= 0xd1) f.i32const(1);
        else { this.regRead(1, 1, 1); f.i32wrapI64(); }
        f.i32const(size).call(H.j_shift).localSet(this.R);
        this.rmWrite(ins, size, this.R);
        return false;
      }

      case 'setcc':
        if (m.mem) this.ea(ins, m);
        this.cond(ins.cc);
        f.i64extendI32u().localSet(this.V);
        this.rmWrite(ins, 1, this.V);
        return false;

      case 'cmov': {
        const s = ins.opsize;
        this.rmRead(ins, s);
        f.localSet(this.V);
        this.cond(ins.cc);
        f.if_();
        this.regWrite(m.reg, s, rex, this.V);
        if (s === 4) {
          // a 32-bit CMOV still zeroes the upper half when not taken
          f.else_();
          this.regRead(m.reg, 4, rex);
          f.localSet(this.V);
          this.regWrite(m.reg, 4, rex, this.V);
        }
        f.end();
        return false;
      }

      // ---- control transfers ----
      case 'follow':                    // a jump whose target the block continues at
        return false;

      case 'jcc':
        this.cond(ins.cc);
        f.if_();
        if (ins.backEdge) this.backEdge(ins);
        else { this.jumpTarget(ins); this.leave(); }
        if (ins.sideExit) { f.end(); return false; }
        f.else_();
        this.ripAt(ins.next);
        f.globalSet(G.g_rip);
        f.end();
        this.leave();
        return true;

      case 'jmp':
        if (ins.backEdge) { this.backEdge(ins); return true; }
        this.jumpTarget(ins);
        this.leave();
        return true;

      case 'call':
        this.ripAt(ins.next);
        f.localSet(this.V);
        this.push(ins, this.V, ins.d64);
        this.jumpTarget(ins);
        this.leave();
        return true;

      case 'ret':
        this.pop(ins, ins.d64);
        if (ins.op === 0xc2) {
          // $h_ret adds the immediate to the whole of RSP, whatever the width
          this.regRead(RSP, 8, 1);
          f.i64const(BigInt.asUintN(16, ins.imm)).i64add().localSet(this.T);
          this.regWrite(RSP, 8, 1, this.T);
        }
        f.localGet(this.V).globalSet(G.g_rip);
        this.leave();
        return true;

      case 'jmp_rm':
      case 'call_rm':
        this.rmRead(ins, ins.d64);
        f.localSet(this.T);
        if (ins.kind === 'call_rm') {
          this.ripAt(ins.next);
          f.localSet(this.V);
          this.push(ins, this.V, ins.d64);
        }
        f.localGet(this.T);
        this.jumpMask(ins);
        f.globalSet(G.g_rip);
        this.leave();
        return true;

      case 'loop':
      case 'jcxz': {
        const as = ins.addrsize;
        this.regRead(1, as, 1);
        if (ins.kind === 'loop') {
          f.i64const(1).i64sub();
          this.trunc(as);
          f.localSet(this.V);
          this.regWrite(1, as, 1, this.V);
          f.localGet(this.V).i64eqz().i32eqz();
        } else {
          f.i64eqz();
        }
        f.if_();
        if (ins.backEdge) this.backEdge(ins);
        else this.jumpTarget(ins);
        f.else_();
        this.ripAt(ins.next);
        f.globalSet(G.g_rip);
        f.end();
        this.leave();
        return true;
      }

      default:
        return this.interp(ins);
    }
  }

  /** ALU op on A and B into R; `write` stores R unless the op is CMP/TEST. */
  alu(ins, op, size, write) {
    const f = this.f;
    const keep = op !== 7 && write;
    if (op === 2 || op === 3) {
      // ADC and SBB read the carry, so they go through the core's own code.
      this.materialize();
      f.i32const(op).localGet(this.A).localGet(this.B).i32const(size).call(H.j_alu)
        .localSet(this.R);
      if (keep) write();
      return;
    }
    f.localGet(this.A).localGet(this.B);
    if (op === 0) f.i64add();
    else if (op === 5 || op === 7) f.i64sub();
    else if (op === 1) f.i64or();
    else if (op === 4) f.i64and();
    else f.i64xor();
    this.trunc(size);
    f.localSet(this.R);
    if (keep) write();
    if (op === 0) {
      f.localGet(this.B); this.trunc(size); f.localSet(this.B);
      this.setPending(F_ADD, size, this.A, this.B, this.R);
    } else if (op === 5 || op === 7) {
      f.localGet(this.B); this.trunc(size); f.localSet(this.B);
      this.setPending(F_SUB, size, this.A, this.B, this.R);
    } else {
      this.setPending(F_LOGIC, size, this.R, this.R, this.R);
    }
  }

  /**
   * A branch back to the block's entry.  The flags are produced, so the top
   * of the loop sees them exactly as it does on entry, and the block goes
   * round again unless its instruction budget is spent or an interrupt is
   * waiting to be taken -- either of which sends it back to the run loop.
   */
  backEdge(ins) {
    const f = this.f;
    this.emitFlags();
    f.localGet(this.COUNT).globalGet(G.g_budget).i32ltU();
    f.i32const(0).i32load(IRQ_LINE)
      .globalGet(G.g_flags).i64const(9).i64shrU().i32wrapI64().i32and()
      .i32eqz().i32and();
    // 16-bit IP wraps at 64 KiB: the target is the entry only when it fits.
    if (!this.long && ins.opsize === 2) {
      f.localGet(this.BASE).i64const(0xffff).i64leU().i32and();
    }
    f.if_();
    f.brTo(this.top);
    f.end();
    this.jumpTarget(ins);
    this.syncTsc();
    f.localGet(this.COUNT).return_();
  }

  /** RIP <- a relative branch target, masked as $jump_to masks it. */
  jumpTarget(ins) {
    const f = this.f;
    f.localGet(this.BASE).i64const(BigInt(ins.next) + ins.imm).i64add();
    this.jumpMask(ins);
    f.globalSet(G.g_rip);
  }

  jumpMask(ins) {
    if (this.long) return;
    this.f.i64const(ins.opsize === 2 ? 0xffff : 0xffffffff).i64and();
  }

  /**
   * Hand one instruction to the interpreter, in place.  Flags are produced
   * first and RIP and the timestamp counter brought up to date, so it sees
   * exactly the state it would have outside a block.  Afterwards, unless RIP
   * landed on the next instruction and nothing asked the block to stop, the
   * block leaves; a repeated string instruction is called back while it is
   * still iterating.
   */
  interp(ins) {
    const f = this.f;
    this.materialize();
    let loopLabel = null;
    if (ins.repLoop) { loopLabel = f.label(); f.loop(); }
    this.ripAt(ins.at);
    f.globalSet(G.g_rip);
    // The interpreter sees the counter as it stood before this instruction.
    this.syncTo(-1);
    f.call(H.j_step);
    f.if_();
    this.syncTsc();
    f.localGet(this.COUNT).return_();
    f.end();
    if (ins.repLoop) {
      // Still on the same instruction: the interpreter rewound it for another
      // iteration.  Run it again while the budget lasts and nothing is waiting.
      f.globalGet(G.g_rip);
      this.ripAt(ins.at);
      f.i64eq();
      f.localGet(this.COUNT).globalGet(G.g_budget).i32ltU().i32and();
      f.i32const(0).i32load(IRQ_LINE).i32eqz().i32and();
      f.if_();
      f.localGet(this.COUNT).i32const(1).i32add().localSet(this.COUNT);
      f.brTo(loopLabel);
      f.end();
      f.end();
    }
    f.globalGet(G.g_rip);
    this.ripAt(ins.next);
    f.i64ne();
    f.if_();
    this.syncTsc();
    f.localGet(this.COUNT).return_();
    f.end();
    return !!ins.ends;
  }

  /**
   * Run this one instruction in the interpreter and leave the block, whatever
   * happens: the path for the rare case a compiled instruction does not
   * handle itself, such as a privilege check that fails.
   */
  interpOut(ins) {
    const f = this.f;
    this.emitFlags();
    this.ripAt(ins.at);
    f.globalSet(G.g_rip);
    this.syncTo(-1);
    f.call(H.j_step).drop();
    this.syncTsc();
    f.localGet(this.COUNT).return_();
  }

  /** Bring the timestamp counter up to COUNT + delta instructions. */
  syncTo(delta) {
    const f = this.f;
    f.localGet(this.COUNT);
    if (delta) f.i32const(delta).i32add();
    f.localTee(this.ST);
    f.localGet(this.SYNCED).i32sub().i64extendI32u().globalGet(G.g_tsc).i64add()
      .globalSet(G.g_tsc);
    f.localGet(this.ST).localSet(this.SYNCED);
  }
}
