// Shared test helpers: build a minimal long-mode environment and run code.
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { Machine, CS, SS, DS, ES, FS, GS, SEG_CODE64, SEG_DATA32 } from '../src/js/machine.js';

const here = dirname(fileURLToPath(import.meta.url));
export const root = join(here, '..');

export function assemble(name, base = 0) {
  const src = join(here, 'asm', `${name}.s`);
  const obj = join(root, 'build', `${name}.o`);
  execFileSync('clang', ['-target', 'x86_64-unknown-none', '-c', src, '-o', obj]);
  const bin = execFileSync(
    'python3', [join(here, 'elf2bin.py'), obj, '0x' + base.toString(16)],
    { maxBuffer: 1 << 26, encoding: 'buffer' });
  return new Uint8Array(bin);
}

export async function newMachine(opts = {}) {
  const wasm = readFileSync(join(root, 'build', 'cpu.wasm'));
  const m = new Machine({ ramSize: opts.ramSize ?? 64 * 1024 * 1024 });
  await m.load(wasm);
  return m;
}

// Identity map the low 1 GiB with 2 MiB pages and switch the CPU to long mode.
export const PML4_PA = 0x70000;
export const GDT_PA = 0x60000;

// A GDT has to exist in guest memory even when the host seeds the segment
// caches directly, because interrupt delivery reloads CS from it.
function buildGdt(m) {
  m.wr64(GDT_PA + 0x00, 0n);
  m.wr64(GDT_PA + 0x08, 0x00AF9A000000FFFFn);   // 0x08 code64, L=1
  m.wr64(GDT_PA + 0x10, 0x00CF92000000FFFFn);   // 0x10 data
  m.setGdtr(GDT_PA, 0x17);
}

export function setupLongMode(m, { entry = 0x100000, stack = 0x8000 } = {}) {
  const PDPT = PML4_PA + 0x1000;
  const PD = PML4_PA + 0x2000;
  buildGdt(m);

  m.wr64(PML4_PA, BigInt(PDPT | 0x3));           // present + writable
  m.wr64(PDPT, BigInt(PD | 0x3));
  for (let i = 0; i < 512; i++) {
    m.wr64(PD + i * 8, BigInt(i * 0x200000) | 0x83n);   // present, writable, 2 MiB page
  }

  m.setCR(3, PML4_PA);
  m.setCR(4, 0x20);                               // PAE
  m.setEfer(0x500);                               // LME | LMA
  m.setCR(0, 0x80000011);                         // PG | ET | PE

  m.setSeg(CS, 0x08, 0, -1, SEG_CODE64);
  for (const s of [SS, DS, ES, FS, GS]) m.setSeg(s, 0x10, 0, -1, SEG_DATA32);
  m.setEfer(0x500);
  m.rip = entry;
  m.setReg(4, stack);                             // RSP
  return m;
}

// Collect bytes written to the debug port 0xE9.
export function captureDebugPort(m) {
  const out = [];
  const prevW = m.ioWrite;
  m.ioWrite = (port, size, val) => {
    if (port === 0xe9) { out.push(val & 0xff); return; }
    prevW(port, size, val);
  };
  return out;
}
