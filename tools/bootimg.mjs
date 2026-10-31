// Boot an arbitrary bootable image through the virtual BIOS, headless.
//
//   node tools/bootimg.mjs disk.img [--slices N] [--kind cdrom|hdd|floppy]
//
// Prints BIOS/bootloader teletype output as it happens and dumps the text-mode
// screen at the end, which is where most bootloaders draw their menus.
import { readFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Emulator } from '../src/js/emulator.js';
import { openDisk } from '../src/js/node-disk.js';

// Accept sizes like 512M, 8G, 2T.
function parseSize(v, fallback = 0) {
  if (!v) return fallback;
  const m = /^(\d+(?:\.\d+)?)\s*([kmgtKMGT]?)i?[bB]?$/.exec(String(v).trim());
  if (!m) throw new Error(`cannot parse size ${v}`);
  const mult = { '': 1, k: 1024, m: 1024 ** 2, g: 1024 ** 3, t: 1024 ** 4 };
  return Math.round(Number(m[1]) * mult[m[2].toLowerCase()]);
}

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const flags = {};
const files = [];
for (let i = 0; i < args.length; i++) {
  if (args[i].startsWith('--')) flags[args[i].slice(2)] = args[++i];
  else files.push(args[i]);
}

if (!files.length) {
  console.error('usage: node tools/bootimg.mjs <image> [options]\n' +
                '  --slices N     scheduling slices to run\n' +
                '  --kind K       cdrom | hdd | floppy (default: auto-detect)\n' +
                '  --ram SIZE     guest RAM, e.g. 512M or 8G (no upper bound)\n' +
                '  --hdd SIZE     size of the blank RAM drive (default 1G, 0 to omit)\n' +
                '  --type TEXT    type TEXT once --after appears on screen');
  process.exit(2);
}

const maxSlices = Number(flags.slices ?? 3000);
const ramSize = parseSize(flags.ram, 256 * 1024 * 1024);
// A PC that boots from CD normally still has a hard disk, and guests wait for
// one.  The browser attaches a RAM drive by default, so this does too; the
// drive is sparse, so an unused one costs nothing.  Pass --hdd 0 to omit it.
const hddSize = parseSize(flags.hdd, 1024 ** 3);

// The text screen is where a bootloader menu ends up.
function dumpText() {
  const m = emu.machine;
  const cols = emu.vga.textCols, rows = emu.vga.textRows;
  const out = [];
  for (let r = 0; r < rows; r++) {
    let s = '';
    for (let c = 0; c < cols; c++) {
      const ch = m.rd8(0xb8000 + (r * cols + c) * 2);
      s += ch >= 0x20 && ch < 0x7f ? String.fromCharCode(ch) : (ch === 0 ? ' ' : '.');
    }
    out.push(s.replace(/\s+$/, ''));
  }
  while (out.length && out[out.length - 1] === '') out.pop();
  return out;
}

const emu = new Emulator({ ramSize, sliceSize: 500_000 });
await emu.init(readFileSync(join(root, 'build', 'cpu.wasm')));

let line = '';
let bytes = 0;
emu.onSerial = (b) => {
  bytes++;
  const ch = String.fromCharCode(b);
  if (ch === '\n') { console.log('| ' + line); line = ''; }
  else if (ch !== '\r' && b >= 0x20) line += ch;
};
emu.onDisplay = (desc) => console.log(`[video] mode -> ${desc}`);
emu.onExit = (why) => console.log(`[exit: ${why}]`);

// The image is read lazily, so its size is bounded by the filesystem rather
// than by how much of it fits in memory.
const disk = openDisk(files[0], flags.kind ?? 'auto');
const info = emu.bootImage(disk, { hddSize, hddName: 'ram0' });

const human = (n) => n >= 2 ** 30 ? `${(n / 2 ** 30).toFixed(1)} GiB`
                                  : `${(n / 2 ** 20).toFixed(0)} MiB`;
console.log(`image    ${files[0]} (${human(disk.store.size)}, read on demand)`);
console.log(`type     ${info.kind}, drive 0x${info.drive.toString(16)}, ` +
            `${info.sectors} sectors of ${info.sectorSize} bytes`);
console.log(`RAM      ${human(ramSize)}`);
if (hddSize) console.log(`hdd      blank ${human(hddSize)} RAM drive on 0x80`);
console.log('--- boot ---');

// Optional scripted typing.  Bootloader menus are drawn straight to video
// memory rather than through the BIOS, so this triggers on the text screen
// (--after) or, failing that, on a slice count (--typeat).
const toType = flags.type ?? null;
const trigger = flags.after ?? null;
const typeAt = Number(flags.typeat ?? 0);
let typed = false;

function typeNow() {
  typed = true;
  for (const ch of toType.replace(/\\n/g, '\n')) {
    const code = ch.charCodeAt(0);
    emu.bios.pushKey(code === 10 ? 13 : code, asciiScan(code));
  }
  console.log(`[typed ${JSON.stringify(toType)}]`);
}

// Rough ASCII -> XT scancode, enough for menu entries and file names.
function asciiScan(code) {
  const row = '1234567890-=';
  const ch = String.fromCharCode(code).toLowerCase();
  if (code === 13 || code === 10) return 0x1c;
  if (code === 8) return 0x0e;
  if (code === 32) return 0x39;
  if (code === 27) return 0x01;
  const digit = row.indexOf(ch);
  if (digit >= 0) return digit + 2;
  const letters = 'qwertyuiop';
  const l2 = 'asdfghjkl';
  const l3 = 'zxcvbnm';
  if (letters.includes(ch)) return 0x10 + letters.indexOf(ch);
  if (l2.includes(ch)) return 0x1e + l2.indexOf(ch);
  if (l3.includes(ch)) return 0x2c + l3.indexOf(ch);
  return 0;
}

const t0 = Date.now();
let slices = 0;
let alive = true;
for (; slices < maxSlices && alive; slices++) {
  alive = emu.step();
  if (toType && !typed) {
    if (typeAt && slices >= typeAt) typeNow();
    else if (trigger && slices % 20 === 0 && dumpText().join('\n').includes(trigger)) typeNow();
  }
}
if (line) console.log('| ' + line);

const s = emu.stats;
const secs = (Date.now() - t0) / 1000;
console.log('--- text screen ---');
for (const l of dumpText()) console.log('> ' + l);
console.log('--- stopped ---');
console.log(`instructions ${s.instructions.toLocaleString()} in ${secs.toFixed(1)}s ` +
            `(${(s.instructions / secs / 1e6).toFixed(1)} MIPS)`);
console.log(`rip 0x${s.rip.toString(16)}  mode ${s.mode}  cpl ${s.cpl}  ` +
            `video ${s.video}  halted ${s.halted}`);
console.log(`bios calls: ${emu.bios.callSummary || '(none)'}`);
console.log(`image chunks fetched: ${disk.store.misses ?? 0}`);
if (emu.ramDisk) {
  console.log(`ram drive: ${human(emu.ramDisk.allocated)} committed of ` +
              `${human(emu.ramDisk.store.size)}`);
}
// Page faults are routine once a kernel is running, so this counts exceptions
// delivered rather than errors.
const fi = emu.machine.exports.fault_trace_index() >>> 0;
console.log(`exceptions delivered: ${fi}`);
for (let i = Math.max(0, fi - 4); i < fi; i++) {
  const rip = emu.machine.exports.fault_trace_rip(i);
  const vec = emu.machine.exports.fault_trace_vec(i);
  const err = emu.machine.exports.fault_trace_err(i);
  const md = emu.machine.exports.fault_trace_mode(i);
  // Resolve through the guest's own page tables; masking to 1 MiB only works
  // for real-mode addresses.
  const pa = emu.machine.translate(rip);
  const bytes = pa === null ? '(unmapped)'
    : [...emu.machine.readBytes(Number(pa), 16)]
        .map((b) => b.toString(16).padStart(2, '0')).join(' ');
  console.log(`  vec ${vec} err 0x${err.toString(16)} mode ${md} ` +
              `rip 0x${rip.toString(16)}  [${bytes}]`);
}
