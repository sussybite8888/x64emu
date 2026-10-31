// ---------------------------------------------------------------------------
//  Platform devices: interrupt controllers, timer, serial console, RTC, and
//  the handful of chipset ports a PC-class kernel pokes during boot.
// ---------------------------------------------------------------------------

import { PciBus } from './pci.js';

// ---- Intel 8259A pair ------------------------------------------------------
class PIC {
  constructor(isMaster, cascade) {
    this.isMaster = isMaster;
    this.cascade = cascade;      // the slave, when this is the master
    this.irr = 0;                // requests
    this.imr = 0xff;             // masks (1 = masked)
    this.isr = 0;                // in service
    this.base = isMaster ? 0x08 : 0x70;
    this.initState = 0;
    this.icw4Needed = false;
    this.autoEoi = false;
    this.readIsr = false;
  }

  /** Power-on state.  A bit left in the in-service register outlives a reboot
   *  and blocks that line and every lower-priority one for good. */
  reset() {
    this.irr = 0;
    this.imr = 0xff;
    this.isr = 0;
    this.initState = 0;
    this.icw4Needed = false;
    this.autoEoi = false;
    this.readIsr = false;
    this.base = this.isMaster ? 0x08 : 0x70;
  }

  raise(line) { this.irr |= 1 << line; }
  lower(line) { this.irr &= ~(1 << line); }

  // highest priority unmasked request that outranks anything in service
  pending() {
    const ready = this.irr & ~this.imr;
    if (!ready) return -1;
    for (let i = 0; i < 8; i++) {
      const bit = 1 << i;
      if (this.isr & bit) return -1;      // a higher priority IRQ is in service
      if (ready & bit) return i;
    }
    return -1;
  }

  ack(line) {
    this.irr &= ~(1 << line);
    if (!this.autoEoi) this.isr |= 1 << line;
  }

  write(port, val) {
    const isCommand = (port & 1) === 0;
    if (isCommand) {
      if (val & 0x10) {                    // ICW1
        this.initState = 1;
        this.icw4Needed = (val & 1) !== 0;
        this.imr = 0;
        this.isr = 0;
        return;
      }
      if (val & 0x08) {                    // OCW3
        if (val & 2) this.readIsr = (val & 1) !== 0;
        return;
      }
      // OCW2
      const kind = val >> 5;
      if (kind === 1) {                    // non-specific EOI
        for (let i = 0; i < 8; i++) {
          if (this.isr & (1 << i)) { this.isr &= ~(1 << i); break; }
        }
      } else if (kind === 3) {             // specific EOI
        this.isr &= ~(1 << (val & 7));
      }
      return;
    }
    // data port
    switch (this.initState) {
      case 1: this.base = val & 0xf8; this.initState = 2; return;   // ICW2
      case 2: this.initState = this.icw4Needed ? 3 : 0; return;      // ICW3
      case 3: this.autoEoi = (val & 2) !== 0; this.initState = 0; return;  // ICW4
      default: this.imr = val; return;                               // OCW1
    }
  }

  read(port) {
    if ((port & 1) === 0) return this.readIsr ? this.isr : this.irr;
    return this.imr;
  }
}

export class PicPair {
  constructor() {
    this.slave = new PIC(false, null);
    this.master = new PIC(true, this.slave);
    // Told whenever a request, mask or EOI may have made something
    // deliverable, so the CPU sees it at its next instruction rather than at
    // the end of the slice it is running.
    this.onChange = () => {};
    // The same ISA lines run to the I/O APIC.
    this.onLine = () => {};
  }

  reset() { this.master.reset(); this.slave.reset(); }

  raise(irq) {
    if (irq < 8) this.master.raise(irq);
    else this.slave.raise(irq - 8);
    this.syncCascade();
    this.onLine(irq, true);
    this.onChange();
  }

  lower(irq) {
    if (irq < 8) this.master.lower(irq);
    else this.slave.lower(irq - 8);
    this.syncCascade();
    this.onLine(irq, false);
  }

  /**
   * IR2 of the master is not a latch: it is wired to the slave's INT output and
   * follows it continuously.  Treating it as an ordinary request bit strands
   * every later slave interrupt, because anything that clears it while the
   * slave is masked leaves the line low once the mask is lifted.
   */
  syncCascade() {
    if (this.slave.pending() >= 0) this.master.raise(2);
    else this.master.lower(2);
  }

  hasPending() {
    this.syncCascade();
    return this.master.pending() >= 0;
  }

  // Returns the interrupt vector to inject, or -1.
  acknowledge() {
    this.syncCascade();
    const line = this.master.pending();
    if (line < 0) return -1;
    if (line === 2) {
      const s = this.slave.pending();
      if (s < 0) { this.master.ack(2); return this.master.base + 2; }
      this.master.ack(2);
      this.slave.ack(s);
      return this.slave.base + s;
    }
    this.master.ack(line);
    return this.master.base + line;
  }

  io(port, size, val, isWrite) {
    const pic = port < 0xa0 ? this.master : this.slave;
    if (isWrite) {
      pic.write(port, val & 0xff);
      this.syncCascade();          // a mask or EOI changes what the slave offers
      this.onChange();
      return 0;
    }
    return pic.read(port);
  }
}

// ---- Intel 8254 programmable interval timer --------------------------------
//  Channel 0 drives the periodic tick on IRQ 0.  The counters are derived from
//  the machine's virtual clock rather than being free-run, because guests read
//  them back to measure time: latch, read the low byte, read the high byte, and
//  compare against a previous sample.  A counter that is not a function of time
//  makes those loops either spin forever or measure nonsense.
export class PIT {
  constructor() {
    this.channels = [0, 1, 2].map(() => ({
      reload: 0x10000, mode: 3, access: 3,
      writeLo: true, readLo: true,
      latched: null, startNs: 0,
    }));
    this.ticksPending = 0;
    this.nowNs = () => 0;          // supplied by the emulator
  }

  reset() {
    for (const c of this.channels) {
      Object.assign(c, { reload: 0x10000, mode: 3, access: 3,
                         writeLo: true, readLo: true, latched: null, startNs: 0 });
    }
    this.ticksPending = 0;
  }

  get hz() {
    const r = this.channels[0].reload || 0x10000;
    return 1193182 / r;
  }

  /** The value a channel's counter holds right now. */
  currentCount(ch) {
    const c = this.channels[ch];
    const r = c.reload || 0x10000;
    const ticks = Math.floor((this.nowNs() - c.startNs) * 1.193182e-3);
    if (ticks < 0) return r & 0xffff;
    // modes 0 and 1 count down once and stop; the rest reload and wrap
    if (c.mode === 0 || c.mode === 1) return Math.max(0, r - ticks) & 0xffff;
    return (r - (ticks % r)) & 0xffff;
  }

  // Advance by a wall-clock delta in milliseconds, returning whole ticks.
  advance(ms) {
    this.ticksPending += (ms / 1000) * this.hz;
    const whole = Math.floor(this.ticksPending);
    this.ticksPending -= whole;
    return whole;
  }

  write(port, val) {
    val &= 0xff;
    if (port === 0x43) {
      const ch = val >> 6;
      if (ch === 3) return;                     // read-back command
      const c = this.channels[ch];
      const access = (val >> 4) & 3;
      if (access === 0) {                       // counter latch
        c.latched = this.currentCount(ch);
        c.readLo = true;
        return;
      }
      c.access = access;
      c.mode = (val >> 1) & 7;
      c.writeLo = true;
      c.latched = null;
      return;
    }
    const c = this.channels[port & 3];
    if (c.access === 1) { c.reload = val; }
    else if (c.access === 2) { c.reload = val << 8; }
    else if (c.writeLo) { c.reload = (c.reload & 0xff00) | val; c.writeLo = false; return; }
    else { c.reload = (c.reload & 0xff) | (val << 8); c.writeLo = true; }
    if (c.reload === 0) c.reload = 0x10000;
    // writing a count restarts the channel
    c.startNs = this.nowNs();
    c.latched = null;
  }

  read(port) {
    if (port === 0x43) return 0;
    const ch = port & 3;
    const c = this.channels[ch];
    const value = c.latched !== null ? c.latched : this.currentCount(ch);
    if (c.access === 1) { c.latched = null; return value & 0xff; }
    if (c.access === 2) { c.latched = null; return (value >> 8) & 0xff; }
    if (c.readLo) { c.readLo = false; return value & 0xff; }
    c.readLo = true;
    c.latched = null;
    return (value >> 8) & 0xff;
  }
}

// ---- 16550A UART -----------------------------------------------------------
//  The transmitter is always empty, since bytes leave the moment they are
//  written, so its interrupt is pending whenever it is enabled -- except that,
//  as on the real part, reading IIR while it is the reported source clears it
//  until the next byte is written or the interrupt is enabled again.  Linux
//  writes to a tty by enabling that interrupt and waiting for it; a UART that
//  only interrupted after a byte had been written never started transmitting,
//  which is why the shell prompt used to go missing.
export class Serial {
  constructor(base, irq, pic) {
    this.base = base;
    this.irq = irq;
    this.pic = pic;
    this.rxQueue = [];
    this.thrPending = false;
    this.ier = 0;
    this.lcr = 0;
    this.mcr = 0;
    this.fcr = 0;
    this.scratch = 0;
    this.divisor = 12;
    this.onByte = () => {};        // host sink for transmitted characters
  }

  get dlab() { return (this.lcr & 0x80) !== 0; }

  // line status: transmitter always ready, receiver ready when queued
  get lsr() { return 0x60 | (this.rxQueue.length ? 1 : 0); }

  receive(byte) {
    this.rxQueue.push(byte & 0xff);
    this.updateIrq();
  }

  receiveString(s) {
    for (const ch of s) this.receive(ch.charCodeAt(0));
  }

  // The line follows the conditions: up while any enabled one holds.
  updateIrq() {
    const rxReady = this.rxQueue.length > 0 && (this.ier & 1);
    const txEmpty = this.thrPending && (this.ier & 2);
    if (rxReady || txEmpty) this.pic.raise(this.irq);
    else this.pic.lower(this.irq);
  }

  // Interrupt identification: received data outranks an empty transmitter,
  // and reporting the transmitter clears it.
  readIir() {
    if (this.rxQueue.length && (this.ier & 1)) return 0xc4;
    if (this.thrPending && (this.ier & 2)) {
      this.thrPending = false;
      this.updateIrq();
      return 0xc2;
    }
    return 0xc1;
  }

  read(reg) {
    switch (reg) {
      case 0:
        if (this.dlab) return this.divisor & 0xff;
        {
          const b = this.rxQueue.shift() ?? 0;
          this.updateIrq();
          return b;
        }
      case 1: return this.dlab ? (this.divisor >> 8) & 0xff : this.ier;
      case 2: return this.readIir();
      case 3: return this.lcr;
      case 4: return this.mcr;
      case 5: return this.lsr;
      case 6: return 0xb0;                 // modem status: DCD, DSR, CTS
      default: return this.scratch;
    }
  }

  write(reg, val) {
    val &= 0xff;
    switch (reg) {
      case 0:
        if (this.dlab) { this.divisor = (this.divisor & 0xff00) | val; return; }
        this.onByte(val);
        this.thrPending = true;          // sent at once, so empty again at once
        this.updateIrq();
        return;
      case 1: {
        if (this.dlab) { this.divisor = (this.divisor & 0xff) | (val << 8); return; }
        // enabling the transmitter interrupt with the transmitter empty raises
        // it straight away; disabling it drops it
        const enabling = (val & 2) && !(this.ier & 2);
        this.ier = val & 0x0f;
        if (enabling) this.thrPending = true;
        else if (!(val & 2)) this.thrPending = false;
        this.updateIrq();
        return;
      }
      case 2: this.fcr = val; return;
      case 3: this.lcr = val; return;
      case 4: this.mcr = val; return;
      case 7: this.scratch = val; return;
      default: return;
    }
  }
}

// ---- MC146818 RTC / CMOS ---------------------------------------------------
export class CMOS {
  constructor(ramSizeBytes, pic = null) {
    this.pic = pic;
    this.index = 0;
    this.ram = new Uint8Array(128);
    this.ram[0x0a] = 0x26;
    this.ram[0x0b] = 0x02;            // 24 hour, binary-coded decimal
    this.ram[0x0d] = 0x80;            // battery good
    this.ram[0x14] = 0x23;            // equipment: video, floppy, coprocessor
    this.ram[0x0f] = 0;
    this.setMemorySize(ramSizeBytes);
    this.resetInterrupts();
  }

  resetInterrupts() {
    this.ram[0x0b] &= ~0x70;          // no interrupt sources enabled
    this.ram[0x0c] = 0;
    this.period = -1;                 // the last periodic and update events seen
    this.second = -1;
  }

  // ---- IRQ 8 -----------------------------------------------------------------
  //  Windows XP's APIC HAL runs its clock from the periodic interrupt, at the
  //  64 Hz it puts in register A; with no interrupt it waited for its first
  //  tick forever.  The update-ended interrupt comes once a second.

  /** The periodic rate register A selects, or 0 when it is off. */
  get periodicHz() {
    const r = this.ram[0x0a] & 0x0f;
    if (!r) return 0;
    return r <= 2 ? 32768 >> (r + 6) : 32768 >> (r - 1);
  }

  /** Raise whatever has come due by `nowNs`.  Missed periods make one event. */
  poll(nowNs) {
    let flags = 0;
    const hz = this.periodicHz;
    if (hz) {
      const n = Math.floor((nowNs * hz) / 1e9);
      if (n !== this.period) { this.period = n; flags |= 0x40; }
    }
    const sec = Math.floor(nowNs / 1e9);
    if (sec !== this.second) { this.second = sec; flags |= 0x10; }
    if (!flags) return;
    this.ram[0x0c] |= flags;
    // The line stays up until register C is read, so a second event before
    // then is not a second interrupt.
    if ((this.ram[0x0c] & this.ram[0x0b] & 0x70) && !(this.ram[0x0c] & 0x80)) {
      this.ram[0x0c] |= 0x80;
      this.pic?.raise(8);
    }
  }

  /** When the next enabled interrupt is due, for an idle processor to sleep to. */
  nextEventNs(nowNs) {
    let next = Infinity;
    const hz = this.periodicHz;
    if (hz && (this.ram[0x0b] & 0x40)) next = ((Math.floor((nowNs * hz) / 1e9) + 1) * 1e9) / hz;
    if (this.ram[0x0b] & 0x10) next = Math.min(next, (Math.floor(nowNs / 1e9) + 1) * 1e9);
    return next;
  }

  setMemorySize(bytes) {
    const base = Math.min(640, bytes >> 10);
    this.ram[0x15] = base & 0xff;
    this.ram[0x16] = base >> 8;
    const ext = Math.min(0xffff, Math.max(0, (bytes >> 10) - 1024));
    this.ram[0x17] = ext & 0xff;
    this.ram[0x18] = ext >> 8;
    this.ram[0x30] = ext & 0xff;
    this.ram[0x31] = ext >> 8;
    const above16 = Math.max(0, (bytes - 16 * 1024 * 1024)) / 65536;
    this.ram[0x34] = above16 & 0xff;
    this.ram[0x35] = (above16 >> 8) & 0xff;
  }

  read(port) {
    if (port === 0x70) return 0xff;
    const bcd = (n) => ((Math.floor(n / 10) << 4) | (n % 10)) & 0xff;
    const now = new Date();
    switch (this.index & 0x7f) {
      case 0x00: return bcd(now.getUTCSeconds());
      case 0x02: return bcd(now.getUTCMinutes());
      case 0x04: return bcd(now.getUTCHours());
      case 0x06: return bcd(now.getUTCDay() + 1);
      case 0x07: return bcd(now.getUTCDate());
      case 0x08: return bcd(now.getUTCMonth() + 1);
      case 0x09: return bcd(now.getUTCFullYear() % 100);
      case 0x32: return bcd(Math.floor(now.getUTCFullYear() / 100));
      case 0x0c: {                    // reading the flags clears them and the line
        const v = this.ram[0x0c];
        this.ram[0x0c] = 0;
        if (v & 0x80) this.pic?.lower(8);
        return v;
      }
      default: return this.ram[this.index & 0x7f];
    }
  }

  write(port, val) {
    if (port === 0x70) { this.index = val & 0x7f; return; }
    const reg = this.index & 0x7f;
    if (reg === 0x0c || reg === 0x0d) return;   // read-only
    this.ram[reg] = val & 0xff;
  }
}

// ---- port dispatch ---------------------------------------------------------
// ---- ACPI fixed hardware ---------------------------------------------------
//  The registers the FADT points at.  SMI_CMD is reported as zero, meaning the
//  machine is already in ACPI mode, so SCI_EN reads back as set and the OS
//  never has to ask for the handover.
export class AcpiPm {
  constructor(base) {
    this.base = base;
    this.pm1Status = 0;
    this.pm1Enable = 0;
    this.sleepRequested = false;
    this.nowNs = () => 0;          // supplied by the emulator
  }

  static PM_TIMER_HZ = 3579545;

  /** The power management timer is a free-running 24-bit counter. */
  get timer() {
    return Math.floor(this.nowNs() * (AcpiPm.PM_TIMER_HZ / 1e9)) & 0xffffff;
  }

  covers(port) { return port >= this.base && port < this.base + 12; }

  read(port, size) {
    switch (port - this.base) {
      case 0: return this.pm1Status;
      case 2: return this.pm1Enable;
      case 4: return 1;                        // PM1a_CNT: SCI_EN
      case 8: return this.timer;
      default: return size === 1 ? 0xff : size === 2 ? 0xffff : 0xffffffff;
    }
  }

  write(port, size, val) {
    switch (port - this.base) {
      case 0: this.pm1Status &= ~(val & 0xffff); return;   // write-1-to-clear
      case 2: this.pm1Enable = val & 0xffff; return;
      case 4:
        // SLP_EN with sleep type 5 is the OS asking to power off.
        if ((val & 0x2000) && ((val >> 10) & 7) === 5) this.sleepRequested = true;
        return;
      default:
    }
  }
}

export class IOBus {
  constructor(machine, opts = {}) {
    this.machine = machine;
    this.pic = new PicPair();
    this.pit = new PIT();
    this.serial = new Serial(0x3f8, 4, this.pic);
    this.acpi = new AcpiPm(0x600);
    this.cmos = new CMOS(machine.ramSize, this.pic);
    this.port92 = 0x02;
    this.a20 = true;
    this.postCode = 0;
    this.pci = new PciBus();
    this.shutdownRequested = false;
    this.debugOut = opts.debugOut ?? (() => {});
    this.handlers = new Map();

    // set by the Emulator once those devices exist
    this.vga = null;
    this.ps2 = null;
    this.bios = null;
    this.ata = null;
  }

  /** Bring the chipset back to power-on state for a guest-initiated reboot. */
  reset() {
    this.pic.reset();
    this.pit.reset();
    this.cmos.resetInterrupts();
    this.acpi.pm1Status = 0;
    this.acpi.pm1Enable = 0;
    this.acpi.sleepRequested = false;
    this.port92 = 0;
    this.setA20(true);
    this.postCode = 0;
    this.shutdownRequested = false;
  }

  /**
   * The A20 gate, reached through port 0x92 and the keyboard controller's
   * output port.  It is on at power-on.  HIMEM turns it off and on and checks
   * that memory really wraps at 1 MiB; a gate that only pretends spins HIMEM
   * through a 64K-iteration timeout on every call, which is a million guest
   * instructions each time DOS asks.
   */
  setA20(on) {
    this.a20 = on;
    this.port92 = (this.port92 & ~2) | (on ? 2 : 0);
    this.machine.exports.set_a20(on ? 1 : 0);
  }

  static isAtaPort(port) {
    return (port >= 0x1f0 && port <= 0x1f7) || port === 0x3f6 ||
           (port >= 0x170 && port <= 0x177) || port === 0x376;
  }

  // Devices outside the fixed set register themselves here.
  addPortRange(start, length, read, write) {
    for (let i = 0; i < length; i++) this.handlers.set(start + i, { read, write });
  }

  read(port, size) {
    const custom = this.handlers.get(port);
    if (custom) return custom.read(port, size) >>> 0;

    if (this.vga && ((port >= 0x3b4 && port <= 0x3df) ||
                     port === 0x1ce || port === 0x1cf)) {
      return this.vga.read(port);
    }
    if (this.ps2 && (port === 0x60 || port === 0x64)) return this.ps2.read(port);
    if (this.ata && IOBus.isAtaPort(port)) return this.ata.read(port, size);
    if (port >= 0x3f8 && port <= 0x3ff) return this.serial.read(port - 0x3f8);
    if (port >= 0x2f8 && port <= 0x2ff) return 0xff;         // COM2 absent
    if (port === 0x20 || port === 0x21 || port === 0xa0 || port === 0xa1)
      return this.pic.io(port, size, 0, false);
    if (port >= 0x40 && port <= 0x43) return this.pit.read(port);
    if (port === 0x61) {
      // speaker port; bit 5 toggles so calibration loops make progress
      this.refreshToggle = (this.refreshToggle ?? 0) ^ 0x10;
      return 0x20 | this.refreshToggle;
    }
    if (port === 0x70 || port === 0x71) return this.cmos.read(port);
    if (port === 0x92) return this.port92;
    if (port === 0x60 || port === 0x64) return port === 0x64 ? 0x1c : 0x00;
    if (port === 0x3f2 || port === 0x3f4 || port === 0x3f5) return 0x80;  // no FDC
    if (this.acpi.covers(port)) return this.acpi.read(port, size);
    if (this.pci.covers(port)) return this.pci.read(port, size);
    if (port === 0x80) return this.postCode;
    return size === 1 ? 0xff : size === 2 ? 0xffff : 0xffffffff;
  }

  write(port, size, val) {
    // The BIOS trampolines announce themselves here, and in 16-bit code this is
    // by far the most frequent write on the bus, so it is tested before the
    // map lookup rather than after it.
    if (port === 0xfa && this.bios) { this.bios.handleTrap(); return; }

    const custom = this.handlers.get(port);
    if (custom) { custom.write(port, size, val); return; }

    if (this.vga && port >= 0x3b4 && port <= 0x3df) {
      this.vga.write(port, val, size);
      return;
    }
    if (this.vga && (port === 0x1ce || port === 0x1cf)) {
      this.vga.writeDispi(port, val);
      return;
    }
    if (this.ps2 && (port === 0x60 || port === 0x64)) { this.ps2.write(port, val); return; }
    if (this.ata && IOBus.isAtaPort(port)) { this.ata.write(port, size, val); return; }
    if (port >= 0x3f8 && port <= 0x3ff) { this.serial.write(port - 0x3f8, val); return; }
    if (port === 0x20 || port === 0x21 || port === 0xa0 || port === 0xa1) {
      this.pic.io(port, size, val, true);
      return;
    }
    if (port >= 0x40 && port <= 0x43) { this.pit.write(port, val); return; }
    if (port === 0x70 || port === 0x71) { this.cmos.write(port, val); return; }
    if (port === 0x92) { this.port92 = val & 0xff; this.setA20((val & 2) !== 0); return; }
    if (port === 0x80) { this.postCode = val & 0xff; return; }
    if (port === 0xe9) { this.debugOut(val & 0xff); return; }   // bochs debug port
    if (this.pci.covers(port)) { this.pci.write(port, size, val); return; }
    if (this.acpi.covers(port)) {
      this.acpi.write(port, size, val);
      if (this.acpi.sleepRequested) this.shutdownRequested = true;
      return;
    }
    // isa-debug shutdown gates used by qemu-style firmware
    if (port === 0xb004 || port === 0x8900) {
      this.shutdownRequested = true;
      return;
    }
  }
}
