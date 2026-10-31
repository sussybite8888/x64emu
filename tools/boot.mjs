// Headless boot harness: load a kernel, run it, stream the serial console.
//
//   node tools/boot.mjs images/tinycore-vmlinuz [images/initrd.gz] [--slices N]
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { Emulator } from '../src/js/emulator.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const flags = {};
const files = [];
for (let i = 0; i < args.length; i++) {
  if (args[i].startsWith('--')) flags[args[i].slice(2)] = args[++i];
  else files.push(args[i]);
}

const kernelPath = files[0] ?? join(root, 'images', 'tinycore-vmlinuz');
const initrdPath = files[1] ?? null;
const maxSlices = Number(flags.slices ?? 4000);
// sizes may be given as 512M, 8G, ... with no upper bound
const parseSize = (v, d) => {
  if (!v) return d;
  const m = /^(\d+(?:\.\d+)?)\s*([kmgtKMGT]?)i?[bB]?$/.exec(String(v).trim());
  if (!m) throw new Error(`cannot parse size ${v}`);
  const mult = { '': 1, k: 1024, m: 1024 ** 2, g: 1024 ** 3, t: 1024 ** 4 };
  return Math.round(Number(m[1]) * mult[m[2].toLowerCase()]);
};
const ramSize = parseSize(flags.ram, 256 * 1024 * 1024);
const cmdline = flags.cmdline ??
  'console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 loglevel=7 nokaslr';

const emu = new Emulator({ ramSize, sliceSize: 2_000_000 });
await emu.init(readFileSync(join(root, 'build', 'cpu.wasm')));

let line = '';
let bytes = 0;
emu.onSerial = (b) => {
  bytes++;
  const ch = String.fromCharCode(b);
  if (ch === '\n') { console.log('| ' + line); line = ''; }
  else if (ch !== '\r') line += ch;
};

const kernel = new Uint8Array(readFileSync(kernelPath));
const initrd = initrdPath ? new Uint8Array(readFileSync(initrdPath)) : null;

const hddSize = parseSize(flags.hdd, 0);
const info = emu.bootLinux({ kernel, initrd, cmdline, hddSize, hddName: 'ram0' });
if (hddSize) {
  console.log(`hdd      blank ${(hddSize / 2 ** 30).toFixed(1)} GiB RAM drive on ATA`);
}
console.log(`kernel   ${kernelPath}`);
console.log(`protocol ${info.setup.version >> 8}.${info.setup.version & 0xff}` +
            `  ${info.bits}-bit entry`);
console.log(`load     0x${info.loadAddr.toString(16)}  entry 0x${info.entry.toString(16)}` +
            `  init_size 0x${info.setup.initSize.toString(16)}`);
if (initrd) {
  console.log(`initrd   0x${info.initrdAddr.toString(16)} (${initrd.length} bytes)`);
}
console.log(`cmdline  ${info.cmdline}`);
console.log('--- serial console ---');

emu.onExit = (why) => console.log(`[exit: ${why}]`);

const t0 = Date.now();
let slices = 0;
let alive = true;
// Optional scripted input, injected once `--after` appears on the console.
const toType = flags.type ?? null;
const trigger = flags.after ?? '# ';
let typed = false;
let seen = '';
// Delivered between slices.  The run loop never yields, so a microtask queued
// here would only run once the whole boot had finished.
let pendingInput = null;
const prevSink = emu.onSerial;
emu.onSerial = (b) => {
  prevSink(b);
  if (toType && !typed) {
    seen = (seen + String.fromCharCode(b)).slice(-64);
    if (seen.includes(trigger)) {
      typed = true;
      pendingInput = toType.replace(/\\n/g, '\n');
    }
  }
};
for (; slices < maxSlices && alive; slices++) {
  if (pendingInput !== null) { emu.sendInput(pendingInput); pendingInput = null; }
  alive = emu.step();
}
if (line) console.log('| ' + line);

const s = emu.stats;
const secs = (Date.now() - t0) / 1000;
console.log('--- stopped ---');
console.log(`instructions ${s.instructions.toLocaleString()} in ${secs.toFixed(1)}s ` +
            `(${(s.instructions / secs / 1e6).toFixed(1)} MIPS)`);
console.log(`rip 0x${s.rip.toString(16)}  mode ${s.mode}  cpl ${s.cpl}  ` +
            `halted ${s.halted}  serial bytes ${bytes}`);

// Dump the bytes at the faulting instruction, which is usually enough to
// identify an opcode the core does not implement.
const m = emu.machine;
console.log(`last exception vector ${m.stateU32[0xc8 / 4]} ` +
            `err 0x${BigInt.asUintN(64, m.stateI64[0xd0 / 8]).toString(16)}`);
const pa = m.translate(s.rip);
if (pa !== null) {
  const b = m.readBytes(Number(pa), 16);
  console.log('bytes at rip: ' + [...b].map(x => x.toString(16).padStart(2, '0')).join(' '));
} else {
  console.log('rip is not mapped');
}

const idx = m.exports.cpl_trace_index();
console.log('recent privilege changes (oldest first):');
for (let i = Math.max(0, idx - 12); i < idx; i++) {
  console.log(`  at 0x${m.exports.cpl_trace_rip(i).toString(16)}  ` +
              `cpl ${m.exports.cpl_trace_old(i)} -> ${m.exports.cpl_trace_new(i)}`);
}
