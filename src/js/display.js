// ---------------------------------------------------------------------------
//  Canvas renderer for the VGA adapter.
//
//  Text modes are drawn as glyphs with the browser's monospace font, which
//  avoids shipping a 4 KiB ROM font and stays crisp at any zoom.  Graphics
//  modes go through ImageData.
// ---------------------------------------------------------------------------

import { VGA } from './vga.js';

const CELL_W = 9;
const CELL_H = 16;

export class Display {
  constructor(canvas, vga) {
    this.canvas = canvas;
    this.vga = vga;
    this.ctx = canvas.getContext('2d', { alpha: false });
    this.imageData = null;
    this.prevCells = null;
    this.prevMode = '';
    this.blinkOn = true;
    this.lastBlink = 0;
  }

  resize() {
    const { w, h } = this.vga.size;
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
      this.prevCells = null;
      this.imageData = null;
      this.ctx.imageSmoothingEnabled = false;
    }
  }

  render(now = 0) {
    const mode = this.vga.describe();
    if (mode !== this.prevMode) {
      this.prevMode = mode;
      this.prevCells = null;
      this.imageData = null;
    }
    this.resize();
    if (this.vga.mode.text) this.renderText(now);
    else this.renderGraphics();
  }

  renderGraphics() {
    const { w, h } = this.vga.size;
    // A frame that arrived already rendered is put on screen as it is.
    const ready = this.vga.takeImage?.();
    let img = ready;
    if (!img) {
      if (!this.imageData || this.imageData.width !== w || this.imageData.height !== h) {
        this.imageData = this.ctx.createImageData(w, h);
      }
      this.vga.renderGraphics(this.imageData.data);
      img = this.imageData;
    }
    this.ctx.putImageData(img, 0, 0);
    // sampled, so the count costs little on a large mode
    let lit = 0;
    const d = img.data;
    for (let i = 0; i < d.length; i += 64) if (d[i] | d[i + 1] | d[i + 2]) lit++;
    this.litSample = lit;
    this.litTotal = d.length >> 6;
  }

  renderText(now) {
    const ctx = this.ctx;
    const cols = this.vga.textCols;
    const rows = this.vga.textRows;
    const cells = this.vga.readText();

    if (now - this.lastBlink > 500) {
      this.lastBlink = now;
      this.blinkOn = !this.blinkOn;
      this.cursorDirty = true;
    }

    this.litSample = null;
    if (!this.prevCells || this.prevCells.length !== cells.length) {
      this.prevCells = new Uint8Array(cells.length).fill(0xff);
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    }

    ctx.font = `${CELL_H - 3}px ui-monospace, Menlo, Consolas, monospace`;
    ctx.textBaseline = 'top';

    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const i = (r * cols + c) * 2;
        const ch = cells[i];
        const attr = cells[i + 1];
        if (ch === this.prevCells[i] && attr === this.prevCells[i + 1] &&
            !this.cursorDirty) {
          continue;
        }
        this.prevCells[i] = ch;
        this.prevCells[i + 1] = attr;

        const x = c * CELL_W;
        const y = r * CELL_H;
        const bg = VGA.textColor((attr >> 4) & 7);
        const fg = VGA.textColor(attr & 15);
        ctx.fillStyle = `rgb(${bg[0]},${bg[1]},${bg[2]})`;
        ctx.fillRect(x, y, CELL_W, CELL_H);
        if (ch >= 0x20 && ch !== 0xff) {
          ctx.fillStyle = `rgb(${fg[0]},${fg[1]},${fg[2]})`;
          ctx.fillText(codeToChar(ch), x, y + 1);
        }
      }
    }

    // hardware cursor
    const cur = this.vga.cursor;
    if (this.blinkOn && cur.row < rows && cur.col < cols) {
      ctx.fillStyle = '#c8c8c8';
      ctx.fillRect(cur.col * CELL_W, cur.row * CELL_H + CELL_H - 3, CELL_W, 2);
      const i = (cur.row * cols + cur.col) * 2;
      this.prevCells[i] = 0xff;             // force a redraw when it moves
    }
    this.cursorDirty = false;
  }
}

/**
 * The screen as a worker last sent it, presented the way Display reads a VGA.
 *
 * The emulator runs off the page's thread, so the page never sees video
 * memory: it is sent text cells, or a graphics frame already rendered to RGBA,
 * and this answers Display's questions from whichever arrived last.
 */
export class FrameSource {
  constructor() {
    this.mode = { text: true };
    this.textCols = 80;
    this.textRows = 25;
    this.cells = new Uint8Array(80 * 25 * 2);
    this.cursorPos = { row: 0, col: 0 };
    this.w = 720;
    this.h = 400;
    this.image = null;
    this.desc = 'text 80x25';
  }

  /** Take a frame message; returns a buffer the sender may have back. */
  update(f) {
    this.desc = f.desc;
    if (f.text) {
      this.mode = { text: true };
      this.textCols = f.cols;
      this.textRows = f.rows;
      this.cells = f.cells;
      this.cursorPos = f.cursor;
      return null;
    }
    this.mode = { text: false };
    this.w = f.w;
    this.h = f.h;
    this.image = new ImageData(f.rgba, f.w, f.h);
    this.lastImage = this.image;
    return null;
  }

  /** The pending rendered frame, once; Display puts it on screen as it is. */
  takeImage() {
    const img = this.image;
    this.image = null;
    return img;
  }

  describe() { return this.desc; }

  get size() {
    return this.mode.text ? { w: this.textCols * 9, h: this.textRows * 16 }
                          : { w: this.w, h: this.h };
  }

  readText() { return this.cells; }
  get cursor() { return this.cursorPos; }

  // Only reached when a graphics frame is drawn twice; the last one stands.
  renderGraphics(rgba) {
    const last = this.lastImage?.data;
    if (last && last.length === rgba.length) rgba.set(last);
  }
}

// Code page 437, for the box-drawing and symbol characters bootloader menus use.
const CP437_HIGH =
  'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒ' +
  'áíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐' +
  '└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀' +
  'αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ';

const CP437_LOW =
  ' ☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼';

function codeToChar(code) {
  if (code >= 0x20 && code < 0x7f) return String.fromCharCode(code);
  if (code < 0x20) return CP437_LOW[code] ?? ' ';
  return CP437_HIGH[code - 0x80] ?? ' ';
}
