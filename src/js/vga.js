// ---------------------------------------------------------------------------
//  VGA adapter.
//
//  Video memory lives inside guest RAM, so the CPU writes to it at full speed
//  and the renderer simply reads the same bytes back each frame:
//
//    0xA0000  64 KiB window, linear in mode 13h
//    0xB8000  text mode character/attribute pairs
//    lfbBase  linear framebuffer for the high-resolution (VBE) modes
//
//  Higher resolutions use the Bochs "dispi" register pair at 0x01CE/0x01CF,
//  which is what the VBE calls in the BIOS drive.
// ---------------------------------------------------------------------------

export const DISPI_INDEX = 0x01ce;
export const DISPI_DATA = 0x01cf;

const DISPI_ID = 0, DISPI_XRES = 1, DISPI_YRES = 2, DISPI_BPP = 3,
      DISPI_ENABLE = 4, DISPI_BANK = 5, DISPI_VIRT_WIDTH = 6,
      DISPI_VIRT_HEIGHT = 7, DISPI_X_OFFSET = 8, DISPI_Y_OFFSET = 9;

// the 16 EGA/CGA text colours
const TEXT_PALETTE = [
  [0x00, 0x00, 0x00], [0x00, 0x00, 0xaa], [0x00, 0xaa, 0x00], [0x00, 0xaa, 0xaa],
  [0xaa, 0x00, 0x00], [0xaa, 0x00, 0xaa], [0xaa, 0x55, 0x00], [0xaa, 0xaa, 0xaa],
  [0x55, 0x55, 0x55], [0x55, 0x55, 0xff], [0x55, 0xff, 0x55], [0x55, 0xff, 0xff],
  [0xff, 0x55, 0x55], [0xff, 0x55, 0xff], [0xff, 0xff, 0x55], [0xff, 0xff, 0xff],
];

// The attribute palette a VGA BIOS sets beside the EGA DAC colours: the same
// sixteen colours, by their rgbRGB numbers (0x14 is brown, 0x38 dark grey).
const EGA_ATTR_PALETTE = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07,
                          0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f];

// BIOS mode number -> geometry.
//  `planar` modes are the four-plane EGA/VGA layouts, where a byte of video
//  memory holds one bit of eight pixels in each of four planes.
// The DAC contents a mode set loads, six bits per primary.  The BIOS's ROM
// copy loads the same through the DAC ports.
//  the standard 256-colour VGA ramp: 16 text colours, a 6x6x6 cube, greys
export const DEFAULT_DAC = (() => {
  const dac = new Uint8Array(768);
  for (let i = 0; i < 16; i++) {
    const c = TEXT_PALETTE[i];
    dac[i * 3] = c[0] >> 2;
    dac[i * 3 + 1] = c[1] >> 2;
    dac[i * 3 + 2] = c[2] >> 2;
  }
  let i = 16;
  for (let r = 0; r < 6; r++) {
    for (let g = 0; g < 6; g++) {
      for (let b = 0; b < 6; b++, i++) {
        dac[i * 3] = Math.round(r * 63 / 5);
        dac[i * 3 + 1] = Math.round(g * 63 / 5);
        dac[i * 3 + 2] = Math.round(b * 63 / 5);
      }
    }
  }
  for (; i < 256; i++) {
    const v = Math.round(((i - 232) / 23) * 63);
    dac[i * 3] = dac[i * 3 + 1] = dac[i * 3 + 2] = Math.max(0, Math.min(63, v));
  }
  return dac;
})();
//  the 64 EGA colours, two bits per primary (rgbRGB), for the 16-colour modes
export const EGA_DAC = (() => {
  const dac = new Uint8Array(192);
  const level = (k, hi, lo) => (((k >> hi) & 1) * 2 + ((k >> lo) & 1)) * 21;
  for (let k = 0; k < 64; k++) {
    dac[k * 3] = level(k, 2, 5);
    dac[k * 3 + 1] = level(k, 1, 4);
    dac[k * 3 + 2] = level(k, 0, 3);
  }
  return dac;
})();

const BIOS_MODES = new Map([
  [0x00, { text: true, cols: 40, rows: 25 }],
  [0x01, { text: true, cols: 40, rows: 25 }],
  [0x02, { text: true, cols: 80, rows: 25 }],
  [0x03, { text: true, cols: 80, rows: 25 }],
  [0x07, { text: true, cols: 80, rows: 25 }],
  [0x0d, { text: false, planar: true, w: 320, h: 200, bpp: 4 }],
  [0x0e, { text: false, planar: true, w: 640, h: 200, bpp: 4 }],
  [0x10, { text: false, planar: true, w: 640, h: 350, bpp: 4 }],
  [0x11, { text: false, planar: true, w: 640, h: 480, bpp: 1 }],
  [0x12, { text: false, planar: true, w: 640, h: 480, bpp: 4 }],
  [0x13, { text: false, w: 320, h: 200, bpp: 8, linear: 0xa0000 }],
]);

// For each plane byte, its eight bits moved to the bottom of eight nibbles,
// leftmost pixel (bit 7) in the lowest.  ORing four planes' entries, each
// shifted by its plane number, yields eight pixels' colour indices at once.
// The machines this runs on are little-endian, which the RGBA words assume.
const PLANE_SPREAD = (() => {
  const t = new Uint32Array(256);
  for (let b = 0; b < 256; b++) {
    let v = 0;
    for (let px = 0; px < 8; px++) if (b & (0x80 >> px)) v |= 1 << (px * 4);
    t[b] = v >>> 0;
  }
  return t;
})();

export const VGA_WINDOW_BASE = 0xa0000;
export const VGA_WINDOW_SIZE = 0x10000;

const ror8 = (v, n) => ((v >> n) | (v << (8 - n))) & 0xff;

export class VGA {
  /**
   * @param {Machine} machine
   * @param {number} lfbBase physical address reserved for the framebuffer
   * @param {number} memSize bytes reserved there
   */
  constructor(machine, lfbBase, memSize = 16 * 1024 * 1024) {
    this.m = machine;
    this.lfbBase = lfbBase;
    this.memSize = memSize;

    this.textCols = 80;
    this.textRows = 25;
    this.mode = { text: true, cols: 80, rows: 25 };
    this.biosMode = 0x03;

    // Bochs dispi state
    this.dispiIndex = 0;
    this.dispi = new Uint16Array(16);
    this.dispi[DISPI_ID] = 0xb0c5;
    this.lfbEnabled = false;
    this.currentVbeMode = 0x03;
    // The 64 KiB of video memory window A shows in a VBE mode (4F05h).
    this.vbeBank = 0;

    // VGA register files, kept so reads return what was written
    this.crtcIndex = 0;
    // 0x40 entries with a 0x3f mask: the CRTC goes up to 0x18, and a mask that
    // clears bit 4 would alias 0x11 onto 0x01, 0x12 onto 0x02 and so on.
    this.crtc = new Uint8Array(0x40);
    this.seqIndex = 0;
    // Room for an SVGA's extended registers (see cirrus.js); a plain VGA
    // simply never uses the upper ones.
    this.seq = new Uint8Array(0x20);
    this.gcIndex = 0;
    this.gc = new Uint8Array(0x40);
    this.attrIndex = 0;
    this.attrFlipFlop = false;
    this.attr = new Uint8Array(0x20);
    this.miscOutput = 0x67;
    this.dacWriteIndex = 0;
    this.dacReadIndex = 0;
    this.dacLatch = 0;
    this.palette = new Uint8Array(768);
    this.statusToggle = 0;

    // Four 64 KiB planes, addressed through the 0xA0000 window.
    this.planes = [0, 1, 2, 3].map(() => new Uint8Array(VGA_WINDOW_SIZE));
    this.latch = new Uint8Array(4);
    this.onWindowRouting = () => {};

    this.setDefaultPalette();
    this.dirty = true;

    // The standard VESA numbers mean what VBE 1.2 says they mean: a driver
    // of that age (Windows 95's Super VGA) sets 0x112 for 24-bit colour without
    // asking.  32 bits per pixel has no standard number, so those modes are at
    // 0x140 up, where VBE 2.0 software finds them by reading the mode info.
    this.vbeModes = new Map([
      [0x100, { w: 640, h: 400, bpp: 8 }],
      [0x101, { w: 640, h: 480, bpp: 8 }],
      [0x103, { w: 800, h: 600, bpp: 8 }],
      [0x105, { w: 1024, h: 768, bpp: 8 }],
      [0x110, { w: 640, h: 480, bpp: 15 }],
      [0x111, { w: 640, h: 480, bpp: 16 }],
      [0x112, { w: 640, h: 480, bpp: 24 }],
      [0x113, { w: 800, h: 600, bpp: 15 }],
      [0x114, { w: 800, h: 600, bpp: 16 }],
      [0x115, { w: 800, h: 600, bpp: 24 }],
      [0x116, { w: 1024, h: 768, bpp: 15 }],
      [0x117, { w: 1024, h: 768, bpp: 16 }],
      [0x118, { w: 1024, h: 768, bpp: 24 }],
      [0x140, { w: 640, h: 480, bpp: 32 }],
      [0x141, { w: 800, h: 600, bpp: 32 }],
      [0x142, { w: 1024, h: 768, bpp: 32 }],
    ]);
  }

  /**
   * Back to power-on state, for a guest-initiated reboot.
   *
   * Without this the adapter keeps the mode, the palette and the plane
   * contents the previous system left behind, so the display goes on showing
   * that system's last frame while the new one boots underneath it -- and if
   * the old mode was a linear framebuffer, nothing the new one writes to the
   * text buffer appears at all.
   */
  reset() {
    this.textCols = 80;
    this.textRows = 25;
    this.mode = { text: true, cols: 80, rows: 25 };
    this.biosMode = 0x03;

    this.dispiIndex = 0;
    this.dispi.fill(0);
    this.dispi[DISPI_ID] = 0xb0c5;
    this.lfbEnabled = false;
    this.currentVbeMode = 0x03;

    this.crtcIndex = 0; this.crtc.fill(0);
    this.seqIndex = 0; this.seq.fill(0);
    this.gcIndex = 0; this.gc.fill(0);
    this.attrIndex = 0; this.attrFlipFlop = false; this.attr.fill(0);
    this.miscOutput = 0x67;
    this.dacWriteIndex = 0; this.dacReadIndex = 0; this.dacLatch = 0;
    this.statusToggle = 0;

    for (const p of this.planes) p.fill(0);
    this.latch.fill(0);
    this.setDefaultPalette();
    this.cirrus?.reset();
    this.dirty = true;

    // The 0xA0000 window routing follows the graphics controller, which has
    // just gone back to its defaults, and the host has to be told the mode
    // changed or the canvas keeps the old geometry.
    this.onWindowRouting();
    this.onModeChange?.(this.describe());
  }

  setDefaultPalette() {
    this.palette.set(DEFAULT_DAC);
  }

  /**
   * What a VGA BIOS loads for the text modes and the 350- and 480-line
   * 16-colour modes: the 64 EGA colours in the first 64 DAC entries (two bits
   * per primary, rgbRGB), and an attribute palette choosing the usual sixteen
   * from them.  Windows' 16-colour driver depends on it: it programs only the
   * attribute palette, in EGA terms, and takes the DAC as the BIOS left it.
   */
  setEgaPalette() {
    this.palette.set(EGA_DAC);
    this.attr.set(EGA_ATTR_PALETTE);
  }

  // ---- mode selection ----------------------------------------------------
  setBiosMode(mode) {
    const known = BIOS_MODES.get(mode);
    if (!known) {
      // Falling back to text silently is worse than saying so: the guest goes
      // on drawing into a mode that is not being displayed.
      this.onUnsupportedMode?.(mode);
    }
    const m = known ?? BIOS_MODES.get(0x03);
    // A standard mode set leaves any SVGA mode, as the BIOS's does.
    if (this.cirrus) { this.seq[0x07] = 0; this.cirrus.hiddenDac = 0; }
    this.biosMode = mode;
    this.mode = { ...m };
    this.lfbEnabled = false;
    this.dispi[DISPI_ENABLE] = 0;
    // Each mode set loads the palette that mode expects, as the BIOS does.
    if (m.text || (m.planar && m.h >= 350)) {
      this.setEgaPalette();
      if (m.bpp === 1) this.attr.fill(0x3f, 1, 16);   // mode 11h: black and white
    } else {
      this.setDefaultPalette();                 // CGA colours first, then the ramp
      for (let i = 0; i < 16; i++) this.attr[i] = i;
    }
    if (m.text) {
      this.textCols = m.cols;
      this.textRows = m.rows;
      // clear the text buffer, as a real mode set would
      for (let i = 0; i < m.cols * m.rows; i++) {
        this.m.wr16(0xb8000 + i * 2, 0x0720);
      }
    } else if (m.planar) {
      for (const p of this.planes) p.fill(0);
      this.seq[2] = 0x0f;                       // all planes enabled
      this.gc[8] = 0xff;                        // full bit mask
    } else {
      for (let i = 0; i < m.w * m.h; i++) this.m.wr8(0xa0000 + i, 0);
    }
    this.syncRegisters(m);
    this.updateWindowRouting();
    this.dirty = true;
    this.onModeChange?.(this.describe());
  }

  /** Planar modes need the CPU's writes to the window, other modes do not. */
  updateWindowRouting() {
    // 2 also routes the SVGA's BitBLT registers at 0xB8000, where Windows XP's
    // Cirrus driver puts them; left as memory, every fill and copy it started
    // vanished into the text buffer and windows were drawn without backgrounds.
    const regs = !!this.cirrus?.mmioAtB8000();
    const on = !!this.mode.planar || !!this.cirrus?.wantsWindow() || this.lfbEnabled;
    this.onWindowRouting(regs ? 2 : on ? 1 : 0);
  }

  // ---- deriving the mode from the registers -------------------------------
  //  Plenty of software never calls the BIOS: it programs the sequencer, CRTC
  //  and graphics controller itself.  osakaOS does exactly that to reach mode
  //  13h.  The displayed geometry therefore has to come from the registers,
  //  not only from whatever INT 10h was last asked for.

  /** Total displayed scan lines, assembled from the CRTC overflow bits. */
  verticalDisplayEnd() {
    const c7 = this.crtc[7];
    return (this.crtc[0x12] | ((c7 & 0x02) << 7) | ((c7 & 0x40) << 3)) + 1;
  }

  recomputeFromRegisters() {
    if (this.lfbEnabled) return;            // a VBE mode owns the display
    // An SVGA mode is described by the chip's own registers.
    const ext = this.cirrus?.mode();
    if (ext) {
      const m = this.mode;
      if (!m.cirrus || m.w !== ext.w || m.h !== ext.h || m.bpp !== ext.bpp ||
          m.pitch !== ext.pitch || m.linear !== ext.linear) {
        const sizeChanged = !m.cirrus || m.w !== ext.w || m.h !== ext.h || m.bpp !== ext.bpp;
        this.mode = ext;
        this.updateWindowRouting();
        this.dirty = true;
        if (sizeChanged) this.onModeChange?.(this.describe());
      }
      return;
    }
    if (this.mode.cirrus) {
      // just left an SVGA mode: fall through to the standard derivation, but
      // make sure it does not mistake the old geometry for the new
      this.mode = { text: true, cols: this.textCols, rows: this.textRows, stale: true };
    }
    const graphics = (this.gc[6] & 0x01) !== 0;
    const cols = (this.crtc[1] || 79) + 1;
    const dots = (this.seq[1] & 0x01) ? 8 : 9;
    const maxScan = (this.crtc[9] & 0x1f) + 1;
    let lines = this.verticalDisplayEnd();
    if (lines < 8 || lines > 2048) return;  // registers not programmed yet

    let next;
    if (!graphics) {
      const rows = Math.max(1, Math.round(lines / maxScan));
      if (rows < 10 || rows > 60) return;
      next = { text: true, cols, rows };
    } else {
      const chain4 = (this.seq[4] & 0x08) !== 0;
      let w = cols * dots;
      if (chain4) w >>= 1;                  // 256-colour modes halve the dot clock
      let h = Math.max(1, Math.round(lines / maxScan));
      if ((this.crtc[9] & 0x80) && maxScan === 1) h >>= 1;
      if (w < 64 || w > 2048 || h < 64 || h > 2048) return;
      next = { text: false, planar: !chain4, w, h, bpp: chain4 ? 8 : 4,
               linear: 0xa0000 };
    }

    const same = next.text === this.mode.text &&
                 (next.text
                   ? next.cols === this.textCols && next.rows === this.textRows
                   : next.w === this.mode.w && next.h === this.mode.h &&
                     next.bpp === this.mode.bpp && !!next.planar === !!this.mode.planar);
    if (same) return;

    this.mode = next;
    if (next.text) { this.textCols = next.cols; this.textRows = next.rows; }
    this.updateWindowRouting();
    this.dirty = true;
    this.onModeChange?.(this.describe());
  }

  /**
   * Make the register file agree with a mode chosen through the BIOS, so that
   * a later register write is interpreted against the same picture.
   */
  syncRegisters(m) {
    if (m.text) {
      this.gc[6] = 0x0e;                    // alphanumeric, B8000 window
      this.seq[1] = 0x00;                   // 9-dot characters
      this.seq[4] = 0x02;
      this.crtc[1] = m.cols - 1;
      this.crtc[9] = 0x4f;                  // 16 scan lines per character
      this.crtc[7] = 0x1f;
      this.crtc[0x12] = 0x8f;               // 400 lines total
    } else if (m.planar) {
      this.gc[6] = 0x05;                    // graphics, A0000 window
      this.seq[1] = 0x01;
      this.seq[4] = 0x06;                   // planar
      this.crtc[1] = (m.w >> 3) - 1;
      this.crtc[9] = 0x40;
      this.crtc[7] = m.h > 400 ? 0x3e : 0x1f;
      this.crtc[0x12] = (m.h - 1) & 0xff;
    } else {
      this.gc[6] = 0x05;
      this.seq[1] = 0x01;
      this.seq[4] = 0x0e;                   // chain 4
      this.crtc[1] = ((m.w << 1) >> 3) - 1;
      this.crtc[9] = 0x41;                  // doubled scan lines
      this.crtc[7] = 0x1f;
      this.crtc[0x12] = 0x8f;
    }
  }

  setVbeMode(mode, linear) {
    this.updateWindowRouting();
    const info = this.vbeModes.get(mode);
    if (!info) return false;
    this.currentVbeMode = mode;
    this.lfbEnabled = true;
    this.vbeBank = 0;
    this.mode = { text: false, w: info.w, h: info.h, bpp: info.bpp,
                  linear: this.lfbBase };
    this.dispi[DISPI_XRES] = info.w;
    this.dispi[DISPI_YRES] = info.h;
    this.dispi[DISPI_BPP] = info.bpp;
    this.dispi[DISPI_ENABLE] = 1;
    this.mode.planar = false;
    this.updateWindowRouting();
    this.dirty = true;
    this.onModeChange?.(this.describe());
    return true;
  }

  describe() {
    if (this.mode.text) return `text ${this.textCols}x${this.textRows}`;
    const kind = this.mode.planar ? ' planar' : '';
    return `${this.mode.w}x${this.mode.h}x${this.mode.bpp}${kind}`;
  }

  // ---- planar window -----------------------------------------------------
  //  Writes pass through the graphics controller: the map mask picks planes,
  //  set/reset can substitute a colour, an ALU op combines with the latches
  //  and the bit mask decides which bits of the result survive.
  /** VBE window A: which 64 KiB of video memory 0xA0000 shows. */
  setVbeBank(bank) {
    this.vbeBank = bank & 0xff;
  }

  vbeWindowAddr(offset) {
    return this.lfbBase + ((this.vbeBank * 0x10000 + (offset & 0xffff)) % this.memSize);
  }

  windowWrite(offset, value) {
    if (this.cirrus?.wantsWindow() && !this.mode.planar) { this.cirrus.windowWrite(offset, value & 0xff); return; }
    if (this.lfbEnabled) { this.m.u8[this.vbeWindowAddr(offset)] = value & 0xff; return; }
    offset &= VGA_WINDOW_SIZE - 1;
    value &= 0xff;
    const mode = this.gc[5] & 3;
    const mapMask = this.seq[2] & 0x0f;
    const bitMask = this.gc[8];
    const setReset = this.gc[0] & 0x0f;
    const enableSR = this.gc[1] & 0x0f;
    const rotate = this.gc[3] & 7;
    const op = (this.gc[3] >> 3) & 3;

    for (let p = 0; p < 4; p++) {
      if (!(mapMask & (1 << p))) continue;
      let v;
      let mask = bitMask;

      if (mode === 0) {
        v = rotate ? ror8(value, rotate) : value;
        if (enableSR & (1 << p)) v = (setReset & (1 << p)) ? 0xff : 0x00;
      } else if (mode === 1) {
        this.planes[p][offset] = this.latch[p];      // straight latch copy
        continue;
      } else if (mode === 2) {
        v = (value & (1 << p)) ? 0xff : 0x00;
      } else {
        // mode 3: the written byte becomes the mask, set/reset the colour
        const rotated = rotate ? ror8(value, rotate) : value;
        mask = bitMask & rotated;
        v = (setReset & (1 << p)) ? 0xff : 0x00;
      }

      if (mode !== 3) {
        if (op === 1) v &= this.latch[p];
        else if (op === 2) v |= this.latch[p];
        else if (op === 3) v ^= this.latch[p];
      }
      this.planes[p][offset] = (v & mask) | (this.latch[p] & ~mask);
    }
    this.dirty = true;
  }

  windowRead(offset) {
    if (this.cirrus?.wantsWindow() && !this.mode.planar) return this.cirrus.windowRead(offset);
    if (this.lfbEnabled) return this.m.u8[this.vbeWindowAddr(offset)];
    offset &= VGA_WINDOW_SIZE - 1;
    for (let p = 0; p < 4; p++) this.latch[p] = this.planes[p][offset];
    if ((this.gc[5] >> 3) & 1) {
      // read mode 1: report which pixels match the colour compare register
      const cmp = this.gc[2] & 0x0f;
      const care = this.gc[7] & 0x0f;
      let out = 0;
      for (let bit = 0; bit < 8; bit++) {
        let match = 1;
        for (let p = 0; p < 4; p++) {
          if (!(care & (1 << p))) continue;
          const v = (this.planes[p][offset] >> (7 - bit)) & 1;
          if (v !== ((cmp >> p) & 1)) { match = 0; break; }
        }
        if (match) out |= 0x80 >> bit;
      }
      return out;
    }
    return this.planes[this.gc[4] & 3][offset];
  }

  // ---- port I/O ----------------------------------------------------------
  read(port) {
    switch (port) {
      case 0x3c0: return this.attrIndex;
      case 0x3c1: return this.attr[this.attrIndex & 0x1f];
      case 0x3c2: return 0x10;                        // input status 0
      case 0x3c4: return this.seqIndex;
      case 0x3c5: {
        const ext = this.cirrus?.readSeq(this.seqIndex);
        if (ext !== undefined && ext !== null) return ext;
        return this.seq[this.seqIndex & 0x0f];
      }
      case 0x3c6: return this.cirrus ? this.cirrus.readPel() : 0xff;   // pixel mask
      case 0x3c7: this.cirrus?.dacTouched(); return 0;
      case 0x3c8: this.cirrus?.dacTouched(); return this.dacWriteIndex;
      case 0x3c9: {
        this.cirrus?.dacTouched();
        const v = this.palette[(this.dacReadIndex * 3 + this.dacLatch) % 768];
        if (++this.dacLatch === 3) { this.dacLatch = 0; this.dacReadIndex++; }
        return v;
      }
      case 0x3cc: return this.miscOutput;
      case 0x3ce: return this.gcIndex;
      case 0x3cf: {
        const ext = this.cirrus?.readGc(this.gcIndex);
        if (ext !== undefined && ext !== null) return ext;
        return this.gc[this.gcIndex & 0x0f];
      }
      case 0x3b4: case 0x3d4: return this.crtcIndex;
      case 0x3b5: case 0x3d5:
        // without an SVGA, the chip ID register reads as nothing
        if (!this.cirrus && (this.crtcIndex & 0x3f) === 0x27) return 0;
        return this.crtc[this.crtcIndex & 0x3f];
      case 0x3ba: case 0x3da:
        // Reading status 1 resets the attribute flip-flop.  The retrace bits
        // are toggled so polling loops make progress.
        this.attrFlipFlop = false;
        this.statusToggle ^= 0x09;
        return this.statusToggle;
      case DISPI_INDEX: return this.dispiIndex;
      case DISPI_DATA: return this.dispi[this.dispiIndex & 0x0f];
      default: return 0xff;
    }
  }

  write(port, val, size = 1) {
    // Almost all VGA programming writes the index and the data together with a
    // single 16-bit OUT; taking only the low byte silently discards the value.
    if (size >= 2) {
      if (port === 0x3c0) {
        // the attribute controller takes both through its flip-flop
        this.write(0x3c0, val & 0xff);
        this.write(0x3c0, (val >> 8) & 0xff);
        return;
      }
      if (port === 0x3c4 || port === 0x3ce || port === 0x3d4 || port === 0x3b4) {
        this.write(port, val & 0xff);
        this.write(port + 1, (val >> 8) & 0xff);
        return;
      }
    }
    val &= 0xff;
    switch (port) {
      case 0x3c0:
        if (!this.attrFlipFlop) this.attrIndex = val;
        else this.attr[this.attrIndex & 0x1f] = val;
        this.attrFlipFlop = !this.attrFlipFlop;
        return;
      case 0x3c2: this.miscOutput = val; return;
      case 0x3c4: this.seqIndex = val; return;
      case 0x3c5:
        if (this.cirrus?.writeSeq(this.seqIndex, val)) return;
        this.seq[this.seqIndex & 0x0f] = val;
        if ((this.seqIndex & 0x0f) === 1 || (this.seqIndex & 0x0f) === 4) {
          this.recomputeFromRegisters();
        }
        return;
      case 0x3c6: this.cirrus?.writePel(val); return;
      case 0x3c7: this.cirrus?.dacTouched(); this.dacReadIndex = val; this.dacLatch = 0; return;
      case 0x3c8: this.cirrus?.dacTouched(); this.dacWriteIndex = val; this.dacLatch = 0; return;
      case 0x3c9: {
        this.cirrus?.dacTouched();
        if (this.cirrus?.dacExtended(this.dacWriteIndex, this.dacLatch, val)) {
          if (++this.dacLatch === 3) { this.dacLatch = 0; this.dacWriteIndex++; }
          this.dirty = true;
          return;
        }
        this.palette[(this.dacWriteIndex * 3 + this.dacLatch) % 768] = val & 0x3f;
        if (++this.dacLatch === 3) { this.dacLatch = 0; this.dacWriteIndex++; }
        this.dirty = true;
        return;
      }
      case 0x3ce: this.gcIndex = val; return;
      case 0x3cf:
        if (this.cirrus?.writeGc(this.gcIndex, val)) return;
        this.gc[this.gcIndex & 0x0f] = val;
        if ((this.gcIndex & 0x0f) === 6) this.recomputeFromRegisters();
        return;
      case 0x3b4: case 0x3d4: this.crtcIndex = val; return;
      case 0x3b5: case 0x3d5: {
        const i = this.crtcIndex & 0x3f;
        if (this.cirrus?.writeCrtc(i, val)) return;
        this.crtc[i] = val;
        this.dirty = true;
        if (i === 1 || i === 7 || i === 9 || i === 0x12 ||
            (this.cirrus && (i === 0x0c || i === 0x0d || i === 0x13))) this.recomputeFromRegisters();
        return;
      }
      default: return;
    }
  }

  writeDispi(port, val) {
    if (port === DISPI_INDEX) { this.dispiIndex = val & 0xffff; return; }
    const i = this.dispiIndex & 0x0f;
    this.dispi[i] = val & 0xffff;
    if (i === DISPI_ENABLE) {
      if (val & 1) {
        this.lfbEnabled = (val & 0x40) !== 0 || true;
        this.vbeBank = 0;
        this.mode = {
          text: false,
          w: this.dispi[DISPI_XRES] || 640,
          h: this.dispi[DISPI_YRES] || 480,
          bpp: this.dispi[DISPI_BPP] || 8,
          linear: this.lfbBase,
        };
      } else {
        this.setBiosMode(0x03);
      }
      this.updateWindowRouting();
      this.dirty = true;
      this.onModeChange?.(this.describe());
    }
  }

  // ---- cursor ------------------------------------------------------------
  get cursor() {
    const pos = (this.crtc[0x0e] << 8) | this.crtc[0x0f];
    return { col: pos % this.textCols, row: Math.floor(pos / this.textCols) };
  }

  // ---- framebuffer extraction -------------------------------------------
  /** Screen size in pixels for the current mode. */
  get size() {
    if (this.mode.text) return { w: this.textCols * 9, h: this.textRows * 16 };
    return { w: this.mode.w, h: this.mode.h };
  }

  /**
   * Render the current video memory into an RGBA buffer.
   * Text mode is handled by the caller (it draws glyphs), so this only covers
   * the graphics modes.
   */
  renderGraphics(rgba) {
    if (this.mode.planar) return this.renderPlanar(rgba);
    this.renderLinear(rgba);
    if (this.mode.cirrus) this.cirrus.drawCursor(rgba, this.mode.w, this.mode.h);
  }

  renderLinear(rgba) {
    const { w, h, bpp, linear } = this.mode;
    // Scan lines may be padded past the visible width; a mode that says so
    // carries its own pitch.
    const bytesPP = bpp === 15 ? 2 : Math.max(1, bpp >> 3);
    const pitch = this.mode.pitch ?? w * bytesPP;
    const src = this.m.readBytes(linear, pitch * (h - 1) + w * bytesPP);
    const out = new Uint32Array(rgba.buffer, rgba.byteOffset, w * h);
    let o = 0;
    if (bpp === 8) {
      const lut = new Uint32Array(256);
      for (let c = 0; c < 256; c++) {
        lut[c] = ((this.palette[c * 3] << 2) | ((this.palette[c * 3 + 1] << 2) << 8) |
                  ((this.palette[c * 3 + 2] << 2) << 16) | 0xff000000) >>> 0;
      }
      for (let y = 0; y < h; y++) {
        let s = y * pitch;
        for (let x = 0; x < w; x++) out[o++] = lut[src[s++]];
      }
    } else if (bpp === 15 || bpp === 16) {
      const five = bpp === 15;
      for (let y = 0; y < h; y++) {
        let s = y * pitch;
        for (let x = 0; x < w; x++, s += 2) {
          const v = src[s] | (src[s + 1] << 8);
          let r, g, b;
          if (five) { r = (v >> 10) & 0x1f; g = ((v >> 5) & 0x1f) << 1; b = v & 0x1f; }
          else { r = (v >> 11) & 0x1f; g = (v >> 5) & 0x3f; b = v & 0x1f; }
          // Replicating the top bits fills the low ones, so full scale is 255.
          out[o++] = (((r << 3) | (r >> 2)) | (((g << 2) | (g >> 4)) << 8) |
                      (((b << 3) | (b >> 2)) << 16) | 0xff000000) >>> 0;
        }
      }
    } else if (bpp === 24) {
      for (let y = 0; y < h; y++) {
        let s = y * pitch;
        for (let x = 0; x < w; x++, s += 3) {
          out[o++] = (src[s + 2] | (src[s + 1] << 8) | (src[s] << 16) | 0xff000000) >>> 0;
        }
      }
    } else {
      for (let y = 0; y < h; y++) {
        let s = y * pitch;
        for (let x = 0; x < w; x++, s += 4) {
          out[o++] = (src[s + 2] | (src[s + 1] << 8) | (src[s] << 16) | 0xff000000) >>> 0;
        }
      }
    }
  }

  /**
   * Planar modes store one bit of eight pixels per plane, so a pixel's colour
   * index is assembled a bit at a time and then run through the attribute
   * palette and the DAC.
   */
  renderPlanar(rgba) {
    const { w, h } = this.mode;
    const stride = w >> 3;
    const [p0, p1, p2, p3] = this.planes;
    // The sixteen colours, resolved through the attribute palette and the DAC
    // once per frame rather than once per pixel, as whole RGBA words.
    const colours = new Uint32Array(16);
    const bytes = new Uint8Array(colours.buffer);
    for (let i = 0; i < 16; i++) {
      const dac = (this.attr[i] & 0x3f) * 3;
      bytes[i * 4] = this.palette[dac] << 2;
      bytes[i * 4 + 1] = this.palette[dac + 1] << 2;
      bytes[i * 4 + 2] = this.palette[dac + 2] << 2;
      bytes[i * 4 + 3] = 255;
    }
    const out = new Uint32Array(rgba.buffer, rgba.byteOffset, w * h);
    const spread = PLANE_SPREAD;
    let o = 0;
    for (let y = 0; y < h; y++) {
      const row = y * stride;
      for (let bx = 0; bx < stride; bx++) {
        const i = row + bx;
        // Eight 4-bit colour indices at once, pixel 0 in the low nibble.
        const nib = spread[p0[i]] | (spread[p1[i]] << 1) |
                    (spread[p2[i]] << 2) | (spread[p3[i]] << 3);
        out[o] = colours[nib & 15];
        out[o + 1] = colours[(nib >>> 4) & 15];
        out[o + 2] = colours[(nib >>> 8) & 15];
        out[o + 3] = colours[(nib >>> 12) & 15];
        out[o + 4] = colours[(nib >>> 16) & 15];
        out[o + 5] = colours[(nib >>> 20) & 15];
        out[o + 6] = colours[(nib >>> 24) & 15];
        out[o + 7] = colours[nib >>> 28];
        o += 8;
      }
    }
  }

  /** Snapshot of the text buffer: one entry per cell. */
  readText() {
    const cells = this.textCols * this.textRows;
    const raw = this.m.readBytes(0xb8000, cells * 2);
    return raw;
  }

  static textColor(index) { return TEXT_PALETTE[index & 15]; }
}
