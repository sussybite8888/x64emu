// ---------------------------------------------------------------------------
//  Cirrus Logic CL-GD5446: the SVGA chip Windows XP and 2000 drive with a
//  driver of their own (cirrus.sys / cirrus.dll), and Linux with cirrus-qemu.
//
//  Everything a standard VGA does stays in vga.js; this adds what makes the
//  chip an SVGA adapter:
//
//    - extended sequencer, graphics controller and CRTC registers, unlocked by
//      writing 0x12 to SR6, and the chip ID in CR27
//    - the "hidden DAC" register behind four reads of 0x3C6, which picks the
//      direct-colour pixel format
//    - display modes of 8, 15, 16, 24 and 32 bits per pixel, read straight off
//      the registers, with any pitch and start address
//    - banked access to video memory through the 0xA0000 window
//    - a 32x32 or 64x64 hardware cursor
//    - the BitBLT engine: copies forwards and backwards, sixteen raster
//      operations, 8x8 patterns, colour expansion from one bit per pixel,
//      transparency, solid fills, and source data written by the CPU
//    - its registers through memory-mapped I/O as well as ports
//
//  Video memory is guest RAM, at the start of the PCI framebuffer BAR, so the
//  CPU draws at full speed.  The second half of the BAR is the BitBLT host
//  transfer aperture, which is not RAM: writes there reach the engine.
// ---------------------------------------------------------------------------

export const CIRRUS_VENDOR = 0x1013;
export const CIRRUS_DEVICE = 0x00b8;            // CL-GD5446
export const CIRRUS_VRAM = 4 * 1024 * 1024;     // what QEMU gives a 5446, and Windows expects
export const CIRRUS_BAR0_SIZE = 32 * 1024 * 1024;
export const CIRRUS_BAR1_SIZE = 4096;

// GR30, the BitBLT mode
const BLT_BACKWARDS = 0x01;
const BLT_MEMSYSDEST = 0x02;
const BLT_MEMSYSSRC = 0x04;
const BLT_TRANSPARENT = 0x08;
const BLT_PATTERN = 0x40;
const BLT_COLOREXPAND = 0x80;
// GR31, start and status
const BLT_BUSY = 0x01;
const BLT_START = 0x02;
const BLT_RESET = 0x04;
const BLT_AUTOSTART = 0x80;
// GR33, mode extensions
const BLTX_DWORDGRAN = 0x01;
const BLTX_COLOREXPINV = 0x02;
const BLTX_SOLIDFILL = 0x04;

/**
 * The sixteen raster operations a 5446 implements, as functions of the source
 * and destination bytes.  Anything else behaves as a plain copy.
 */
const ROPS = new Map([
  [0x00, () => 0],
  [0x05, (s, d) => s & d],
  [0x06, (s, d) => d],
  [0x09, (s, d) => s & ~d],
  [0x0b, (s, d) => ~d],
  [0x0d, (s) => s],
  [0x0e, () => 0xff],
  [0x50, (s, d) => ~s & d],
  [0x59, (s, d) => s ^ d],
  [0x6d, (s, d) => s | d],
  [0x90, (s, d) => ~s | ~d],
  [0x95, (s, d) => ~(s ^ d)],
  [0xad, (s, d) => s | ~d],
  [0xd0, (s) => ~s],
  [0xd6, (s, d) => ~s | d],
  [0xda, (s, d) => ~s & ~d],
]);

// The extended modes the BIOS offers, by Cirrus mode number.
export const CIRRUS_MODES = new Map([
  [0x5f, { w: 640, h: 480, bpp: 8 }],
  [0x66, { w: 640, h: 480, bpp: 15 }],
  [0x64, { w: 640, h: 480, bpp: 16 }],
  [0x71, { w: 640, h: 480, bpp: 24 }],
  [0x5c, { w: 800, h: 600, bpp: 8 }],
  [0x67, { w: 800, h: 600, bpp: 15 }],
  [0x65, { w: 800, h: 600, bpp: 16 }],
  [0x78, { w: 800, h: 600, bpp: 24 }],
  [0x60, { w: 1024, h: 768, bpp: 8 }],
  [0x68, { w: 1024, h: 768, bpp: 15 }],
  [0x74, { w: 1024, h: 768, bpp: 16 }],
  [0x79, { w: 1024, h: 768, bpp: 24 }],
  [0x6d, { w: 1280, h: 1024, bpp: 8 }],
  [0x69, { w: 1280, h: 1024, bpp: 15 }],
  [0x75, { w: 1280, h: 1024, bpp: 16 }],
]);

export class Cirrus {
  /**
   * @param {VGA} vga         the standard VGA this extends
   * @param {Machine} machine
   * @param {number} vramBase physical address of video memory (BAR0)
   */
  constructor(vga, machine, vramBase) {
    this.vga = vga;
    this.m = machine;
    this.vramBase = vramBase;
    this.vramSize = CIRRUS_VRAM;
    this.mmioBase = 0;              // BAR1, set by the PCI function
    this.onTrapChange = () => {};   // host-transfer routing, set by the emulator
    this.reset();
  }

  reset() {
    this.hiddenDac = 0;
    this.dacReads = 0;
    this.cursorX = 0;
    this.cursorY = 0;
    this.cursorColors = new Uint8Array(6);   // background RGB, foreground RGB (6-bit)
    // host transfer state
    this.xfer = null;
    if (this.trapping) this.onTrapChange(false);
    this.trapping = false;
    const v = this.vga;
    // power-on values for a 4 MiB PCI 5446, as QEMU sets them up
    v.seq[0x06] = 0x0f;
    v.seq[0x07] = 0x00;
    v.seq[0x0f] = 0x98;
    v.seq[0x15] = 0x04;
    v.seq[0x17] = 0x20;
    v.seq[0x1f] = 0x2d;
    v.gc[0x18] = 0x0f;
    v.crtc[0x27] = 0xb8;            // CL-GD5446
  }

  get unlocked() { return this.vga.seq[0x06] === 0x12; }

  /** True while an extended (SVGA) display mode is selected. */
  get extended() { return (this.vga.seq[0x07] & 0x01) !== 0; }

  // ---- registers -------------------------------------------------------------
  /** Sequencer write; returns true if handled here. */
  writeSeq(index, val) {
    const v = this.vga;
    const i = index & 0x1f;
    if (i === 0x06) { v.seq[6] = (val & 0x17) === 0x12 ? 0x12 : 0x0f; return true; }
    if (i < 0x07) return false;
    // The cursor position's low three bits travel in the index register.
    if (i === 0x10) { v.seq[0x10] = val; this.cursorX = (val << 3) | (index >> 5); return true; }
    if (i === 0x11) { v.seq[0x11] = val; this.cursorY = (val << 3) | (index >> 5); return true; }
    v.seq[i] = val;
    if (i === 0x07) { v.recomputeFromRegisters(); v.updateWindowRouting(); }
    if (i === 0x12 || i === 0x13) v.dirty = true;
    if (i === 0x17) v.updateWindowRouting();
    return true;
  }

  readSeq(index) {
    const v = this.vga;
    const i = index & 0x1f;
    if (i === 0x10) return v.seq[0x10];
    if (i === 0x11) return v.seq[0x11];
    if (i === 0x06) return v.seq[6];
    if (i < 0x07) return null;
    return v.seq[i];
  }

  writeGc(index, val) {
    const v = this.vga;
    const i = index & 0x3f;
    if (i < 0x09 && i > 0x01) return false;
    v.gc[i] = val;
    if (i === 0x09 || i === 0x0a || i === 0x0b) v.updateWindowRouting();
    if (i === 0x2a && (v.gc[0x31] & BLT_AUTOSTART)) this.bltStart();
    if (i === 0x31) {
      if (val & BLT_RESET) { this.xfer = null; this.setTrap(false); v.gc[0x31] &= ~(BLT_RESET | BLT_BUSY); }
      if (val & BLT_START) this.bltStart();
    }
    return i > 0x01;
  }

  readGc(index) {
    const i = index & 0x3f;
    if (i === 0x31) {
      const busy = this.xfer ? BLT_BUSY : 0;
      return (this.vga.gc[0x31] & ~(BLT_BUSY | BLT_START)) | busy;
    }
    return i > 0x08 ? this.vga.gc[i] : null;
  }

  writeCrtc(i, val) {
    const v = this.vga;
    if (i === 0x27 || i === 0x25) return true;       // read-only chip ID / status
    if (i < 0x19) return false;
    v.crtc[i] = val;
    if (i === 0x1a || i === 0x1b || i === 0x1d) { v.dirty = true; v.recomputeFromRegisters(); }
    return true;
  }

  /**
   * 0x3C6 hides a register: four reads in a row, then the next access to
   * 0x3C6 is the hidden DAC instead of the pixel mask.  Any other DAC port
   * access resets the count.
   */
  readPel() {
    if (this.dacReads === 4) { this.dacReads = 0; return this.hiddenDac; }
    this.dacReads++;
    return 0xff;
  }

  writePel(val) {
    if (this.dacReads === 4) {
      this.hiddenDac = val & 0xff;
      this.vga.recomputeFromRegisters();
      this.vga.dirty = true;
    }
    this.dacReads = 0;
  }

  dacTouched() { this.dacReads = 0; }

  /**
   * With SR12 bit 1 set, DAC entries 0x00 and 0x0F stand for the cursor's two
   * colours instead of the palette.  Returns true if the write went there.
   */
  dacExtended(index, comp, val) {
    if (!(this.vga.seq[0x12] & 0x02)) return false;
    if (index === 0x00) { this.cursorColors[comp] = val & 0x3f; return true; }
    if (index === 0x0f) { this.cursorColors[3 + comp] = val & 0x3f; return true; }
    return false;
  }

  // ---- the display -------------------------------------------------------------
  bpp() {
    const v = this.vga;
    switch (v.seq[0x07] & 0x0e) {
      case 0x00: return 8;
      case 0x02: case 0x06: return (this.hiddenDac & 0x0f) === 1 ? 16 : 15;
      case 0x04: return 24;
      case 0x08: return 32;
      default: return 8;
    }
  }

  /** The extended mode the registers describe, or null outside one. */
  mode() {
    if (!this.extended) return null;
    const c = this.vga.crtc;
    const w = (c[0x01] + 1) * 8;
    let h = (c[0x12] | ((c[0x07] & 0x02) << 7) | ((c[0x07] & 0x40) << 3)) + 1;
    if (c[0x1a] & 0x01) h *= 2;
    const pitch = (c[0x13] | ((c[0x1b] & 0x10) << 4)) << 3;
    const start = ((c[0x0c] << 8) | c[0x0d] | ((c[0x1b] & 0x01) << 16) |
                   ((c[0x1b] & 0x0c) << 15) | ((c[0x1d] & 0x80) << 12)) << 2;
    const bpp = this.bpp();
    if (w < 64 || h < 64 || w > 2048 || h > 2048) return null;
    const bytes = bpp === 15 ? 2 : bpp >> 3;
    return { text: false, w, h, bpp, pitch: pitch || w * bytes,
             linear: this.vramBase + (start % this.vramSize), cirrus: true };
  }

  /** Draw the hardware cursor over a rendered RGBA frame. */
  drawCursor(rgba, w, h) {
    const v = this.vga;
    if (!this.extended || !(v.seq[0x12] & 0x01)) return;
    const big = (v.seq[0x12] & 0x04) !== 0;
    const size = big ? 64 : 32;
    const base = this.vramSize - 16384 + (big ? (v.seq[0x13] & 0x3c) : (v.seq[0x13] & 0x3f)) * 256;
    const ram = this.m.u8;
    const col = (o) => [this.cursorColors[o] << 2, this.cursorColors[o + 1] << 2,
                        this.cursorColors[o + 2] << 2];
    const bg = col(0), fg = col(3);
    for (let y = 0; y < size; y++) {
      const sy = this.cursorY + y;
      if (sy >= h) break;
      for (let x = 0; x < size; x++) {
        const sx = this.cursorX + x;
        if (sx >= w) break;
        let p0, p1;
        if (big) {
          const row = base + y * 16;
          p0 = (ram[this.vramBase + row + (x >> 3)] >> (7 - (x & 7))) & 1;
          p1 = (ram[this.vramBase + row + 8 + (x >> 3)] >> (7 - (x & 7))) & 1;
        } else {
          const row = base + y * 4;
          p0 = (ram[this.vramBase + row + (x >> 3)] >> (7 - (x & 7))) & 1;
          p1 = (ram[this.vramBase + row + 128 + (x >> 3)] >> (7 - (x & 7))) & 1;
        }
        if (!p0 && !p1) continue;
        const o = (sy * w + sx) * 4;
        if (!p0) {                              // invert what is underneath
          rgba[o] ^= 0xff; rgba[o + 1] ^= 0xff; rgba[o + 2] ^= 0xff;
          continue;
        }
        const c = p1 ? fg : bg;
        rgba[o] = c[0]; rgba[o + 1] = c[1]; rgba[o + 2] = c[2];
      }
    }
  }

  // ---- banked access through 0xA0000 ---------------------------------------------
  /** Whether the 0xA0000 window has to come through here. */
  wantsWindow() { return this.extended || this.xfer !== null || this.mmioAtB8000(); }

  /** BitBLT registers at 0xB8000: SR17 says so, and only in an SVGA mode. */
  mmioAtB8000() { return this.extended && (this.vga.seq[0x17] & 0x44) === 0x04; }

  /** Offset into video memory of a window address, honouring the bank registers. */
  bankOffset(off) {
    const v = this.vga;
    const gran = (v.gc[0x0b] & 0x20) ? 16384 : 4096;
    let bank, within;
    if ((v.gc[0x0b] & 0x01) && off >= 0x8000) { bank = v.gc[0x0a]; within = off - 0x8000; }
    else { bank = v.gc[0x09]; within = off & ((v.gc[0x0b] & 0x01) ? 0x7fff : 0xffff); }
    return (bank * gran + within) % this.vramSize;
  }

  windowRead(off) {
    if (off >= 0x18000 && this.mmioAtB8000()) return this.bltRegRead((off - 0x18000) & 0xff);
    if (off >= 0x10000) return 0xff;
    return this.m.u8[this.vramBase + this.bankOffset(off)];
  }

  windowWrite(off, val) {
    if (off >= 0x18000 && this.mmioAtB8000()) { this.bltRegWrite((off - 0x18000) & 0xff, val); return; }
    if (off >= 0x10000) return;
    if (this.xfer) { this.hostData(val, 1); return; }
    this.m.u8[this.vramBase + this.bankOffset(off)] = val;
    this.vga.dirty = true;
  }

  // ---- memory-mapped registers -----------------------------------------------------
  //  BAR1 is 4 KiB: its first 256 bytes are the VGA ports from 0x3C0 on, and
  //  the BitBLT registers start at 0x100.  The older window at 0xB8000 has the
  //  BitBLT registers alone, from offset 0.  This table is that BitBLT layout.
  static MMIO_GR = new Map([
    [0x00, 0x00], [0x01, 0x10], [0x02, 0x12], [0x03, 0x14],      // background colour
    [0x04, 0x01], [0x05, 0x11], [0x06, 0x13], [0x07, 0x15],      // foreground colour
    [0x08, 0x20], [0x09, 0x21], [0x0a, 0x22], [0x0b, 0x23],      // width, height
    [0x0c, 0x24], [0x0d, 0x25], [0x0e, 0x26], [0x0f, 0x27],      // pitches
    [0x10, 0x28], [0x11, 0x29], [0x12, 0x2a],                    // destination
    [0x14, 0x2c], [0x15, 0x2d], [0x16, 0x2e],                    // source
    [0x17, 0x2f], [0x18, 0x30], [0x1a, 0x32], [0x1b, 0x33],      // mask, mode, ROP, ext
    [0x1c, 0x34], [0x1d, 0x35], [0x20, 0x38], [0x21, 0x39],      // transparency
    [0x40, 0x31],                                                 // start / status
  ]);

  /** BAR1: VGA ports below 0x100, the BitBLT registers from 0x100. */
  mmioRead(off, size) {
    let v = 0;
    for (let i = 0; i < size; i++) v |= this.mmioRead8(off + i) << (i * 8);
    return v >>> 0;
  }

  mmioRead8(off) {
    if (off < 0x100) return off < 0x20 ? this.vga.read(0x3c0 + off) & 0xff : 0xff;
    return this.bltRegRead(off - 0x100);
  }

  mmioWrite(off, size, val) {
    for (let i = 0; i < size; i++) this.mmioWrite8(off + i, (val >>> (i * 8)) & 0xff);
  }

  mmioWrite8(off, val) {
    if (off < 0x100) { if (off < 0x20) this.vga.write(0x3c0 + off, val, 1); return; }
    this.bltRegWrite(off - 0x100, val);
  }

  bltRegRead(off) {
    const gr = Cirrus.MMIO_GR.get(off);
    if (gr === undefined) return 0;
    if (gr === 0x31) return this.readGc(0x31);
    return this.vga.gc[gr];
  }

  bltRegWrite(off, val) {
    const gr = Cirrus.MMIO_GR.get(off);
    if (gr !== undefined) this.writeGc(gr, val);
  }

  // ---- the BitBLT engine ------------------------------------------------------------
  blt() {
    const g = this.vga.gc;
    const mode = g[0x30];
    return {
      width: (g[0x20] | ((g[0x21] & 0x1f) << 8)) + 1,
      height: (g[0x22] | ((g[0x23] & 0x07) << 8)) + 1,
      dstPitch: g[0x24] | ((g[0x25] & 0x1f) << 8),
      srcPitch: g[0x26] | ((g[0x27] & 0x1f) << 8),
      dst: (g[0x28] | (g[0x29] << 8) | ((g[0x2a] & 0x3f) << 16)) % this.vramSize,
      src: (g[0x2c] | (g[0x2d] << 8) | ((g[0x2e] & 0x3f) << 16)) % this.vramSize,
      mode,
      ext: g[0x33],
      rop: ROPS.get(g[0x32]) ?? ROPS.get(0x0d),
      bpp: ((mode >> 4) & 3) + 1,
      fg: (g[0x01] | (g[0x11] << 8) | (g[0x13] << 16) | (g[0x15] << 24)) >>> 0,
      bg: (g[0x00] | (g[0x10] << 8) | (g[0x12] << 16) | (g[0x14] << 24)) >>> 0,
      key: g[0x34] | (g[0x35] << 8),
      skip: g[0x2f] & 0x07,
    };
  }

  bltStart() {
    const v = this.vga;
    v.gc[0x31] &= ~BLT_START;
    const b = this.blt();
    if (b.mode & BLT_MEMSYSSRC) { this.beginHostTransfer(b); return; }
    if (b.mode & BLT_MEMSYSDEST) return;        // video to host: not used by the drivers
    if (b.ext & BLTX_SOLIDFILL) this.solidFill(b);
    else if (b.mode & BLT_PATTERN) this.patternFill(b);
    else if (b.mode & BLT_COLOREXPAND) this.expandFromVram(b);
    else this.copy(b);
    v.dirty = true;
  }

  // Access to video memory, wrapping at its size as the chip's address does.
  rd(off) { return this.m.u8[this.vramBase + (off % this.vramSize)]; }
  wr(off, val) { this.m.u8[this.vramBase + (off % this.vramSize)] = val & 0xff; }

  /** Write one pixel of colour `c` (bpp bytes) at `off`, through the ROP. */
  putPixel(b, off, c) {
    for (let i = 0; i < b.bpp; i++) {
      const s = (c >>> (i * 8)) & 0xff;
      this.wr(off + i, b.rop(s, this.rd(off + i)));
    }
  }

  copy(b) {
    const back = (b.mode & BLT_BACKWARDS) !== 0;
    const transparent = (b.mode & BLT_TRANSPARENT) !== 0;
    // Overlapping copies have to read before they write, so each line goes
    // through a buffer.
    const line = new Uint8Array(b.width);
    for (let y = 0; y < b.height; y++) {
      const srow = back ? b.src - y * b.srcPitch : b.src + y * b.srcPitch;
      const drow = back ? b.dst - y * b.dstPitch : b.dst + y * b.dstPitch;
      for (let x = 0; x < b.width; x++) line[x] = this.rd(back ? srow - x : srow + x);
      if (!transparent && b.rop === ROPS.get(0x0d)) {
        for (let x = 0; x < b.width; x++) this.wr(back ? drow - x : drow + x, line[x]);
        continue;
      }
      for (let x = 0; x < b.width; x += b.bpp) {
        let px = 0;
        for (let i = 0; i < b.bpp; i++) px |= line[x + i] << (i * 8);
        if (transparent && (px & 0xffff) === (b.key & (b.bpp === 1 ? 0xff : 0xffff))) continue;
        for (let i = 0; i < b.bpp; i++) {
          const off = back ? drow - x - i : drow + x + i;
          this.wr(off, b.rop(line[x + i], this.rd(off)));
        }
      }
    }
  }

  solidFill(b) {
    for (let y = 0; y < b.height; y++) {
      const row = b.dst + y * b.dstPitch;
      for (let x = 0; x < b.width; x += b.bpp) this.putPixel(b, row + x, b.fg);
    }
  }

  patternFill(b) {
    const expand = (b.mode & BLT_COLOREXPAND) !== 0;
    const transparent = (b.mode & BLT_TRANSPARENT) !== 0;
    const inv = (b.ext & BLTX_COLOREXPINV) !== 0;
    // The pattern is 8x8 pixels at the source address rounded down to eight
    // bytes; the low three bits say which of its rows the first line uses.
    // GR2F clips that many pixels off the left of every line.
    const pat = b.src & ~7;
    const py = b.src & 7;
    for (let y = 0; y < b.height; y++) {
      const row = b.dst + y * b.dstPitch;
      const pr = (py + y) & 7;
      for (let x = b.skip * b.bpp, px = b.skip; x < b.width; x += b.bpp, px++) {
        const pcol = px & 7;
        let c;
        if (expand) {
          let bit = (this.rd(pat + pr) >> (7 - pcol)) & 1;
          if (inv) bit ^= 1;
          if (!bit && transparent) continue;
          c = bit ? b.fg : b.bg;
        } else {
          c = 0;
          const at = pat + (pr * 8 + pcol) * b.bpp;
          for (let i = 0; i < b.bpp; i++) c |= this.rd(at + i) << (i * 8);
        }
        this.putPixel(b, row + x, c >>> 0);
      }
    }
  }

  /** Colour expansion with the monochrome source in video memory. */
  expandFromVram(b) {
    const transparent = (b.mode & BLT_TRANSPARENT) !== 0;
    const inv = (b.ext & BLTX_COLOREXPINV) !== 0;
    const pixels = Math.floor(b.width / b.bpp);
    const rowBytes = b.srcPitch || Math.ceil(pixels / 8);
    for (let y = 0; y < b.height; y++) {
      const srow = b.src + y * rowBytes;
      const drow = b.dst + y * b.dstPitch;
      for (let p = b.skip; p < pixels; p++) {
        let bit = (this.rd(srow + (p >> 3)) >> (7 - (p & 7))) & 1;
        if (inv) bit ^= 1;
        if (!bit && transparent) continue;
        this.putPixel(b, drow + p * b.bpp, bit ? b.fg : b.bg);
      }
    }
  }

  // ---- host transfers -------------------------------------------------------------------
  //  The CPU supplies the source: anything it writes to video memory -- the
  //  0xA0000 window, the framebuffer, or the aperture after it -- goes to the
  //  engine until a whole rectangle's worth has arrived.
  //
  //  How much each line takes matters more than anything else here: a
  //  transfer that expects more than the driver sends never finishes, and
  //  every framebuffer write after it is swallowed as source data -- windows
  //  that stop repainting.  Monochrome lines are packed a byte apart unless
  //  GR33 asks for dword granularity; colour lines are a dword apart.  The
  //  stream itself is continuous, so a line can end part way through a write
  //  and the rest of that write begins the next one; whatever is left over
  //  when the last line is done is padding and is dropped.
  beginHostTransfer(b) {
    const expand = (b.mode & BLT_COLOREXPAND) !== 0;
    const pixels = Math.floor(b.width / b.bpp);
    let stride, lines;
    if (b.mode & BLT_PATTERN) {
      // an 8x8 pattern sent from the host, then the fill it describes
      stride = expand ? 8 : 64 * b.bpp;
      lines = 1;
    } else if (expand) {
      stride = (b.ext & BLTX_DWORDGRAN) ? ((pixels + 31) >> 5) * 4 : (pixels + 7) >> 3;
      lines = b.height;
    } else {
      stride = (b.width + 3) & ~3;
      lines = b.height;
    }
    this.xfer = { b, expand, stride, lines, pattern: (b.mode & BLT_PATTERN) !== 0,
                  buf: new Uint8Array(stride), have: 0, y: 0 };
    this.vga.gc[0x31] |= BLT_BUSY;
    this.setTrap(true);
  }

  /** Bytes the CPU wrote while a host transfer is in progress. */
  hostData(val, size) {
    const t = this.xfer;
    if (!t) return;
    for (let i = 0; i < size; i++) {
      t.buf[t.have++] = (val >>> (i * 8)) & 0xff;
      if (t.have === t.stride) {
        if (t.pattern) this.hostPattern(t);
        else this.hostLine(t);
        t.have = 0;
        if (++t.y >= t.lines) { this.endHostTransfer(); return; }
      }
    }
  }

  /** A pattern that came from the host: fill with it as if it were in VRAM. */
  hostPattern(t) {
    const b = t.b;
    const expand = t.expand;
    const transparent = (b.mode & BLT_TRANSPARENT) !== 0;
    const inv = (b.ext & BLTX_COLOREXPINV) !== 0;
    for (let y = 0; y < b.height; y++) {
      const row = b.dst + y * b.dstPitch;
      const pr = y & 7;
      for (let x = b.skip * b.bpp, px = b.skip; x < b.width; x += b.bpp, px++) {
        const pcol = px & 7;
        let c;
        if (expand) {
          let bit = (t.buf[pr] >> (7 - pcol)) & 1;
          if (inv) bit ^= 1;
          if (!bit && transparent) continue;
          c = bit ? b.fg : b.bg;
        } else {
          c = 0;
          const at = (pr * 8 + pcol) * b.bpp;
          for (let i = 0; i < b.bpp; i++) c |= t.buf[at + i] << (i * 8);
        }
        this.putPixel(b, row + x, c >>> 0);
      }
    }
    this.vga.dirty = true;
  }

  hostLine(t) {
    const b = t.b;
    const drow = b.dst + t.y * b.dstPitch;
    if (t.expand) {
      const transparent = (b.mode & BLT_TRANSPARENT) !== 0;
      const inv = (b.ext & BLTX_COLOREXPINV) !== 0;
      const pixels = Math.floor(b.width / b.bpp);
      for (let p = b.skip; p < pixels; p++) {
        let bit = (t.buf[p >> 3] >> (7 - (p & 7))) & 1;
        if (inv) bit ^= 1;
        if (!bit && transparent) continue;
        this.putPixel(b, drow + p * b.bpp, bit ? b.fg : b.bg);
      }
    } else {
      for (let x = 0; x < b.width; x++) this.wr(drow + x, b.rop(t.buf[x], this.rd(drow + x)));
    }
    this.vga.dirty = true;
  }

  endHostTransfer() {
    this.xfer = null;
    this.vga.gc[0x31] &= ~BLT_BUSY;
    this.setTrap(false);
  }

  /**
   * While a host transfer runs, writes to the framebuffer have to come here
   * instead of landing in RAM; the emulator turns that routing on and off.
   */
  setTrap(on) {
    if (on === this.trapping) return;
    this.trapping = on;
    this.onTrapChange(on);
    this.vga.updateWindowRouting();
  }

  /** A write to the framebuffer BAR that did not land in RAM. */
  barWrite(off, size, val) {
    if (this.xfer) { this.hostData(val, size); return; }
    if (off < this.vramSize) {
      for (let i = 0; i < size; i++) this.wr(off + i, val >>> (i * 8));
      this.vga.dirty = true;
    }
  }

  barRead(off, size) {
    if (off >= this.vramSize) return 0xffffffff >>> (32 - size * 8);
    let v = 0;
    for (let i = 0; i < size; i++) v |= this.rd(off + i) << (i * 8);
    return v >>> 0;
  }
}
