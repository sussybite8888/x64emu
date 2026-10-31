// ---------------------------------------------------------------------------
//  PCI: configuration mechanism #1 and the devices of a 440FX/PIIX3 board.
//
//  On a PC the IDE controller is a PCI device, and that is how a distribution
//  kernel finds its disks: Debian's ata_piix binds to the PIIX3 IDE function
//  by its PCI id, and the only driver for the bare ISA ports, pata_legacy, is
//  a module nothing ever loads.  With no PCI bus the kernel saw no disk and
//  stopped in its initramfs.
//
//  The IDE function runs both channels in legacy mode -- the ports at 0x1F0
//  and 0x170 and IRQs 14 and 15 that the ATA controller already provides --
//  and has no bus-master BAR, so drivers fall back to PIO, which is all there
//  is.  Nothing here moves a device: BARs a guest writes are kept, and only
//  their size bits are fixed.
// ---------------------------------------------------------------------------

class PciFunction {
  /**
   * @param {object} id  vendor, device, class (base, sub, prog-if), header type
   */
  constructor({ vendor, device, classCode, revision = 0, headerType = 0, init = {} }) {
    this.config = new Uint8Array(256);
    // which bits a guest may change: by default only those named here
    this.writable = new Uint8Array(256);
    const v = new DataView(this.config.buffer);
    v.setUint16(0x00, vendor, true);
    v.setUint16(0x02, device, true);
    v.setUint8(0x08, revision);
    v.setUint8(0x09, classCode & 0xff);          // programming interface
    v.setUint8(0x0a, (classCode >> 8) & 0xff);   // subclass
    v.setUint8(0x0b, (classCode >> 16) & 0xff);  // base class
    v.setUint8(0x0e, headerType);
    // command (I/O, memory, bus master, INTx disable) and the line register
    this.writable[0x04] = 0x07;
    this.writable[0x05] = 0x04;
    this.writable[0x0c] = 0xff;                  // cache line size
    this.writable[0x0d] = 0xff;                  // latency timer
    this.writable[0x3c] = 0xff;                  // interrupt line
    for (const [reg, value] of Object.entries(init)) this.config[Number(reg)] = value;
  }

  /** Let the guest write a range of device-specific registers. */
  allowWrites(from, to) {
    for (let i = from; i <= to; i++) this.writable[i] = 0xff;
    return this;
  }

  read(reg, size) {
    let v = 0;
    for (let i = 0; i < size; i++) v |= this.config[(reg + i) & 0xff] << (8 * i);
    return v >>> 0;
  }

  write(reg, size, val) {
    for (let i = 0; i < size; i++) {
      const r = (reg + i) & 0xff, w = this.writable[r];
      this.config[r] = (this.config[r] & ~w) | ((val >>> (8 * i)) & w);
    }
  }
}

export class PciBus {
  constructor() {
    this.address = 0;
    this.functions = new Map();                  // devfn on bus 0 -> PciFunction

    // 00.0  Intel 440FX host bridge
    this.add(0, 0, new PciFunction({ vendor: 0x8086, device: 0x1237, classCode: 0x060000,
                                     revision: 0x02 }));
    // 01.0  PIIX3 ISA bridge; the header type's top bit says function 1 exists
    this.add(1, 0, new PciFunction({ vendor: 0x8086, device: 0x7000, classCode: 0x060100,
                                     headerType: 0x80 }));
    // 01.1  PIIX3 IDE, both channels legacy (prog-if bits 0 and 2 clear).  The
    // IDE timing registers keep "decode enable" set, which ata_piix checks
    // before it will touch a channel.
    this.add(1, 1, new PciFunction({
      vendor: 0x8086, device: 0x7010, classCode: 0x010180,
      init: { 0x04: 0x01, 0x41: 0x80, 0x43: 0x80 },
    }).allowWrites(0x40, 0x4f));
  }

  add(slot, fn, f) { this.functions.set((slot << 3) | fn, f); }

  /** The function the address register currently selects, if any. */
  selected() {
    if (!(this.address & 0x80000000)) return null;
    if ((this.address >>> 16) & 0xff) return null;   // only bus 0 exists
    return this.functions.get((this.address >>> 8) & 0xff) ?? null;
  }

  covers(port) { return port === 0xcf8 || (port >= 0xcfc && port <= 0xcff); }

  read(port, size) {
    if (port === 0xcf8) return this.address >>> 0;
    const f = this.selected();
    if (!f) return size === 1 ? 0xff : size === 2 ? 0xffff : 0xffffffff;
    return f.read((this.address & 0xfc) + (port - 0xcfc), size);
  }

  write(port, size, val) {
    if (port === 0xcf8) {
      if (size === 4) this.address = val >>> 0;
      return;
    }
    this.selected()?.write((this.address & 0xfc) + (port - 0xcfc), size, val);
  }
}
