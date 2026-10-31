// A basic-block JIT for the hot paths of the interpreter.
//
// The core counts how often each address is reached and publishes the ones
// that get hot; this compiles a straight-line run of instructions starting
// there into a WebAssembly function and hands it back through the shared
// table.  From then on the core reaches that run with a single call_indirect.
//
// WHAT IS ACTUALLY SAVED
//   Not the arithmetic -- flags are still produced by the interpreter's own
//   primitives, and deferring them was already tried and measured slower.
//   What goes away is everything wrapped around the arithmetic: refilling the
//   instruction window, the prefix loop, two opcode-table lookups, the
//   call_indirect into a handler, and re-deriving the ModRM byte and effective
//   address on every single execution of an instruction whose encoding never
//   changes.  Those are constants at compile time, so they are folded away.
//
// WHY THE SUBSET IS SMALL
//   A block ends at the first instruction this does not handle, and the
//   interpreter picks up from there.  That makes an unsupported opcode a
//   missed optimisation rather than a correctness problem, and it is why the
//   set below can grow one instruction at a time without ever being wrong in
//   between.  Anything that changes control flow, touches a segment register,
//   or carries a prefix other than REX or 0x66 ends the block.
import { buildModule, Func, I32, I64 } from './wasm_emit.js';

// Helper functions the generated code calls, in the order it indexes them.
const HELPERS = [
  { name: 'j_alu', params: [I32, I64, I64, I32], results: [I64] },
  { name: 'j_rd', params: [I32, I64, I32], results: [I64] },
  { name: 'j_wr', params: [I32, I64, I32, I64], results: [] },
  { name: 'j_push', params: [I64, I32], results: [] },
  { name: 'j_pop', params: [I32], results: [I64] },
  { name: 'j_cond', params: [I32], results: [I32] },
];
const H_ALU = 0, H_RD = 1, H_WR = 2, H_PUSH = 3, H_POP = 4, H_COND = 5;

// Imported mutable globals, in index order.
const G_RIP = 0, G_RIP0 = 1, G_FAULT = 2, G_RSP0 = 3;

const MAX_INSTRS = 24;          // a block long enough to pay for its dispatch
const SEG_DS = 3, SEG_SS = 2;

/** Thrown to abandon a block cleanly at the first thing we cannot compile. */
class Unsupported extends Error {}

/**
 * Reads instruction bytes for the compiler.
 *
 * Compilation happens outside the guest's execution, so it must not disturb
 * anything: translation is done through the core's debug path, which walks the
 * page tables without touching the TLB or raising faults.
 */
class CodeReader {
  constructor(machine, la) {
    this.m = machine;
    this.start = la;
    this.pos = la;
  }

  u8() {
    const pa = this.m.exports.debug_translate(this.pos);
    if (pa < 0n) throw new Unsupported('unmapped');
    // A translation can succeed and still land outside guest RAM -- memory
    // mapped device space, or past the end of what is installed.  Code there
    // is not something to compile, and reading it back gives undefined rather
    // than a byte, so it has to be rejected explicitly.
    const b = this.m.rd8(Number(pa));
    if (typeof b !== 'number') throw new Unsupported('not RAM');
    this.pos += 1n;
    return b;
  }

  imm(size) {                    // little-endian, unsigned
    let v = 0n;
    for (let i = 0; i < size; i++) v |= BigInt(this.u8()) << BigInt(i * 8);
    return v;
  }

  simm(size) {                   // sign-extended to 64 bits
    const v = this.imm(size);
    const bits = BigInt(size * 8);
    return BigInt.asIntN(Number(bits), v) & 0xffffffffffffffffn;
  }
}

export class Jit {
  constructor(machine) {
    this.m = machine;
    this.slots = 0;              // next free index in the shared table
    this.compiled = 0;
    this.rejected = 0;
    this.instrs = 0;             // guest instructions covered by compiled code
    this.reasons = new Map();
    this.lastDrained = 0;
  }

  /** Compile everything the core has flagged as hot since the last call. */
  drain() {
    const x = this.m.exports;
    const total = x.jit_hot_count();
    if (total === this.lastDrained) return 0;
    // The ring holds the most recent 64; if more than that arrived between
    // drains the older ones are simply missed and will be offered again.
    const first = Math.max(this.lastDrained, total - 64);
    let made = 0;
    for (let i = first; i < total; i++) {
      if (this.compileAt(x.jit_hot_at(i))) made++;
    }
    this.lastDrained = total;
    return made;
  }

  compileAt(la) {
    const x = this.m.exports;
    // Virtual-8086 code decodes like real mode but traps differently, and
    // blocks are not built to tell the two apart.
    if (x.get_vm()) { this.rejected++; return false; }
    const mode = x.get_mode();
    let plan;
    try {
      plan = this.decodeBlock(la, mode);
    } catch (err) {
      if (!(err instanceof Unsupported)) throw err;
      this.rejected++;
      this.reasons.set(err.message, (this.reasons.get(err.message) ?? 0) + 1);
      return false;
    }
    if (!plan || plan.instrs.length < 2) { this.rejected++; return false; }

    const bytes = this.emit(plan);
    let inst;
    try {
      inst = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
        env: {
          state: this.m.stateMem,
          g_rip: x.g_rip, g_rip0: x.g_rip0, g_fault: x.g_fault, g_rsp0: x.g_rsp0,
          ...Object.fromEntries(HELPERS.map((h) => [h.name, x[h.name]])),
        },
      });
    } catch (err) {
      // A module that will not compile is a bug in this file, not in the
      // guest, and silently interpreting instead would hide it.
      throw new Error(`JIT produced an invalid module at 0x${la.toString(16)}: ${err.message}`);
    }

    const slot = this.slots++;
    if (slot >= this.m.jitTable.length) this.m.jitTable.grow(64);
    this.m.jitTable.set(slot, inst.exports.blk);
    x.jit_install(la, slot, mode);
    // Everything after the head belongs to this block, so it must never become
    // a block head of its own.
    for (const ins of plan.instrs.slice(1)) x.jit_suppress(ins.at);
    this.compiled++;
    this.instrs += plan.instrs.length;
    return true;
  }

  // ---- decoding ---------------------------------------------------------
  //  Operand and address defaults come from the mode exactly as the core's
  //  $cache_mode_defaults sets them: 16-bit code defaults to 2/2, 32-bit
  //  protected to 4/4, and long mode to 4/8.  Deriving them here rather than
  //  reading the live globals keeps a compiled block valid for as long as its
  //  mode is, which is precisely what the cache key promises.
  static DEFAULTS = {
    0: { defOp: 2, defAddr: 2 },      // real 16
    1: { defOp: 2, defAddr: 2 },      // protected 16
    2: { defOp: 4, defAddr: 4 },      // protected 32
    3: { defOp: 4, defAddr: 8 },      // long 64
  };

  decodeBlock(la, mode) {
    const defaults = Jit.DEFAULTS[mode];
    if (!defaults) throw new Unsupported(`mode ${mode}`);
    const r = new CodeReader(this.m, la);
    const instrs = [];
    const page = la >> 12n;
    while (instrs.length < MAX_INSTRS) {
      // Staying inside one page keeps the whole block covered by the single
      // code-page bit the invalidator checks.
      if ((r.pos >> 12n) !== page) break;
      const at = r.pos;
      let ins;
      try {
        ins = this.decodeOne(r, mode, defaults);
      } catch (err) {
        if (err instanceof Unsupported && instrs.length) break;   // short block is fine
        throw err;
      }
      if (!ins) break;
      ins.at = at;
      ins.next = r.pos;
      // A RIP-relative operand is relative to the end of the instruction, which
      // is only known now that its immediate has been consumed.  Folding it
      // here turns the whole address into a constant.
      if (ins.m?.riprel) {
        ins.m.disp = (ins.next + ins.m.disp) & 0xffffffffffffffffn;
      }
      instrs.push(ins);
      if (ins.ends) break;
    }
    return instrs.length ? { la, mode, instrs } : null;
  }

  decodeOne(r, mode, defaults) {
    let rex = 0, op66 = false, addr67 = false;
    const long = mode === 3;
    let b = r.u8();
    for (;;) {
      // A later prefix cancels REX, which is the whole reason REX has to be
      // the last one before the opcode.
      if (b === 0x66) { op66 = true; rex = 0; b = r.u8(); continue; }
      if (b === 0x67) { addr67 = true; rex = 0; b = r.u8(); continue; }
      if (long && (b & 0xf0) === 0x40) { rex = b; b = r.u8(); continue; }
      // Segment overrides, LOCK and the repeat prefixes still change operand
      // meaning in ways this compiler does not model.
      if ([0x26, 0x2e, 0x36, 0x3e, 0x64, 0x65, 0xf0, 0xf2, 0xf3].includes(b)) {
        throw new Unsupported(`prefix ${b.toString(16)}`);
      }
      break;
    }

    // 0x66 and 0x67 toggle their size away from the mode's default rather than
    // selecting a fixed width, so in 16-bit code they widen and in 32-bit code
    // they narrow.  REX.W overrides the operand size outright.
    let opsize = (rex & 8) ? 8 : op66 ? (defaults.defOp === 2 ? 4 : 2) : defaults.defOp;
    let addrsize = defaults.defAddr;
    if (addr67) addrsize = long ? 4 : (defaults.defAddr === 2 ? 4 : 2);
    const W = { rex, opsize, addrsize, long, op66, mode };

    // ---- ALU, forms 0..5 -------------------------------------------------
    if (b < 0x40 && (b & 7) < 6 && b !== 0x0f) {
      const aluop = (b >> 3) & 7;
      const form = b & 7;
      const size = (form & 1) ? opsize : 1;
      if (form < 4) {
        const m = this.modrm(r, W, size);
        const dirRM = form < 2;                 // r/m is the destination
        return { kind: 'alu', aluop, size, m, dirRM, W };
      }
      // accumulator, immediate
      const imm = r.simm(size === 1 ? 1 : size === 2 ? 2 : 4);
      return { kind: 'alu_ai', aluop, size, imm, W };
    }

    // ---- group 1: ALU r/m, imm ------------------------------------------
    if (b === 0x80 || b === 0x81 || b === 0x83) {
      const size = b === 0x80 ? 1 : opsize;
      const m = this.modrm(r, W, size);
      const imm = b === 0x81 ? r.simm(size === 2 ? 2 : 4) : r.simm(1);
      return { kind: 'alu_mi', aluop: m.ext, size, m, imm, W };
    }

    // ---- TEST r/m, r -----------------------------------------------------
    if (b === 0x84 || b === 0x85) {
      const size = b === 0x84 ? 1 : opsize;
      const m = this.modrm(r, W, size);
      return { kind: 'alu', aluop: 7 /* cmp-like: discard */, size, m, dirRM: true,
               test: true, W };
    }

    // ---- MOV -------------------------------------------------------------
    if (b >= 0x88 && b <= 0x8b) {
      const size = (b & 1) ? opsize : 1;
      const m = this.modrm(r, W, size);
      return { kind: 'mov', size, m, dirRM: b < 0x8a, W };
    }
    if (b >= 0xb8 && b <= 0xbf) {
      const reg = (b & 7) | ((rex & 1) << 3);
      const imm = opsize === 8 ? r.imm(8) : r.imm(opsize);
      return { kind: 'mov_ri', size: opsize, reg, imm, W };
    }
    if (b >= 0xb0 && b <= 0xb7) {
      const reg = (b & 7) | ((rex & 1) << 3);
      return { kind: 'mov_ri', size: 1, reg, imm: r.imm(1), W };
    }
    if (b === 0xc6 || b === 0xc7) {
      const size = b === 0xc6 ? 1 : opsize;
      const m = this.modrm(r, W, size);
      if (m.ext !== 0) throw new Unsupported('c7 /n');
      const imm = r.simm(size === 1 ? 1 : size === 2 ? 2 : 4);
      return { kind: 'mov_mi', size, m, imm, W };
    }

    // ---- LEA -------------------------------------------------------------
    if (b === 0x8d) {
      const m = this.modrm(r, W, opsize);
      if (!m.mem) throw new Unsupported('lea reg');
      return { kind: 'lea', size: opsize, m, W };
    }

    // ---- PUSH / POP register --------------------------------------------
    // PUSH and POP default to 64 bits in long mode and cannot be encoded at
    // 32; elsewhere they follow the operand size like everything else.  This
    // is what $opsize_d64 computes.
    const dflt64 = long ? (op66 ? 2 : 8) : opsize;
    if (b >= 0x50 && b <= 0x57) {
      const reg = (b & 7) | ((rex & 1) << 3);
      return { kind: 'push', size: dflt64, reg, W };
    }
    if (b >= 0x58 && b <= 0x5f) {
      const reg = (b & 7) | ((rex & 1) << 3);
      return { kind: 'pop', size: dflt64, reg, W };
    }

    // ---- branches --------------------------------------------------------
    // A branch is compiled as the last instruction of its block rather than a
    // reason to stop before one.  That is what lets a loop body and the jump
    // that closes it become a single block: without it, branch-dense code --
    // which is most real-mode code -- never accumulates more than an
    // instruction or two between exits.
    if (b >= 0x70 && b <= 0x7f) {
      return { kind: 'jcc', cc: b & 15, disp: r.simm(1), ends: true, W };
    }
    if (b === 0xeb) return { kind: 'jmp', disp: r.simm(1), ends: true, W };
    if (b === 0xe9) {
      return { kind: 'jmp', disp: r.simm(opsize === 2 ? 2 : 4), ends: true, W };
    }
    if (b === 0x0f) {
      const b2 = r.u8();
      if (b2 >= 0x80 && b2 <= 0x8f) {
        return { kind: 'jcc', cc: b2 & 15,
                 disp: r.simm(opsize === 2 ? 2 : 4), ends: true, W };
      }
      throw new Unsupported(`opcode 0f ${b2.toString(16)}`);
    }

    if (b === 0x90 && !rex) return { kind: 'nop', W };

    throw new Unsupported(`opcode ${b.toString(16)}`);
  }

  /**
   * Decode ModRM and, for a memory operand, reduce the address to a recipe:
   * a base register, an optional scaled index and a constant displacement.
   * RIP-relative operands fold to a plain constant, because the compiler knows
   * exactly where the instruction ends.
   */
  modrm(r, W, size) {
    const m = r.u8();
    const mod = m >> 6, rmLow = m & 7;
    const ext = (m >> 3) & 7;
    const reg = ext | (((W.rex >> 2) & 1) << 3);
    if (mod === 3) {
      return { mem: false, ext, reg, rm: rmLow | ((W.rex & 1) << 3), size };
    }
    if (W.addrsize === 2) return this.addr16(r, W, mod, rmLow, ext, reg, size);
    let base = -1, index = -1, scale = 0, disp = 0n, seg = SEG_DS, riprel = false;
    if (rmLow === 4) {
      const sib = r.u8();
      scale = sib >> 6;
      const idx = ((sib >> 3) & 7) | (((W.rex >> 1) & 1) << 3);
      if (idx !== 4) index = idx;
      if ((sib & 7) === 5 && mod === 0) {
        disp = r.simm(4);
      } else {
        base = (sib & 7) | ((W.rex & 1) << 3);
        if ((base & 7) === 4 || (base & 7) === 5) seg = SEG_SS;
      }
    } else if (rmLow === 5 && mod === 0) {
      disp = r.simm(4);
      if (W.long) riprel = true;
    } else {
      base = rmLow | ((W.rex & 1) << 3);
      if (rmLow === 5) seg = SEG_SS;
    }
    if (mod === 1) disp = (disp + r.simm(1)) & 0xffffffffffffffffn;
    if (mod === 2) disp = (disp + r.simm(4)) & 0xffffffffffffffffn;
    return { mem: true, ext, reg, base, index, scale, disp, seg, riprel, size };
  }

  /**
   * The 16-bit addressing forms, which share nothing with the 32-bit ones:
   * there is no SIB byte, only seven fixed register pairs, and the two
   * BP-based forms default to SS rather than DS because they are how a
   * compiler reaches its own stack frame.
   */
  addr16(r, W, mod, rmLow, ext, reg, size) {
    const BX = 3, BP = 5, SI = 6, DI = 7;
    const FORMS = [
      { base: BX, index: SI, seg: SEG_DS },
      { base: BX, index: DI, seg: SEG_DS },
      { base: BP, index: SI, seg: SEG_SS },
      { base: BP, index: DI, seg: SEG_SS },
      { base: SI, index: -1, seg: SEG_DS },
      { base: DI, index: -1, seg: SEG_DS },
      { base: BP, index: -1, seg: SEG_SS },
      { base: BX, index: -1, seg: SEG_DS },
    ];
    let { base, index, seg } = FORMS[rmLow];
    let disp = 0n;
    // rm 6 with mod 0 is the one form that is a bare displacement rather than
    // BP-relative, which is also why [bp] with no displacement cannot be
    // encoded and assemblers emit [bp+0] instead.
    if (rmLow === 6 && mod === 0) { base = -1; index = -1; seg = SEG_DS; disp = r.simm(2); }
    if (mod === 1) disp = (disp + r.simm(1)) & 0xffffffffffffffffn;
    if (mod === 2) disp = (disp + r.simm(2)) & 0xffffffffffffffffn;
    return { mem: true, ext, reg, base, index, scale: 0, disp, seg,
             riprel: false, a16: true, size };
  }

  // ---- code generation --------------------------------------------------
  emit(plan) {
    const f = new Func([], [I32], [I64, I64, I32, I64]);
    const T0 = 0, T1 = 1, COUNT = 2, BASE = 3;
    const g = new Gen(f, T0, T1, COUNT, plan.mode);
    const long = plan.mode === 3;
    g.BASE = BASE;
    g.la = plan.la;

    // RIP is written as an offset from wherever the block was entered, never
    // as an absolute value.  Outside long mode CS has a base, so the same
    // linear address -- which is what the block is keyed on -- can be reached
    // through more than one CS:IP pair, and a baked-in IP would be right for
    // only one of them.
    f.globalGet(G_RIP); f.localSet(BASE);
    const setRip = (delta, which) => {
      f.localGet(BASE);
      if (delta !== 0n) { f.i64const(delta); f.i64add(); }
      if (!long) { f.i64const(0xffffffffn); f.i64and(); }   // $rip_mask
      f.globalSet(which);
    };

    for (let i = 0; i < plan.instrs.length; i++) {
      const ins = plan.instrs[i];
      // The interpreter reports a fault against the instruction that raised
      // it, so the same two values have to be in place before each one.
      setRip(ins.at - plan.la, G_RIP0);
      setRip(ins.next - plan.la, G_RIP);
      f.i32const(0).i64load(4 * 8).globalSet(G_RSP0);   // RSP, for a fault to restore
      // The retired count is set before the body, not after, so that a guard
      // in the middle of an instruction returns the same number the
      // interpreter would have counted: it charges for a faulting instruction
      // exactly once, just as $run does.
      f.i32const(i + 1); f.localSet(COUNT);
      g.instr(ins);
      if (g.canFault) {
        f.globalGet(G_FAULT);
        f.if_();
        f.localGet(COUNT).return_();
        f.end();
        g.canFault = false;
      }
    }
    f.localGet(COUNT);

    return buildModule({
      memories: [{ module: 'env', name: 'state', min: 1 }],
      globals: [
        { module: 'env', name: 'g_rip', type: I64, mutable: true },
        { module: 'env', name: 'g_rip0', type: I64, mutable: true },
        { module: 'env', name: 'g_fault', type: I32, mutable: true },
        { module: 'env', name: 'g_rsp0', type: I64, mutable: true },
      ],
      imports: HELPERS.map((h) => ({ module: 'env', ...h })),
      funcs: [{ name: 'blk', fn: f }],
    });
  }
}

/**
 * Emits the body of one instruction.
 *
 * Register operands are plain state-block accesses: the general registers are
 * eight bytes apart at offset zero, so a register number is a constant offset
 * and the load or store is a single instruction with no dispatch on size.
 */
class Gen {
  constructor(f, t0, t1, count, mode) {
    this.f = f;
    this.T0 = t0; this.T1 = t1; this.COUNT = count;
    this.mode = mode;
    this.canFault = false;
  }

  // ---- register file ----------------------------------------------------
  // Without REX, the 8-bit registers 4..7 name AH/CH/DH/BH: the high byte of
  // one of the first four registers, not the low byte of the fifth.  Resolving
  // that here means the generated code never has to consult the REX state.
  byteOff(reg, rex) {
    return (!rex && reg >= 4 && reg < 8) ? (reg - 4) * 8 + 1 : reg * 8;
  }

  regRead(reg, size, rex) {
    const f = this.f;
    if (size === 1) { f.i32const(0).i32load8u(this.byteOff(reg, rex)); f.i64extendI32u(); return; }
    f.i32const(0);
    if (size === 8) f.i64load(reg * 8);
    else if (size === 4) { f.i32load(reg * 8); f.i64extendI32u(); }
    else { f.i32load16u(reg * 8); f.i64extendI32u(); }
  }

  /** Store the i64 already on the stack into a register at the given width. */
  regWrite(reg, size, rex) {
    const f = this.f;
    f.localSet(this.T0);
    if (size === 1) {
      f.i32const(0).localGet(this.T0).i32wrapI64().i32store8(this.byteOff(reg, rex));
    } else if (size === 2) {
      f.i32const(0).localGet(this.T0).i32wrapI64().i32store16(reg * 8);
    } else if (size === 4) {
      // A 32-bit write clears the upper half, so storing the masked value as a
      // full quadword is both correct and one instruction.
      f.i32const(0).localGet(this.T0).i64const(0xffffffffn).i64and().i64store(reg * 8);
    } else {
      f.i32const(0).localGet(this.T0).i64store(reg * 8);
    }
  }

  /** Push the effective address of a memory operand as an i64. */
  addr(m) {
    const f = this.f;
    if (m.riprel) { f.i64const(m.disp); return; }   // already an absolute value
    let pushed = false;
    if (m.base >= 0) { this.regRead(m.base, 8, 1); pushed = true; }
    if (m.index >= 0) {
      this.regRead(m.index, 8, 1);
      if (m.scale) { f.i64const(BigInt(m.scale)); f.i64shl(); }
      if (pushed) f.i64add(); else pushed = true;
    }
    if (!pushed) f.i64const(m.disp);
    else if (m.disp !== 0n) { f.i64const(m.disp); f.i64add(); }
    // An effective address wraps at its address size, and the components are
    // read as full quadwords regardless: addition is congruent modulo 2^16 and
    // 2^32, so masking once at the end gives the same answer as narrowing each
    // register first, for one instruction instead of three.
    if (m.a16) { f.i64const(0xffffn); f.i64and(); }
    else if (this.mode !== 3) { f.i64const(0xffffffffn); f.i64and(); }
  }

  rmRead(m, size, rex) {
    if (!m.mem) return this.regRead(m.rm, size, rex);
    const f = this.f;
    f.i32const(m.seg);
    this.addr(m);
    f.i32const(size);
    f.call(H_RD);
    this.canFault = true;
  }

  /** Write the i64 on the stack to the ModRM operand. */
  rmWrite(m, size, rex) {
    const f = this.f;
    if (!m.mem) return this.regWrite(m.rm, size, rex);
    f.localSet(this.T1);
    f.i32const(m.seg);
    this.addr(m);
    f.i32const(size);
    f.localGet(this.T1);
    f.call(H_WR);
    this.canFault = true;
  }

  /**
   * Set RIP to a relative branch target.
   *
   * The displacement counts from the end of the branch, and RIP is tracked as
   * an offset from the block entry, so the whole thing collapses to one
   * constant added to the entry value.  The mask is $jump_to's: a 16-bit jump
   * wraps within the segment rather than escaping it.
   */
  jumpTarget(ins) {
    const f = this.f;
    const delta = (ins.next - this.la) + ins.disp;
    f.localGet(this.BASE);
    f.i64const(BigInt.asIntN(64, delta));
    f.i64add();
    if (this.mode !== 3) {
      f.i64const(ins.W.opsize === 2 ? 0xffffn : 0xffffffffn);
      f.i64and();
    }
    f.globalSet(0);                       // G_RIP
  }

  instr(ins) {
    const f = this.f;
    const rex = ins.W.rex;
    switch (ins.kind) {
      case 'nop':
        return;

      case 'mov':
        if (ins.dirRM) {                            // r/m <- reg
          this.regRead(ins.m.reg, ins.size, rex);
          this.rmWrite(ins.m, ins.size, rex);
        } else {                                    // reg <- r/m
          this.rmRead(ins.m, ins.size, rex);
          this.regWrite(ins.m.reg, ins.size, rex);
        }
        return;

      case 'mov_ri':
        f.i64const(ins.imm);
        this.regWrite(ins.reg, ins.size, rex);
        return;

      case 'mov_mi':
        f.i64const(ins.imm);
        this.rmWrite(ins.m, ins.size, rex);
        return;

      case 'lea':
        this.addr(ins.m);
        // LEA truncates to the operand size, and never touches memory.
        if (ins.size !== 8) {
          f.i64const(ins.size === 2 ? 0xffffn : 0xffffffffn);
          f.i64and();
        }
        this.regWrite(ins.m.reg, ins.size, rex);
        return;

      case 'alu': {
        // Operand order is what distinguishes the two directions, and getting
        // it backwards is invisible for AND but not for SUB or CMP.
        f.i32const(ins.test ? 4 /* AND, result discarded */ : ins.aluop);
        if (ins.dirRM) {
          this.rmRead(ins.m, ins.size, rex);
          this.regRead(ins.m.reg, ins.size, rex);
        } else {
          this.regRead(ins.m.reg, ins.size, rex);
          this.rmRead(ins.m, ins.size, rex);
        }
        f.i32const(ins.size);
        f.call(H_ALU);
        // CMP (7) and TEST keep only the flags.
        if (ins.test || ins.aluop === 7) { f.drop(); return; }
        if (ins.dirRM) this.rmWrite(ins.m, ins.size, rex);
        else this.regWrite(ins.m.reg, ins.size, rex);
        return;
      }

      case 'alu_mi': {
        f.i32const(ins.aluop);
        this.rmRead(ins.m, ins.size, rex);
        f.i64const(ins.imm);
        f.i32const(ins.size);
        f.call(H_ALU);
        if (ins.aluop === 7) { f.drop(); return; }
        this.rmWrite(ins.m, ins.size, rex);
        return;
      }

      case 'alu_ai': {
        f.i32const(ins.aluop);
        this.regRead(0, ins.size, rex);
        f.i64const(ins.imm);
        f.i32const(ins.size);
        f.call(H_ALU);
        if (ins.aluop === 7) { f.drop(); return; }
        this.regWrite(0, ins.size, rex);
        return;
      }

      case 'push':
        this.regRead(ins.reg, ins.size, rex);
        f.i32const(ins.size);
        f.call(H_PUSH);
        this.canFault = true;
        return;

      case 'pop':
        f.i32const(ins.size);
        f.call(H_POP);
        // A pop that faulted returns zero, and writing that to the register
        // would corrupt state the interpreter leaves untouched, so the guard
        // has to come before the write rather than at the end of the
        // instruction.  The popped value stays on the stack across the test.
        f.globalGet(G_FAULT);
        f.if_();
        f.localGet(this.COUNT).return_();
        f.end();
        this.regWrite(ins.reg, ins.size, rex);
        return;

      case 'jcc':
        // The fall-through RIP is already in place from the instruction
        // preamble, so only the taken path has anything to write.
        f.i32const(ins.cc);
        f.call(H_COND);
        f.if_();
        this.jumpTarget(ins);
        f.end();
        return;

      case 'jmp':
        this.jumpTarget(ins);
        return;

      default:
        throw new Unsupported(`emit ${ins.kind}`);
    }
  }
}
