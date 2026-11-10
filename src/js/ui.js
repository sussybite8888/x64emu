// ---------------------------------------------------------------------------
//  Browser front end: VGA canvas, serial log, keyboard routing, run loop.
// ---------------------------------------------------------------------------

import { human, formatDiskRow } from './format.js';
import { Display, FrameSource } from './display.js';

// Sizes may be written as 512M, 8G, 2T; there is no imposed ceiling.
function parseSize(text, fallback) {
  const m = /^(\d+(?:\.\d+)?)\s*([kmgtKMGT]?)i?[bB]?$/.exec(String(text).trim());
  if (!m) return fallback;
  const mult = { '': 1, k: 1024, m: 1024 ** 2, g: 1024 ** 3, t: 1024 ** 4 };
  return Math.round(Number(m[1]) * mult[m[2].toLowerCase()]);
}

const $ = (id) => document.getElementById(id);


const REG_NAMES = ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
                   'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'];
const MODE_NAMES = { 0: 'real 16', 1: 'prot 16', 2: 'prot 32', 3: 'long 64' };

class SerialLog {
  constructor(el) {
    this.el = el;
    this.lines = [''];
    this.dirty = true;
  }

  write(byte) {
    const ch = String.fromCharCode(byte);
    if (ch === '\n') this.lines.push('');
    else if (ch === '\r') { /* ignore */ }
    else if (ch === '\b') {
      const i = this.lines.length - 1;
      this.lines[i] = this.lines[i].slice(0, -1);
    } else if (byte >= 0x20 && byte < 0x7f) {
      this.lines[this.lines.length - 1] += ch;
    }
    if (this.lines.length > 1200) this.lines.splice(0, this.lines.length - 1200);
    this.dirty = true;
  }

  text(s) { for (const ch of s) this.write(ch.charCodeAt(0)); }

  flush() {
    if (!this.dirty) return;
    this.dirty = false;
    this.el.textContent = this.lines.join('\n');
    this.el.scrollTop = this.el.scrollHeight;
  }
}

class App {
  constructor() {
    this.serial = new SerialLog($('serial'));
    // The machine runs in a worker; the page holds only what it last sent.
    this.worker = null;
    this.booted = false;
    this.screen = new FrameSource();
    this.display = null;
    this.running = false;
    this.image = null;
    this.kernel = null;
    this.initrd = null;
    this.keyboardToSerial = false;
    this.lastStatsAt = 0;
    this.lastInstrs = 0;
  }

  log(msg) { this.serial.text(msg + '\n'); this.serial.flush(); }

  async init() {
    // Never serve a cached core: a stale cpu.wasm looks exactly like the
    // emulator ignoring a fix.
    this.wasm = await fetch('build/cpu.wasm', { cache: 'no-store' }).then((r) => {
      if (!r.ok) throw new Error('build/cpu.wasm not found - run ./build.sh');
      return r.arrayBuffer();
    });
    // A quick capability probe, so a mismatched core is visible immediately
    // rather than showing up later as a guest that hangs.
    try {
      const probe = await WebAssembly.compile(this.wasm);
      this.fpuPresent = WebAssembly.Module.imports(probe).some((i) => i.name === 'f_sin');
    } catch { this.fpuPresent = false; }
    this.display = new Display($('vga'), this.screen);
    this.startWorker();
    this.serial.lines = [''];
    this.log(`x64emu ready (core ${this.wasm.byteLength} bytes, ` +
             `FPU ${this.fpuPresent ? 'yes' : 'NO'}).`);
    this.log('Pick a bootable image to boot it through the BIOS, or load a');
    this.log('Linux kernel to enter it directly.');
    this.wire();
  }

  // ---- the worker ----------------------------------------------------------
  startWorker() {
    this.worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
    this.worker.onmessage = (e) => this.onWorker(e.data);
    this.worker.onerror = (e) => this.log(`[worker failed: ${e.message ?? 'unknown error'}]`);
    // A copy, so the page keeps its own for the capability probe.
    this.worker.postMessage({ type: 'init', wasm: this.wasm.slice(0) });
  }

  send(msg, transfer) { this.worker?.postMessage(msg, transfer ?? []); }

  onWorker(msg) {
    switch (msg.type) {
      case 'ready':
        return;
      case 'log':
        this.log(msg.text);
        return;
      case 'serial':
        for (let i = 0; i < msg.text.length; i++) this.serial.write(msg.text.charCodeAt(i));
        return;
      case 'booted':
        this.booted = true;
        this.ramSize = msg.ramSize;
        if (msg.kind === 'image') {
          const info = msg.info;
          this.log(`booting ${info.name} as ${info.kind}: ${info.sectors} sectors ` +
                   `of ${info.sectorSize} bytes, drive 0x${info.drive.toString(16)}`);
          this.reportDisks(info, msg.ramDisk);
        } else {
          const info = msg.info;
          this.log(`boot protocol ${info.version >> 8}.${info.version & 0xff}, ` +
                   `${info.bits}-bit entry at 0x${info.entry.toString(16)}`);
          this.reportDisks({ disks: [] }, msg.ramDisk);
        }
        this.lastStatsAt = 0;
        this.updateButtons();
        return;
      case 'video':
        $('video').textContent = msg.desc;
        // The canvas backing store changes size with the mode, so its CSS size
        // has to be recomputed or the picture keeps the previous dimensions.
        requestAnimationFrame(() => this.applyZoom());
        return;
      case 'frame': {
        const before = this.screen.describe();
        this.screen.update(msg);
        this.display.render(performance.now());
        if (this.screen.describe() !== before) this.applyZoom();
        // Drawn: the worker may send the next one.
        this.send({ type: 'frame-ack' });
        return;
      }
      case 'stats':
        this.updateStats(msg);
        return;
      case 'reset':
        this.log('\n[reset]');
        this.running = true;
        this.updateButtons();
        return;
      case 'exit':
        this.running = false;
        this.log(`\n[machine stopped: ${msg.why}]`);
        this.updateButtons();
        return;
      case 'download': {
        const blob = new Blob([msg.data], { type: 'application/octet-stream' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = msg.name;
        a.click();
        URL.revokeObjectURL(a.href);
        return;
      }
      case 'error':
        this.running = false;
        this.log(`[emulator error] ${msg.message}`);
        this.updateButtons();
        return;
      default:
        return;
    }
  }

  wire() {
    // A disk image is kept as a File and read in pieces; a kernel and initrd
    // have to land in guest RAM anyway, so those are read up front.
    $('imageFile').addEventListener('change', (e) => {
      const f = e.target.files[0];
      if (!f) return;
      this.image = f;
      this.log(`disk image: ${f.name} (${human(f.size)}, read on demand)`);
      this.updateButtons();
    });
    const pick = (id, prop, label) => {
      $(id).addEventListener('change', async (e) => {
        const f = e.target.files[0];
        if (!f) return;
        this[prop] = { data: new Uint8Array(await f.arrayBuffer()), name: f.name };
        this.log(`${label}: ${f.name} (${human(f.size)})`);
        this.updateButtons();
      });
    };
    pick('kernelFile', 'kernel', 'kernel');
    pick('initrdFile', 'initrd', 'initrd');
    $('downloadHdd').addEventListener('click', () => this.downloadDisk());

    $('bootImage').addEventListener('click', () => this.bootImage());
    $('bootKernel').addEventListener('click', () => this.bootKernel());
    $('pause').addEventListener('click', () => this.togglePause());
    $('reset').addEventListener('click', () => this.reset());
    $('stop').addEventListener('click', () => {
      this.running = false;
      this.send({ type: 'run', running: false });
      this.log('[stopped by user]');
      this.updateButtons();
    });
    $('grabKeys').addEventListener('click', () => {
      this.keyboardToSerial = !this.keyboardToSerial;
      const b = $('grabKeys');
      b.textContent = `Keyboard: ${this.keyboardToSerial ? 'serial' : 'display'}`;
      b.classList.toggle('on', !this.keyboardToSerial);
    });
    $('zoom').addEventListener('change', () => this.applyZoom());

    const canvas = $('vga');
    canvas.addEventListener('keydown', (e) => this.onKey(e, true));
    canvas.addEventListener('keyup', (e) => this.onKey(e, false));
    // The pointer is captured while the guest has it, so movement keeps
    // arriving however far it goes and the host's cursor does not sit on top
    // of the guest's.  The click that captures it is not passed on, and Esc
    // gives it back.  Where capture is unavailable the mouse works uncaptured.
    const captured = () => this.noPointerLock || document.pointerLockElement === canvas;
    const bit = (e) => 1 << (e.button === 2 ? 1 : e.button === 1 ? 2 : 0);
    this.noPointerLock = !canvas.requestPointerLock;
    canvas.addEventListener('mousedown', (e) => {
      canvas.focus();
      if (!captured()) {
        if (this.booted && this.running) canvas.requestPointerLock();
        return;
      }
      this.buttons = (this.buttons ?? 0) | bit(e);
      this.sendMouse(0, 0, this.buttons);
    });
    canvas.addEventListener('mouseup', (e) => {
      if (!captured()) return;
      this.buttons = (this.buttons ?? 0) & ~bit(e);
      this.sendMouse(0, 0, this.buttons);
    });
    canvas.addEventListener('mousemove', (e) => {
      if (!this.booted || !this.running || !captured()) return;
      this.sendMouse(e.movementX ?? 0, e.movementY ?? 0, this.buttons ?? 0);
    });
    document.addEventListener('pointerlockchange', () => {
      if (captured() || !this.buttons) return;
      this.buttons = 0;                        // nothing stays held once released
      this.sendMouse(0, 0, 0);
    });
    document.addEventListener('pointerlockerror', () => { this.noPointerLock = true; });
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    window.addEventListener('blur', () => this.releaseAll());
  }

  sendMouse(dx, dy, buttons) {
    this.send({ type: 'mouse', dx, dy, buttons });
  }

  applyZoom() {
    const c = $('vga');
    const requested = Number($('zoom').value);
    let z = requested;
    if (!requested || requested < 1) {
      // Auto: scale up to fill the panel in whole pixels.  Without this a
      // 320x200 mode is displayed at 320x200 CSS pixels, which is a postage
      // stamp in the middle of a large dark panel and reads as a blank screen.
      const box = c.parentElement?.clientWidth || 720;
      z = Math.max(1, Math.min(6, Math.floor((box - 16) / c.width)));
    }
    c.style.width = `${c.width * z}px`;
    c.style.height = `${c.height * z}px`;
  }

  onKey(e, pressed) {
    if (!this.booted || !this.running) return;
    e.preventDefault();

    if (this.keyboardToSerial) {
      if (!pressed) return;
      let s = null;
      if (e.key === 'Enter') s = '\r';
      else if (e.key === 'Backspace') s = '\x7f';
      else if (e.key === 'Tab') s = '\t';
      else if (e.key === 'Escape') s = '\x1b';
      else if (e.key.length === 1) {
        s = e.ctrlKey ? String.fromCharCode(e.key.toUpperCase().charCodeAt(0) & 0x1f)
                      : e.key;
      }
      if (s !== null) this.send({ type: 'serial-in', text: s });
      return;
    }
    this.send({ type: 'key', code: e.code, pressed });
    if (pressed) this.heldKeys = (this.heldKeys ?? new Set()).add(e.code);
    else this.heldKeys?.delete(e.code);
  }

  // Releasing everything on focus loss avoids a key sticking down in the guest.
  releaseAll() {
    if (!this.booted || !this.heldKeys) return;
    for (const code of this.heldKeys) this.send({ type: 'key', code, pressed: false });
    this.heldKeys.clear();
  }

  async bootImage() {
    if (!this.image) return;
    this.serial.lines = [''];
    this.serial.flush();
    this.running = true;
    // The File itself goes to the worker, which reads it in pieces.
    this.send({
      type: 'boot-image',
      file: this.image,
      kind: $('imageKind').value,
      hddSize: parseSize($('hddSize').value, 0),
      ramSize: parseSize($('ram').value, 256 * 1024 * 1024),
      ...this.machineOptions(),
    });
    this.start();
  }

  /** What the machine is built with, besides its disks. */
  machineOptions() {
    return { display: $('display').value, jit: $('jit').checked };
  }

  reportDisks(info, ramDisk) {
    for (const d of info.disks ?? []) {
      this.log(`  drive 0x${d.drive.toString(16)}: ${d.name} (${d.kind}, ` +
               `${d.sectors.toLocaleString()} sectors, ` +
               `${d.writable ? 'writable' : 'read-only'})`);
    }
    $('downloadHdd').disabled = !ramDisk;
    $('hddState').textContent = ramDisk ? `${human(ramDisk.size)} attached` : 'not attached';
  }

  // Hand back whatever the guest actually wrote, so work on the RAM drive can
  // be kept.  Only the committed chunks are materialised.
  downloadDisk() {
    if (this.booted) this.send({ type: 'download' });
  }

  async bootKernel() {
    if (!this.kernel) return;
    this.serial.lines = [''];
    this.serial.flush();
    this.running = true;
    this.send({
      type: 'boot-kernel',
      kernel: this.kernel.data,
      initrd: this.initrd?.data ?? null,
      cmdline: $('cmdline').value,
      hddSize: parseSize($('hddSize').value, 0),
      ramSize: parseSize($('ram').value, 256 * 1024 * 1024),
      ...this.machineOptions(),
    });
    this.start();
  }

  start() {
    this.running = true;
    this.updateButtons();
    $('vga').focus();
    this.applyZoom();
    this.blink();
  }

  /**
   * The machine's reset button: it restarts from power-on, paused, stopped or
   * running, and keeps whatever the guest wrote to its disks.  Keys held down
   * are forgotten rather than released, since the keyboard is reset as well.
   */
  reset() {
    if (!this.booted) return;
    this.heldKeys?.clear();
    this.send({ type: 'reset' });
    $('vga').focus();
  }

  togglePause() {
    if (!this.booted) return;
    this.running = !this.running;
    this.send({ type: 'run', running: this.running });
    this.updateButtons();
  }

  updateButtons() {
    $('bootImage').disabled = !this.image;
    $('bootKernel').disabled = !this.kernel;
    $('pause').disabled = !this.booted;
    $('reset').disabled = !this.booted;
    $('pause').textContent = this.running ? 'Pause' : 'Resume';
  }

  // Frames arrive from the worker and are drawn as they come; all that is left
  // to do here is keep the text cursor blinking and the serial log current.
  blink() {
    if (this.blinking) return;
    this.blinking = true;
    const tick = () => {
      if (this.screen.mode.text) this.display.render(performance.now());
      this.serial.flush();
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  /**
   * One row per drive: a lamp showing whether it is being read right now, the
   * throughput, and the total pulled off it.
   *
   * "Still reading the install image" and "wedged" are the two states worth
   * telling apart while a guest boots, and neither the instruction counter nor
   * the screen distinguishes them.
   */
  updateDiskIo(disks, dt) {
    const host = $('diskIo');
    if (!host) return;
    if (host.childElementCount !== disks.length) {
      host.textContent = '';
      for (const _ of disks) {
        const row = document.createElement('div');
        row.className = 'stat';
        row.innerHTML = '<span></span><span></span>';
        host.appendChild(row);
      }
      this.lastDiskBytes = disks.map((d) => d.bytesRead);
      this.lastPending = disks.map((d) => d.pendingReads);
    }
    disks.forEach((d, i) => {
      const delta = d.bytesRead - (this.lastDiskBytes[i] ?? d.bytesRead);
      const waiting = d.pendingReads !== this.lastPending[i];
      this.lastDiskBytes[i] = d.bytesRead;
      this.lastPending[i] = d.pendingReads;
      const row = host.children[i];
      const { lamp, label, value } = formatDiskRow(d, delta, waiting, dt);
      row.children[0].innerHTML = `<span class="${lamp}"></span>${label}`;
      row.children[1].textContent = value;
    });
  }

  updateStats(s) {
    const now = performance.now();
    const dt = (now - this.lastStatsAt) / 1000;
    const mips = this.lastStatsAt && s.instructions >= this.lastInstrs
      ? (s.instructions - this.lastInstrs) / dt / 1e6 : 0;
    this.lastStatsAt = now;
    this.lastInstrs = s.instructions;

    $('mips').textContent = mips.toFixed(1);
    // Of the instructions run since the last update, the share that ran as
    // compiled code: what decides how much faster the JIT makes a guest.
    if (s.jit) {
      const ran = s.instructions - (this.lastJitTotal ?? 0);
      const inBlocks = s.jit.instrsRun - (this.lastJitRun ?? 0);
      this.lastJitTotal = s.instructions;
      this.lastJitRun = s.jit.instrsRun;
      const share = ran > 0 ? Math.min(100, Math.max(0, (100 * inBlocks) / ran)) : 0;
      $('jitStat').textContent = `${share.toFixed(0)}% compiled, ${s.jit.compiled.toLocaleString()} blocks`;
    } else {
      $('jitStat').textContent = 'off';
    }
    $('instrs').textContent = s.instructions.toLocaleString();
    $('mode').textContent = s.vm ? 'virtual 8086' : (MODE_NAMES[s.mode] ?? s.mode);
    $('cpl').textContent = s.cpl;
    $('video').textContent = s.video;
    $('ramStat').textContent = human(s.ramSize);
    $('litStat').textContent = this.display?.litSample == null
      ? 'text mode'
      : `${this.display.litSample} / ${this.display.litTotal}`;
    $('diskStat').textContent = s.ramDisk
      ? `${human(s.ramDisk.allocated)} / ${human(s.ramDisk.size)}`
      : '-';
    this.updateDiskIo(s.disks ?? [], dt);
    $('state').textContent = s.halted ? 'halted' : (s.running ? 'running' : 'paused');

    const hex = (v, w = 16) => BigInt.asUintN(64, BigInt(v)).toString(16).padStart(w, '0');
    let rows = '';
    for (let i = 0; i < 16; i += 2) {
      rows += `${REG_NAMES[i].padEnd(3)} ${hex(s.regs[i])}   ` +
              `${REG_NAMES[i + 1].padEnd(3)} ${hex(s.regs[i + 1])}\n`;
    }
    rows += `rip ${hex(s.rip)}   fl  ${hex(s.flags)}\n`;
    rows += `cr0 ${hex(s.cr0)}   cr3 ${hex(s.cr3)}\n`;
    rows += `cr4 ${hex(s.cr4)}   efr ${hex(s.efer)}\n`;
    $('regs').textContent = rows;
  }
}

const app = new App();
app.init().catch((e) => {
  document.getElementById('serial').textContent = 'startup failed: ' + e.message;
});
