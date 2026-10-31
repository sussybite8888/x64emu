// ---------------------------------------------------------------------------
//  Browser front end: VGA canvas, serial log, keyboard routing, run loop.
// ---------------------------------------------------------------------------

import { Emulator } from './emulator.js';
import { human, formatDiskRow } from './format.js';
import { Display } from './display.js';
import { Disk, fileStore } from './disk.js';

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
    this.emu = null;
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
    this.serial.lines = [''];
    this.log(`x64emu ready (core ${this.wasm.byteLength} bytes, ` +
             `FPU ${this.fpuPresent ? 'yes' : 'NO'}).`);
    this.log('Pick a bootable image to boot it through the BIOS, or load a');
    this.log('Linux kernel to enter it directly.');
    this.wire();
  }

  async makeEmulator() {
    const ramSize = parseSize($('ram').value, 256 * 1024 * 1024);
    try {
      this.emu = new Emulator({ ramSize, sliceSize: 400_000 });
    } catch (err) {
      this.log(err.message);
      throw err;
    }
    await this.emu.init(this.wasm);
    this.emu.onSerial = (b) => this.serial.write(b);
    this.emu.onDisplay = (desc) => {
      $('video').textContent = desc;
      // The canvas backing store changes size with the mode, so its CSS size
      // has to be recomputed or the picture keeps the previous dimensions.
      requestAnimationFrame(() => this.applyZoom());
    };
    this.emu.onExit = (why) => {
      this.running = false;
      this.log(`\n[machine stopped: ${why}]`);
      this.updateButtons();
    };
    this.display = new Display($('vga'), this.emu.vga);
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
    $('stop').addEventListener('click', () => {
      this.running = false;
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
        if (this.emu && this.running) canvas.requestPointerLock();
        return;
      }
      this.buttons = (this.buttons ?? 0) | bit(e);
      this.emu?.sendMouse(0, 0, this.buttons);
    });
    canvas.addEventListener('mouseup', (e) => {
      if (!captured()) return;
      this.buttons = (this.buttons ?? 0) & ~bit(e);
      this.emu?.sendMouse(0, 0, this.buttons);
    });
    canvas.addEventListener('mousemove', (e) => {
      if (!this.emu || !this.running || !captured()) return;
      this.emu.sendMouse(e.movementX ?? 0, e.movementY ?? 0, this.buttons ?? 0);
    });
    document.addEventListener('pointerlockchange', () => {
      if (captured() || !this.buttons) return;
      this.buttons = 0;                        // nothing stays held once released
      this.emu?.sendMouse(0, 0, 0);
    });
    document.addEventListener('pointerlockerror', () => { this.noPointerLock = true; });
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    window.addEventListener('blur', () => this.releaseAll());
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
    if (!this.emu || !this.running) return;
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
      if (s !== null) this.emu.sendInput(s);
      return;
    }
    this.emu.sendKey(e.code, pressed);
    if (pressed) this.heldKeys = (this.heldKeys ?? new Set()).add(e.code);
    else this.heldKeys?.delete(e.code);
  }

  // Releasing everything on focus loss avoids a key sticking down in the guest.
  releaseAll() {
    if (!this.emu || !this.heldKeys) return;
    for (const code of this.heldKeys) this.emu.sendKey(code, false);
    this.heldKeys.clear();
  }

  async bootImage() {
    if (!this.image) return;
    await this.makeEmulator();
    this.serial.lines = [''];
    try {
      const store = fileStore(this.image);
      // The volume descriptors have to be resident before the image kind can be
      // sniffed.  Anything further in (a boot catalog, the boot image) is
      // fetched on demand through the BIOS retry path.
      await store.ensure(0, 64 * 1024);
      if (store.size > 20 * 2048) await store.ensure(16 * 2048, 4 * 2048);
      const disk = new Disk(store, $('imageKind').value, this.image.name);
      const info = this.emu.bootImage(disk, {
        hddSize: parseSize($('hddSize').value, 0),
        hddName: 'ram0',
      });
      this.log(`booting ${info.name} as ${info.kind}: ${info.sectors} sectors ` +
               `of ${info.sectorSize} bytes, drive 0x${info.drive.toString(16)}`);
      this.reportDisks(info);
    } catch (err) {
      this.log(`boot failed: ${err.message}`);
      return;
    }
    this.start();
  }

  reportDisks(info) {
    for (const d of info.disks ?? []) {
      this.log(`  drive 0x${d.drive.toString(16)}: ${d.name} (${d.kind}, ` +
               `${d.sectors.toLocaleString()} sectors, ` +
               `${d.writable ? 'writable' : 'read-only'})`);
    }
    $('downloadHdd').disabled = !this.emu.ramDisk;
    $('hddState').textContent = this.emu.ramDisk
      ? `${human(this.emu.ramDisk.store.size)} attached`
      : 'not attached';
  }

  // Hand back whatever the guest actually wrote, so work on the RAM drive can
  // be kept.  Only the committed chunks are materialised.
  downloadDisk() {
    const disk = this.emu?.ramDisk;
    if (!disk) return;
    const committed = disk.allocated;
    if (committed > 512 * 1024 * 1024) {
      this.log(`disk holds ${human(committed)}; that is too large to export here`);
      return;
    }
    const blob = new Blob([disk.store.export()], { type: 'application/octet-stream' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `${disk.name}.img`;
    a.click();
    URL.revokeObjectURL(a.href);
  }

  async bootKernel() {
    if (!this.kernel) return;
    await this.makeEmulator();
    this.serial.lines = [''];
    try {
      const info = this.emu.bootLinux({
        kernel: this.kernel.data,
        initrd: this.initrd?.data ?? null,
        cmdline: $('cmdline').value,
        hddSize: parseSize($('hddSize').value, 0),
        hddName: 'ram0',
      });
      this.log(`boot protocol ${info.setup.version >> 8}.${info.setup.version & 0xff}, ` +
               `${info.bits}-bit entry at 0x${info.entry.toString(16)}`);
      $('downloadHdd').disabled = !this.emu.ramDisk;
      $('hddState').textContent = this.emu.ramDisk
        ? `${human(this.emu.ramDisk.store.size)} attached on ATA`
        : 'not attached';
    } catch (err) {
      this.log(`boot failed: ${err.message}`);
      return;
    }
    this.start();
  }

  start() {
    this.running = true;
    this.updateButtons();
    $('vga').focus();
    this.applyZoom();
    this.loop();
  }

  togglePause() {
    if (!this.emu) return;
    this.running = !this.running;
    this.updateButtons();
    if (this.running) this.loop();
  }

  updateButtons() {
    $('bootImage').disabled = !this.image;
    $('bootKernel').disabled = !this.kernel;
    $('pause').disabled = !this.emu;
    $('pause').textContent = this.running ? 'Pause' : 'Resume';
  }

  async loop() {
    if (this.looping) return;
    this.looping = true;
    while (this.running) {
      // Bound the work per frame so the page stays responsive.
      const deadline = performance.now() + 12;
      while (performance.now() < deadline) {
        if (!this.emu.step()) { this.running = false; break; }
        // If the guest is blocked on a disk read, wait for it here rather than
        // letting it spin for the rest of the frame.  Reading an image in
        // pieces is otherwise limited to one chunk per frame.
        const io = this.emu.pendingIo();
        if (io) { await io; }
      }
      const now = performance.now();
      this.display.render(now);
      this.serial.flush();
      this.updateStats(now);
      await new Promise((r) => requestAnimationFrame(r));
    }
    this.looping = false;
    this.updateButtons();
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

  updateStats(now) {
    if (now - this.lastStatsAt < 250) return;
    const s = this.emu.stats;
    const dt = (now - this.lastStatsAt) / 1000;
    const mips = this.lastStatsAt ? (s.instructions - this.lastInstrs) / dt / 1e6 : 0;
    this.lastStatsAt = now;
    this.lastInstrs = s.instructions;

    $('mips').textContent = mips.toFixed(1);
    $('instrs').textContent = s.instructions.toLocaleString();
    $('mode').textContent = s.vm ? 'virtual 8086' : (MODE_NAMES[s.mode] ?? s.mode);
    $('cpl').textContent = s.cpl;
    $('video').textContent = s.video;
    $('ramStat').textContent = human(this.emu.ramSize);
    $('litStat').textContent = this.display?.litSample == null
      ? 'text mode'
      : `${this.display.litSample} / ${this.display.litTotal}`;
    $('diskStat').textContent = this.emu.ramDisk
      ? `${human(this.emu.ramDisk.allocated)} / ${human(this.emu.ramDisk.store.size)}`
      : '-';
    this.updateDiskIo(s.disks ?? [], dt);
    $('state').textContent = s.halted ? 'halted' : (this.running ? 'running' : 'paused');

    const m = this.emu.machine;
    const hex = (v, w = 16) => v.toString(16).padStart(w, '0');
    let rows = '';
    for (let i = 0; i < 16; i += 2) {
      rows += `${REG_NAMES[i].padEnd(3)} ${hex(m.getReg(i))}   ` +
              `${REG_NAMES[i + 1].padEnd(3)} ${hex(m.getReg(i + 1))}\n`;
    }
    rows += `rip ${hex(m.rip)}   fl  ${hex(m.flags)}\n`;
    rows += `cr0 ${hex(m.getCR(0))}   cr3 ${hex(m.getCR(3))}\n`;
    rows += `cr4 ${hex(m.getCR(4))}   efr ${hex(m.getCR(9))}\n`;
    $('regs').textContent = rows;
  }
}

const app = new App();
app.init().catch((e) => {
  document.getElementById('serial').textContent = 'startup failed: ' + e.message;
});
