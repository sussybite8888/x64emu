// ---------------------------------------------------------------------------
//  Local APIC and I/O APIC, for one processor.
//
//  Windows XP installed on a machine with an APIC keeps the HAL it was
//  installed with (halaacpi, "ACPI Uniprocessor PC"), and that HAL drives the
//  local APIC directly: it reads the task priority register on its first
//  interrupt-related call, and takes every device interrupt through the I/O
//  APIC.  With nothing at these addresses the reads came back as all ones, the
//  boot faulted on them until its stack ran out, and the machine triple
//  faulted.  Linux reads the local APIC too whenever CPUID reports one, and
//  waited forever for an IPI whose ICR busy bit was stuck at one.
//
//  The 8259 pair stays: its output reaches the processor through LINT0 when
//  the local APIC is in virtual-wire mode (or software disabled, the state the
//  BIOS leaves it in), so older systems that never touch the APIC see no
//  difference.  ISA lines go to both controllers, the way the chipset wires
//  them, and the system decides which one it listens to.
// ---------------------------------------------------------------------------

export const LAPIC_BASE = 0xfee00000;
export const IOAPIC_BASE = 0xfec00000;
export const IOAPIC_PINS = 24;

// The timer counts the bus clock through a divider.  Guests calibrate it
// against the PIT or the PM timer, so the value only has to be stable.
const BUS_HZ = 100_000_000;

const LVT_MASKED = 0x10000;
const DM_FIXED = 0, DM_LOWEST = 1, DM_NMI = 4, DM_EXTINT = 7;

/** Highest set bit of a 256-bit register held as eight 32-bit words, or -1. */
function highest(words) {
  for (let i = 7; i >= 0; i--) {
    if (words[i]) return i * 32 + 31 - Math.clz32(words[i]);
  }
  return -1;
}
const setBit = (words, v) => { words[v >> 5] |= 1 << (v & 31); };
const clearBit = (words, v) => { words[v >> 5] &= ~(1 << (v & 31)); };
const testBit = (words, v) => (words[v >> 5] >>> (v & 31)) & 1;

export class LocalApic {
  /**
   * @param {object} hooks
   *   nowNs()      virtual time, current to the instruction
   *   baseMsr()    IA32_APIC_BASE as the guest last wrote it
   *   onChange()   something may have become deliverable
   *   onDeadline() the timer was armed or rearmed
   */
  constructor({ nowNs, baseMsr, onChange = () => {}, onDeadline = () => {} }) {
    this.base = BigInt(LAPIC_BASE);
    this.length = 0x1000;
    this.nowNs = nowNs;
    this.baseMsr = baseMsr;
    this.onChange = onChange;
    this.onDeadline = onDeadline;
    this.ioapic = null;
    this.irr = new Uint32Array(8);
    this.isr = new Uint32Array(8);
    this.tmr = new Uint32Array(8);
    this.reset();
  }

  reset() {
    this.id = 0;
    this.tpr = 0;
    this.ldr = 0;
    this.dfr = 0xffffffff;
    this.svr = 0xff;                        // software disabled
    this.irr.fill(0); this.isr.fill(0); this.tmr.fill(0);
    this.esr = 0;
    this.icrLo = 0; this.icrHi = 0;
    // timer, thermal, performance, LINT0, LINT1, error
    this.lvt = [LVT_MASKED, LVT_MASKED, LVT_MASKED, LVT_MASKED, LVT_MASKED, LVT_MASKED];
    this.initialCount = 0;
    this.divideConfig = 0;
    this.timerStart = 0;
    this.deadline = Infinity;               // next expiry, in virtual ns
  }

  /** Globally enabled through the MSR and software enabled through SVR. */
  get accepting() {
    return (this.baseMsr() & 0x800) !== 0 && (this.svr & 0x100) !== 0;
  }

  /** The 8259's output reaches the processor through LINT0 as ExtINT. */
  get extIntOpen() {
    if (!this.accepting) return true;       // as the BIOS leaves it
    const lint0 = this.lvt[3];
    return !(lint0 & LVT_MASKED) && ((lint0 >> 8) & 7) === DM_EXTINT;
  }

  get ppr() {
    const isrv = highest(this.isr);
    const isrClass = isrv < 0 ? 0 : isrv & 0xf0;
    return (this.tpr & 0xf0) >= isrClass ? this.tpr & 0xff : isrClass;
  }

  /** The vector the processor would take now, or -1. */
  pending() {
    const v = highest(this.irr);
    if (v < 0 || (v & 0xf0) <= (this.ppr & 0xf0)) return -1;
    return v;
  }

  /** Called by the processor when it takes the interrupt. */
  acknowledge() {
    const v = this.pending();
    if (v < 0) return -1;
    clearBit(this.irr, v);
    setBit(this.isr, v);
    return v;
  }

  /** An interrupt message arrives from the I/O APIC, an IPI or the timer. */
  accept(vector, level = false) {
    if (vector < 16) { this.esr |= 0x40; return; }   // illegal vector
    setBit(this.irr, vector);
    if (level) setBit(this.tmr, vector); else clearBit(this.tmr, vector);
    this.onChange();
  }

  eoi() {
    const v = highest(this.isr);
    if (v < 0) return;
    clearBit(this.isr, v);
    if (testBit(this.tmr, v)) {
      clearBit(this.tmr, v);
      this.ioapic?.eoi(v);
    }
    this.onChange();
  }

  // ---- timer ---------------------------------------------------------------
  get divisor() {
    const d = ((this.divideConfig & 8) >> 1) | (this.divideConfig & 3);
    return d === 7 ? 1 : 2 << d;
  }

  get periodNs() { return (this.initialCount * this.divisor * 1e9) / BUS_HZ; }

  currentCount() {
    if (!this.initialCount) return 0;
    const ticks = Math.floor(((this.nowNs() - this.timerStart) * BUS_HZ) / 1e9 / this.divisor);
    if (ticks < 0) return this.initialCount;
    if ((this.lvt[0] >> 17) & 1) return this.initialCount - (ticks % this.initialCount);
    return Math.max(0, this.initialCount - ticks);
  }

  armTimer() {
    this.timerStart = this.nowNs();
    this.deadline = this.initialCount ? this.timerStart + this.periodNs : Infinity;
    this.onDeadline();
  }

  /** Fire the timer if it is due.  Several missed periods make one interrupt. */
  poll(now = this.nowNs()) {
    if (now < this.deadline) return;
    if ((this.lvt[0] >> 17) & 1) {
      const p = this.periodNs;
      this.deadline += Math.ceil((now - this.deadline + 1) / p) * p;
    } else {
      this.deadline = Infinity;
    }
    const lvt = this.lvt[0];
    if (!(lvt & LVT_MASKED)) this.accept(lvt & 0xff);
  }

  /** When the timer next needs attention, for a halted processor to sleep to. */
  get nextDeadline() {
    return this.lvt[0] & LVT_MASKED ? Infinity : this.deadline;
  }

  // ---- interprocessor interrupts ---------------------------------------------
  sendIpi() {
    const lo = this.icrLo;
    const mode = (lo >> 8) & 7;
    const shorthand = (lo >> 18) & 3;
    const dest = this.icrHi >>> 24;
    let self;
    if (shorthand === 1 || shorthand === 2) self = true;
    else if (shorthand === 3) self = false;
    else if (lo & 0x800) self = (dest & (this.ldr >>> 24)) !== 0;   // logical
    else self = dest === this.id || dest === 0xff;
    // There is no other processor for INIT and startup messages to reach.
    if (self && (mode === DM_FIXED || mode === DM_LOWEST)) this.accept(lo & 0xff);
  }

  // ---- registers ---------------------------------------------------------------
  read(off) {
    const reg = off & 0xff0;
    if (reg >= 0x100 && reg < 0x180) return this.isr[(reg - 0x100) >> 4];
    if (reg >= 0x180 && reg < 0x200) return this.tmr[(reg - 0x180) >> 4];
    if (reg >= 0x200 && reg < 0x280) return this.irr[(reg - 0x200) >> 4];
    switch (reg) {
      case 0x020: return this.id << 24;
      case 0x030: return 0x00050014;        // version 0x14, six LVT entries
      case 0x080: return this.tpr;
      case 0x090: return 0;                 // arbitration priority
      case 0x0a0: return this.ppr;
      case 0x0d0: return this.ldr;
      case 0x0e0: return this.dfr;
      case 0x0f0: return this.svr;
      case 0x280: return this.esr;
      case 0x300: return this.icrLo;        // delivery status: always idle
      case 0x310: return this.icrHi;
      case 0x320: case 0x330: case 0x340: case 0x350: case 0x360: case 0x370:
        return this.lvt[(reg - 0x320) >> 4];
      case 0x380: return this.initialCount;
      case 0x390: return this.currentCount();
      case 0x3e0: return this.divideConfig;
      default: return 0;
    }
  }

  write(off, size, val) {
    const reg = off & 0xff0;
    val >>>= 0;
    switch (reg) {
      case 0x020: this.id = val >>> 24; return;
      case 0x080: this.tpr = val & 0xff; this.onChange(); return;
      case 0x0b0: this.eoi(); return;
      case 0x0d0: this.ldr = val & 0xff000000; return;
      case 0x0e0: this.dfr = (val | 0x0fffffff) >>> 0; return;
      case 0x0f0:
        this.svr = val & 0x3ff;
        // Software disabling masks every LVT entry.
        if (!(val & 0x100)) this.lvt = this.lvt.map((e) => e | LVT_MASKED);
        this.onChange();
        return;
      case 0x280: this.esr = 0; return;
      case 0x300: this.icrLo = val & ~0x1000; this.sendIpi(); return;
      case 0x310: this.icrHi = val & 0xff000000; return;
      case 0x320: case 0x330: case 0x340: case 0x350: case 0x360: case 0x370: {
        const i = (reg - 0x320) >> 4;
        const keep = [0x700ff, 0x107ff, 0x107ff, 0x1a7ff, 0x1a7ff, 0x100ff][i];
        let e = val & keep;
        if (!(this.svr & 0x100)) e |= LVT_MASKED;
        this.lvt[i] = e;
        if (i === 0) this.onDeadline();
        this.onChange();
        return;
      }
      case 0x380: this.initialCount = val; this.armTimer(); return;
      case 0x3e0: this.divideConfig = val & 0xb; return;
      default:
    }
  }
}

export class IoApic {
  constructor(lapic) {
    this.base = BigInt(IOAPIC_BASE);
    this.length = 0x1000;
    this.lapic = lapic;
    lapic.ioapic = this;
    this.lo = new Uint32Array(IOAPIC_PINS);
    this.hi = new Uint32Array(IOAPIC_PINS);
    this.reset();
  }

  reset() {
    this.id = 1;
    this.select = 0;
    this.lo.fill(LVT_MASKED);
    this.hi.fill(0);
    this.pendingPins = 0;                   // edges seen, or levels asserted, not yet sent
    this.levels = 0;                        // lines currently high
  }

  /** An interrupt line changed.  A raise always counts as an edge, as on the 8259s. */
  setLine(pin, high) {
    if (pin >= IOAPIC_PINS) return;
    const bit = 1 << pin;
    if (high) {
      this.levels |= bit;
      this.pendingPins |= bit;
    } else {
      this.levels &= ~bit;
      if (this.lo[pin] & 0x8000) this.pendingPins &= ~bit;   // level: gone again
    }
    this.service();
  }

  service() {
    for (let pin = 0; pin < IOAPIC_PINS; pin++) {
      const bit = 1 << pin;
      if (!(this.pendingPins & bit)) continue;
      const lo = this.lo[pin];
      if (lo & LVT_MASKED) continue;        // held until unmasked
      const mode = (lo >> 8) & 7;
      const level = (lo & 0x8000) !== 0;
      if (level && (lo & 0x4000)) continue; // remote IRR: awaiting EOI
      this.pendingPins &= ~bit;
      // ExtINT pins carry the 8259's output, which the processor already sees
      // through its own path; NMI and the rest have nowhere to go here.
      if (mode !== DM_FIXED && mode !== DM_LOWEST) continue;
      if (level) this.lo[pin] |= 0x4000;
      // One processor: every destination that names anything names it.
      this.lapic.accept(lo & 0xff, level);
    }
  }

  /** The local APIC finished a level-triggered vector. */
  eoi(vector) {
    for (let pin = 0; pin < IOAPIC_PINS; pin++) {
      if ((this.lo[pin] & 0xff) !== vector || !(this.lo[pin] & 0x4000)) continue;
      this.lo[pin] &= ~0x4000;
      if (this.levels & (1 << pin)) this.pendingPins |= 1 << pin;
    }
    this.service();
  }

  /** An ExtINT pin that is unmasked lets the 8259 through, virtual-wire style. */
  get extIntOpen() {
    for (let pin = 0; pin < IOAPIC_PINS; pin++) {
      const lo = this.lo[pin];
      if (!(lo & LVT_MASKED) && ((lo >> 8) & 7) === DM_EXTINT) return true;
    }
    return false;
  }

  readRegister(r) {
    if (r === 0x00) return this.id << 24;
    if (r === 0x01) return ((IOAPIC_PINS - 1) << 16) | 0x11;
    if (r === 0x02) return this.id << 24;
    if (r >= 0x10 && r < 0x10 + IOAPIC_PINS * 2) {
      const pin = (r - 0x10) >> 1;
      return r & 1 ? this.hi[pin] : this.lo[pin];
    }
    return 0;
  }

  writeRegister(r, val) {
    if (r === 0x00) { this.id = (val >>> 24) & 0x0f; return; }
    if (r >= 0x10 && r < 0x10 + IOAPIC_PINS * 2) {
      const pin = (r - 0x10) >> 1;
      if (r & 1) { this.hi[pin] = val & 0xff000000; return; }
      // delivery status and remote IRR are read-only
      this.lo[pin] = (val & ~0x5000) | (this.lo[pin] & 0x4000);
      if (!(this.lo[pin] & 0x8000)) this.lo[pin] &= ~0x4000;
      this.service();
      this.lapic.onChange();
    }
  }

  read(off) {
    if (off === 0x00) return this.select;
    if (off === 0x10) return this.readRegister(this.select);
    return 0;
  }

  write(off, size, val) {
    if (off === 0x00) { this.select = val & 0xff; return; }
    if (off === 0x10) { this.writeRegister(this.select, val >>> 0); return; }
    if (off === 0x40) this.eoi(val & 0xff);
  }
}
