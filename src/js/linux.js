// ---------------------------------------------------------------------------
//  Linux/x86 boot protocol loader.
//
//  A bzImage carries a "setup" header at offset 0x1F1 of its first sector.
//  Rather than emulate the real-mode setup code (which wants BIOS services we
//  do not provide), this uses the 64-bit entry point: the kernel is placed at
//  its preferred load address, a boot_params page is filled in, page tables
//  and a GDT are built, and control enters at code32_start + 0x200 in long
//  mode.  This is the same path a modern bootloader takes.
//
//  Reference: Documentation/arch/x86/boot.rst in the kernel tree.
// ---------------------------------------------------------------------------

import { CS, SS, DS, ES, FS, GS, RSI, Machine } from './machine.js';

// physical layout chosen for the guest
export const BOOT_PARAMS = 0x0001_0000;   // zero page
export const CMDLINE     = 0x0002_0000;
export const GDT_PA      = 0x0003_0000;
export const PML4_PA     = 0x0004_0000;   // 4 pages: PML4, PDPT, PD0..PD3
export const E820_MAX    = 128;

export function parseSetupHeader(img) {
  const dv = new DataView(img.buffer, img.byteOffset, img.byteLength);
  const u8 = (o) => img[o];
  const u16 = (o) => dv.getUint16(o, true);
  const u32 = (o) => dv.getUint32(o, true);

  const magic = u32(0x202);
  if (magic !== 0x53726448) {              // "HdrS"
    throw new Error('not a Linux bzImage (missing HdrS magic)');
  }
  let setupSects = u8(0x1f1);
  if (setupSects === 0) setupSects = 4;

  return {
    setupSects,
    version: u16(0x206),
    loadflags: u8(0x211),
    codeSize: u32(0x214),                  // code32_start from the image
    relocatableKernel: u8(0x234) !== 0,
    minAlignment: u8(0x235),
    xloadflags: u16(0x236),
    cmdlineSize: u32(0x238),
    payloadOffset: u32(0x248),
    payloadLength: u32(0x24c),
    prefAddress: dv.getBigUint64(0x258, true),
    initSize: u32(0x260),
    handoverOffset: u32(0x264),
    kernelOffset: (setupSects + 1) * 512,  // where the protected-mode kernel starts
  };
}

// Build a flat GDT with 64-bit code and data, matching what the kernel expects
// to already be loaded on entry (boot.rst: __BOOT_CS = 0x10, __BOOT_DS = 0x18).
function buildGdt(m) {
  m.wr64(GDT_PA + 0x00, 0n);
  m.wr64(GDT_PA + 0x08, 0n);
  m.wr64(GDT_PA + 0x10, 0x00af9a000000ffffn);   // 0x10 code64
  m.wr64(GDT_PA + 0x18, 0x00cf92000000ffffn);   // 0x18 data
  m.setGdtr(GDT_PA, 0x1f);
}

// Identity map `gib` GiB with 2 MiB pages.
function buildPageTables(m, gib = 4) {
  const PDPT = PML4_PA + 0x1000;
  const PD0 = PML4_PA + 0x2000;

  for (let i = 0; i < 0x6000; i += 8) m.wr64(PML4_PA + i, 0n);

  m.wr64(PML4_PA, BigInt(PDPT | 3));
  for (let g = 0; g < gib; g++) {
    const pd = PD0 + g * 0x1000;
    m.wr64(PDPT + g * 8, BigInt(pd | 3));
    for (let i = 0; i < 512; i++) {
      const addr = BigInt(g) * 0x40000000n + BigInt(i) * 0x200000n;
      m.wr64(pd + i * 8, addr | 0x83n);          // present, writable, 2 MiB
    }
  }
  return PML4_PA;
}

// The zero page: only the fields the early kernel actually reads.
function buildBootParams(m, hdr, { cmdline, initrdAddr, initrdSize, ramSize, memoryMap }) {
  for (let i = 0; i < 0x1000; i += 8) m.wr64(BOOT_PARAMS + i, 0n);

  // copy the setup header (0x1f1..0x268) verbatim, then patch it
  const img = hdr.image;
  for (let o = 0x1f1; o < 0x268; o++) m.wr8(BOOT_PARAMS + o, img[o]);

  const s = hdr.setup;
  m.wr8(BOOT_PARAMS + 0x210, 0xff);                 // type_of_loader: unknown/custom
  m.wr8(BOOT_PARAMS + 0x211, s.loadflags | 0x80);   // KEEP_SEGMENTS, LOADED_HIGH
  m.wr32(BOOT_PARAMS + 0x228, CMDLINE);             // cmd_line_ptr
  m.wr32(BOOT_PARAMS + 0x218, initrdAddr);          // ramdisk_image
  m.wr32(BOOT_PARAMS + 0x21c, initrdSize);          // ramdisk_size
  m.wr32(BOOT_PARAMS + 0x22c, 0x7fffffff);          // initrd_addr_max
  m.wr32(BOOT_PARAMS + 0x224, 0xde00);              // heap_end_ptr
  m.wr8(BOOT_PARAMS + 0x226, 0);                    // ext_loader_ver
  m.wr8(BOOT_PARAMS + 0x227, 0);                    // ext_loader_type

  // command line
  const bytes = new TextEncoder().encode(cmdline);
  for (let i = 0; i < bytes.length; i++) m.wr8(CMDLINE + i, bytes[i]);
  m.wr8(CMDLINE + bytes.length, 0);

  // ---- E820 memory map ----
  //  entry layout: u64 addr, u64 size, u32 type
  const entries = memoryMap ?? [
    { base: 0x0000_0000, size: 0x0009_fc00, type: 1 },
    { base: 0x0009_fc00, size: 0x0000_0400, type: 2 },
    { base: 0x000f_0000, size: 0x0001_0000, type: 2 },
    { base: 0x0010_0000, size: ramSize - 0x0010_0000, type: 1 },
  ];
  let off = 0x2d0;
  for (const e of entries) {
    m.wr64(BOOT_PARAMS + off, BigInt(e.base));
    m.wr64(BOOT_PARAMS + off + 8, BigInt(e.size));
    m.wr32(BOOT_PARAMS + off + 16, e.type);
    off += 20;
  }
  m.wr8(BOOT_PARAMS + 0x1e8, entries.length);             // e820_entries

  // no EFI, no EDD, no video: screen_info says "serial only"
  m.wr8(BOOT_PARAMS + 0x00, 0);        // orig_x
  m.wr8(BOOT_PARAMS + 0x01, 0);        // orig_y
  m.wr16(BOOT_PARAMS + 0x04, 0);       // ext_mem_k
  m.wr8(BOOT_PARAMS + 0x06, 0);        // orig_video_page
  m.wr8(BOOT_PARAMS + 0x07, 0xff);     // orig_video_mode: no display
  m.wr8(BOOT_PARAMS + 0x0e, 0);        // orig_video_lines
  m.wr8(BOOT_PARAMS + 0x0f, 0);        // orig_video_cols
  m.wr16(BOOT_PARAMS + 0x1fa, 0xffff); // vid_mode = VIDEO_CURRENT_MODE
}

/**
 * Load a bzImage (and optional initrd) and leave the CPU ready to run.
 * Returns a description of what was placed where.
 */
export function bootLinux(m, {
  kernel,
  initrd = null,
  cmdline = 'console=ttyS0 earlyprintk=serial,ttyS0,115200 nokaslr',
  memoryMap = null,
} = {}) {
  const setup = parseSetupHeader(kernel);

  if (setup.version < 0x0206) {
    throw new Error(
      `boot protocol ${(setup.version >> 8)}.${setup.version & 0xff} is too old`);
  }

  // XLF_KERNEL_64 tells us whether a 64-bit entry point exists at all.
  // 32-bit kernels are entered in protected mode with paging off instead.
  const has64 = (setup.xloadflags & 1) !== 0;

  // Where the protected-mode kernel goes.  Relocatable kernels accept the
  // preferred address; everything else must land exactly where it was linked.
  let loadAddr = Number(setup.prefAddress);
  if (!loadAddr) loadAddr = 0x100000;
  if (loadAddr + setup.initSize > m.ramSize) {
    throw new Error('not enough guest RAM for this kernel');
  }

  const body = kernel.subarray(setup.kernelOffset);
  m.writeBytes(loadAddr, body);

  // initrd goes as high as it fits, page aligned
  const usableTop = memoryMap
    ? memoryMap.filter((e) => e.type === 1).reduce((a, e) => Math.max(a, e.base + e.size), 0)
    : m.ramSize;

  let initrdAddr = 0, initrdSize = 0;
  if (initrd && initrd.length) {
    initrdSize = initrd.length;
    initrdAddr = (usableTop - initrdSize - 0x100000) & ~0xfff;
    if (initrdAddr < loadAddr + setup.initSize) {
      throw new Error('not enough guest RAM for this initrd');
    }
    m.writeBytes(initrdAddr, initrd);
  }

  buildBootParams(m, { setup, image: kernel },
                  { cmdline, initrdAddr, initrdSize, ramSize: m.ramSize, memoryMap });
  buildGdt(m);

  m.reset();
  m.setGdtr(GDT_PA, 0x1f);
  m.flags = 0x2;                           // interrupts disabled
  m.setReg(4, 0x8000);                     // scratch stack; the kernel sets its own

  let entry;
  if (has64) {
    // boot.rst, "64-bit BOOT PROTOCOL": long mode with paging on, a flat GDT,
    // interrupts off, RSI at boot_params, entry 0x200 past the load address.
    const cr3 = buildPageTables(m, 4);
    m.setCR(4, 0x20);                      // PAE
    m.setCR(3, cr3);
    m.setEfer(0x500);                      // LME | LMA
    m.setCR(0, 0x80000011);                // PG | ET | PE
    m.setSeg(CS, 0x10, 0, -1, Machine.segAttr({ code: true, long: true }));
    for (const s of [SS, DS, ES, FS, GS]) {
      m.setSeg(s, 0x18, 0, -1, Machine.segAttr({ db: true }));
    }
    entry = loadAddr + 0x200;
  } else {
    // boot.rst, "32-bit BOOT PROTOCOL": protected mode, paging off, flat 4 GiB
    // descriptors, ESI at boot_params, entry exactly at the load address.
    m.setCR(0, 0x11);                      // PE | ET, no paging
    m.setSeg(CS, 0x10, 0, -1, Machine.segAttr({ code: true, db: true }));
    for (const s of [SS, DS, ES, FS, GS]) {
      m.setSeg(s, 0x18, 0, -1, Machine.segAttr({ db: true }));
    }
    m.setReg(3, 0);                        // EBX = 0
    m.setReg(5, 0);                        // EBP = 0
    m.setReg(7, 0);                        // EDI = 0
    entry = loadAddr;
  }

  m.setReg(RSI, BOOT_PARAMS);
  m.rip = entry;

  return {
    loadAddr,
    entry,
    bits: has64 ? 64 : 32,
    setup,
    initrdAddr,
    initrdSize,
    cmdline,
    bootParams: BOOT_PARAMS,
  };
}
