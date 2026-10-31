// ---------------------------------------------------------------------------
//  ATA/IDE PIO controller.
//
//  The BIOS can only be called from real mode, so a protected-mode OS needs a
//  real controller to reach the disks.  This is the legacy PIO interface Linux
//  probes as `pata_legacy` and DOS-era software drives directly:
//
//    0x1F0  data (16-bit)          0x1F4  LBA mid
//    0x1F1  error / features       0x1F5  LBA high
//    0x1F2  sector count           0x1F6  drive / head
//    0x1F3  LBA low                0x1F7  status / command
//    0x3F6  device control / alternate status
//
//  Both LBA28 and LBA48 addressing are supported, which is what lets a drive
//  larger than 128 GiB be addressed at all.
// ---------------------------------------------------------------------------

import { NEED_DATA } from './disk.js';

const ST_ERR = 0x01, ST_DRQ = 0x08, ST_DSC = 0x10, ST_DRDY = 0x40, ST_BSY = 0x80;
const ERR_ABRT = 0x04;

// Interrupt-reason bits, reported in the sector count register during a packet
// transfer: bit 0 command/data, bit 1 direction.
const IR_CMD = 0x01, IR_IO = 0x02;

// SCSI sense keys
const SENSE_NONE = 0, SENSE_NOT_READY = 2, SENSE_ILLEGAL = 5;

const be16 = (b, o, v) => { b[o] = (v >> 8) & 0xff; b[o + 1] = v & 0xff; };
const be32 = (b, o, v) => {
  b[o] = (v >>> 24) & 0xff; b[o + 1] = (v >>> 16) & 0xff;
  b[o + 2] = (v >>> 8) & 0xff; b[o + 3] = v & 0xff;
};
const rd16 = (b, o) => (b[o] << 8) | b[o + 1];
const rd32 = (b, o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
const ascii = (b, o, str, len) => {
  const p = str.padEnd(len, ' ');
  for (let i = 0; i < len; i++) b[o + i] = p.charCodeAt(i);
};

export class ATAChannel {
  constructor(pic, { base = 0x1f0, control = 0x3f6, irq = 14 } = {}) {
    this.pic = pic;
    this.base = base;
    this.control = control;
    this.irq = irq;
    this.drives = [null, null];
    this.resetState();
  }

  /** Registers and any transfer in flight, back to their power-on values.
   *  The drives stay where they are: a reset is not an unplug. */
  resetState() {
    this.selected = 0;
    this.features = 0;
    this.sectorCount = 0;
    this.lba = [0, 0, 0];           // low, mid, high bytes
    this.lbaHigh = [0, 0, 0];       // the previous values, for LBA48
    this.driveHead = 0xa0;
    this.status = ST_DRDY | ST_DSC;
    this.error = 0;
    this.deviceControl = 0;
    this.hobEnabled = false;        // "high order byte" latch for LBA48

    this.buffer = null;             // Uint8Array being transferred
    this.bufferPos = 0;
    this.writeTarget = null;        // {lba} while a write is in progress
    this.writeRemaining = 0;
    // PIO moves data in blocks with an interrupt for each: one sector for
    // READ/WRITE SECTORS, the multiple count for READ/WRITE MULTIPLE.
    this.blockSize = 512;
    this.multiple = [0, 0];         // SET MULTIPLE MODE, per drive
    this.chs = [null, null];        // INITIALIZE DEVICE PARAMETERS, per drive

    // ATAPI state
    this.packet = null;             // 12-byte command packet being received
    this.xfer = null;               // full response, served in blocks
    this.xferPos = 0;
    this.byteCountLimit = 0;
    this.sense = SENSE_NONE;
    this.asc = 0;
    this.retryPacket = null;        // command waiting on a non-resident chunk
    this.retryCommand = null;       // the same for a plain ATA read
    this.retryWrite = false;        // and for a write's data
  }

  /** Optical drives speak the packet protocol rather than plain ATA. */
  isAtapi(slot = this.selected) {
    const d = this.drives[slot & 1];
    return !!d && d.kind === 'cdrom';
  }

  /** The signature a host reads to tell an ATAPI device from a disk. */
  setAtapiSignature() {
    this.sectorCount = 1;
    this.lba = [0x01, 0x14, 0xeb];
  }

  attach(slot, disk) {
    this.drives[slot & 1] = disk;
    if (disk && disk.kind === 'cdrom' && (slot & 1) === this.selected) {
      this.setAtapiSignature();
    }
  }

  /** Re-run a packet command that was blocked on a not-yet-resident chunk. */
  retryNow() {
    if (this.retryPacket) {
      const pkt = this.retryPacket;
      this.retryPacket = null;
      this.runPacket(pkt);
    } else if (this.retryCommand !== null) {
      const cmd = this.retryCommand;
      this.retryCommand = null;
      this.command(cmd);
    } else if (this.retryWrite) {
      this.retryWrite = false;
      this.finishWrite();
    }
  }

  /** A command is parked, busy, until an image chunk arrives. */
  get waiting() {
    return !!this.retryPacket || this.retryCommand !== null || this.retryWrite;
  }

  get disk() { return this.drives[this.selected]; }

  raiseIrq() {
    if (!(this.deviceControl & 0x02)) this.pic.raise(this.irq);
  }
  lowerIrq() { this.pic.lower(this.irq); }

  // ---- register access ---------------------------------------------------
  read(port, size) {
    // With no device selected every register reads back zero.  Reporting a
    // ready drive makes detection believe in a disk that is not there, and
    // reporting 0xFF sets BSY, which hangs anything that polls for it to clear.
    if (!this.drives[this.selected]) return 0x00;
    if (port === this.control) {
      if (this.waiting) this.retryNow();
      return this.status;                                // alternate status
    }
    switch (port - this.base) {
      case 0: return this.readData(size);
      case 1: return this.error;
      case 2: return this.sectorCount & 0xff;
      case 3: return this.lba[0];
      case 4: return this.lba[1];
      case 5: return this.lba[2];
      case 6: return this.driveHead;
      case 7:
        this.lowerIrq();                                 // reading status acks
        if (this.waiting) this.retryNow();
        return this.status;
      default: return 0xff;
    }
  }

  write(port, size, val) {
    // Linux writes sectors with 32-bit OUTSD.  Masking those to a byte as well
    // kept the low byte of every dword and zeroed the rest, so each block that
    // fsck replayed from the journal wiped the one it landed on.
    val = size === 4 ? val >>> 0 : val & (size === 2 ? 0xffff : 0xff);
    if (port === this.control) {
      if ((val & 0x04) && !(this.deviceControl & 0x04)) this.softReset();
      this.deviceControl = val;
      return;
    }
    switch (port - this.base) {
      case 0: return this.writeData(val, size);
      case 1: this.features = val; return;
      // LBA48 sends each register twice; the first write is the high byte.
      case 2:
        this.sectorCount = ((this.sectorCount << 8) | val) & 0xffff;
        return;
      case 3: this.lbaHigh[0] = this.lba[0]; this.lba[0] = val; return;
      case 4: this.lbaHigh[1] = this.lba[1]; this.lba[1] = val; return;
      case 5: this.lbaHigh[2] = this.lba[2]; this.lba[2] = val; return;
      case 6:
        this.driveHead = val;
        this.selected = (val >> 4) & 1;
        return;
      case 7: return this.command(val);
      default: return;
    }
  }

  softReset() {
    this.status = ST_DRDY | ST_DSC;
    this.error = 1;
    this.buffer = null;
    this.bufferPos = 0;
    this.packet = null;
    this.xfer = null;
    this.retryPacket = null;
    this.retryCommand = null;
    this.retryWrite = false;
    this.sectorCount = 1;
    this.lba = [1, 0, 0];
    if (this.isAtapi()) this.setAtapiSignature();
    this.lowerIrq();
  }

  // ---- addressing --------------------------------------------------------
  currentLba(lba48) {
    if (lba48) {
      // Each register is written twice, high-order byte first: the latched
      // previous value holds bits 24-47 and the current one bits 0-23.  Taking
      // them the other way round sent a 664-sector journal write to an LBA
      // past the end of the disk.
      return this.lba[0] + this.lba[1] * 256 + this.lba[2] * 65536 +
             (this.lbaHigh[0] + this.lbaHigh[1] * 256 + this.lbaHigh[2] * 65536) * 16777216;
    }
    if (this.driveHead & 0x40) {                          // LBA28
      return this.lba[0] | (this.lba[1] << 8) | (this.lba[2] << 16) |
             ((this.driveHead & 0x0f) << 24);
    }
    // CHS, in the geometry the host last set
    const g = this.currentChs();
    const cyl = this.lba[1] | (this.lba[2] << 8);
    const head = this.driveHead & 0x0f;
    return (cyl * g.h + head) * g.s + (this.lba[0] - 1);
  }

  /**
   * The geometry a drive reports as its default.  This is the drive's own,
   * not the BIOS's: a CHS command has four bits for the head, so it has at
   * most 16 heads, and 16383 cylinders cover 8.4 GB.  Reporting the BIOS's
   * 255 heads made the CHS capacity look as large as the disk, so Windows XP
   * addressed a 20 GB disk by CHS -- in a geometry no command can express --
   * and found no boot device.
   */
  defaultChs(d = this.disk) {
    const h = 16, s = 63;
    return { c: Math.max(1, Math.min(16383, Math.floor(d.sectorCount / (h * s)))), h, s };
  }

  currentChs() {
    const set = this.chs[this.selected];
    if (set) return set;
    return this.disk ? this.defaultChs() : { c: 0, h: 16, s: 63 };
  }

  count(lba48) {
    const n = lba48 ? (this.sectorCount & 0xffff) : (this.sectorCount & 0xff);
    if (n === 0) return lba48 ? 65536 : 256;
    return n;
  }

  /** Block size for a transfer: one sector, or the multiple count. */
  setBlock(multiple) {
    const m = this.multiple[this.selected];
    if (multiple && !m) { this.abort(); return false; }   // multiple mode is off
    this.blockSize = (multiple ? m : 1) * 512;
    return true;
  }

  abort() {
    this.status = ST_DRDY | ST_DSC | ST_ERR;
    this.error = ERR_ABRT;
    this.buffer = null;
    this.raiseIrq();
  }

  // ---- commands ----------------------------------------------------------
  command(cmd) {
    const d = this.disk;
    if (!d && cmd !== 0x90) { this.abort(); return; }

    if (this.isAtapi()) {
      switch (cmd) {
        case 0xa1:                                        // IDENTIFY PACKET DEVICE
          this.buffer = this.identifyPacket();
          this.bufferPos = 0;
          this.status = ST_DRDY | ST_DSC | ST_DRQ;
          this.raiseIrq();
          return;
        case 0xa0:                                        // PACKET
          // The host now writes a 12-byte command packet to the data port.
          this.byteCountLimit = this.lba[1] | (this.lba[2] << 8);
          this.packet = new Uint8Array(12);
          this.bufferPos = 0;
          this.sectorCount = IR_CMD;                      // expecting a command
          this.status = ST_DRDY | ST_DSC | ST_DRQ;
          return;
        case 0x08:                                        // DEVICE RESET
          this.softReset();
          return;
        case 0xec:
          // A disk command on a packet device aborts, and leaves the signature
          // behind so the host knows to use IDENTIFY PACKET DEVICE instead.
          this.setAtapiSignature();
          this.abort();
          return;
        case 0xef:
          this.status = ST_DRDY | ST_DSC;
          this.raiseIrq();
          return;
        case 0x90:
          this.error = 1;
          this.setAtapiSignature();
          this.status = ST_DRDY | ST_DSC;
          this.raiseIrq();
          return;
        default:
          this.abort();
          return;
      }
    }

    switch (cmd) {
      case 0xec:                                          // IDENTIFY DEVICE
        this.buffer = this.identify();
        this.bufferPos = 0;
        this.status = ST_DRDY | ST_DSC | ST_DRQ;
        this.raiseIrq();
        return;

      case 0x20: case 0x21:                               // READ SECTORS
      case 0x24:                                          // READ SECTORS EXT
      case 0xc4: case 0x29: {                             // READ MULTIPLE (EXT)
        const lba48 = cmd === 0x24 || cmd === 0x29;
        if (!this.setBlock(cmd === 0xc4 || cmd === 0x29)) return;
        const n = this.count(lba48);
        const data = d.read(this.currentLba(lba48), n);
        // Not resident yet, as an image read in pieces in a browser often
        // is: stay busy and run the command again once the chunk is in.
        // Aborting was reported to the guest as a read error.
        if (data === null) { this.status = ST_BSY; this.retryCommand = cmd; return; }
        if (!data) { this.abort(); return; }
        this.buffer = data;
        this.bufferPos = 0;
        this.status = ST_DRDY | ST_DSC | ST_DRQ;
        this.error = 0;
        this.raiseIrq();
        return;
      }

      case 0x30: case 0x31:                               // WRITE SECTORS
      case 0x34:                                          // WRITE SECTORS EXT
      case 0xc5: case 0x39: {                             // WRITE MULTIPLE (EXT)
        const lba48 = cmd === 0x34 || cmd === 0x39;
        if (!d.writable) { this.abort(); return; }
        if (!this.setBlock(cmd === 0xc5 || cmd === 0x39)) return;
        const n = this.count(lba48);
        this.writeTarget = this.currentLba(lba48);
        this.buffer = new Uint8Array(n * d.sectorSize);
        this.bufferPos = 0;
        this.status = ST_DRDY | ST_DSC | ST_DRQ;
        this.error = 0;
        return;                                           // no IRQ until data moves
      }

      case 0xc6: {                                        // SET MULTIPLE MODE
        const n = this.sectorCount & 0xff;
        // a power of two up to the sixteen IDENTIFY offers; zero turns it off
        if (n > 16 || (n & (n - 1))) { this.abort(); return; }
        this.multiple[this.selected] = n;
        this.status = ST_DRDY | ST_DSC;
        this.raiseIrq();
        return;
      }

      case 0xe7: case 0xea:                               // FLUSH CACHE
        this.status = ST_DRDY | ST_DSC;
        this.raiseIrq();
        return;

      case 0xef:                                          // SET FEATURES
        this.status = ST_DRDY | ST_DSC;
        this.raiseIrq();
        return;

      case 0x91: {                                        // INITIALIZE DEVICE PARAMETERS
        const h = (this.driveHead & 0x0f) + 1, sectors = this.sectorCount & 0xff;
        if (!sectors) { this.abort(); return; }
        const c = Math.min(65535, Math.floor(d.sectorCount / (h * sectors)));
        this.chs[this.selected] = { c, h, s: sectors };
        this.status = ST_DRDY | ST_DSC;
        this.raiseIrq();
        return;
      }

      case 0x90:                                          // EXECUTE DIAGNOSTIC
        this.error = 1;
        this.status = ST_DRDY | ST_DSC;
        this.raiseIrq();
        return;

      default:
        this.abort();
        return;
    }
  }

  // ---- data port ---------------------------------------------------------
  readData(size) {
    if (!this.buffer || this.status & ST_BSY) return 0;
    const b = this.buffer;
    let v = 0;
    const n = size === 4 ? 4 : 2;
    for (let i = 0; i < n; i++) {
      v |= (this.bufferPos < b.length ? b[this.bufferPos] : 0) << (i * 8);
      this.bufferPos++;
    }
    if (this.bufferPos >= b.length) {
      this.buffer = null;
      if (this.xfer) this.nextAtapiBlock();               // more of the response
      else this.status = ST_DRDY | ST_DSC;                // DRQ clears
    } else if (!this.xfer && this.bufferPos % this.blockSize === 0) {
      // The next block is ready: DRQ stays up and the drive interrupts again.
      // A host driven by interrupts reads one block per interrupt and waits
      // for the next, so a single interrupt for the whole transfer stalled
      // every multi-sector read after its first sector.
      this.raiseIrq();
    }
    return v >>> 0;
  }

  writeData(val, size) {
    // collecting a command packet
    if (this.packet) {
      const n = size === 4 ? 4 : 2;
      for (let i = 0; i < n; i++) {
        if (this.bufferPos < this.packet.length) {
          this.packet[this.bufferPos] = (val >> (i * 8)) & 0xff;
        }
        this.bufferPos++;
      }
      if (this.bufferPos >= this.packet.length) {
        const pkt = this.packet;
        this.packet = null;
        this.status = ST_BSY;
        this.runPacket(pkt);
      }
      return;
    }
    if (!this.buffer || this.writeTarget === null) return;
    const n = size === 4 ? 4 : 2;
    for (let i = 0; i < n; i++) {
      if (this.bufferPos < this.buffer.length) {
        this.buffer[this.bufferPos] = (val >> (i * 8)) & 0xff;
      }
      this.bufferPos++;
    }
    if (this.bufferPos >= this.buffer.length) {
      this.finishWrite();
    } else if (this.bufferPos % this.blockSize === 0) {
      this.raiseIrq();                                    // ready for the next block
    }
  }

  /** Commit a complete write, or park it until its chunks are resident. */
  finishWrite() {
    const r = this.disk.write(this.writeTarget, this.buffer);
    if (r === NEED_DATA) { this.status = ST_BSY; this.retryWrite = true; return; }
    this.buffer = null;
    this.writeTarget = null;
    this.status = r ? (ST_DRDY | ST_DSC) : (ST_DRDY | ST_DSC | ST_ERR);
    if (!r) this.error = ERR_ABRT;
    this.raiseIrq();
  }

  // ---- ATAPI packet execution --------------------------------------------
  /** Serve the next block of a response, honouring the byte count limit. */
  nextAtapiBlock() {
    const remain = this.xfer.length - this.xferPos;
    if (remain <= 0) {
      this.xfer = null;
      this.status = ST_DRDY | ST_DSC;
      this.sectorCount = IR_CMD | IR_IO;                  // transfer complete
      this.raiseIrq();
      return;
    }
    let n = Math.min(remain, this.byteCountLimit || 2048);
    if (n & 1) n++;
    n = Math.min(n, remain);
    this.buffer = this.xfer.subarray(this.xferPos, this.xferPos + n);
    this.xferPos += n;
    this.bufferPos = 0;
    this.lba[1] = n & 0xff;
    this.lba[2] = (n >> 8) & 0xff;
    this.sectorCount = IR_IO;                             // data, to the host
    this.status = ST_DRDY | ST_DSC | ST_DRQ;
    this.raiseIrq();
  }

  atapiData(bytes) {
    this.sense = SENSE_NONE;
    this.asc = 0;
    this.error = 0;
    if (!bytes || bytes.length === 0) {
      this.xfer = null;
      this.buffer = null;
      this.status = ST_DRDY | ST_DSC;
      this.sectorCount = IR_CMD | IR_IO;
      this.raiseIrq();
      return;
    }
    this.xfer = bytes;
    this.xferPos = 0;
    this.nextAtapiBlock();
  }

  atapiFail(key, asc) {
    this.sense = key;
    this.asc = asc;
    this.xfer = null;
    this.buffer = null;
    this.error = (key << 4) | ERR_ABRT;
    this.status = ST_DRDY | ST_DSC | ST_ERR;
    this.sectorCount = IR_CMD | IR_IO;
    this.raiseIrq();
  }

  runPacket(pkt) {
    const d = this.disk;
    if (!d) { this.atapiFail(SENSE_NOT_READY, 0x3a); return; }
    const op = pkt[0];

    switch (op) {
      case 0x00:                                          // TEST UNIT READY
      case 0x1b:                                          // START STOP UNIT
      case 0x1e:                                          // PREVENT ALLOW REMOVAL
      case 0x35:                                          // SYNCHRONIZE CACHE
        this.atapiData(null);
        return;

      case 0x03: {                                        // REQUEST SENSE
        const b = new Uint8Array(18);
        b[0] = 0x70;                                      // current, fixed format
        b[2] = this.sense;
        b[7] = 10;                                        // additional length
        b[12] = this.asc;
        this.atapiData(b.subarray(0, Math.min(18, pkt[4] || 18)));
        return;
      }

      case 0x12: {                                        // INQUIRY
        const b = new Uint8Array(36);
        b[0] = 0x05;                                      // CD-ROM
        b[1] = 0x80;                                      // removable
        b[2] = 0x00;
        b[3] = 0x21;
        b[4] = 31;
        ascii(b, 8, 'x64emu', 8);
        ascii(b, 16, 'CD-ROM', 16);
        ascii(b, 32, '1.0', 4);
        this.atapiData(b.subarray(0, Math.min(36, pkt[4] || 36)));
        return;
      }

      case 0x25: {                                        // READ CAPACITY
        const b = new Uint8Array(8);
        be32(b, 0, Math.max(0, d.sectorCount - 1));
        be32(b, 4, 2048);
        this.atapiData(b);
        return;
      }

      case 0x28:                                          // READ(10)
      case 0xa8: {                                        // READ(12)
        const lba = rd32(pkt, 2);
        const len = op === 0x28 ? rd16(pkt, 7) : rd32(pkt, 6);
        if (len === 0) { this.atapiData(null); return; }
        const data = d.read(lba, len);
        if (data === null) {
          // The image chunk has not arrived yet.  Stay busy and retry when the
          // host next polls status, which is what the guest is already doing.
          this.retryPacket = pkt;
          this.status = ST_BSY;
          return;
        }
        if (!data) { this.atapiFail(SENSE_ILLEGAL, 0x21); return; }
        this.atapiData(data);
        return;
      }

      case 0x43: {                                        // READ TOC
        const b = new Uint8Array(12);
        be16(b, 0, 10);                                   // data length
        b[2] = 1; b[3] = 1;                               // first/last track
        b[4] = 0;
        b[5] = 0x14;                                      // data track
        b[6] = 1;                                         // track number
        be32(b, 8, 0);                                    // start address
        this.atapiData(b.subarray(0, Math.min(12, rd16(pkt, 7) || 12)));
        return;
      }

      case 0x1a:                                          // MODE SENSE(6)
      case 0x5a: {                                        // MODE SENSE(10)
        const len = op === 0x1a ? pkt[4] : rd16(pkt, 7);
        const b = new Uint8Array(Math.max(8, Math.min(len || 8, 32)));
        if (op === 0x1a) b[0] = b.length - 1; else be16(b, 0, b.length - 2);
        this.atapiData(b);
        return;
      }

      case 0x4a: {                                        // GET EVENT STATUS
        const b = new Uint8Array(8);
        be16(b, 0, 6);
        b[2] = 0x00;
        b[3] = 0x00;
        this.atapiData(b.subarray(0, Math.min(8, rd16(pkt, 7) || 8)));
        return;
      }

      case 0x46: {                                        // GET CONFIGURATION
        const b = new Uint8Array(8);
        be32(b, 0, 4);
        be16(b, 6, 0x0008);                               // CD-ROM profile
        this.atapiData(b.subarray(0, Math.min(8, rd16(pkt, 7) || 8)));
        return;
      }

      default:
        this.atapiFail(SENSE_ILLEGAL, 0x20);              // invalid command
        return;
    }
  }

  identifyPacket() {
    const w = new Uint16Array(256);
    // ATAPI device, CD-ROM command set, removable, 12-byte packets
    w[0] = 0x85c0;
    w[49] = 0x0300;                                       // LBA and DMA
    w[53] = 0x0006;
    w[64] = 0x0003;                                       // PIO modes 3 and 4
    w[80] = 0x001e;
    const put = (word, str, len) => {
      const p = str.padEnd(len, ' ').slice(0, len);
      for (let i = 0; i < len; i += 2) {
        w[word + i / 2] = (p.charCodeAt(i) << 8) | p.charCodeAt(i + 1);
      }
    };
    put(10, 'X64EMUCD0000000000001', 20);
    put(23, '1.0', 8);
    put(27, 'x64emu CD-ROM', 40);
    return new Uint8Array(w.buffer);
  }

  // ---- IDENTIFY ----------------------------------------------------------
  identify() {
    const d = this.disk;
    const w = new Uint16Array(256);
    const total = d.sectorCount;
    const g = this.defaultChs();
    const cur = this.currentChs();

    w[0] = 0x0040;                                   // fixed device
    w[1] = g.c;
    w[3] = g.h;
    w[6] = g.s;
    w[47] = 0x8010;                                  // max sectors per interrupt
    w[49] = 0x0300;                                  // LBA and DMA supported
    const multiple = this.multiple[this.selected];
    w[59] = multiple ? 0x0100 | multiple : 0;        // current multiple setting
    w[50] = 0x4000;
    w[53] = 0x0007;                                  // words 54-58, 64-70, 88 valid
    w[54] = cur.c;
    w[55] = cur.h;
    w[56] = cur.s;
    const chsTotal = Math.min(0xfffffff, cur.c * cur.h * cur.s);
    w[57] = chsTotal & 0xffff;
    w[58] = chsTotal >>> 16;
    w[60] = Math.min(0xfffffff, total) & 0xffff;     // LBA28 capacity
    w[61] = Math.min(0xfffffff, total) >>> 16;
    w[80] = 0x007e;                                  // ATA-1 .. ATA-6
    w[83] = 0x4400;                                  // LBA48 supported
    w[86] = 0x0400;
    w[88] = 0x203f;                                  // UDMA modes
    // 48-bit capacity, words 100..103
    let t = BigInt(total);
    for (let i = 0; i < 4; i++) {
      w[100 + i] = Number(t & 0xffffn);
      t >>= 16n;
    }

    const put = (word, str, len) => {
      const padded = str.padEnd(len, ' ').slice(0, len);
      for (let i = 0; i < len; i += 2) {
        // ATA strings are byte-swapped within each word
        w[word + i / 2] = (padded.charCodeAt(i) << 8) | padded.charCodeAt(i + 1);
      }
    };
    put(10, 'X64EMU00000000000001', 20);             // serial number
    put(23, '1.0     ', 8);                          // firmware revision
    put(27, 'x64emu RAM disk', 40);                  // model

    return new Uint8Array(w.buffer);
  }
}

export class ATA {
  constructor(pic) {
    this.primary = new ATAChannel(pic, { base: 0x1f0, control: 0x3f6, irq: 14 });
    this.secondary = new ATAChannel(pic, { base: 0x170, control: 0x376, irq: 15 });
  }

  channelFor(port) {
    if ((port >= 0x1f0 && port <= 0x1f7) || port === 0x3f6) return this.primary;
    if ((port >= 0x170 && port <= 0x177) || port === 0x376) return this.secondary;
    return null;
  }

  /**
   * Hard disks go on the primary channel and optical drives on the secondary,
   * which is the layout guests expect to find them in.
   */
  attach(disk) {
    const order = disk.kind === 'cdrom'
      ? [this.secondary, this.primary]
      : [this.primary, this.secondary];
    for (const ch of order) {
      for (let slot = 0; slot < 2; slot++) {
        if (!ch.drives[slot]) { ch.attach(slot, disk); return true; }
      }
    }
    return false;
  }

  /**
   * A controller reset, which is not the same as unplugging the drives.
   *
   * Clearing the drive list here meant a guest that reboots through the reset
   * vector came back to an IDE bus with nothing on it: its CD-ROM driver probed
   * the ports, found no device, and gave up. Only the registers and any
   * half-finished transfer belong in a reset.
   */
  reset() {
    this.primary.resetState();
    this.secondary.resetState();
  }

  /** Take every drive off the bus, for when the machine is re-populated. */
  detachAll() {
    this.primary.drives = [null, null];
    this.secondary.drives = [null, null];
  }

  /** Whether either channel has a command parked on data not yet resident. */
  get waiting() { return this.primary.waiting || this.secondary.waiting; }

  /** Run parked commands again; those whose data has arrived complete. */
  retryPending() {
    for (const ch of [this.primary, this.secondary]) if (ch.waiting) ch.retryNow();
  }

  read(port, size) {
    const ch = this.channelFor(port);
    return ch ? ch.read(port, size) : 0xff;
  }

  write(port, size, val) {
    const ch = this.channelFor(port);
    if (ch) ch.write(port, size, val);
  }
}
