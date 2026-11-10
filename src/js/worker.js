// ---------------------------------------------------------------------------
//  The emulator, run in a Web Worker.
//
//  On the page's own thread the machine could only run between frames: about
//  12 ms of every 16.7, less whatever drawing the screen took, and anything
//  else the page did came out of the guest's time as well.  Here it runs
//  continuously and the page only draws what it is sent.
//
//  Messages in:  init, boot-image, boot-kernel, reset, run, key, mouse,
//                serial-in, frame-ack, download
//  Messages out: ready, log, serial, booted, reset, video, frame, stats, exit,
//                download, error
// ---------------------------------------------------------------------------

import { Emulator } from './emulator.js';
import { Disk, fileStore } from './disk.js';

let wasm = null;
let emu = null;
let running = false;
let looping = false;

// Frames are sent one at a time: the next waits until the page has drawn the
// previous one and handed its buffer back.
let frameOutstanding = false;
let lastFrameAt = 0;
let lastStatsAt = 0;
let serialOut = '';

// Linear framebuffers are written as plain memory and leave no trace, so they
// are redrawn at a fixed rate.  Planar modes go through the adapter and say
// when they have changed.
const FRAME_MS = 1000 / 60;
const LINEAR_FRAME_MS = 1000 / 30;

const post = (msg, transfer) => self.postMessage(msg, transfer ?? []);
const log = (text) => post({ type: 'log', text });

// ---- yielding --------------------------------------------------------------
// setTimeout(0) is clamped to 4 ms once nested, which would idle the guest for
// a quarter of the time.  A message to ourselves comes back as soon as the
// event loop has run whatever is queued ahead of it -- which is exactly the
// input and frame acknowledgements this yield exists to let through.
const channel = new MessageChannel();
const yieldQueue = [];
channel.port1.onmessage = () => yieldQueue.shift()?.();
const yieldNow = () => new Promise((r) => { yieldQueue.push(r); channel.port2.postMessage(0); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- pacing ----------------------------------------------------------------
// The machine's clock is virtual: it advances by instructions executed, and
// jumps ahead to the next timer event whenever the guest halts.  Unchecked,
// an idle guest would therefore run its clock as fast as the host can loop --
// minutes of guest time a second, with every clock and animation racing.
// While the guest is idle its clock is held to real time; while it is busy it
// runs as fast as it can, and if that leaves it behind it may catch up during
// the next idle spell, but never by more than a second at a time.
let realAnchor = 0;
let virtAnchor = 0;
const MAX_LAG_MS = 1000;

function resetPacing() {
  realAnchor = performance.now();
  virtAnchor = emu ? emu.virtualNs / 1e6 : 0;
}

/** Milliseconds the guest's clock is ahead of real time, if it is. */
function aheadMs() {
  const real = performance.now() - realAnchor;
  const virt = emu.virtualNs / 1e6 - virtAnchor;
  if (real - virt > MAX_LAG_MS) {               // too far behind: forgive it
    virtAnchor = emu.virtualNs / 1e6 - (real - MAX_LAG_MS);
  }
  return virt - real;
}

// ---- machine construction --------------------------------------------------
async function makeEmulator(ramSize, { display = 'cirrus', jit = true } = {}) {
  emu = new Emulator({ ramSize, sliceSize: 400_000, display, jit });
  await emu.init(wasm);
  emu.onSerial = (b) => { serialOut += String.fromCharCode(b); };
  emu.onDisplay = (desc) => post({ type: 'video', desc });
  emu.onExit = (why) => {
    running = false;
    flushSerial();
    sendFrame(true);
    post({ type: 'exit', why });
  };
  frameOutstanding = false;
}

function diskInfo() {
  return emu.ramDisk
    ? { allocated: emu.ramDisk.allocated, size: emu.ramDisk.store.size }
    : null;
}

async function bootImage({ file, kind, hddSize, ramSize, display, jit }) {
  await makeEmulator(ramSize, { display, jit });
  const store = fileStore(file);
  // The volume descriptors have to be resident before the image kind can be
  // sniffed.  Anything further in (a boot catalog, the boot image) is fetched
  // on demand through the BIOS retry path.
  await store.ensure(0, 64 * 1024);
  if (store.size > 20 * 2048) await store.ensure(16 * 2048, 4 * 2048);
  const disk = new Disk(store, kind, file.name);
  const info = emu.bootImage(disk, { hddSize, hddName: 'ram0' });
  post({ type: 'booted', kind: 'image', info, ramDisk: diskInfo() });
}

async function bootKernel({ kernel, initrd, cmdline, hddSize, ramSize, display, jit }) {
  await makeEmulator(ramSize, { display, jit });
  const info = emu.bootLinux({
    kernel, initrd, cmdline, hddSize, hddName: 'ram0',
  });
  post({ type: 'booted', kind: 'kernel', ramDisk: diskInfo(),
         info: { version: info.setup.version, bits: info.bits, entry: info.entry } });
}

// ---- output ----------------------------------------------------------------
function flushSerial() {
  if (!serialOut) return;
  post({ type: 'serial', text: serialOut });
  serialOut = '';
}

/**
 * Send the screen if the page is ready for it and it may have changed.
 * Graphics modes are rendered here, into a buffer that is transferred rather
 * than copied; text modes send the cells and let the page draw glyphs.
 */
function sendFrame(force = false) {
  if (!emu || (frameOutstanding && !force)) return;
  const vga = emu.vga;
  const now = performance.now();
  const text = vga.mode.text;
  const interval = text || vga.mode.planar ? FRAME_MS : LINEAR_FRAME_MS;
  if (!force && now - lastFrameAt < interval) return;
  // A planar screen only changes through the adapter, which says so.
  if (!force && vga.mode.planar && !vga.dirty) return;
  lastFrameAt = now;
  frameOutstanding = true;

  const desc = vga.describe();
  if (text) {
    const cells = vga.readText().slice();
    post({ type: 'frame', text: true, cols: vga.textCols, rows: vga.textRows,
           cells, cursor: vga.cursor, desc }, [cells.buffer]);
    return;
  }
  const { w, h } = vga.size;
  // A fresh buffer each time: the page keeps the last one to redraw from.
  const rgba = new Uint8ClampedArray(w * h * 4);
  vga.dirty = false;
  vga.renderGraphics(rgba);
  post({ type: 'frame', text: false, w, h, rgba, desc }, [rgba.buffer]);
}

function sendStats(now) {
  if (now - lastStatsAt < 250) return;
  lastStatsAt = now;
  const s = emu.stats;
  const m = emu.machine;
  const regs = [];
  for (let i = 0; i < 16; i++) regs.push(m.getReg(i));
  post({
    type: 'stats',
    instructions: s.instructions, mode: s.mode, vm: s.vm, cpl: s.cpl,
    halted: s.halted, video: s.video, disks: s.disks,
    ramSize: emu.ramSize, ramDisk: diskInfo(), running,
    regs, rip: m.rip, flags: m.flags,
    cr0: m.getCR(0), cr3: m.getCR(3), cr4: m.getCR(4), efer: m.getCR(9),
    jit: emu.jitStats?.() ?? null,
  });
}

// ---- the run loop ------------------------------------------------------------
async function loop() {
  if (looping) return;
  looping = true;
  resetPacing();
  try {
    while (running) {
      const deadline = performance.now() + 16;
      let idle = false;
      while (running && performance.now() < deadline) {
        if (!emu.step()) { running = false; break; }
        // A guest blocked on an image read waits for it here rather than
        // spinning until the read lands.
        const io = emu.pendingIo();
        if (io) { await io; resetPacing(); }
        if (emu.lastStepIdle && aheadMs() > 1) { idle = true; break; }
      }
      flushSerial();
      const now = performance.now();
      sendFrame();
      sendStats(now);
      // An idle guest sleeps until real time catches up with its clock; a busy
      // one only yields long enough for input to arrive.
      const ahead = idle ? aheadMs() : 0;
      if (ahead > 1) await sleep(Math.min(ahead, 20));
      else await yieldNow();
    }
  } catch (err) {
    running = false;
    post({ type: 'error', message: `${err.message}\n${err.stack ?? ''}` });
  }
  flushSerial();
  sendFrame(true);
  if (emu) sendStats(Infinity);
  looping = false;
}

// ---- messages ----------------------------------------------------------------
self.onmessage = async (e) => {
  const msg = e.data;
  try {
    switch (msg.type) {
      case 'init':
        wasm = msg.wasm;
        post({ type: 'ready' });
        return;
      case 'boot-image':
        running = false;
        while (looping) await sleep(5);
        await bootImage(msg);
        running = true;
        loop();
        return;
      case 'boot-kernel':
        running = false;
        while (looping) await sleep(5);
        await bootKernel(msg);
        running = true;
        loop();
        return;
      case 'reset':
        // The same machine from power-on, disks as the guest left them.  The
        // loop is let go first so a reset never lands in the middle of a step.
        if (!emu) return;
        running = false;
        while (looping) await sleep(5);
        if (!emu.reset()) return;
        post({ type: 'reset' });
        running = true;
        loop();
        return;
      case 'run':
        if (!emu) return;
        running = msg.running;
        if (running) loop();
        return;
      case 'key':
        emu?.sendKey(msg.code, msg.pressed);
        return;
      case 'mouse':
        emu?.sendMouse(msg.dx, msg.dy, msg.buttons);
        return;
      case 'serial-in':
        emu?.sendInput(msg.text);
        return;
      case 'frame-ack':
        frameOutstanding = false;
        // While paused nothing else will send the next frame.
        if (!running && emu) sendFrame();
        return;
      case 'download': {
        const disk = emu?.ramDisk;
        if (!disk) return;
        if (disk.allocated > 512 * 1024 * 1024) {
          log(`disk holds ${(disk.allocated / 2 ** 20).toFixed(0)} MiB; that is too large to export here`);
          return;
        }
        // A sparse store flattens into a fresh array, which can be handed over
        // outright; any other store exports its own backing array, which must
        // be copied rather than detached from under it.
        const data = disk.store.export();
        const out = disk.store.chunks ? data : data.slice();
        post({ type: 'download', name: `${disk.name}.img`, data: out.buffer }, [out.buffer]);
        return;
      }
      default:
        return;
    }
  } catch (err) {
    post({ type: 'error', message: `${err.message}\n${err.stack ?? ''}` });
  }
};
