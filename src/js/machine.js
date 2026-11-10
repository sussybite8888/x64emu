// ---------------------------------------------------------------------------
//  Machine: owns guest memory, instantiates the WAT core, routes I/O.
//  Runs unchanged in Node and in the browser.
// ---------------------------------------------------------------------------

// Guest RAM has its own 64-bit memory now, so physical addresses index it
// directly and there is no base offset to add.
export const RAM_BASE = 0;

// Wasm pages are 64 KiB.
const PAGE = 65536;

// The state block plus the JIT's tables (see part 85 of the core).
const STATE_PAGES = 72;

// Physical pages holding compiled code, one bit each, inside the state block.
// The host checks it before telling the core about a write of its own.
const JIT_CODE_MAP = 0x30000;

// segment register indices, matching the WAT core
export const ES = 0, CS = 1, SS = 2, DS = 3, FS = 4, GS = 5;

// GPR indices
export const RAX = 0, RCX = 1, RDX = 2, RBX = 3,
             RSP = 4, RBP = 5, RSI = 6, RDI = 7;

export const EXIT_BUDGET = 0, EXIT_HALT = 1, EXIT_STOP = 2, EXIT_TRIPLE = 3;

export class Machine {
  constructor(opts = {}) {
    this.ramSize = opts.ramSize ?? 128 * 1024 * 1024;

    // Memory 0 holds CPU state, the TLBs and the JIT's tables, and never
    // changes size.  The core declares the minimum it needs.
    this.stateMem = new WebAssembly.Memory({ initial: STATE_PAGES });
    this.stateU8 = new Uint8Array(this.stateMem.buffer);
    this.stateU32 = new Uint32Array(this.stateMem.buffer);
    // The general registers are plain memory at the base of the state block, so
    // the host can reach them without crossing into wasm.  The BIOS touches a
    // dozen or more of them per trap and that boundary is not free.
    this.stateI64 = new BigInt64Array(this.stateMem.buffer);

    // Memory 1 is guest RAM: 64-bit indexed, so it is not bounded by the 4 GiB
    // ceiling a wasm32 memory imposes.  No maximum is declared, which lets it
    // grow to whatever the host will actually hand out.
    const pages = BigInt(Math.ceil(this.ramSize / PAGE));
    try {
      this.memory = new WebAssembly.Memory({ initial: pages, address: 'i64' });
    } catch (err) {
      throw new Error(
        `could not allocate ${(this.ramSize / 2 ** 30).toFixed(2)} GiB of guest ` +
        `RAM: ${err.message}`);
    }
    this.refreshViews();

    this.ioRead = () => 0xff;      // replaced by the device layer
    this.ioWrite = () => {};
    this.mmioRead = () => 0n;
    this.mmioWrite = () => {};
    this.irqAck = () => -1;

    this.instructionsRun = 0;
    this.exports = null;
  }

  /** Rebuild the typed-array views; required after any memory.grow. */
  refreshViews() {
    this.u8 = new Uint8Array(this.memory.buffer);
    this.dv = new DataView(this.memory.buffer);
    this.u32 = this.stateU32;          // state block, for host-side pokes
  }

  /** Enlarge guest RAM.  Returns the new size in bytes. */
  growRam(extraBytes) {
    const pages = BigInt(Math.ceil(extraBytes / PAGE));
    if (pages <= 0n) return this.ramSize;
    if (this.memory.grow(pages) === -1n) {
      throw new Error('host refused to grow guest RAM');
    }
    this.ramSize += Number(pages) * PAGE;
    this.refreshViews();
    this.exports?.set_ram_size(BigInt(this.ramSize));
    return this.ramSize;
  }

  async load(wasmBytes) {
    // Compiled blocks are published into this table and reached from the core
    // with call_indirect.  It exists even when nothing will ever be compiled,
    // because the core imports it unconditionally; an empty table costs
    // nothing.
    this.jitTable = new WebAssembly.Table({ initial: 1, element: 'anyfunc' });
    const imports = {
      env: {
        state: this.stateMem,
        ram: this.memory,
        jit: this.jitTable,
        io_read: (port, size) => this.ioRead(port, size) >>> 0,
        io_write: (port, size, val) => this.ioWrite(port, size, val >>> 0),
        mmio_read: (addr, size) => this.mmioRead(addr, size),
        mmio_write: (addr, size, val) => this.mmioWrite(addr, size, val),
        irq_ack: () => this.irqAck(),
        // With no JIT attached there is nothing to be exact about.
        jit_precise: (pa, len) => (this.jitPrecise ? this.jitPrecise(Number(pa), len) : 1),
        host_log: (tag, a, b) => console.log(`[cpu ${tag}] ${a.toString(16)} ${b.toString(16)}`),
        // WebAssembly has no transcendental instructions, so the x87 unit
        // borrows the host's.
        f_sin: Math.sin,
        f_cos: Math.cos,
        f_atan2: Math.atan2,
        f_log2: Math.log2,
        f_exp2: (x) => 2 ** x,
        f_fmod: (a, b) => a % b,
      },
    };
    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    this.exports = instance.exports;
    this.exports.init(BigInt(this.ramSize));
    this.exports.reset();
    return this;
  }

  // ---- guest physical memory helpers -------------------------------------
  rd8(pa)  { return this.u8[pa]; }
  rd16(pa) { return this.dv.getUint16(pa, true); }
  rd32(pa) { return this.dv.getUint32(pa, true); }
  rd64(pa) { return this.dv.getBigUint64(pa, true); }
  wr8(pa, v)  { this.hostWrote(pa, 1); this.u8[pa] = v; }
  wr16(pa, v) { this.hostWrote(pa, 2); this.dv.setUint16(pa, v, true); }
  wr32(pa, v) { this.hostWrote(pa, 4); this.dv.setUint32(pa, v, true); }
  wr64(pa, v) { this.hostWrote(pa, 8); this.dv.setBigUint64(pa, BigInt(v), true); }

  /**
   * A write by the host -- a BIOS disk read, a mode set clearing video memory
   * -- that lands on compiled code has to invalidate it, exactly as a guest
   * store would.  The bitmap is read here so that the common case, a page
   * with no code on it, never crosses into the core.
   */
  hostWrote(pa, len) {
    const first = Math.floor(pa / 4096), last = Math.floor((pa + len - 1) / 4096);
    for (let p = first; p <= last; p++) {
      const i = p & 0xfffff;
      if (this.stateU8[JIT_CODE_MAP + (i >> 3)] & (1 << (i & 7))) {
        this.exports.jit_host_write(BigInt(pa), len);
        return;
      }
    }
  }

  /** Copy into guest RAM, in chunks so arbitrarily large images are fine. */
  writeBytes(pa, bytes) {
    this.hostWrote(pa, bytes.length);
    if (bytes.length <= 0x400000) { this.u8.set(bytes, pa); return; }
    const step = 0x400000;
    for (let off = 0; off < bytes.length; off += step) {
      this.u8.set(bytes.subarray(off, Math.min(off + step, bytes.length)), pa + off);
    }
  }

  readBytes(pa, len) {
    return this.u8.subarray(pa, pa + len);
  }

  // ---- CPU state ----------------------------------------------------------
  get reg()   { return (i) => this.exports.get_reg(i); }
  setReg(i, v) { this.stateI64[i] = BigInt(v); }
  getReg(i)    { return this.stateI64[i]; }

  // Segment caches sit at 0x100, 32 bytes each, with the base eight bytes in.
  // Reading it straight out of the block keeps the BIOS off the wasm boundary,
  // which it would otherwise cross several times per trap.
  segBaseFast(s) { return this.stateI64[32 + s * 4 + 1]; }
  segSelFast(s) { return this.stateU32[(0x100 + s * 32) >> 2] & 0xffff; }
  get rip()    { return this.exports.get_rip(); }
  set rip(v)   { this.exports.set_rip(BigInt(v)); }
  get flags()  { return this.exports.get_flags(); }
  set flags(v) { this.exports.set_flags(BigInt(v)); }
  get mode()   { return this.exports.get_mode(); }
  get vm()     { return this.exports.get_vm() !== 0; }
  // CR0.PG, read from the state block without crossing into wasm
  get pagingOn() { return (this.stateU32[0x90 >> 2] & 0x80000000) !== 0; }
  get halted() { return this.exports.is_halted() !== 0; }

  setSeg(s, sel, base, limit, attr) {
    this.exports.set_seg(s, sel, BigInt(base), limit, attr);
  }
  setCR(i, v)  { this.exports.set_cr(i, BigInt(v)); }
  getCR(i)     { return this.exports.get_cr(i); }
  setEfer(v)   { this.exports.set_efer(BigInt(v)); }
  setGdtr(b, l) { this.exports.set_gdtr(BigInt(b), l); }
  setIdtr(b, l) { this.exports.set_idtr(BigInt(b), l); }
  setIrqLine(v) { this.exports.set_irq_line(v ? 1 : 0); }
  reset()       { this.exports.reset(); }
  wake()        { this.exports.wake(); }
  stop()        { this.exports.stop(); }

  run(budget) {
    const r = this.exports.run(budget);
    this.instructionsRun = Number(this.exports.get_cycles());
    return r;
  }

  // Resolve a guest virtual address for inspection; null when unmapped.
  translate(va) {
    const pa = this.exports.debug_translate(BigInt(va));
    return pa === -1n ? null : pa;
  }

  // Resolve a linear address as the running code would access it, setting
  // the accessed and dirty bits; null where that access would fault.
  translateFor(va, write) {
    const pa = this.exports.lin_translate(BigInt(va), write ? 1 : 0);
    return pa === -1n ? null : Number(pa);
  }

  // ---- segment attribute helper ------------------------------------------
  //  bit0 present, bit1 writable/readable, bit2 code, bit3 conforming,
  //  bit4 long, bit5 default32, bits8-9 DPL, bit12 non-system
  static segAttr({ code = false, long: isLong = false, db = false, dpl = 0 }) {
    let a = 1 | 2 | (1 << 12);
    if (code) a |= 4;
    if (isLong) a |= 1 << 4;
    if (db) a |= 1 << 5;
    a |= (dpl & 3) << 8;
    return a;
  }
}

export const SEG_CODE64 = Machine.segAttr({ code: true, long: true });
export const SEG_CODE32 = Machine.segAttr({ code: true, db: true });
export const SEG_CODE16 = Machine.segAttr({ code: true });
export const SEG_DATA32 = Machine.segAttr({ db: true });
export const SEG_DATA16 = Machine.segAttr({});
