// ---------------------------------------------------------------------------
//  Emulator: Machine + devices + the scheduling loop that ties them together.
// ---------------------------------------------------------------------------

import { Machine, EXIT_HALT, EXIT_TRIPLE } from './machine.js';
import { Jit } from './jit.js';
import { IOBus } from './devices.js';
import { bootLinux } from './linux.js';
import { VGA, VGA_WINDOW_BASE, VGA_WINDOW_SIZE } from './vga.js';
import { PS2 } from './ps2.js';
import { BIOS } from './bios.js';
import { ATA } from './ata.js';
import { LocalApic, IoApic } from './apic.js';
import { Disk, MemoryStore } from './disk.js';

// The guest's notion of clock speed.  Everything (TSC, PIT, delay loops) is
// derived from this one number so the kernel's calibration agrees with the
// timer interrupt rate it later observes.
const CPU_HZ = 100_000_000;

// Video memory is carved off the top of RAM so the CPU can write it directly
// instead of trapping to the host for every pixel.
const VRAM_BYTES = 16 * 1024 * 1024;

export class Emulator {
  constructor(opts = {}) {
    this.ramSize = opts.ramSize ?? 256 * 1024 * 1024;
    this.sliceSize = opts.sliceSize ?? 500_000;
    // ACPI is required by anything newer than XP, but it also changes which
    // path a Linux kernel takes through its own boot, so it can be turned off
    // to tell an ACPI problem apart from everything else.
    this.acpiOptions = opts.acpi === false ? null : (opts.acpi ?? {});
    // The JIT is opt-in.  It is a large win on tight loops and a small loss on
    // code it cannot compile, so which way it goes depends on the workload.
    this.jitEnabled = opts.jit ?? false;
    this.jit = null;
    this.machine = new Machine({ ramSize: this.ramSize });
    this.io = null;
    this.vga = null;
    this.ps2 = null;
    this.bios = null;
    this.virtualNs = 0;
    this.sliceTsc = null;          // the TSC when the running slice began
    this.sliceEndNs = 0;
    this.idleWait = false;
    this.ioWait = false;
    this.blockedOnIo = false;
    this.onSerial = () => {};
    this.onDisplay = () => {};
    // BIOS teletype output is mirrored into the serial stream so headless runs
    // can see bootloader text without a canvas.
    this.onBiosChar = (ch) => this.onSerial(ch);
    this.onExit = () => {};
    this.tripleFaults = 0;

    // The framebuffer sits just below the end of RAM, aligned to 2 MiB.  VBE
    // reports its address in a 32-bit field, so it has to stay under 4 GiB no
    // matter how much RAM the machine has.
    const top = Math.min(this.ramSize, 0x1_0000_0000);
    // Aligned by arithmetic, not by a bitwise AND.  JavaScript's bitwise
    // operators work on 32-bit *signed* values, so on a machine with 4 GiB the
    // base lands above 0x7fffffff and `& ~0x1fffff` turns it negative -- which
    // is then handed to the guest as its framebuffer address and used here to
    // read the pixels back, so nothing the guest draws is ever seen.
    const ALIGN = 0x20_0000;
    this.vramBase = Math.floor((top - VRAM_BYTES) / ALIGN) * ALIGN;
  }

  async init(wasmBytes) {
    await this.machine.load(wasmBytes);
    if (this.jitEnabled) {
      this.jit = new Jit(this.machine);
      this.machine.exports.jit_enable(1);
    }
    this.io = new IOBus(this.machine, { debugOut: (b) => this.onSerial(b) });
    this.io.serial.onByte = (b) => this.onSerial(b);
    // Every timer counts against the same virtual clock, read to the
    // instruction: a guest calibrating the APIC timer polls it against the PM
    // timer, and both standing still for a whole slice made that useless.
    const now = () => this.nowNs();
    this.io.pit.nowNs = now;
    this.io.acpi.nowNs = now;
    this.lapic = new LocalApic({
      nowNs: now,
      baseMsr: () => Number(this.machine.stateI64[0x2d0 >> 3] & 0xfffn),
      onChange: () => { if (this.interruptPending()) this.machine.setIrqLine(true); },
      onDeadline: () => this.timerArmed(),
    });
    this.ioapic = new IoApic(this.lapic);
    this.addMmioDevice(this.lapic);
    this.addMmioDevice(this.ioapic);
    // ISA IRQ 0 is wired to pin 2, as the MADT says
    this.io.pic.onLine = (irq, high) => this.ioapic.setLine(irq === 0 ? 2 : irq, high);

    this.vga = new VGA(this.machine, this.vramBase, VRAM_BYTES);
    this.vga.onModeChange = (desc) => this.onDisplay(desc);
    this.vga.onUnsupportedMode = (mode) =>
      this.emitText(`[vga] mode 0x${mode.toString(16)} is not supported; ` +
                    `showing text instead\n`);
    // Planar modes need every CPU write to the window; other modes are faster
    // left as plain memory.
    this.vga.onWindowRouting = (on) => this.machine.exports.set_vga_mmio(on ? 1 : 0);
    this.ps2 = new PS2(this.io.pic);
    this.ata = new ATA(this.io.pic);
    this.bios = new BIOS(this);
    this.bios.acpiOptions = this.acpiOptions;
    this.bios.log = (msg) => this.emitText(`[bios] ${msg}\n`);

    this.io.vga = this.vga;
    this.io.ps2 = this.ps2;
    this.io.bios = this.bios;
    this.io.ata = this.ata;
    this.ps2.onReset = () => {
      if (this.bootedImage) this.bootImage(this.bootedImage, this.bootedOpts ?? {});
    };
    this.ps2.onA20 = (on) => this.io.setA20(on);
    this.ps2.getA20 = () => this.io.a20;

    const m = this.machine;
    m.ioRead = (port, size) => this.io.read(port, size);
    m.ioWrite = (port, size, val) => this.io.write(port, size, val);
    m.irqAck = () => this.acknowledgeInterrupt();
    // Raised only: the core drops the line itself when an acknowledge finds
    // nothing to deliver.
    this.io.pic.onChange = () => { if (this.interruptPending()) m.setIrqLine(true); };
    m.mmioRead = (addr, size) => this.mmioRead(addr, size);
    m.mmioWrite = (addr, size, val) => this.mmioWrite(addr, size, val);
    return this;
  }

  // ---- interrupts ----------------------------------------------------------
  //  The local APIC decides what the processor takes.  The 8259 pair's output
  //  gets through only as ExtINT, through LINT0 or an I/O APIC pin, or
  //  directly while the local APIC is software disabled as the BIOS left it.
  get legacyOpen() { return this.lapic.extIntOpen || this.ioapic.extIntOpen; }

  interruptPending() {
    if (this.lapic.accepting && this.lapic.pending() >= 0) return true;
    return this.legacyOpen && this.io.pic.hasPending();
  }

  acknowledgeInterrupt() {
    if (this.lapic.accepting) {
      const v = this.lapic.acknowledge();
      if (v >= 0) return v;
    }
    return this.legacyOpen ? this.io.pic.acknowledge() : -1;
  }

  /** Virtual time, current to the instruction while a slice runs. */
  nowNs() {
    if (this.sliceTsc === null) return this.virtualNs;
    const ran = Number(this.machine.exports.get_tsc() - this.sliceTsc);
    return this.virtualNs + Math.max(0, ran) * (1e9 / CPU_HZ);
  }

  /** The APIC timer was armed: end the slice early if it expires within it. */
  timerArmed() {
    if (this.sliceTsc !== null && this.lapic.nextDeadline < this.sliceEndNs) this.machine.stop();
  }

  emitText(s) {
    for (const ch of s) this.onSerial(ch.charCodeAt(0));
  }

  // ---- memory map shared by the BIOS and the direct kernel loader --------
  memoryMap() {
    return [
      { base: 0x0000_0000, size: 0x0009_fc00, type: 1 },   // conventional
      { base: 0x0009_fc00, size: 0x0000_0400, type: 2 },   // EBDA
      { base: 0x000f_0000, size: 0x0001_0000, type: 2 },   // our ROM
      { base: 0x0010_0000, size: this.vramBase - 0x0010_0000, type: 1 },
      { base: this.vramBase, size: this.ramSize - this.vramBase, type: 2 },
    ];
  }

  // Unclaimed physical addresses read as all ones, like an empty bus.
  mmioRead(addr, size) {
    const off = Number(addr) - VGA_WINDOW_BASE;
    if (off >= 0 && off < VGA_WINDOW_SIZE) {
      let v = 0n;
      for (let i = 0; i < size; i++) {
        v |= BigInt(this.vga.windowRead(off + i)) << BigInt(i * 8);
      }
      return v;
    }
    const dev = this.findMmio(addr);
    if (dev) return BigInt(dev.read(Number(addr - dev.base), size) >>> 0);
    return size >= 8 ? 0xffffffffffffffffn : (1n << BigInt(size * 8)) - 1n;
  }

  mmioWrite(addr, size, val) {
    const off = Number(addr) - VGA_WINDOW_BASE;
    if (off >= 0 && off < VGA_WINDOW_SIZE) {
      for (let i = 0; i < size; i++) {
        this.vga.windowWrite(off + i, Number((val >> BigInt(i * 8)) & 0xffn));
      }
      return;
    }
    const dev = this.findMmio(addr);
    if (dev) dev.write(Number(addr - dev.base), size, Number(val & 0xffffffffn));
  }

  findMmio(addr) {
    for (const d of this.mmioDevices ?? []) {
      if (addr >= d.base && addr < d.base + BigInt(d.length)) return d;
    }
    return null;
  }

  addMmioDevice(dev) {
    (this.mmioDevices ??= []).push(dev);
  }

  // ---- boot entry points -------------------------------------------------
  /** Load a kernel directly, skipping the BIOS. */
  bootLinux(opts) {
    this.bios.disks = [];
    this.ata.reset();
    for (const other of opts.disks ?? []) this.bios.attach(Emulator.toDisk(other, 'disk'));
    if (opts.hddSize) {
      // The drive has to survive a reboot.  An installer writes itself onto it
      // and expects to boot from it afterwards; handing back a blank one sends
      // the machine round the installer again instead.
      if (!this.ramDisk || this.ramDisk.store.size !== opts.hddSize) {
        this.ramDisk = Disk.ramDisk(opts.hddSize, opts.hddName ?? 'ramdisk');
      }
      this.bios.attach(this.ramDisk);
    }
    for (const d of this.bios.disks) {
      if (d.kind === 'hdd' || d.kind === 'cdrom') this.ata.attach(d);
    }

    this.bios.install(this.memoryMap());
    this.bootInfo = bootLinux(this.machine, {
      ...opts,
      memoryMap: this.memoryMap(),
    });
    this.vga.setBiosMode(0x03);
    return this.bootInfo;
  }

  /**
   * Boot an arbitrary image the way a PC would: run its boot sector under a
   * BIOS and let it take over from there.
   *
   * @param {{data: Uint8Array, name?: string, kind?: string}|Uint8Array} image
   */
  bootImage(image, opts = {}) {
    this.bootedImage = image;
    this.bootedOpts = opts;

    // A reboot has to start the CPU from its power-on state.  Without this the
    // boot sector runs with whatever paging, segment caches and protected-mode
    // state the previous OS left behind, and hangs on its first instruction.
    this.resetHardware();
    this.bios.disks = [];
    this.ata.detachAll();
    const disk = this.bios.attach(Emulator.toDisk(image, 'image'));
    for (const other of opts.extra ?? []) {
      this.bios.attach(Emulator.toDisk(other, 'disk'));
    }
    // A blank writable drive the guest can partition, format and install onto.
    // One is attached by default: real machines have a disk, guests poll for
    // one, and a sparse drive that is never touched costs nothing.
    if (opts.hddSize === undefined) opts = { ...opts, hddSize: 1024 ** 3 };
    if (opts.hddSize) {
      // The drive has to survive a reboot.  An installer writes itself onto it
      // and expects to boot from it afterwards; handing back a blank one sends
      // the machine round the installer again instead.
      if (!this.ramDisk || this.ramDisk.store.size !== opts.hddSize) {
        this.ramDisk = Disk.ramDisk(opts.hddSize, opts.hddName ?? 'ramdisk');
      }
      this.bios.attach(this.ramDisk);
    }
    // Disks and optical drives are also reachable through the ATA controller,
    // which is how a protected-mode OS gets at them once the BIOS is out of the
    // picture.  Floppies belong to the FDC and are not presented here.
    for (const d of this.bios.disks) {
      if (d.kind === 'hdd' || d.kind === 'cdrom') this.ata.attach(d);
    }
    this.bios.bootDisk = opts.bootFrom
      ? this.bios.disks.find((d) => d.name === opts.bootFrom) ?? disk
      : disk;

    this.vga.setBiosMode(0x03);
    this.bios.install(this.memoryMap());
    this.bios.startBoot();

    return {
      name: this.bios.bootDisk.name,
      kind: this.bios.bootDisk.kind,
      drive: this.bios.bootDisk.driveNumber,
      sectors: this.bios.bootDisk.sectorCount,
      sectorSize: this.bios.bootDisk.sectorSize,
      disks: this.bios.disks.map((d) => ({
        name: d.name, kind: d.kind, drive: d.driveNumber,
        sectors: d.sectorCount, writable: d.writable,
      })),
    };
  }

  /** Accept raw bytes, a spec object, or an already-built Disk. */
  static toDisk(spec, fallbackName) {
    if (spec instanceof Disk) return spec;
    if (spec instanceof Uint8Array) {
      return Disk.fromBytes(spec, 'auto', fallbackName);
    }
    if (spec.store) return new Disk(spec.store, spec.kind ?? 'auto', spec.name ?? fallbackName);
    return new Disk(new MemoryStore(spec.data), spec.kind ?? 'auto',
                    spec.name ?? fallbackName);
  }

  /**
   * What to do about a triple fault: reboot, or stop.
   *
   * Real hardware resets, and a small operating system often reboots by
   * deliberately causing one -- it is the shortest way to do it without a
   * keyboard controller.  Halting instead looks to the user like the machine
   * froze on reboot.
   *
   * A guest that faults again immediately would reboot forever and never
   * surface the problem, so a repeat in quick succession stops instead. That
   * makes the common case work and keeps a genuinely broken guest visible.
   */
  onTripleFault(now = Date.now()) {
    const since = now - (this.lastTripleAt ?? -Infinity);
    this.lastTripleAt = now;
    if (!this.bootedImage) { this.onExit('triple-fault'); return false; }
    if (since < 2000 || this.tripleFaults > 8) {
      this.onExit(`triple-fault (${this.tripleFaults}), not rebooting again`);
      return false;
    }
    this.onExit('triple-fault: rebooting');
    return true;
  }

  /**
   * Power-on state for everything except the drives.
   *
   * Every reboot path goes through here so they cannot drift apart: the CPU,
   * the chipset, the keyboard controller, the disk controller and the display
   * all have state that outlives a reboot and breaks the next boot in its own
   * way -- stale paging, a stuck interrupt in service, a half-finished
   * controller command, or a screen still showing the previous system.
   */
  resetHardware() {
    this.machine.reset();
    this.virtualNs = 0;
    this.resetPeripherals();
  }

  /**
   * Everything except the CPU and the drives.
   *
   * A guest that reboots by jumping to the reset vector never asks the CPU to
   * reset -- it sets up its own state and expects the machine around it to be
   * as it was at power-on.  That is the path DOS and Windows 95 take.
   */
  resetPeripherals() {
    this.io.reset();
    this.lapic.reset();
    this.ioapic.reset();
    this.ps2.resetState();
    this.ata.reset();
    // A reset masks every interrupt, exactly as the hardware does; POST is what
    // unmasks them again, so it has to run too or the timer is gone for good.
    this.bios?.programPic();
    // A device that exists but is missing a method it should have means the
    // page is running a mixture of module versions, which otherwise surfaces
    // as an unexplained "not a function" in the middle of booting.
    if (this.vga && typeof this.vga.reset !== 'function') {
      throw new Error('vga.js is older than emulator.js: reload the page to ' +
                      'clear the cached module');
    }
    this.vga?.reset();
  }

  /** Attach a blank writable RAM drive without rebooting. */
  addRamDisk(sizeBytes, name = 'ramdisk') {
    this.ramDisk = Disk.ramDisk(sizeBytes, name);
    this.bios.attach(this.ramDisk);
    return this.ramDisk;
  }

  /**
   * A promise for a disk read the guest is actually blocked on, or null.
   *
   * This deliberately ignores readahead still in flight: those are speculative,
   * nothing is waiting for them, and awaiting them would stall the guest on
   * reads it never asked for.
   */
  pendingIo() {
    if (!this.blockedOnIo) return null;
    const waits = [];
    for (const d of this.bios?.disks ?? []) {
      const p = d.store.whenReady?.();
      if (p) waits.push(p);
    }
    return waits.length ? Promise.all(waits) : null;
  }

  // ---- input -------------------------------------------------------------
  sendInput(text) {
    this.io.serial.receiveString(text);
  }

  /** Deliver a key event to both the PS/2 controller and the BIOS buffer. */
  sendKey(code, pressed) {
    const bios = this.ps2.key(code, pressed);
    if (bios && this.bios) this.bios.pushKey(bios.ascii, bios.scan);
    this.idleWait = false;
    this.machine.wake();
  }

  sendMouse(dx, dy, buttons) {
    this.ps2.mouseMove(dx, dy, buttons);
  }

  // ---- scheduling --------------------------------------------------------
  step() {
    const m = this.machine;
    m.setIrqLine(this.interruptPending());
    // Blocks are compiled between slices, never while the core is inside one,
    // so installing one can never disturb a block that is currently running.
    if (this.jit) this.jit.drain();
    // ATA commands parked on image data run again; any whose chunk has come
    // in complete and interrupt, whether or not the guest is polling.
    if (this.ata.waiting) this.ata.retryPending();

    // The APIC timer fires when it expires rather than at the end of whatever
    // slice it expires in; Linux and Windows both run their clocks from it.
    let budget = this.sliceSize;
    const due = this.lapic.nextDeadline;
    if (due !== Infinity) {
      budget = Math.max(1000, Math.min(budget, Math.ceil(((due - this.virtualNs) * CPU_HZ) / 1e9)));
    }
    this.sliceEndNs = this.virtualNs + (budget * 1e9) / CPU_HZ;
    this.sliceTsc = m.exports.get_tsc();
    const before = Number(m.exports.get_cycles());
    const reason = m.run(budget);
    const after = Number(m.exports.get_cycles());
    // A guest that resets the machine mid-slice zeroes the counter, and the
    // difference ran the clock backwards; what it holds then is the slice.
    const executed = after >= before ? after - before : after;
    this.sliceTsc = null;

    let elapsedNs = (executed / CPU_HZ) * 1e9;

    // Either a HLT or a BIOS call blocking on the keyboard means the guest has
    // nothing to do until the next interrupt; jump the clock rather than spin.
    if (reason === EXIT_HALT || this.idleWait) {
      // asleep until the next timer tick, or the APIC timer or RTC if sooner
      let tickNs = 1e9 / this.io.pit.hz;
      const at = this.virtualNs + elapsedNs;
      const next = Math.min(this.lapic.nextDeadline, this.io.cmos.nextEventNs(at));
      if (next - at < tickNs) tickNs = Math.max(0, next - at);
      elapsedNs += tickNs;
      m.exports.add_tsc(BigInt(Math.round((tickNs / 1e9) * CPU_HZ)));
      this.idleWait = false;
    }
    // A BIOS call that could not be served yet means the guest is genuinely
    // blocked; that is the only case the host should wait on.
    this.blockedOnIo = this.ioWait || this.ata.waiting;
    if (this.ioWait) {
      // Waiting on a disk read costs the guest a little time, but nothing like
      // a full timer tick.
      elapsedNs += 1e6;
      m.exports.add_tsc(BigInt(Math.round(1e-3 * CPU_HZ)));
      this.ioWait = false;
    }

    this.virtualNs += elapsedNs;
    const ticks = this.io.pit.advance(elapsedNs / 1e6);
    if (ticks > 0) this.io.pic.raise(0);
    this.lapic.poll(this.virtualNs);
    this.io.cmos.poll(this.virtualNs);

    if (this.interruptPending()) m.wake();

    if (reason === EXIT_TRIPLE) {
      this.tripleFaults++;
      if (this.onTripleFault()) {
        this.bootImage(this.bootedImage, this.bootedOpts ?? {});
        return true;
      }
      return false;
    }
    if (this.io.shutdownRequested) {
      this.onExit('shutdown');
      return false;
    }
    return true;
  }

  runFor(maxSlices) {
    for (let i = 0; i < maxSlices; i++) {
      if (!this.step()) return false;
    }
    return true;
  }

  get stats() {
    const m = this.machine;
    return {
      instructions: Number(m.exports.get_cycles()),
      rip: m.rip,
      mode: m.mode,
      vm: m.vm,
      cpl: m.exports.get_cpl(),
      halted: m.halted,
      virtualMs: this.virtualNs / 1e6,
      video: this.vga ? this.vga.describe() : '-',
      // One entry per attached drive, so "is it still reading the ISO" has an
      // answer rather than an inference from the instruction counter.
      disks: (this.bios?.disks ?? []).map((d) => ({
        name: d.name,
        kind: d.kind,
        reads: d.reads,
        bytesRead: d.bytesRead,
        pendingReads: d.pendingReads,
        lastLba: d.lastLba,
        sectorSize: d.sectorSize,
        size: d.store.size,
      })),
    };
  }
}
