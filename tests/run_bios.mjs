// BIOS and VGA test: assemble a boot sector, wrap it in a floppy image, boot it
// the way a PC would, and check both the framebuffer contents and the RGBA the
// renderer produces from them.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assemble } from './harness.mjs';
import { Emulator } from '../src/js/emulator.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

let failures = 0;
const check = (name, ok, detail = '') => {
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  ' + detail}`);
};

// ---- build a 1.44 MB floppy whose first sector is the test program ----
const code = assemble('t_vga', 0x7c00);
const floppy = new Uint8Array(1440 * 1024);
floppy.set(code.subarray(0, 512), 0);

const emu = new Emulator({ ramSize: 64 * 1024 * 1024, sliceSize: 200_000 });
await emu.init(readFileSync(join(root, 'build', 'cpu.wasm')));

let serial = '';
const debugPort = [];
emu.onSerial = (b) => { serial += String.fromCharCode(b); };
emu.io.debugOut = (b) => debugPort.push(b);

const info = emu.bootImage({ data: floppy, name: 't_vga.img', kind: 'floppy' });
check('floppy image detected', info.kind === 'floppy' && info.drive === 0,
      `got ${info.kind} drive ${info.drive}`);

for (let i = 0; i < 400 && !emu.machine.halted; i++) emu.step();

check('guest reported success', debugPort.at(-1) === 0,
      `debug port: ${JSON.stringify(debugPort)}`);
check('INT 10h teletype reached the console', serial.includes('x64emu vga test'),
      JSON.stringify(serial.slice(0, 60)));
check('video mode is 320x200x8', emu.vga.describe() === '320x200x8',
      emu.vga.describe());

// the guest wrote colour (x ^ y) at every pixel
const fb = emu.machine.readBytes(0xa0000, 320 * 200);
let pixelsOk = true;
for (const [x, y] of [[0, 0], [1, 0], [17, 5], [319, 199], [255, 128]]) {
  if (fb[y * 320 + x] !== ((x ^ y) & 0xff)) {
    pixelsOk = false;
    console.log(`   pixel (${x},${y}) = ${fb[y * 320 + x]}, expected ${(x ^ y) & 0xff}`);
  }
}
check('framebuffer holds the expected pattern', pixelsOk);

// and the renderer turns those indices into the palette colours
const rgba = new Uint8ClampedArray(320 * 200 * 4);
emu.vga.renderGraphics(rgba);
const pal = emu.vga.palette;
const idx = (17 ^ 5) & 0xff;
const at = (5 * 320 + 17) * 4;
const expect = [pal[idx * 3] << 2, pal[idx * 3 + 1] << 2, pal[idx * 3 + 2] << 2, 255];
const got = [rgba[at], rgba[at + 1], rgba[at + 2], rgba[at + 3]];
check('renderer maps indices through the palette',
      expect.every((v, i) => v === got[i]), `${got} vs ${expect}`);

check('no CPU exceptions were taken',
      (emu.machine.exports.fault_trace_index() >>> 0) === 0,
      `${emu.machine.exports.fault_trace_index() >>> 0} faults`);

// ---------------------------------------------------------------------------
//  writable RAM hard drive
// ---------------------------------------------------------------------------
{
  const code2 = assemble('t_disk', 0x7c00);
  const boot = new Uint8Array(1440 * 1024);
  boot.set(code2.subarray(0, 512), 0);

  const emu2 = new Emulator({ ramSize: 64 * 1024 * 1024, sliceSize: 200_000 });
  await emu2.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const dbg = [];
  emu2.io.debugOut = (b) => dbg.push(b);
  emu2.onSerial = () => {};

  // a 256 GiB drive, which only exists as the chunks the guest touches
  const HDD = 256 * 1024 * 1024 * 1024;
  const info2 = emu2.bootImage({ data: boot, name: 'boot.img', kind: 'floppy' },
                               { hddSize: HDD, hddName: 'ram0' });

  const hdd = info2.disks.find((d) => d.name === 'ram0');
  check('RAM drive attached as 0x80', hdd && hdd.drive === 0x80, JSON.stringify(hdd));
  check('RAM drive is writable', hdd && hdd.writable === true);
  check('RAM drive reports its full size',
        hdd && hdd.sectors === HDD / 512, `${hdd?.sectors} sectors`);
  check('an unused 256 GiB drive costs nothing',
        emu2.ramDisk.allocated === 0, `${emu2.ramDisk.allocated} bytes`);

  for (let i = 0; i < 600 && !emu2.machine.halted; i++) emu2.step();

  check('guest disk checks passed', dbg.at(-1) === 0,
        `debug port: ${JSON.stringify(dbg)}`);

  // the pattern really is in the store, at the LBA the guest asked for
  const back = emu2.ramDisk.read(0x12345, 1);
  let patternOk = back && back.length === 512;
  if (patternOk) {
    for (let i = 0; i < 512; i++) {
      if (back[i] !== ((i & 0xff) ^ 0x5a)) { patternOk = false; break; }
    }
  }
  check('written sector is present in the store', patternOk);

  const committed = emu2.ramDisk.allocated;
  check('only touched regions are committed',
        committed > 0 && committed <= 4 * 1024 * 1024,
        `${(committed / 1048576).toFixed(0)} MiB committed of 256 GiB`);
  console.log(`   (256 GiB drive, ${(committed / 1048576).toFixed(0)} MiB actually allocated)`);
}

// ---------------------------------------------------------------------------
//  ATA controller, driven the way an OS driver would
// ---------------------------------------------------------------------------
{
  const emu3 = new Emulator({ ramSize: 32 * 1024 * 1024 });
  await emu3.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const tiny = new Uint8Array(512);
  tiny[510] = 0x55; tiny[511] = 0xaa;
  emu3.bootImage({ data: tiny, name: 'stub.img', kind: 'floppy' },
                 { hddSize: 4 * 1024 * 1024 * 1024, hddName: 'ram0' });

  const io = emu3.io;
  const rd = (p, sz = 1) => io.read(p, sz);
  const wr = (p, v, sz = 1) => io.write(p, sz, v);

  const selectLba = (lba, count) => {
    wr(0x1f6, 0xe0 | ((lba >>> 24) & 0x0f));    // LBA mode, master
    wr(0x1f2, count);
    wr(0x1f3, lba & 0xff);
    wr(0x1f4, (lba >>> 8) & 0xff);
    wr(0x1f5, (lba >>> 16) & 0xff);
  };

  // IDENTIFY
  wr(0x1f6, 0xe0);
  wr(0x1f7, 0xec);
  const ident = new Uint8Array(512);
  for (let i = 0; i < 256; i++) {
    const w = rd(0x1f0, 2);
    ident[i * 2] = w & 0xff;
    ident[i * 2 + 1] = (w >> 8) & 0xff;
  }
  let model = '';
  for (let i = 0; i < 40; i += 2) model += String.fromCharCode(ident[54 + i + 1], ident[54 + i]);
  check('ATA IDENTIFY returns a model string', model.trim() === 'x64emu RAM disk',
        JSON.stringify(model.trim()));
  const lba48 = ident[100 * 2] | (ident[100 * 2 + 1] << 8) |
                (ident[101 * 2] << 16) | (ident[101 * 2 + 1] << 24);
  check('ATA reports the full 48-bit capacity',
        lba48 === (4 * 1024 * 1024 * 1024) / 512, `${lba48} sectors`);
  // A CHS command has four bits for the head.  The BIOS's 255-head geometry
  // here made a large disk look CHS-addressable, and Windows XP used CHS on it.
  const word = (i) => ident[i * 2] | (ident[i * 2 + 1] << 8);
  check('IDENTIFY reports a geometry CHS commands can express',
        word(1) === Math.floor(lba48 / (16 * 63)) && word(3) === 16 && word(6) === 63,
        `${word(1)}/${word(3)}/${word(6)}`);

  // write a sector through the data port
  const pattern = new Uint8Array(512);
  for (let i = 0; i < 512; i++) pattern[i] = (i * 7 + 3) & 0xff;
  selectLba(0x20000, 1);
  wr(0x1f7, 0x30);                               // WRITE SECTORS
  check('ATA asserts DRQ for the data phase', (rd(0x1f7) & 0x08) !== 0);
  for (let i = 0; i < 512; i += 2) {
    wr(0x1f0, pattern[i] | (pattern[i + 1] << 8), 2);
  }
  check('ATA clears DRQ when the sector is complete', (rd(0x1f7) & 0x08) === 0);

  const stored = emu3.ramDisk.read(0x20000, 1);
  check('ATA write reached the sparse store',
        stored && pattern.every((v, i) => stored[i] === v));

  // read it back through the data port
  selectLba(0x20000, 1);
  wr(0x1f7, 0x20);                               // READ SECTORS
  const got = new Uint8Array(512);
  for (let i = 0; i < 512; i += 2) {
    const w = rd(0x1f0, 2);
    got[i] = w & 0xff;
    got[i + 1] = (w >> 8) & 0xff;
  }
  check('ATA read returns what was written', pattern.every((v, i) => got[i] === v));

  // an untouched sector reads back as zeros
  selectLba(0x30000, 1);
  wr(0x1f7, 0x20);
  let zeros = true;
  for (let i = 0; i < 256; i++) if (rd(0x1f0, 2) !== 0) { zeros = false; break; }
  check('ATA read of an unwritten sector is zeros', zeros);

  // an unknown command must abort rather than hang
  wr(0x1f7, 0xff);
  check('ATA aborts unknown commands', (rd(0x1f7) & 0x01) !== 0);

  // PIO data-in is one block per interrupt.  Linux's ata_piix reads a sector
  // when interrupted and waits for the next; one interrupt for the whole
  // transfer left every multi-sector read hanging after its first sector.
  const irq14 = () => (io.pic.slave.irr & 0x40) !== 0;
  const sector = () => { for (let i = 0; i < 256; i++) rd(0x1f0, 2); };
  selectLba(0, 2);
  wr(0x1f7, 0x20);                                 // READ SECTORS, two of them
  const first = irq14();
  rd(0x1f7);                                       // acknowledge
  sector();
  const second = irq14() && (rd(0x1f7) & 0x08) !== 0;
  sector();
  check('a two-sector PIO read interrupts once per sector',
        first && second && !irq14() && (rd(0x1f7) & 0x08) === 0,
        `first ${first} second ${second}`);

  // READ MULTIPLE moves the SET MULTIPLE MODE count per interrupt
  wr(0x1f2, 4);
  wr(0x1f7, 0xc6);                                 // SET MULTIPLE MODE, 4 sectors
  rd(0x1f7);
  selectLba(0, 8);
  wr(0x1f7, 0xc4);                                 // READ MULTIPLE
  rd(0x1f7);
  for (let s = 0; s < 4; s++) sector();
  check('READ MULTIPLE interrupts once per block of the multiple count',
        irq14() && (rd(0x1f7) & 0x08) !== 0);
  for (let s = 0; s < 4; s++) sector();

  // LBA48 writes each register twice, the high-order byte first.  Reading the
  // two halves the wrong way round sent Debian's journal writes past the end
  // of its disk.
  wr(0x1f6, 0xe0);
  wr(0x1f2, 0x00); wr(0x1f3, 0x00); wr(0x1f4, 0x00); wr(0x1f5, 0x00);   // bits 24-47
  wr(0x1f2, 0x01); wr(0x1f3, 0x34); wr(0x1f4, 0x12); wr(0x1f5, 0x7f);   // bits 0-23
  wr(0x1f7, 0x34);                                 // WRITE SECTORS EXT
  for (let i = 0; i < 256; i++) wr(0x1f0, 0xc0de, 2);
  const at48 = emu3.ramDisk.read(0x7f1234, 1);
  check('an LBA48 write lands on the sector the host named',
        (rd(0x1f7) & 0x01) === 0 && at48 && at48[0] === 0xde && at48[1] === 0xc0,
        `status 0x${rd(0x1f7).toString(16)}`);

  // Linux moves sector data a dword at a time.  Each one used to be cut to
  // its low byte on the way in, and fsck's journal replay zeroed the disk.
  selectLba(0x40000, 1);
  wr(0x1f7, 0x30);
  for (let i = 0; i < 128; i++) wr(0x1f0, 0x9a3de56a, 4);
  const dw = emu3.ramDisk.read(0x40000, 1);
  selectLba(0x40000, 1);
  wr(0x1f7, 0x20);
  const back = rd(0x1f0, 4);
  // INITIALIZE DEVICE PARAMETERS sets the geometry later CHS commands use
  wr(0x1f6, 0xa3);                                 // 4 heads
  wr(0x1f2, 17);                                   // 17 sectors per track
  wr(0x1f7, 0x91);
  rd(0x1f7);
  wr(0x1f6, 0xa2);                                 // CHS: head 2
  wr(0x1f2, 1); wr(0x1f3, 5); wr(0x1f4, 1); wr(0x1f5, 0);   // sector 5, cylinder 1
  wr(0x1f7, 0x30);
  for (let i = 0; i < 256; i++) wr(0x1f0, 0x5aa5, 2);
  const chsAt = emu3.ramDisk.read((1 * 4 + 2) * 17 + 4, 1);
  check('a CHS write lands where the geometry set by INITIALIZE DEVICE PARAMETERS puts it',
        chsAt && chsAt[0] === 0xa5 && chsAt[1] === 0x5a);

  check('a 32-bit data write stores all four bytes',
        dw && dw[0] === 0x6a && dw[1] === 0xe5 && dw[2] === 0x3d && dw[3] === 0x9a &&
        dw[511] === 0x9a && back === 0x9a3de56a,
        dw ? `stored ${[...dw.subarray(0, 4)].map((b) => b.toString(16)).join(' ')}` : 'nothing stored');
}

// An image read in pieces, as a browser reads a File, may not have the sector
// yet.  The drive stays busy and finishes once the chunk is in, interrupting
// as usual; aborting was reported to Linux as a read error.
{
  const { ChunkStore, Disk } = await import('../src/js/disk.js');
  const e = new Emulator({ ramSize: 16 * 1024 * 1024 });
  await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  e.bios.log = () => {};
  const bytes = new Uint8Array(4 * 1024 * 1024);
  bytes[3 * 1024 * 1024] = 0xab;                   // first byte of LBA 6144
  const store = new ChunkStore(bytes.length,
    (off, len) => Promise.resolve(bytes.slice(off, off + len)));
  await store.ensure(0, 64 * 1024);
  e.bootImage(new Disk(store, 'hdd', 'async.img'), { hddSize: 0 });
  const io = e.io;
  io.write(0x1f6, 1, 0xe0);
  io.write(0x1f2, 1, 1);
  io.write(0x1f3, 1, 0x00); io.write(0x1f4, 1, 0x18); io.write(0x1f5, 1, 0x00);
  io.write(0x1f7, 1, 0x20);                        // a chunk not fetched yet
  const busy = io.read(0x3f6, 1);
  await store.whenReady();
  e.ata.retryPending();
  const done = io.read(0x3f6, 1);
  check('an ATA read of a chunk still in flight stays busy, then completes',
        busy === 0x80 && (done & 0x09) === 0x08 && (io.read(0x1f0, 2) & 0xff) === 0xab,
        `busy 0x${busy.toString(16)} then 0x${done.toString(16)}`);
}

// Sectors past 4 GiB are their own, in both an image and a RAM disk.  The
// chunk index was taken with >>>, which wrapped them onto the first 4 GiB.
{
  const { ChunkStore, SparseStore } = await import('../src/js/disk.js');
  const GiB = 1024 ** 3;
  const ram = new SparseStore(6 * GiB);
  ram.write(5 * GiB, Uint8Array.of(0x55, 0x66));
  const far = ram.readSync(5 * GiB, 2), near = ram.readSync(1 * GiB, 2);
  check('a RAM disk keeps a sector past 4 GiB apart from the low ones',
        far[0] === 0x55 && far[1] === 0x66 && near[0] === 0 && near[1] === 0);
  // every byte of the image is the number of the gigabyte it sits in
  const image = new ChunkStore(6 * GiB,
    (off, len) => new Uint8Array(len).fill(Math.floor(off / GiB)), { writable: true });
  const before = image.readSync(5 * GiB, 1)[0];
  image.write(5 * GiB + 512, Uint8Array.of(0x77));
  check('an image reads and writes past 4 GiB where it was asked to',
        before === 5 && image.readSync(5 * GiB + 512, 1)[0] === 0x77 &&
        image.readSync(1 * GiB + 512, 1)[0] === 1,
        `read ${before}`);
}

// ---------------------------------------------------------------------------
//  the display actually produces a picture
// ---------------------------------------------------------------------------
//  Everything above checks video memory.  This drives the browser renderer end
//  to end through a stub canvas and asserts that something is really drawn, in
//  each class of mode, because "the mode was set" and "the screen shows it" are
//  different claims.
{
  const { Display } = await import('../src/js/display.js');
  const puts = [];
  let fills = 0, glyphs = 0;
  const ctx = {
    imageSmoothingEnabled: true, font: '', textBaseline: '', fillStyle: '',
    createImageData: (w, h) => ({ width: w, height: h,
                                  data: new Uint8ClampedArray(w * h * 4) }),
    putImageData: (img) => puts.push(img),
    fillRect: () => { fills++; },
    fillText: () => { glyphs++; },
  };
  const canvas = { width: 720, height: 400, style: {}, getContext: () => ctx };

  const emu9 = new Emulator({ ramSize: 64 * 1024 * 1024 });
  await emu9.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const disp = new Display(canvas, emu9.vga);
  const v = emu9.vga;
  const stats = (img) => {
    let lit = 0; const seen = new Set();
    for (let i = 0; i < img.data.length; i += 4) {
      const [r, g, b] = [img.data[i], img.data[i + 1], img.data[i + 2]];
      if (r | g | b) lit++;
      seen.add((r << 16) | (g << 8) | b);
    }
    return { lit, colours: seen.size };
  };

  // text
  v.setBiosMode(0x03);
  const msg = 'GRAPHICAL OUTPUT TEST';
  for (let i = 0; i < msg.length; i++) {
    emu9.machine.wr8(0xb8000 + i * 2, msg.charCodeAt(i));
    emu9.machine.wr8(0xb8000 + i * 2 + 1, 0x0f);
  }
  disp.render(0);
  check('text mode draws cells and glyphs', fills > 100 && glyphs >= msg.length,
        `${fills} cells, ${glyphs} glyphs`);

  // mode 13h, 256 colours through the palette
  v.setBiosMode(0x13);
  for (let i = 0; i < 320 * 200; i++) emu9.machine.wr8(0xa0000 + i, (i % 200) + 20);
  disp.render(16);
  let st = stats(puts.at(-1));
  check('mode 13h presents a picture',
        puts.at(-1).width === 320 && st.lit > 60000 && st.colours > 32,
        `${st.lit} lit, ${st.colours} colours`);

  // planar, through the graphics controller
  v.setBiosMode(0x12);
  emu9.machine.exports.set_vga_mmio(1);
  for (let p = 0; p < 4; p++) {
    v.seq[2] = 1 << p;
    for (let i = 0; i < 640 * 480 / 8; i++) v.windowWrite(i, (i * (p + 1)) & 0xff);
  }
  disp.render(32);
  st = stats(puts.at(-1));
  check('planar mode presents a picture',
        puts.at(-1).width === 640 && st.lit > 100000 && st.colours > 4,
        `${st.lit} lit, ${st.colours} colours`);

  // a linear VBE mode, 640x480 at 32 bits per pixel
  v.setVbeMode(0x140, true);
  for (let i = 0; i < 640 * 480; i++) {
    emu9.machine.wr32(v.lfbBase + i * 4, (i & 0xff) | ((i >> 3) & 0xff) << 8 | 0x220000);
  }
  disp.render(48);
  st = stats(puts.at(-1));
  check('a VBE mode presents a picture',
        puts.at(-1).width === 640 && st.lit > 200000 && st.colours > 100,
        `${st.lit} lit, ${st.colours} colours`);
}

// ---------------------------------------------------------------------------
//  mode set by programming the VGA registers directly
// ---------------------------------------------------------------------------
{
  const emu8 = new Emulator({ ramSize: 32 * 1024 * 1024 });
  await emu8.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const io = emu8.io;
  const wr = (p, v) => io.write(p, 1, v);
  const v = emu8.vga;

  // CRTC registers run to 0x18; a mask that drops bit 4 aliases 0x11 onto 0x01
  wr(0x3d4, 0x11); wr(0x3d5, 0x0e);
  wr(0x3d4, 0x12); wr(0x3d5, 0x8f);
  wr(0x3d4, 0x17); wr(0x3d5, 0xa3);
  check('CRTC registers above 0x0F do not alias',
        v.crtc[0x11] === 0x0e && v.crtc[0x12] === 0x8f && v.crtc[0x17] === 0xa3 &&
        v.crtc[0x01] !== 0x0e && v.crtc[0x07] !== 0xa3,
        `0x11=${v.crtc[0x11]} 0x01=${v.crtc[0x01]} 0x17=${v.crtc[0x17]} 0x07=${v.crtc[0x07]}`);

  // the standard mode 13h programming sequence, with no BIOS call at all
  wr(0x3c2, 0x63);
  for (const [i, val] of [[0, 0x03], [1, 0x01], [2, 0x0f], [3, 0x00], [4, 0x0e]]) {
    wr(0x3c4, i); wr(0x3c5, val);
  }
  const CRTC13 = [0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0xbf, 0x1f, 0x00, 0x41,
                  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x0e, 0x8f, 0x28,
                  0x40, 0x96, 0xb9, 0xa3, 0xff];
  for (let i = 0; i < CRTC13.length; i++) { wr(0x3d4, i); wr(0x3d5, CRTC13[i]); }
  for (const [i, val] of [[0, 0x00], [1, 0x00], [2, 0x00], [3, 0x00], [4, 0x00],
                          [5, 0x40], [6, 0x05], [7, 0x0f], [8, 0xff]]) {
    wr(0x3ce, i); wr(0x3cf, val);
  }
  check('a directly programmed mode 13h is recognised',
        v.describe() === '320x200x8', v.describe());
  check('mode 13h is not treated as planar', v.mode.planar !== true);

  // and mode 12h likewise, from its own register set
  for (const [i, val] of [[1, 0x01], [4, 0x06]]) { wr(0x3c4, i); wr(0x3c5, val); }
  const CRTC12 = [[1, 0x4f], [7, 0x3e], [9, 0x40], [0x12, 0xdf]];
  for (const [i, val] of CRTC12) { wr(0x3d4, i); wr(0x3d5, val); }
  // VBE must also accept the plain VGA mode numbers
  {
    const emuV = new Emulator({ ramSize: 32 * 1024 * 1024 });
    await emuV.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    const stub = new Uint8Array(512); stub[510] = 0x55; stub[511] = 0xaa;
    emuV.bootImage({ data: stub, name: 's.img', kind: 'floppy' });
    emuV.bios.setR16(0, 0x4f02);          // AX = set VBE mode
    emuV.bios.setR16(3, 0x0012);          // BX = mode 0x12
    emuV.bios.int10();
    check('VBE accepts a plain VGA mode number',
          (emuV.bios.r16(0) & 0xffff) === 0x004f &&
          emuV.vga.describe() === '640x480x4 planar',
          `ax=0x${emuV.bios.r16(0).toString(16)} mode=${emuV.vga.describe()}`);
  }

  // The drive activity readout: a guest still pulling data off the install
  // image and one that has gone quiet look identical in the instruction
  // counter, so the panel has to tell them apart.
  {
    const { formatDiskRow } = await import('../src/js/format.js');
    const iso = { kind: 'cdrom', reads: 12345, bytesRead: 650 * 2 ** 20,
                  lastLba: 158000, sectorSize: 2048, size: 5 * 2 ** 30 };
    const busy = formatDiskRow(iso, 3 * 2 ** 20, false, 1);
    check('a drive being read lights up and reports its rate',
          busy.lamp === 'lamp on' && busy.value.includes('/s'), busy.value);
    const idle = formatDiskRow(iso, 0, false, 1);
    check('a quiet drive does not light up and reports no rate',
          idle.lamp === 'lamp' && !idle.value.includes('/s'), idle.value);
    const waiting = formatDiskRow(iso, 0, true, 1);
    check('a drive waiting on data that is not resident shows apart from both',
          waiting.lamp === 'lamp wait', waiting.lamp);
    check('the readout says how far into the image the guest has reached',
          idle.value.includes('lba 158,000') && idle.value.includes('(6%)'), idle.value);
    const fresh = formatDiskRow({ ...iso, lastLba: -1, bytesRead: 0, reads: 0 }, 0, false, 1);
    check('a drive never read reports idle rather than a position',
          fresh.value.includes('idle') && !fresh.value.includes('lba'), fresh.value);
    // A rate of a few hundred bytes a second is activity, and must not round
    // away to nothing.
    const trickle = formatDiskRow(iso, 338, false, 1);
    check('a slow trickle still reads as a rate rather than zero',
          trickle.value.includes('338 B/s'), trickle.value);
  }

  // The framebuffer base is computed by aligning the top of RAM downwards.
  // Doing that with a bitwise AND silently produced a negative address on any
  // machine with more than about 2.5 GiB, because JavaScript's bitwise
  // operators are 32-bit signed -- and that address is both handed to the guest
  // and used to read its pixels back.
  for (const gib of [1, 2, 3, 4, 8]) {
    const e = new Emulator({ ramSize: gib * 1024 ** 3 });
    check(`framebuffer base is sane with ${gib} GiB`,
          e.vramBase > 0 && e.vramBase < 0x1_0000_0000 &&
          e.vramBase % 0x20_0000 === 0 &&
          e.vramBase + 16 * 1024 * 1024 <= Math.min(e.ramSize, 0x1_0000_0000),
          `0x${e.vramBase.toString(16)}`);
  }

  // The character generator hands out a pointer a guest renders through.  It
  // used to return BP=0 with ES untouched, so every glyph a self-rendering
  // guest drew came out of whatever its own ES pointed at.
  {
    const emuF = new Emulator({ ramSize: 32 * 1024 * 1024 });
    await emuF.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    const stub = new Uint8Array(512); stub[510] = 0x55; stub[511] = 0xaa;
    emuF.bootImage({ data: stub, name: 's.img', kind: 'floppy' });
    emuF.bios.setR16(0, 0x1130);          // AX = get font information
    emuF.bios.setR16(3, 0x0600);          // BH = 6, the 8x16 font
    emuF.bios.int10();
    const seg = emuF.machine.exports.get_seg_base(0);   // ES
    const bp = emuF.bios.r16(5) & 0xffff;
    const cx = emuF.bios.r16(1) & 0xffff;
    const at = Number(seg) + bp;
    // 'A' must be a real glyph: non-blank, and inside the cell rather than
    // running into its neighbours.
    const rows = [];
    for (let i = 0; i < 16; i++) rows.push(emuF.machine.rd8(at + 0x41 * 16 + i));
    const lit = rows.filter((r) => r !== 0).length;
    check('INT 10h AX=1130 returns a usable font pointer',
          Number(seg) !== 0 && cx === 16 && lit >= 5 && rows.every((r) => (r & 1) === 0),
          `es:bp=${seg.toString(16)}:${bp.toString(16)} cx=${cx} rows lit=${lit}`);
    check('the font table covers the printable range',
          [0x20, 0x30, 0x5a, 0x7a, 0x7e].every((c) => {
            const any = [];
            for (let i = 0; i < 16; i++) any.push(emuF.machine.rd8(at + c * 16 + i));
            return c === 0x20 ? any.every((r) => r === 0) : any.some((r) => r !== 0);
          }), 'space blank, 0 Z z ~ all drawn');
  }

  check('a directly programmed mode 12h is recognised',
        v.describe() === '640x480x4 planar', v.describe());

  // going back to text through the graphics controller
  wr(0x3ce, 6); wr(0x3cf, 0x0e);
  wr(0x3c4, 1); wr(0x3c5, 0x00);
  wr(0x3d4, 9); wr(0x3d5, 0x4f);
  wr(0x3d4, 0x12); wr(0x3d5, 0x8f);
  wr(0x3d4, 7); wr(0x3d5, 0x1f);
  wr(0x3d4, 1); wr(0x3d5, 79);
  check('returning to alphanumeric mode is recognised',
        v.mode.text === true, v.describe());
}

// ---------------------------------------------------------------------------
//  planar VGA (mode 12h)
// ---------------------------------------------------------------------------
{
  const code = assemble('t_planar', 0x7c00);
  const img = new Uint8Array(1440 * 1024);
  img.set(code.subarray(0, 512), 0);

  const emu7 = new Emulator({ ramSize: 32 * 1024 * 1024, sliceSize: 200_000 });
  await emu7.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const dbg = [];
  emu7.io.debugOut = (b) => dbg.push(b);
  emu7.onSerial = () => {};
  emu7.bootImage({ data: img, name: 'planar.img', kind: 'floppy' });
  for (let i = 0; i < 400 && !emu7.machine.halted; i++) emu7.step();

  check('planar guest reported success', dbg.at(-1) === 0, JSON.stringify(dbg));
  check('mode 12h is planar 640x480',
        emu7.vga.describe() === '640x480x4 planar', emu7.vga.describe());

  const v = emu7.vga;
  check('a single-plane write lands only in that plane',
        v.planes[0][0] === 0xff && v.planes[1][0] === 0x00 &&
        v.planes[2][0] === 0x00 && v.planes[3][0] === 0x00,
        [v.planes[0][0], v.planes[1][0], v.planes[2][0], v.planes[3][0]].join(','));
  check('the map mask selects several planes',
        v.planes[0][80] === 0xff && v.planes[1][80] === 0xff &&
        v.planes[2][80] === 0x00,
        [v.planes[0][80], v.planes[1][80], v.planes[2][80]].join(','));
  check('the bit mask limits which bits change',
        v.planes[2][160] === 0x80, '0x' + v.planes[2][160].toString(16));

  // and the renderer turns those planes into the right colours
  const rgba = new Uint8ClampedArray(640 * 480 * 4);
  v.renderPlanar(rgba);
  const pixel = (x, y) => {
    const o = (y * 640 + x) * 4;
    return [rgba[o], rgba[o + 1], rgba[o + 2]];
  };
  const dacOf = (idx) => {
    const d = (v.attr[idx] & 0x3f) * 3;
    return [v.palette[d] << 2, v.palette[d + 1] << 2, v.palette[d + 2] << 2];
  };
  check('row 0 renders as colour 1',
        pixel(0, 0).join(',') === dacOf(1).join(','),
        `${pixel(0, 0)} vs ${dacOf(1)}`);
  check('row 1 renders as colour 3',
        pixel(0, 1).join(',') === dacOf(3).join(','),
        `${pixel(0, 1)} vs ${dacOf(3)}`);
  check('row 2 has only its first pixel set',
        pixel(0, 2).join(',') !== pixel(1, 2).join(','),
        `${pixel(0, 2)} vs ${pixel(1, 2)}`);
}

// ---------------------------------------------------------------------------
//  ATAPI: an optical drive reached through the packet protocol
// ---------------------------------------------------------------------------
{
  // A synthetic CD: enough of an ISO 9660 signature to be detected as one,
  // with a recognisable pattern in the data area.
  const SECTORS = 64;
  const iso = new Uint8Array(SECTORS * 2048);
  iso.set([0x01, 0x43, 0x44, 0x30, 0x30, 0x31], 16 * 2048);   // "\x01CD001"
  for (let i = 0; i < 2048; i++) iso[40 * 2048 + i] = (i * 5 + 11) & 0xff;

  const emu5 = new Emulator({ ramSize: 32 * 1024 * 1024 });
  await emu5.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const stub = new Uint8Array(512);
  stub[510] = 0x55; stub[511] = 0xaa;
  emu5.bootImage({ data: stub, name: 'stub.img', kind: 'floppy' },
                 { extra: [{ data: iso, name: 'test.iso', kind: 'auto' }] });

  const io = emu5.io;
  const rd = (p, sz = 1) => io.read(p, sz);
  const wr = (p, v, sz = 1) => io.write(p, sz, v);

  // optical drives land on the secondary channel
  wr(0x176, 0xa0);                                   // select master
  check('CD-ROM is on the secondary channel',
        emu5.ata.secondary.drives[0]?.kind === 'cdrom',
        JSON.stringify(emu5.ata.secondary.drives[0]?.kind));

  // IDENTIFY DEVICE must abort and leave the ATAPI signature behind
  wr(0x177, 0xec);
  const sig = [rd(0x172), rd(0x173), rd(0x174), rd(0x175)];
  check('IDENTIFY aborts on a packet device', (rd(0x177) & 0x01) !== 0);
  check('the ATAPI signature is presented',
        sig[0] === 1 && sig[1] === 1 && sig[2] === 0x14 && sig[3] === 0xeb,
        JSON.stringify(sig));

  // IDENTIFY PACKET DEVICE
  wr(0x177, 0xa1);
  const ident = new Uint8Array(512);
  for (let i = 0; i < 256; i++) {
    const w = rd(0x170, 2);
    ident[i * 2] = w & 0xff; ident[i * 2 + 1] = (w >> 8) & 0xff;
  }
  const w0 = ident[0] | (ident[1] << 8);
  check('IDENTIFY PACKET reports an ATAPI CD-ROM', (w0 & 0xc000) === 0x8000,
        '0x' + w0.toString(16));

  // helper: issue a 12-byte packet and read the response back
  const packet = (bytes, limit = 2048) => {
    wr(0x174, limit & 0xff);
    wr(0x175, (limit >> 8) & 0xff);
    wr(0x177, 0xa0);                                 // PACKET
    const pkt = new Uint8Array(12);
    pkt.set(bytes);
    for (let i = 0; i < 12; i += 2) wr(0x170, pkt[i] | (pkt[i + 1] << 8), 2);
    const out = [];
    let guard = 0;
    while ((rd(0x177) & 0x08) && guard++ < 8192) {    // while DRQ
      const n = rd(0x174) | (rd(0x175) << 8);
      for (let i = 0; i < n; i += 2) {
        const v = rd(0x170, 2);
        out.push(v & 0xff, (v >> 8) & 0xff);
      }
    }
    return new Uint8Array(out);
  };

  const inq = packet([0x12, 0, 0, 0, 36]);
  const vendor = String.fromCharCode(...inq.subarray(8, 14));
  check('INQUIRY identifies the drive', inq[0] === 0x05 && vendor.trim() === 'x64emu',
        `type ${inq[0]} vendor ${JSON.stringify(vendor)}`);

  const cap = packet([0x25, 0, 0, 0, 0, 0, 0, 0]);
  const lastLba = (cap[0] << 24) | (cap[1] << 16) | (cap[2] << 8) | cap[3];
  const blockSize = (cap[4] << 24) | (cap[5] << 16) | (cap[6] << 8) | cap[7];
  check('READ CAPACITY reports the disc geometry',
        lastLba === SECTORS - 1 && blockSize === 2048,
        `last ${lastLba}, block ${blockSize}`);

  const sector = packet([0x28, 0, 0, 0, 0, 40, 0, 0, 1]);
  let dataOk = sector.length >= 2048;
  if (dataOk) {
    for (let i = 0; i < 2048; i++) {
      if (sector[i] !== ((i * 5 + 11) & 0xff)) { dataOk = false; break; }
    }
  }
  check('READ(10) returns the sector contents', dataOk, `${sector.length} bytes`);

  // a transfer larger than the byte count limit has to arrive in blocks
  const twoSectors = packet([0x28, 0, 0, 0, 0, 40, 0, 0, 2], 512);
  check('a long transfer is split into blocks', twoSectors.length === 4096,
        `${twoSectors.length} bytes`);

  wr(0x177, 0xff);
  check('an unknown packet-device command aborts', (rd(0x177) & 0x01) !== 0);
}

// ---------------------------------------------------------------------------
//  an async image whose boot catalog lies beyond the first chunk
// ---------------------------------------------------------------------------
{
  const { ChunkStore, Disk } = await import('../src/js/disk.js');

  // 8 MiB disc with the catalog at 3.1 MiB and the boot image at 4.1 MiB, so
  // both land well outside whatever gets fetched up front.
  const CAT_LBA = 1600, IMG_LBA = 2100;
  const iso = new Uint8Array(8 * 1024 * 1024);
  iso.set([0x01, 0x43, 0x44, 0x30, 0x30, 0x31], 16 * 2048);        // PVD
  const brvd = 17 * 2048;
  iso[brvd] = 0x00;
  iso.set([...'CD001'].map((c) => c.charCodeAt(0)), brvd + 1);
  iso.set([...'EL TORITO SPECIFICATION'].map((c) => c.charCodeAt(0)), brvd + 7);
  new DataView(iso.buffer).setUint32(brvd + 0x47, CAT_LBA, true);
  const cat = CAT_LBA * 2048;
  iso[cat] = 0x01;                                                  // validation
  iso[cat + 32] = 0x88;                                             // bootable
  iso[cat + 33] = 0x00;                                             // no emulation
  new DataView(iso.buffer).setUint16(cat + 34, 0x07c0, true);       // load segment
  new DataView(iso.buffer).setUint16(cat + 38, 4, true);            // sector count
  new DataView(iso.buffer).setUint32(cat + 40, IMG_LBA, true);
  // a boot image that reports success and halts
  iso.set([0xb0, 0x00, 0xe6, 0xe9, 0xf4, 0xeb, 0xfd], IMG_LBA * 2048);

  let fetched = 0;
  const store = new ChunkStore(iso.length, (off, len) => {
    fetched++;
    return Promise.resolve(iso.subarray(off, off + len));
  }, { writable: true });

  const emu6 = new Emulator({ ramSize: 32 * 1024 * 1024, sliceSize: 100_000 });
  await emu6.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const dbg = [];
  emu6.io.debugOut = (b) => dbg.push(b);
  let log = '';
  emu6.onSerial = (b) => { log += String.fromCharCode(b); };

  await store.ensure(0, 64 * 1024);
  await store.ensure(16 * 2048, 4 * 2048);
  const disk = new Disk(store, 'auto', 'far-catalog.iso');
  check('a far catalog still detects as a CD', disk.kind === 'cdrom', disk.kind);

  emu6.bootImage(disk);
  for (let i = 0; i < 500 && !emu6.machine.halted; i++) {
    emu6.step();
    const io = emu6.pendingIo();
    if (io) await io;
  }

  check('El Torito is found past the first chunk',
        !log.includes('no El Torito'), JSON.stringify(log.slice(0, 70)));
  check('the boot image ran', dbg.at(-1) === 0, JSON.stringify(dbg));
  check('chunks were pulled in on demand', fetched > 3, `${fetched} fetches`);
}

// ---------------------------------------------------------------------------
//  asynchronous image source (the path a browser File takes)
// ---------------------------------------------------------------------------
{
  const iso = process.env.X64EMU_ISO;
  if (!iso || !existsSync(iso)) {
    console.log('SKIP  async image source (set X64EMU_ISO to a bootable ISO)');
  } else {
    const { ChunkStore, Disk } = await import('../src/js/disk.js');
    const { openSync, fstatSync, readSync } = await import('node:fs');

    // Same bytes, but every chunk arrives as a promise, so the BIOS has to use
    // its retry path and the host has to await the fetch.
    const fd = openSync(iso, 'r');
    const size = Number(fstatSync(fd).size);
    let fetches = 0;
    const store = new ChunkStore(size, (off, len) => {
      fetches++;
      return Promise.resolve().then(() => {
        const buf = Buffer.allocUnsafe(len);
        readSync(fd, buf, 0, len, off);
        return new Uint8Array(buf.buffer, buf.byteOffset, len);
      });
    }, { writable: true });

    const emu4 = new Emulator({ ramSize: 128 * 1024 * 1024, sliceSize: 200_000 });
    await emu4.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    let text = '';
    emu4.onSerial = (b) => { text += String.fromCharCode(b); };

    // prime enough for the image kind to be sniffed, as the UI does
    await store.whenReady();
    store.readSync(16 * 2048, 8);
    await store.whenReady();

    emu4.bootImage(new Disk(store, 'auto', 'async.iso'));
    for (let i = 0; i < 3000; i++) {
      if (!emu4.step()) break;
      const io = emu4.pendingIo();
      if (io) await io;
    }

    check('async image source boots', text.includes('ISOLINUX') || text.includes('bios'),
          JSON.stringify(text.slice(0, 80)));
    check('the retry path was actually exercised', fetches > 1, `${fetches} fetches`);
    check('readahead reduced round trips',
          store.cache.size >= fetches - 1, `${store.cache.size} cached, ${fetches} fetched`);
  }
}

// ---- INT 13h service coverage ----------------------------------------------
// Every INT 13h subfunction must return through the normal path.  A handler
// that throws leaves the caller inspecting a stale status byte, and bootmgr
// answers that by retrying the call forever rather than failing.
{
  const { Disk, MemoryStore } = await import('../src/js/disk.js');
  const emu5 = new Emulator({ ramSize: 16 * 1024 * 1024, sliceSize: 1000 });
  await emu5.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const logged = [];
  emu5.bios.log = (m) => logged.push(m);
  emu5.bootImage(new Disk(new MemoryStore(new Uint8Array(4 * 1024 * 1024)),
                          'hdd', 'test.img'));

  const RAX = 0, RDX = 2;
  const x = emu5.machine.exports;
  for (const ah of [0x00, 0x01, 0x04, 0x08, 0x15, 0x41]) {
    logged.length = 0;
    x.set_reg(RAX, BigInt(ah << 8));
    x.set_reg(RDX, 0x80n);                       // first hard disk
    let threw = '';
    try { emu5.bios.int13(); } catch (e) { threw = e.message; }
    check(`int 13h ah=${ah.toString(16)} does not throw`, !threw && !logged.length,
          threw || logged.join('; '));
  }

  // ah=15h reports the size in 512-byte sectors across CX:DX
  x.set_reg(RAX, 0x1500n);
  x.set_reg(RDX, 0x80n);
  let sectors = -1;
  try {
    emu5.bios.int13();
    sectors = (Number(x.get_reg(1) & 0xffffn) << 16) | Number(x.get_reg(2) & 0xffffn);
  } catch { /* left at -1, reported by the check below */ }
  check('int 13h ah=15h reports the true sector count', sectors === 4 * 1024 * 1024 / 512,
        `got ${sectors}`);
}

// ---- ACPI tables -----------------------------------------------------------
// Parsed back exactly the way a guest does it: scan the ROM hole for the RSDP,
// verify every checksum, then walk to the FADT and the tables it points at.
// A table with a bad checksum is worse than no table at all -- the OS rejects
// the machine instead of falling back.
{
  const emu6 = new Emulator({ ramSize: 16 * 1024 * 1024, sliceSize: 1000 });
  await emu6.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  emu6.bios.install(emu6.memoryMap());
  const m = emu6.machine;
  const csum = (at, len) => {
    let t = 0;
    for (let i = 0; i < len; i++) t = (t + m.rd8(at + i)) & 0xff;
    return t;
  };
  const sig = (at) => String.fromCharCode(m.rd8(at), m.rd8(at+1), m.rd8(at+2), m.rd8(at+3));

  let rsdp = -1;
  for (let a = 0xe0000; a < 0x100000; a += 16) {
    if (sig(a) === 'RSD ' && sig(a + 4) === 'PTR ') { rsdp = a; break; }
  }
  check('RSDP found in the 0xE0000-0xFFFFF scan range', rsdp >= 0, `at ${rsdp}`);

  if (rsdp >= 0) {
    check('RSDP is 16-byte aligned', (rsdp & 15) === 0, `at 0x${rsdp.toString(16)}`);
    check('RSDP v1 checksum', csum(rsdp, 20) === 0, `sum ${csum(rsdp, 20)}`);
    check('RSDP v2 checksum', csum(rsdp, 36) === 0, `sum ${csum(rsdp, 36)}`);

    const xsdt = Number(m.rd64(rsdp + 24));
    check('XSDT signature', sig(xsdt) === 'XSDT', sig(xsdt));
    check('XSDT checksum', csum(xsdt, m.rd32(xsdt + 4)) === 0);

    // walk the XSDT and check every table it points at
    const n = (m.rd32(xsdt + 4) - 36) / 8;
    const seen = [];
    for (let i = 0; i < n; i++) {
      const t = Number(m.rd64(xsdt + 36 + i * 8));
      seen.push(sig(t));
      check(`${sig(t)} checksum`, csum(t, m.rd32(t + 4)) === 0);
    }
    check('XSDT lists the FADT', seen.includes('FACP'), seen.join(','));
    // Windows XP's APIC HAL takes its interrupt controllers from the MADT.
    const madtAt = seen.indexOf('APIC');
    check('XSDT lists a MADT', madtAt >= 0, seen.join(','));
    if (madtAt >= 0) {
      const t = Number(m.rd64(xsdt + 36 + madtAt * 8));
      const entries = [];
      for (let p = t + 44; p < t + m.rd32(t + 4); p += m.rd8(p + 1)) entries.push(p);
      const ioapic = entries.find((p) => m.rd8(p) === 1);
      const irq0 = entries.find((p) => m.rd8(p) === 2 && m.rd8(p + 3) === 0);
      check('the MADT names the local APIC and the I/O APIC',
            m.rd32(t + 36) === 0xfee00000 && entries.some((p) => m.rd8(p) === 0) &&
            ioapic !== undefined && m.rd32(ioapic + 4) === 0xfec00000);
      check('the MADT routes ISA IRQ 0 to I/O APIC pin 2',
            irq0 !== undefined && m.rd32(irq0 + 4) === 2);
    }

    const fadt = Number(m.rd64(xsdt + 36));
    const dsdt = m.rd32(fadt + 40);
    check('FADT points at a DSDT', sig(dsdt) === 'DSDT', sig(dsdt));
    check('DSDT checksum', csum(dsdt, m.rd32(dsdt + 4)) === 0);
    check('FADT points at a FACS', sig(m.rd32(fadt + 36)) === 'FACS');

  }

  check('BIOS reports a math coprocessor', (emu6.bios.equipment & 2) !== 0,
        `equipment 0x${emu6.bios.equipment.toString(16)}`);
  check('CMOS equipment byte agrees', (emu6.io.cmos.ram[0x14] & 2) !== 0);

  // the PM timer must actually advance, or an OS calibration loop never ends
  const t1 = emu6.io.acpi.timer;
  emu6.virtualNs += 5_000_000;
  const t2 = emu6.io.acpi.timer;
  check('ACPI PM timer advances with the clock', t2 !== t1, `${t1} -> ${t2}`);
  check('PM1a_CNT reports SCI_EN', (emu6.io.read(0x604, 2) & 1) === 1);
}

// ---- El Torito floppy emulation --------------------------------------------
// Only the first sector of the boot image is loaded to 0x7C00; the boot code
// reads the rest itself through INT 13h.  Without a drive behind those reads,
// DOS gets as far as printing "Disk I/O error" and no further.
{
  const { Disk, MemoryStore } = await import('../src/js/disk.js');
  const emu7 = new Emulator({ ramSize: 16 * 1024 * 1024, sliceSize: 1000 });
  await emu7.init(readFileSync(join(root, 'build', 'cpu.wasm')));

  const IMAGE_LBA = 100;
  const iso = new Uint8Array(4 * 1024 * 1024);
  // a marker at the start of the boot image, and one a megabyte further in
  iso.set([0xeb, 0x3c, 0x90, 0x55, 0xaa], IMAGE_LBA * 2048);
  iso[IMAGE_LBA * 2048 + 1024 * 1024] = 0x5a;

  const cd = new Disk(new MemoryStore(iso), 'cdrom', 'test.iso');
  emu7.bios.disks = [cd];
  cd.driveNumber = 0xe0;

  const drive = emu7.bios.installEmulatedDrive(cd, { mediaType: 2, imageLba: IMAGE_LBA });
  check('El Torito floppy emulation claims drive 0x00', drive === 0x00, `got ${drive}`);

  const em = emu7.bios.findDisk(0x00);
  check('the emulated drive is reachable through INT 13h', !!em);
  check('emulated drive is 1.44 MB', em && em.store.size === 1440 * 1024,
        `${em?.store.size} bytes`);
  const g = em?.geometry;
  check('emulated drive has 1.44 MB geometry',
        g && g.c === 80 && g.h === 2 && g.s === 18, JSON.stringify(g));

  // sector 0 of the emulated drive is the start of the boot image, not the ISO
  const s0 = em?.read(0, 1);
  check('sector 0 maps to the boot image, not the start of the ISO',
        s0 && s0[0] === 0xeb && s0[3] === 0x55 && s0[4] === 0xaa,
        s0 ? [...s0.subarray(0, 5)].join(',') : 'null');

  // and reads well past the first sector still land in the right place
  const deep = em?.read(2048, 1);
  check('a read a megabyte in resolves correctly', deep && deep[0] === 0x5a,
        deep ? `${deep[0]}` : 'null');

  // the emulation must not run off the end of its window
  check('reads past the emulated media report an error',
        em && em.read(1440 * 2, 1) === undefined);
}

// ---- guest-triggered reboot ------------------------------------------------
// An installer writes itself to disk and then reboots to continue.  That only
// works if the CPU goes back to its power-on state and the drive it just wrote
// survives, so both are checked here.
{
  const { Disk, MemoryStore } = await import('../src/js/disk.js');
  const emu8 = new Emulator({ ramSize: 32 * 1024 * 1024, sliceSize: 1000 });
  await emu8.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  emu8.onSerial = () => {};

  const boot = new Uint8Array(512);
  boot[510] = 0x55; boot[511] = 0xaa;
  emu8.bootImage({ data: boot, name: 'stub.img', kind: 'floppy' },
                 { hddSize: 16 * 1024 * 1024, hddName: 'ram0' });

  // leave a mark on the drive, the way an installer would
  emu8.ramDisk.write(1234, new Uint8Array(512).fill(0xC3));
  const driveBefore = emu8.ramDisk;

  // drag the CPU into protected mode with paging on, as an OS would leave it
  const x = emu8.machine.exports;
  x.set_cr(0, 0x80000011n);
  const modeBefore = x.get_mode();
  // the check below is meaningless unless this actually took effect
  check('the test really did leave the CPU in protected mode',
        modeBefore !== 0 && (Number(x.get_cr(0)) & 0x80000000) !== 0,
        `mode=${modeBefore} cr0=0x${Number(x.get_cr(0)).toString(16)}`);

  // leave the interrupt controller mid-service, as a reset during an IRQ does
  emu8.io.pic.master.isr = 0x01;            // timer in service, never acknowledged
  emu8.io.pic.master.imr = 0xfe;
  emu8.io.pic.slave.isr = 0x40;

  // POST rebuilds the interrupt vector table, and a reboot has to run it
  // again.  The previous system hooks INT 13h, INT 16h and the rest to handlers
  // inside itself; those hooks outlive a reboot, and leaving them in place
  // sends the next boot sector into a kernel that is no longer there.
  {
    const e = new Emulator({ ramSize: 32 * 1024 * 1024 });
    await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    e.bios.log = () => {};
    const stub = new Uint8Array(512); stub[510] = 0x55; stub[511] = 0xaa;
    e.bootImage({ data: stub, name: 's.img', kind: 'floppy' });
    const vec = (v) => e.machine.rd16(v * 4) | (e.machine.rd16(v * 4 + 2) << 16);
    const bios13 = vec(0x13), bios16 = vec(0x16);
    check('POST points the interrupt vectors at the BIOS',
          (bios13 >>> 16) === 0xf000 && (bios16 >>> 16) === 0xf000,
          `13h=${(bios13 >>> 16).toString(16)} 16h=${(bios16 >>> 16).toString(16)}`);

    // A guest hooks them for itself, then reboots through the reset vector.
    e.machine.wr16(0x13 * 4, 0x0500); e.machine.wr16(0x13 * 4 + 2, 0x0070);
    e.machine.wr16(0x16 * 4, 0x042d); e.machine.wr16(0x16 * 4 + 2, 0x0070);
    e.bios.bootResetDone = false;
    e.bios.dispatch(0x100);
    check('a reboot takes the vectors back off the previous system',
          vec(0x13) === bios13 && vec(0x16) === bios16,
          `13h=${(vec(0x13) >>> 16).toString(16)}:${(vec(0x13) & 0xffff).toString(16)}`);
  }

  // A controller reset is not an unplug.  A guest that reboots through the
  // reset vector must come back to an IDE bus with its drives still on it, or
  // its CD-ROM driver probes the ports, finds nothing and gives up -- which is
  // what left Windows 95 Setup at a DOS prompt saying "No drives found".
  {
    const { Disk: D3, MemoryStore: MS3 } = await import('../src/js/disk.js');
    const e = new Emulator({ ramSize: 32 * 1024 * 1024 });
    await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    e.bios.log = () => {};
    const iso3 = new Uint8Array(64 * 1024);
    e.bootImage(new D3(new MS3(iso3), 'cdrom', 'cd.iso'), { hddSize: 1024 * 1024 });
    const onBus = () => [e.ata.primary, e.ata.secondary]
      .flatMap((c) => c.drives).filter(Boolean).length;
    const before = onBus();
    check('booting puts the drives on the IDE bus', before > 0, `${before} attached`);

    e.ata.primary.status = 0x88;          // a transfer left half finished
    e.resetPeripherals();
    check('a reset leaves the drives on the bus', onBus() === before,
          `${before} -> ${onBus()}`);
    check('a reset does clear the controller registers',
          e.ata.primary.status !== 0x88, `status=0x${e.ata.primary.status.toString(16)}`);
  }

  // A reset masks every interrupt line, which is what the hardware does; POST
  // unmasks them again.  A reboot that resets the controller without re-running
  // POST leaves the timer permanently masked, and anything waiting on the tick
  // counter -- the boot-menu window of every DOS-era system -- waits for good.
  {
    const e = new Emulator({ ramSize: 32 * 1024 * 1024 });
    await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    e.bios.log = () => {};
    const stub = new Uint8Array(512); stub[510] = 0x55; stub[511] = 0xaa;
    e.bootImage({ data: stub, name: 's.img', kind: 'floppy' });
    check('the timer is deliverable after a normal boot',
          (e.io.pic.master.imr & 1) === 0, `imr=0x${e.io.pic.master.imr.toString(16)}`);

    // The reset-vector route: peripherals reset without bootImage running.
    e.resetPeripherals();
    check('the timer is still deliverable after a reset-vector reboot',
          (e.io.pic.master.imr & 1) === 0, `imr=0x${e.io.pic.master.imr.toString(16)}`);
    e.io.pic.raise(0);
    check('and a raised timer actually reaches the CPU',
          e.io.pic.hasPending(), 'IRQ0 blocked');
  }

  // DOS and Windows 95 reboot by jumping to the reset vector rather than
  // through the keyboard controller, so the boot vector is reached a second
  // time with the previous boot's drives still attached.
  {
    const { Disk: D2, MemoryStore: MS2 } = await import('../src/js/disk.js');
    const e = new Emulator({ ramSize: 16 * 1024 * 1024, sliceSize: 1000 });
    await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    e.bios.log = () => {};
    const iso2 = new Uint8Array(4 * 1024 * 1024);
    iso2.set([0xeb, 0x3c, 0x90, 0x55, 0xaa], 100 * 2048);
    const cd2 = new D2(new MS2(iso2), 'cdrom', 'test.iso');
    e.bios.disks = [cd2];
    cd2.driveNumber = 0xe0;
    const hd = D2.ramDisk(1024 * 1024, 'hd');
    e.bios.attach(hd);

    e.bios.installEmulatedDrive(cd2, { mediaType: 2, imageLba: 100 });
    const one = e.bios.disks.filter((d) => d.elTorito).length;
    check('booting a CD attaches one emulated drive', one === 1,
          `${one} of ${e.bios.disks.length}`);
    const hdDrive = hd.driveNumber;

    // A reboot runs the same installation again.
    e.bios.installEmulatedDrive(cd2, { mediaType: 2, imageLba: 100 });
    const again = e.bios.disks.filter((d) => d.elTorito).length;
    check('a reboot replaces the emulated drive instead of adding another',
          again === 1, `${again} of ${e.bios.disks.length}`);
    check('the real drives keep their numbers across a reboot',
          hd.driveNumber === hdDrive,
          `hd 0x${hdDrive.toString(16)} -> 0x${hd.driveNumber.toString(16)}`);
    check('exactly one drive answers as 0x00 after a reboot',
          e.bios.disks.filter((d) => d.driveNumber === 0).length === 1,
          e.bios.disks.map((d) => `${d.kind}:0x${d.driveNumber.toString(16)}`).join(' '));
  }

  // Vectors 0x10-0x1F belong to both the CPU and the BIOS: INT 14h and
  // exception 20 are the same number.  A service this BIOS does not provide
  // must answer as a service, not be mistaken for a fault.
  {
    const e = new Emulator({ ramSize: 32 * 1024 * 1024 });
    await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    const said = [];
    e.bios.log = (m) => said.push(m);
    const stub = new Uint8Array(512); stub[510] = 0x55; stub[511] = 0xaa;
    e.bootImage({ data: stub, name: 's.img', kind: 'floppy' });

    e.bios.setR16(0, 0x0000);            // AH=00, initialise serial port
    e.bios.dispatch(0x14);
    check('INT 14h reports no serial port rather than looking like a fault',
          (e.bios.r8hi(0) & 0x80) !== 0 && !said.some((m) => m.includes('exception')),
          `ah=0x${e.bios.r8hi(0).toString(16)} log=${said.join('|')}`);

    said.length = 0;
    e.bios.setR16(0, 0x0200);            // AH=02, printer status
    e.bios.dispatch(0x17);
    check('INT 17h reports no printer rather than looking like a fault',
          (e.bios.r8hi(0) & 0x01) !== 0 && !said.some((m) => m.includes('exception')),
          `ah=0x${e.bios.r8hi(0).toString(16)} log=${said.join('|')}`);

    // A vector the CPU alone owns is still worth reporting.
    said.length = 0;
    e.bios.dispatch(0x06);               // #UD
    check('a genuine CPU exception vector is still reported',
          said.some((m) => m.includes('exception 0x06')), said.join('|'));
  }

  // A triple fault resets a real machine, and a small operating system often
  // reboots by causing one on purpose.
  {
    const e = new Emulator({ ramSize: 32 * 1024 * 1024 });
    await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    const said = [];
    e.onExit = (why) => said.push(why);
    check('a triple fault with nothing booted stops',
          e.onTripleFault(0) === false, said.join());
    const stub = new Uint8Array(512); stub[510] = 0x55; stub[511] = 0xaa;
    e.bootImage({ data: stub, name: 's.img', kind: 'floppy' });
    e.tripleFaults = 1;
    check('a triple fault reboots rather than freezing',
          e.onTripleFault(100000) === true, said.join());
    // A guest that faults straight back would reboot forever.
    e.tripleFaults = 2;
    check('a second triple fault in quick succession stops instead',
          e.onTripleFault(100500) === false, said.join());
    e.tripleFaults = 3;
    check('and once it has settled down a reboot is allowed again',
          e.onTripleFault(200000) === true, said.join());
    e.tripleFaults = 99;
    check('a guest that keeps faulting is eventually left alone',
          e.onTripleFault(400000) === false, said.join());
  }

  // Leave the display where a graphical guest would: a linear-framebuffer mode
  // with pixels in the planes and a palette of its own.
  emu8.vga.setVbeMode(0x118);
  emu8.vga.planes[0][0] = 0xff;
  emu8.vga.planes[2][4095] = 0xaa;
  emu8.vga.palette[3] = 0x2a;
  const videoBefore = emu8.vga.describe();

  emu8.ps2.onReset();                       // what OUT 0x64,0xFE ends up calling

  // A display left in the previous system's mode goes on showing that system's
  // last frame while the new one boots underneath it, and if that mode was a
  // linear framebuffer then nothing written to the text buffer appears at all.
  check('a reboot returns the display to text mode',
        emu8.vga.mode.text === true && emu8.vga.describe() !== videoBefore,
        `${videoBefore} -> ${emu8.vga.describe()}`);
  check('a reboot turns the linear framebuffer back off',
        emu8.vga.lfbEnabled === false, `lfbEnabled=${emu8.vga.lfbEnabled}`);
  check('a reboot clears what the previous system drew',
        emu8.vga.planes.every((p) => p.every((b) => b === 0)), 'stale pixels remain');
  check('a reboot restores the default palette',
        emu8.vga.palette[3] !== 0x2a, `palette[3]=${emu8.vga.palette[3]}`);

  check('a reboot clears the interrupt controller',
        emu8.io.pic.master.isr === 0 && emu8.io.pic.slave.isr === 0,
        `master isr=0x${emu8.io.pic.master.isr.toString(16)} ` +
        `slave isr=0x${emu8.io.pic.slave.isr.toString(16)}`);
  // the masks are whatever the BIOS programs afterwards, so what matters is
  // only that the timer is not left masked out
  check('the timer is not masked after a reboot',
        (emu8.io.pic.master.imr & 1) === 0,
        `imr=0x${emu8.io.pic.master.imr.toString(16)}`);
  // with a stuck in-service bit the timer can never be delivered again
  emu8.io.pic.raise(0);
  check('the timer can still be delivered after a reboot',
        emu8.io.pic.hasPending(), 'IRQ0 blocked');

  check('a reboot returns the CPU to real mode',
        x.get_mode() === 0, `mode ${modeBefore} -> ${x.get_mode()}`);
  check('a reboot clears paging', (Number(x.get_cr(0)) & 0x80000000) === 0,
        `cr0 0x${Number(x.get_cr(0)).toString(16)}`);
  check('the hard drive survives a reboot', emu8.ramDisk === driveBefore);
  const back = emu8.ramDisk.read(1234, 1);
  check('what the guest wrote before rebooting is still there',
        back && back[0] === 0xc3, back ? `${back[0]}` : 'null');

  // and it can actually execute again rather than wedging
  const before = Number(x.get_cycles());
  for (let i = 0; i < 50; i++) emu8.step();
  check('the machine runs after a reboot', Number(x.get_cycles()) > before,
        `${Number(x.get_cycles()) - before} instructions`);
}

// ---------------------------------------------------------------------------
//  DOS loaded high: the HMA, the A20 gate, and the Windows 95 boot menu
// ---------------------------------------------------------------------------
{
  const { ChunkStore } = await import('../src/js/disk.js');
  const { DS, SEG_DATA16 } = await import('../src/js/machine.js');

  // An empty read at offset zero made the chunk range end at -1 >>> 20, ie.
  // chunk 4095: every chunk of the image was fetched, more than the cache
  // holds, so in a browser the read never completed and the tab hung.
  const fetched = [];
  const store = new ChunkStore(8 * 1024 * 1024, (off, len) => {
    fetched.push(len);
    return new Uint8Array(len);
  });
  const empty = store.readSync(0, 0);
  check('an empty read at offset zero fetches nothing',
        empty?.length === 0 && fetched.length === 0, `${fetched.length} fetches`);

  const e = new Emulator({ ramSize: 32 * 1024 * 1024 });
  await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  e.bios.log = () => {};
  e.onSerial = () => {};
  const img = new Uint8Array(1024 * 1024);
  img[510] = 0x55; img[511] = 0xaa;
  img.fill(0xa5, 5 * 512, 6 * 512);
  e.bootImage({ data: img, name: 'hma.img', kind: 'hdd' }, { hddSize: 0 });
  const m = e.machine, b = e.bios;

  // DOS=HIGH hands INT 13h a packet at FFFF:xxxx, which with A20 on is above
  // 1 MiB.  Wrapping it read the packet as zeros out of the interrupt table.
  m.setSeg(DS, 0xffff, 0xffff0, 0xffff, SEG_DATA16);
  const dap = 0xffff0 + 0x1788;
  m.writeBytes(dap, new Uint8Array([0x10, 0, 1, 0, 0x00, 0x20, 0xff, 0xff,
                                    5, 0, 0, 0, 0, 0, 0, 0]));
  m.wr8(0x1ff0, 0x11);
  b.setR16(0, 0x4200); b.setR16(2, 0x0080); b.setR16(6, 0x1788);
  b.dispatch(0x13);
  check('INT 13h reads a packet that DOS keeps in the HMA',
        b.r8hi(0) === 0 && m.rd8(0xffff0 + 0x2000) === 0xa5,
        `ah=0x${b.r8hi(0).toString(16)} byte=0x${m.rd8(0xffff0 + 0x2000).toString(16)}`);
  check('and the sectors do not land at the wrapped address', m.rd8(0x1ff0) === 0x11);

  // The gate has to really gate: HIMEM disables A20 and waits to see memory
  // wrap, and burned a 64K-iteration timeout every time it did not.
  e.io.write(0x92, 1, 0x00);
  check('port 0x92 turns A20 off',
        (e.io.read(0x92, 1) & 2) === 0 && m.translate(0x100010) === 0x10n,
        `port=0x${e.io.read(0x92, 1).toString(16)} pa=${m.translate(0x100010)}`);
  check('the BIOS wraps at 1 MiB while A20 is off',
        b.mem.resolve(b.linear(DS, 0x10), false) === 0);
  e.io.write(0x92, 1, 0x02);
  check('port 0x92 turns A20 back on',
        (e.io.read(0x92, 1) & 2) !== 0 && m.translate(0x100010) === 0x100010n);

  const kbc = (cmd, data) => {
    e.io.write(0x64, 1, cmd);
    if (data !== undefined) e.io.write(0x60, 1, data);
  };
  kbc(0xd1, 0xdd);                                // output port: A20 off
  kbc(0xd0);
  check('the keyboard controller output port turns A20 off',
        !e.io.a20 && (e.io.read(0x60, 1) & 2) === 0);
  kbc(0xd1, 0xdf);
  check('and back on', e.io.a20 && m.translate(0x100010) === 0x100010n);

  b.setR16(0, 0x2400); b.dispatch(0x15);
  b.setR16(0, 0x2402); b.dispatch(0x15);
  const off = b.r8lo(0);
  b.setR16(0, 0x2401); b.dispatch(0x15);
  check('INT 15h AX=2400/2401/2402 switch and report the gate',
        off === 0 && e.io.a20, `query=${off} now=${e.io.a20}`);

  // The timer interrupt is handled by ROM code that acknowledges the PIC with
  // an OUT, so that a monitor virtualising the PIC sees the EOI.  A host-side
  // EOI bypassed Windows 95's VPICD and left its DOS session stuck inside IRQ 0.
  {
    const t = new Emulator({ ramSize: 16 * 1024 * 1024, sliceSize: 100_000 });
    await t.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    t.bios.log = () => {};
    t.onSerial = () => {};
    const boot = new Uint8Array(1440 * 1024);
    boot.set([0xfb, 0xf4, 0xeb, 0xfc], 0);          // 1: sti; hlt; jmp 1b
    boot[510] = 0x55; boot[511] = 0xaa;
    t.bootImage({ data: boot, name: 'tick.img', kind: 'floppy' }, { hddSize: 0 });
    const eois = [];
    const write = t.io.write.bind(t.io);
    t.io.write = (port, size, val) => {
      if (port === 0x20 && val === 0x20) eois.push(Number(t.machine.rip) & 0xffff);
      return write(port, size, val);
    };
    for (let i = 0; i < 100; i++) t.step();
    const ticks = t.machine.rd32(0x46c);
    check('the timer tick counter advances', ticks > 2, `${ticks} ticks`);
    check('and each tick is acknowledged by a guest OUT from the ROM handler',
          eois.length >= ticks && eois.every((ip) => ip > 0x500 && ip < 0x600) &&
          !t.bios.callCounts.has(0x08),
          `${eois.length} EOIs, host INT 8 calls ${t.bios.callCounts.get(0x08) ?? 0}`);
    check('nothing is left in service', t.io.pic.master.isr === 0,
          `isr=0x${t.io.pic.master.isr.toString(16)}`);
  }

  // The 16550's transmitter interrupt, the way Linux drives it: enable it and
  // wait.  With the transmitter empty that must interrupt at once, reading IIR
  // must clear it, and the next byte written must bring it back.  A UART that
  // only interrupted after a write never started a tty write, and the shell
  // prompt never appeared.
  {
    const io = e.io, uart = io.serial, irq4 = () => (io.pic.master.irr & 0x10) !== 0;
    io.write(0x3f9, 1, 0x00);
    io.pic.master.irr = 0;
    io.write(0x3f9, 1, 0x02);                     // IER: transmitter empty
    check('enabling the transmitter interrupt raises it at once', irq4());
    const iir = io.read(0x3fa, 1);
    check('IIR reports it, and reading IIR clears it',
          (iir & 0x0f) === 0x02 && !irq4() && (io.read(0x3fa, 1) & 1) === 1,
          `iir=0x${iir.toString(16)}`);
    uart.onByte = () => {};
    io.write(0x3f8, 1, 0x41);
    check('writing a byte raises it again', irq4() && (io.read(0x3fa, 1) & 0x0f) === 0x02);
    io.write(0x3f9, 1, 0x00);
    check('disabling it drops the line', !irq4());
    // a request raised by a port write reaches the CPU now, not next slice
    io.pic.master.imr = 0;
    e.machine.setIrqLine(false);
    io.write(0x3f9, 1, 0x02);
    check('a device interrupt raised mid-slice reaches the CPU',
          e.machine.stateU32[0xd8 / 4] === 1);
    io.write(0x3f9, 1, 0x00);
    io.pic.master.imr = 0xff;
  }

  // The PS/2 mouse through INT 15h AH=C2h and the ROM's INT 74h handler, the
  // path Windows 95's mouse driver takes.  Until the equipment word reported
  // a mouse and the BIOS answered C2h, Windows said no mouse was attached.
  {
    const code = assemble('t_mouse', 0x7c00);
    const boot = new Uint8Array(1440 * 1024);
    boot.set(code.subarray(0, 512), 0);
    boot[510] = 0x55; boot[511] = 0xaa;
    const t = new Emulator({ ramSize: 16 * 1024 * 1024, sliceSize: 50_000 });
    await t.init(readFileSync(join(root, 'build', 'cpu.wasm')));
    t.bios.log = () => {};
    t.onSerial = () => {};
    const out = [];
    t.io.debugOut = (b) => out.push(b);
    t.bootImage({ data: boot, name: 'mouse.img', kind: 'floppy' }, { hddSize: 0 });
    for (let i = 0; i < 200 && !out.length; i++) t.step();
    const ready = out[0] === 0xfe;
    if (ready) t.sendMouse(5, -3, 1);                 // right, up, left button
    for (let i = 0; i < 200 && out.length < 2; i++) t.step();
    check('a mouse packet reaches a handler installed through INT 15h C207h',
          ready && out[1] === 0, `debug port: ${JSON.stringify(out)}`);
  }

  // Setting a 480-line 16-colour mode loads the 64 EGA colours into the DAC,
  // as a VGA BIOS does.  Windows' driver then names colours by their EGA
  // numbers through the attribute palette; without them its desktop came out
  // green and its icons purple.
  {
    const v = e.vga;
    v.setBiosMode(0x12);
    const rgb = (k) => [0, 1, 2].map((c) => v.palette[k * 3 + c]).join(',');
    check('mode 12h loads the EGA colours into the DAC',
          rgb(0x03) === '0,42,42' && rgb(0x24) === '63,0,0' && rgb(0x3f) === '63,63,63' &&
          v.attr[6] === 0x14 && rgb(v.attr[6]) === '42,21,0',
          `03=${rgb(0x03)} 24=${rgb(0x24)} attr6=${v.attr[6]}`);
    // and Windows then sets its greys through INT 10h AX=1010h
    b.setR16(0, 0x1010); b.setR16(3, 0x000f); b.setR16(1, 0x3132); b.setR16(2, 0x3000);
    b.dispatch(0x10);
    b.setR16(0, 0x1015); b.setR16(3, 0x000f); b.setR16(1, 0); b.setR16(2, 0);
    b.dispatch(0x10);
    check('INT 10h AX=1010h sets a DAC register, and AX=1015h reads it back',
          rgb(0x0f) === '48,49,50' && b.r8hi(2) === 0x30 && b.r16(1) === 0x3132,
          `0f=${rgb(0x0f)} dh=${b.r8hi(2)} cx=${b.r16(1).toString(16)}`);
    v.setBiosMode(0x03);
  }

  // INT 10h AH=0Eh in a text mode keeps the cell's colour; BL is only a colour
  // in graphics modes.  Windows 95's boot menu prints its countdown with the
  // count in BL, which made every digit a different colour.
  b.setCursor(0, 0, 0);
  m.wr8(0xb8001, 0x07);
  b.setR16(0, 0x0e41); b.setR16(3, 0x001e);
  b.dispatch(0x10);
  check('teletype keeps the text attribute',
        m.rd8(0xb8000) === 0x41 && m.rd8(0xb8001) === 0x07,
        `attr 0x${m.rd8(0xb8001).toString(16)}`);
}

// ---------------------------------------------------------------------------
//  the local APIC, the I/O APIC and the RTC's interrupts
// ---------------------------------------------------------------------------
//  Windows XP's APIC HAL takes every device interrupt through the I/O APIC
//  and its clock from the RTC's periodic interrupt; Linux sends itself IPIs
//  and runs its clock from the APIC timer.  Driven here the way they drive it.
{
  const e = new Emulator({ ramSize: 16 * 1024 * 1024 });
  await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  e.bios.log = () => {};
  e.resetHardware();
  const lapic = (off) => Number(e.mmioRead(0xfee00000n + BigInt(off), 4));
  const setLapic = (off, v) => e.mmioWrite(0xfee00000n + BigInt(off), 4, BigInt(v));
  const ioapic = (reg, v) => {
    e.mmioWrite(0xfec00000n, 4, BigInt(reg));
    if (v !== undefined) e.mmioWrite(0xfec00010n, 4, BigInt(v));
    return Number(e.mmioRead(0xfec00010n, 4));
  };

  check('the local APIC answers at 0xFEE00000',
        lapic(0x30) === 0x00050014 && lapic(0x20) === 0,
        `version 0x${lapic(0x30).toString(16)}`);
  check('the 8259 reaches the CPU while the local APIC is software disabled',
        e.legacyOpen);

  setLapic(0xf0, 0x1ff);                          // software enable, spurious 0xFF
  setLapic(0x350, 0x700);                         // LINT0: ExtINT, unmasked
  check('LINT0 as ExtINT keeps the 8259 connected (virtual wire)', e.legacyOpen);

  // a self-IPI is delivered at once, and its busy bit never sticks
  setLapic(0x300, 0x40000 | 0x41);
  check('a self-IPI arrives, and the ICR reads back idle',
        e.interruptPending() && (lapic(0x300) & 0x1000) === 0);
  // ISR, TMR and IRR keep 32 vectors to a register, at 16-byte steps
  const bit = (base, v) => (lapic(base + 0x10 * (v >> 5)) >>> (v & 31)) & 1;
  check('the CPU takes it, and it is in service until EOI',
        e.acknowledgeInterrupt() === 0x41 && bit(0x100, 0x41) === 1);
  setLapic(0xb0, 0);
  check('EOI clears it', bit(0x100, 0x41) === 0 && !e.interruptPending());

  // the task priority holds back a vector of its class or lower
  setLapic(0x80, 0x50);
  setLapic(0x300, 0x40000 | 0x45);
  check('TPR 0x50 holds back vector 0x45', !e.interruptPending());
  setLapic(0x80, 0);
  check('and lowering it lets it through', e.acknowledgeInterrupt() === 0x45);
  setLapic(0xb0, 0);

  // an ISA line through the I/O APIC, with IRQ 0 on pin 2, once LINT0 is
  // masked as an OS masks it when it leaves virtual-wire mode
  setLapic(0x350, 0x10700);
  check('masking LINT0 disconnects the 8259', !e.legacyOpen);
  check('the I/O APIC reports 24 pins', ((ioapic(1) >> 16) & 0xff) === 23);
  ioapic(0x10 + 2 * 2, 0x31);                     // pin 2: vector 0x31, edge, unmasked
  e.io.pic.raise(0);
  check('ISA IRQ 0 arrives on I/O APIC pin 2', e.acknowledgeInterrupt() === 0x31);
  setLapic(0xb0, 0);
  ioapic(0x10 + 2 * 14, 0x10000 | 0x62);          // pin 14 masked
  e.io.pic.raise(14);
  check('a masked pin holds its edge', !e.interruptPending());
  ioapic(0x10 + 2 * 14, 0x62);
  check('and delivers it when unmasked', e.acknowledgeInterrupt() === 0x62);
  setLapic(0xb0, 0);
  e.io.pic.lower(14);

  // level triggered: one delivery until EOI, then again while the line is up
  ioapic(0x10 + 2 * 9, 0x8000 | 0x71);
  e.io.pic.raise(9);
  check('a level interrupt is delivered once', e.acknowledgeInterrupt() === 0x71 &&
        (ioapic(0x10 + 2 * 9) & 0x4000) !== 0);
  check('and not again before EOI', e.acknowledgeInterrupt() !== 0x71);
  setLapic(0xb0, 0);
  check('EOI with the line still up delivers it again', e.acknowledgeInterrupt() === 0x71);
  e.io.pic.lower(9);
  setLapic(0xb0, 0);

  // the timer: one-shot, counting the bus clock through the divider
  setLapic(0x3e0, 0xb);                           // divide by 1
  setLapic(0x320, 0x51);                          // one-shot, vector 0x51
  setLapic(0x380, 1_000_000);                     // 10 ms at 100 MHz
  const t0 = e.virtualNs;
  e.virtualNs = t0 + 4e6;
  check('the APIC timer counts down at the bus clock', lapic(0x390) === 600_000,
        `count ${lapic(0x390)} after 4 ms`);
  e.virtualNs = t0;
  // An idle processor sleeps to the deadline rather than a whole timer tick
  for (let i = 0; i < 40 && !bit(0x200, 0x51); i++) e.step();
  check('and fires its vector on time when it reaches zero',
        lapic(0x390) === 0 && bit(0x200, 0x51) === 1 && Math.abs(e.virtualNs - t0 - 10e6) < 1e5,
        `fired after ${(e.virtualNs - t0) / 1e6} ms`);

  // the RTC's periodic interrupt on IRQ 8, held until register C is read
  const cmos = (reg, v) => { e.io.write(0x70, 1, reg);
    if (v !== undefined) e.io.write(0x71, 1, v); return e.io.read(0x71, 1); };
  ioapic(0x10 + 2 * 8, 0xd1);
  cmos(0x0a, 0x2a);                               // 64 Hz
  cmos(0x0b, 0x42);                               // periodic interrupt on
  const r0 = e.virtualNs;
  while (e.virtualNs - r0 < 20e6) e.step();
  check('the RTC raises its periodic interrupt', e.acknowledgeInterrupt() === 0xd1);
  setLapic(0xb0, 0);
  check('register C reports it, and reading clears it',
        (cmos(0x0c) & 0xc0) === 0xc0 && cmos(0x0c) === 0);
}

// ---------------------------------------------------------------------------
//  the ROM's own mode set and cursor, programmed through the VGA ports
// ---------------------------------------------------------------------------
//  INT 10h from a virtual-8086 machine runs these, so that Windows 95's VDD
//  sees the registers of a DOS box.  Called here as INT would call them, the
//  display has to follow the port writes alone.
{
  const e = new Emulator({ ramSize: 16 * 1024 * 1024 });
  await e.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  e.bios.log = () => {};
  const disk = new Uint8Array(1440 * 1024);
  disk.set([
    0xb8, 0x48, 0x21, 0x9c, 0x9a, 0x00, 0x20, 0x00, 0xf0,   // mode 12h block; pushf; call far
    0xb8, 0x00, 0x21, 0x9c, 0x9a, 0x00, 0x20, 0x00, 0xf0,   // then mode 3
    0xb8, 0x40, 0x00, 0x8e, 0xd8,                           // ds = 0x40
    0xc6, 0x06, 0x50, 0x00, 0x0a,                           // cursor: column 10
    0xc6, 0x06, 0x51, 0x00, 0x05,                           //         row 5
    0x9c, 0x9a, 0x9f, 0x20, 0x00, 0xf0,                     // set the hardware cursor
    0xf4, 0xeb, 0xfd,                                       // hlt
  ]);
  disk[510] = 0x55; disk[511] = 0xaa;
  const modes = [];
  e.onDisplay = (d) => modes.push(d);
  e.bootImage({ data: disk, name: 'vga_rom.img', kind: 'floppy' });
  e.machine.wr16(0xb8000, 0x4141);                          // something to clear
  for (let i = 0; i < 200 && !e.machine.halted; i++) e.step();
  const v = e.vga;
  check('the ROM mode set reaches 640x480x16 through the ports alone',
        modes.some((d) => /640x480x4/.test(d)), modes.join(', '));
  check('and then 80x25 text, with the CRTC offset a DOS box needs',
        v.mode.text && v.textCols === 80 && v.textRows === 25 && v.crtc[0x13] === 0x28,
        `${v.describe()}, offset 0x${v.crtc[0x13].toString(16)}`);
  check('it loads the EGA colours and clears the text buffer',
        v.palette[3] === 0 && v.palette[4] === 0 && v.palette[5] === 42 &&
        e.machine.rd16(0xb8000) === 0x0720);
  check('the ROM cursor routine puts the cursor where the BDA says',
        ((v.crtc[0x0e] << 8) | v.crtc[0x0f]) === 5 * 80 + 10,
        `at ${(v.crtc[0x0e] << 8) | v.crtc[0x0f]}`);
}

// ---------------------------------------------------------------------------
//  the Cirrus GD5446, driven the way cirrus.sys drives it
// ---------------------------------------------------------------------------
//  PCI identity and BAR sizing, chip detection, the hidden DAC, an extended
//  mode, the BitBLT engine through its memory-mapped registers -- fills,
//  copies both ways, colour expansion fed by the CPU, patterns -- and the
//  hardware cursor in the rendered frame.
{
  const ce = new Emulator({ ramSize: 256 * 1024 * 1024 });
  await ce.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const io = ce.io;
  const out = (p, v, s = 1) => io.write(p, s, v);
  const inp = (p, s = 1) => io.read(p, s);
  const cfg = (dev, reg, size = 4) => { out(0xcf8, (0x80000000 | (dev << 11) | reg) >>> 0, 4); return inp(0xcfc + (reg & 3), size); };
  const cfgw = (dev, reg, v) => { out(0xcf8, (0x80000000 | (dev << 11) | reg) >>> 0, 4); out(0xcfc, v >>> 0, 4); };

  // PCI identity and BAR sizing
  check('PCI 02.0 is a CL-GD5446', cfg(2, 0) === 0x00b81013, cfg(2, 0).toString(16));
  check('display class', (cfg(2, 8) >>> 8) === 0x030000);
  const bar0 = cfg(2, 0x10);
  check('BAR0 is the VRAM, prefetchable', (bar0 & ~0xf) === ce.vramBase && (bar0 & 8) === 8, bar0.toString(16));
  cfgw(2, 0x10, 0xffffffff);
  const size0 = cfg(2, 0x10);
  check('BAR0 sizes as 32 MiB', ((~(size0 & ~0xf)) >>> 0) + 1 === 32 * 1024 * 1024, size0.toString(16));
  cfgw(2, 0x10, bar0);
  check('BAR0 restores', cfg(2, 0x10) === bar0);

  // chip detection as cirrus.sys does it
  out(0x3c4, 0x06); out(0x3c5, 0x00);
  check('SR6 locked reads 0x0F', (out(0x3c4, 6), inp(0x3c5)) === 0x0f);
  out(0x3c4, 0x06); out(0x3c5, 0x12);
  check('SR6 unlocks with 0x12', (out(0x3c4, 6), inp(0x3c5)) === 0x12);
  out(0x3d4, 0x27);
  check('CR27 is 0xB8', inp(0x3d5) === 0xb8, inp(0x3d5).toString(16));
  out(0x3c4, 0x15);
  check('SR15 says 4 MiB', inp(0x3c5) === 0x04);

  // hidden DAC
  inp(0x3c6); inp(0x3c6); inp(0x3c6); inp(0x3c6); out(0x3c6, 0xe1);
  inp(0x3c8); inp(0x3c6); inp(0x3c6); inp(0x3c6); inp(0x3c6);
  check('hidden DAC round trip', inp(0x3c6) === 0xe1);

  // an extended mode, through the BIOS's own routine
  ce.bios.cirrusSetMode(0x74, true);
  const m = ce.vga.mode;
  check('mode 0x74 is 1024x768x16', m.cirrus && m.w === 1024 && m.h === 768 && m.bpp === 16 && m.pitch === 2048,
        JSON.stringify(m));

  // BitBLT through BAR1's registers
  const mm = BigInt(ce.cirrus.mmioBase);
  // the BitBLT registers are at 0x100 in BAR1
  const mw = (off, size, v) => ce.mmioWrite(mm + 0x100n + BigInt(off), size, BigInt(v));
  const blt = ({ w, h, dst, src = 0, dpitch = 2048, spitch = 2048, mode = 0x10, rop = 0x0d, ext = 0, fg = 0, bg = 0 }) => {
    mw(0x00, 4, bg); mw(0x04, 4, fg);
    mw(0x08, 2, w - 1); mw(0x0a, 2, h - 1);
    mw(0x0c, 2, dpitch); mw(0x0e, 2, spitch);
    mw(0x14, 4, src); mw(0x10, 4, dst);
    mw(0x18, 1, mode); mw(0x1a, 1, rop); mw(0x1b, 1, ext);
    mw(0x40, 1, 0x02);
  };
  const vram = ce.machine.u8, vb = ce.vramBase;
  const px16 = (x, y) => vram[vb + y * 2048 + x * 2] | (vram[vb + y * 2048 + x * 2 + 1] << 8);

  // solid fill 100x50 at (10,20) with 0xF800 (red in 5:6:5)
  blt({ w: 200, h: 50, dst: 20 * 2048 + 20, mode: 0x10 | 0xc0, ext: 0x04, fg: 0xf800 });
  check('solid fill', px16(10, 20) === 0xf800 && px16(109, 69) === 0xf800 && px16(110, 20) === 0 && px16(10, 70) === 0,
        `${px16(10, 20).toString(16)} ${px16(109, 69).toString(16)} ${px16(110, 20)} ${px16(10, 70)}`);

  // screen to screen copy of that rectangle to (300, 300)
  blt({ w: 200, h: 50, dst: 300 * 2048 + 600, src: 20 * 2048 + 20 });
  check('screen copy', px16(300, 300) === 0xf800 && px16(399, 349) === 0xf800 && px16(400, 300) === 0);

  // overlapping copy downwards: backwards, from the bottom right corner
  blt({ w: 200, h: 50, dst: (349 + 10) * 2048 + 600 + 199, src: 349 * 2048 + 600 + 199, mode: 0x11 });
  check('backward overlapping copy', px16(300, 310) === 0xf800 && px16(399, 359) === 0xf800);

  // colour expansion from the host: 16x2 pixels, bits from the CPU, transparent zeros
  blt({ w: 32, h: 2, dst: 500 * 2048 + 1000, mode: 0x10 | 0x80 | 0x04 | 0x08, fg: 0x07e0 });
  check('a host transfer is pending', (ce.cirrus.readGc(0x31) & 1) === 1);
  check('and BAR1 reports it busy', (Number(ce.mmioRead(mm + 0x140n, 1)) & 1) === 1);
  ce.mmioWrite(mm + 0x04n, 1, 0x12n); ce.mmioWrite(mm + 0x05n, 1, 0x34n);
  check('BAR1 below 0x100 is the VGA ports', ce.vga.seq[0x12] === 0x34);
  ce.mmioWrite(mm + 0x04n, 1, 0x12n); ce.mmioWrite(mm + 0x05n, 1, 0x00n);
  const fb = BigInt(ce.vramBase);
  // Monochrome lines are packed a byte apart: 2 bytes per 16-pixel line, so
  // both lines arrive in one dword.
  ce.mmioWrite(fb, 4, 0xaa55f00fn);           // line 0: 0x0F, 0xF0; line 1: 0x55, 0xAA
  check('the transfer completes', (ce.cirrus.readGc(0x31) & 1) === 0);
  check('expanded pixels', px16(504, 500) === 0x07e0 && px16(503, 500) === 0 && px16(508, 500) === 0x07e0 &&
        px16(512, 500) === 0 && px16(501, 501) === 0x07e0 && px16(500, 501) === 0,
        [504, 503, 508, 512].map((x) => px16(x, 500).toString(16)).join(' ') + ' / ' + px16(501, 501).toString(16));
  check('framebuffer is memory again', ce.machine.translateFor(ce.vramBase, true) !== null);

  // A glyph: 8 pixels wide, 6 lines, one byte a line -- six bytes, sent as
  // two dwords whose last two bytes are padding.  Expecting a dword a line
  // left a transfer like this waiting for data that never came, and every
  // framebuffer write after it went to the blitter: windows stopped painting.
  blt({ w: 16, h: 6, dst: 520 * 2048 + 1000, mode: 0x10 | 0x80 | 0x04 | 0x08, fg: 0x001f });
  ce.mmioWrite(fb, 4, 0x81422418n);
  ce.mmioWrite(fb, 4, 0x0000ff00n);
  check('a narrow host transfer finishes on the data it is given',
        (ce.cirrus.readGc(0x31) & 1) === 0 && !ce.cirrus.trapping);
  check('and draws each line from its own byte',
        px16(503, 520) === 0x001f && px16(504, 520) === 0x001f && px16(502, 521) === 0x001f &&
        px16(500, 524) === 0 && px16(500, 525) === 0x001f && px16(507, 525) === 0x001f,
        [px16(503, 520), px16(502, 521), px16(500, 525)].map((v) => v.toString(16)).join(' '));

  // With dword granularity (GR33 bit 0) each line does start on a dword.
  blt({ w: 16, h: 2, dst: 530 * 2048 + 1000, mode: 0x10 | 0x80 | 0x04, ext: 0x01, fg: 0xffff, bg: 0 });
  ce.mmioWrite(fb, 4, 0x000000ffn);
  ce.mmioWrite(fb, 4, 0x00000080n);
  check('dword granularity puts each line in its own dword',
        (ce.cirrus.readGc(0x31) & 1) === 0 && px16(507, 530) === 0xffff && px16(500, 531) === 0xffff &&
        px16(501, 531) === 0);

  // 8x8 mono pattern fill
  for (let i = 0; i < 8; i++) vram[vb + 0x300000 + i] = i & 1 ? 0xaa : 0x55;
  blt({ w: 32, h: 4, dst: 600 * 2048 + 0, src: 0x300000, mode: 0x10 | 0xc0, fg: 0xffff, bg: 0x001f });
  check('mono pattern fill', px16(0, 600) === 0x001f && px16(1, 600) === 0xffff && px16(0, 601) === 0xffff,
        [px16(0, 600), px16(1, 600), px16(0, 601)].map((v) => v.toString(16)).join(' '));

  // The BitBLT registers at 0xB8000, where Windows XP's driver puts them
  // (SR17 = 0x24): the window has to reach the chip, not the text buffer.
  let routed = null;
  const prevRouting = ce.vga.onWindowRouting;
  ce.vga.onWindowRouting = (v) => { routed = v; prevRouting(v); };
  out(0x3c4, 0x17); out(0x3c5, 0x24);
  check('SR17 routes the 0xB8000 register window', routed === 2, String(routed));
  const b8 = (off, size, v) => ce.mmioWrite(0xb8000n + BigInt(off), size, BigInt(v));
  b8(0x04, 4, 0x07e0); b8(0x08, 2, 20 - 1); b8(0x0a, 2, 3 - 1);
  b8(0x0c, 2, 2048); b8(0x18, 1, 0x10 | 0xc0); b8(0x1a, 1, 0x0d); b8(0x1b, 1, 0x04);
  b8(0x10, 4, 700 * 2048 + 40);
  b8(0x40, 1, 0x02);
  check('a fill started through 0xB8000 happens', px16(20, 700) === 0x07e0 && px16(29, 702) === 0x07e0 &&
        px16(30, 700) === 0, [px16(20, 700), px16(29, 702), px16(30, 700)].map((v) => v.toString(16)).join(' '));
  check('and its status reads back from there', (Number(ce.mmioRead(0xb8040n, 1)) & 1) === 0);
  out(0x3c4, 0x17); out(0x3c5, 0x20);
  check('turning it off gives 0xB8000 back to memory', routed === 1, String(routed));

  // render with a hardware cursor
  out(0x3c4, 0x12); out(0x3c5, 0x03);          // cursor on, extended DAC colours
  out(0x3c8, 0x0f); out(0x3c9, 63); out(0x3c9, 63); out(0x3c9, 63);   // foreground white
  out(0x3c4, 0x12); out(0x3c5, 0x01);
  out(0x3c4, 0x13); out(0x3c5, 0x00);
  const cbase = vb + 4 * 1024 * 1024 - 16384;
  for (let i = 0; i < 128; i++) { vram[cbase + i] = 0xff; vram[cbase + 128 + i] = 0xff; }
  out(0x3c4, 0x10 | (5 << 5)); out(0x3c5, 100 >> 3);   // x = 101
  out(0x3c4, 0x11); out(0x3c5, 200 >> 3);              // y = 200
  const rgba = new Uint8ClampedArray(1024 * 768 * 4);
  ce.vga.renderGraphics(rgba);
  const at = (x, y) => [...rgba.slice((y * 1024 + x) * 4, (y * 1024 + x) * 4 + 3)];
  check('red fill renders red', at(10, 20).join() === '255,0,0', at(10, 20).join());
  check('cursor drawn in white', at(110, 210).join() === '252,252,252', at(110, 210).join());
}

// ---------------------------------------------------------------------------
//  VBE window A: banked access to a VBE mode through 0xA0000
// ---------------------------------------------------------------------------
//  Windows 95's Super VGA driver dates from before linear framebuffers were
//  usual and reaches video memory 64 KiB at a time, moving the window with
//  4F05h.  The window has to land in video memory, at the bank it was told.
{
  const ve = new Emulator({ ramSize: 64 * 1024 * 1024, display: 'vga' });
  await ve.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  const v = ve.vga;
  v.setVbeMode(0x101, false);
  v.setVbeBank(1);
  ve.mmioWrite(0xa0005n, 1, 0x77n);
  ve.mmioWrite(0xaffffn, 1, 0x88n);
  check('a write through window A lands in its bank of video memory',
        ve.machine.u8[v.lfbBase + 0x10005] === 0x77 && ve.machine.u8[v.lfbBase + 0x1ffff] === 0x88,
        `${ve.machine.u8[v.lfbBase + 0x10005]} ${ve.machine.u8[v.lfbBase + 0x1ffff]}`);
  v.setVbeBank(0);
  ve.machine.u8[v.lfbBase + 3] = 0x5a;
  check('and reads come back from the bank shown', Number(ve.mmioRead(0xa0003n, 1)) === 0x5a);
}

// ---------------------------------------------------------------------------
//  the reset button
// ---------------------------------------------------------------------------
//  The page's Reset: the same machine from power-on -- CPU, chipset, PCI
//  configuration and display adapter -- with every disk as the guest left it.
{
  const { Disk, MemoryStore } = await import('../src/js/disk.js');
  const re = new Emulator({ ramSize: 256 * 1024 * 1024, sliceSize: 1000 });
  await re.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  re.onSerial = () => {};
  re.bios.log = () => {};
  check('reset with nothing booted does nothing', re.reset() === false);

  const bytes = new Uint8Array(1440 * 1024);
  bytes[510] = 0x55; bytes[511] = 0xaa;
  const image = new Disk(new MemoryStore(bytes), 'floppy', 'r.img');
  re.bootImage(image, { hddSize: 16 * 1024 * 1024, hddName: 'ram0' });
  re.step(); re.step();

  // what a running system leaves behind: writes to both drives, paging on,
  // the adapter in an extended mode, BAR1 moved and the triple-fault guard
  // nearly spent
  image.write(100, new Uint8Array(512).fill(0xA5));
  re.ramDisk.write(1234, new Uint8Array(512).fill(0xC3));
  const ram = re.ramDisk;
  const x = re.machine.exports;
  x.set_cr(0, 0x80000011n);
  re.bios.cirrusSetMode(0x74, true);
  const out = (p, v, s = 1) => re.io.write(p, s, v);
  const cfg = (reg) => { out(0xcf8, (0x80000000 | (2 << 11) | reg) >>> 0, 4); return re.io.read(0xcfc, 4); };
  const bar1 = cfg(0x14);
  out(0xcf8, (0x80000000 | (2 << 11) | 0x14) >>> 0, 4); out(0xcfc, 0xfd000000, 4);
  check('the test really did move BAR1', cfg(0x14) === 0xfd000000, cfg(0x14).toString(16));
  re.tripleFaults = 9;

  check('reset reports it ran', re.reset() === true);
  check('the CPU is back in real mode with paging off',
        x.get_mode() === 0 && (Number(x.get_cr(0)) & 0x80000001) === 0,
        `mode=${x.get_mode()} cr0=0x${Number(x.get_cr(0)).toString(16)}`);
  check('the screen is back in 80x25 text', re.vga.mode.text && !re.vga.mode.cirrus, re.vga.describe());
  check('the Cirrus extensions are locked again', re.vga.seq[0x07] === 0 && !re.cirrus.trapping);
  check('BAR1 is back where the BIOS put it', cfg(0x14) === bar1, cfg(0x14).toString(16));
  check('the boot image keeps what the guest wrote',
        re.bios.bootDisk === image && image.read(100, 1)?.[0] === 0xA5);
  check('the RAM drive is the same drive, with what the guest wrote',
        re.ramDisk === ram && ram.read(1234, 1)?.[0] === 0xC3);
  check('the triple-fault guard starts afresh', re.tripleFaults === 0);
  let ran = true;
  for (let i = 0; i < 20 && ran; i++) ran = re.step();
  check('and the machine runs again', ran && re.stats.instructions > 0);
}

// ---------------------------------------------------------------------------
//  what POST leaves for the operating system: memory sizes and the APIC
// ---------------------------------------------------------------------------
//  TempleOS sizes memory by the larger of E801 and E820, and turns the local
//  APIC on without programming LINT0.  Each of the BIOS's answers has to agree
//  with the others, and the APIC has to be left in virtual wire mode, or it
//  puts its heap in the framebuffer and never sees a timer tick.
{
  const pe = new Emulator({ ramSize: 512 * 1024 * 1024, sliceSize: 1000 });
  await pe.init(readFileSync(join(root, 'build', 'cpu.wasm')));
  pe.onSerial = () => {};
  pe.bios.log = () => {};
  const stub = new Uint8Array(512); stub[510] = 0x55; stub[511] = 0xaa;
  pe.bootImage({ data: stub, name: 's.img', kind: 'floppy' });
  const b = pe.bios;
  const usableEnd = pe.vramBase;
  check('the E820 map stops usable RAM at the framebuffer',
        b.e820.some((e) => e.type === 1 && e.base === 0x100000 && e.base + e.size === usableEnd));

  b.setR16(0, 0xe801); b.dispatch(0x15);
  const e801 = 0x100000 + (b.r16(0) & 0xffff) * 1024 + (b.r16(3) & 0xffff) * 65536;
  check('E801 reports the same end of RAM as E820', e801 === usableEnd,
        `E801 0x${e801.toString(16)}, E820 0x${usableEnd.toString(16)}`);
  b.setR16(0, 0x8800); b.dispatch(0x15);
  check('and 88h no more than that', 0x100000 + (b.r16(0) & 0xffff) * 1024 <= usableEnd);
  const cmos = (r) => { pe.io.write(0x70, 1, r); return pe.io.read(0x71, 1); };
  const cmosEnd = 16 * 1024 * 1024 + (cmos(0x34) | (cmos(0x35) << 8)) * 65536;
  check('CMOS 34h/35h agree', cmosEnd === usableEnd,
        `CMOS 0x${cmosEnd.toString(16)}, E820 0x${usableEnd.toString(16)}`);

  const L = pe.lapic;
  check('POST leaves the local APIC in virtual wire mode',
        L.accepting && L.extIntOpen && (L.lvt[3] & 0x10700) === 0x700 && (L.lvt[4] & 0x10700) === 0x400,
        `svr=0x${L.svr.toString(16)} lint0=0x${L.lvt[3].toString(16)} lint1=0x${L.lvt[4].toString(16)}`);
  // what TempleOS does: enable through SVR, set up logical addressing, and
  // leave LINT0 alone
  L.write(0x0f0, 4, 0x1ff); L.write(0x0d0, 4, 0); L.write(0x0e0, 4, 0xf0000000);
  pe.io.pic.raise(0);
  check('and the timer still gets through once the OS enables the APIC itself',
        pe.interruptPending() && pe.acknowledgeInterrupt() === 0x08);
}

console.log(failures ? `\n${failures} failing` : '\nall BIOS/VGA/disk tests passed');
process.exit(failures ? 1 : 0);
