// ---------------------------------------------------------------------------
//  A BIOS implemented in the host rather than in guest code.
//
//  The ROM area contains nothing but trampolines: for interrupt vector v the
//  four bytes at F000:v*4 are
//
//      E6 FA     out 0xFA, al      <- traps into this file
//      CF        iret
//      90        nop
//
//  The OUT is register-preserving, and the vector is recovered from the return
//  address, so a handler here sees the guest's registers exactly as the caller
//  left them.  Results go back through the register file, and the carry flag is
//  written into the FLAGS image the IRET is about to pop.
// ---------------------------------------------------------------------------

import { buildAcpiTables } from './acpi.js';
import { FONT_8X16, FONT_HEIGHT } from './font.js';
import { EGA_DAC, DEFAULT_DAC } from './vga.js';
import { Disk, DISK_CDROM, DISK_FLOPPY, DISK_HDD, SliceStore, parseElTorito, NEED_DATA }
  from './disk.js';

export const BIOS_PORT = 0xfa;
export const ROM_SEG = 0xf000;
export const ROM_BASE = 0xf0000;
export const BOOT_VECTOR = 0x100;          // pseudo-vector for "start booting"

const BDA = 0x400;

// The extended BIOS data area: the last KiB of conventional memory, already
// reserved in the E820 map.  The PS/2 mouse interface keeps its state here, at
// the offsets other BIOSes use, because the INT 74h handler in the ROM has to
// read what INT 15h AH=C2h set up.
const EBDA_SEG = 0x9fc0;
const EBDA_MOUSE_HANDLER = 0x22;     // far pointer the driver installed (C207h)
const EBDA_MOUSE_INDEX = 0x26;       // bytes of the current packet so far
const EBDA_MOUSE_FLAGS = 0x27;       // bit 7 enabled (C200h), bits 0-2 packet size
const EBDA_MOUSE_DATA = 0x28;        // the packet

// ROM-resident data the VBE calls hand out far pointers to
const OEM_STRING_OFF = 0x700;
const MODE_LIST_OFF = 0x800;
// The 8x16 text font, 256 characters of sixteen bytes.  A guest that draws its
// own text asks for a far pointer to this and renders through it, so it has to
// live somewhere the guest can address in real mode.
const FONT_OFF = 0x1000;

// Hardware interrupt handlers are real code in the ROM rather than traps into
// this file.  They acknowledge the interrupt controller and read the keyboard
// with OUT and IN, so whatever stands between the guest and the hardware sees
// them -- under Windows 95, VPICD's virtual PIC and VKD's virtual keyboard.
// A host-side EOI went straight to the real PIC: the DOS session never
// acknowledged its virtual timer interrupt, VPICD never sent it another, and
// every event waiting for it to leave the interrupt waited for good.
const IRQ_CODE_OFF = 0x500;

const IRQ0_HANDLER = [                // INT 08h, the timer
  0x1e,                               //   push ds
  0x50,                               //   push ax
  0xb8, 0x40, 0x00,                   //   mov  ax, 0x40
  0x8e, 0xd8,                         //   mov  ds, ax
  0x83, 0x06, 0x6c, 0x00, 0x01,       //   add  word [0x6c], 1     ticks since midnight
  0x83, 0x16, 0x6e, 0x00, 0x00,       //   adc  word [0x6e], 0
  0x83, 0x3e, 0x6e, 0x00, 0x18,       //   cmp  word [0x6e], 0x18  a day is 0x1800b0
  0x72, 0x15,                         //   jb   .hook
  0x81, 0x3e, 0x6c, 0x00, 0xb0, 0x00, //   cmp  word [0x6c], 0xb0
  0x72, 0x0d,                         //   jb   .hook
  0x31, 0xc0,                         //   xor  ax, ax
  0xa3, 0x6c, 0x00,                   //   mov  [0x6c], ax
  0xa3, 0x6e, 0x00,                   //   mov  [0x6e], ax
  0xc6, 0x06, 0x70, 0x00, 0x01,       //   mov  byte [0x70], 1     midnight passed
  0xcd, 0x1c,                         // .hook: int 0x1c           the user tick hook
  0xb0, 0x20,                         //   mov  al, 0x20
  0xe6, 0x20,                         //   out  0x20, al           EOI
  0x58,                               //   pop  ax
  0x1f,                               //   pop  ds
  0xcf,                               //   iret
];

// Keys reach the BIOS buffer from the host as they are pressed; this only has
// to take the byte off the controller and acknowledge.
const IRQ1_HANDLER = [                // INT 09h, the keyboard
  0x50,                               //   push ax
  0xe4, 0x60,                         //   in   al, 0x60
  0xb0, 0x20,                         //   mov  al, 0x20
  0xe6, 0x20,                         //   out  0x20, al
  0x58,                               //   pop  ax
  0xcf,                               //   iret
];

// IRQ 14 and 15, the ATA channels.  Real-mode disk drivers do not poll the
// controller: they start a command and wait for bit 7 of the byte at 40:8E,
// which this is what sets.
const IRQ_DISK_HANDLER = [            // INT 76h and 77h
  0x1e,                               //   push ds
  0x50,                               //   push ax
  0xb8, 0x40, 0x00,                   //   mov  ax, 0x40
  0x8e, 0xd8,                         //   mov  ds, ax
  0x80, 0x0e, 0x8e, 0x00, 0x80,       //   or   byte [0x8e], 0x80
  0xb0, 0x20,                         //   mov  al, 0x20
  0xe6, 0xa0,                         //   out  0xa0, al
  0xe6, 0x20,                         //   out  0x20, al
  0x58,                               //   pop  ax
  0x1f,                               //   pop  ds
  0xcf,                               //   iret
];

// IRQ 12, the PS/2 mouse: the BIOS half of INT 15h AH=C2h.  Each interrupt
// brings one byte; once a packet is complete, and if the driver has enabled
// reporting and installed a handler, the handler is far-called with the
// status, X, Y and Z words on the stack, as IBM specified.  Windows 95's
// mouse driver works through this.  State lives in the EBDA.
const IRQ12_HANDLER = [               // INT 74h
  0x1e,                               //   push ds
  0x06,                               //   push es
  0x60,                               //   pusha
  0xb8, 0x40, 0x00,                   //   mov  ax, 0x40
  0x8e, 0xd8,                         //   mov  ds, ax
  0x8e, 0x1e, 0x0e, 0x00,             //   mov  ds, [0x0e]          the EBDA
  0xe4, 0x60,                         //   in   al, 0x60
  0x31, 0xdb,                         //   xor  bx, bx
  0x8a, 0x1e, 0x26, 0x00,             //   mov  bl, [0x26]          bytes so far
  0x80, 0xe3, 0x07,                   //   and  bl, 7
  0x75, 0x04,                         //   jnz  .store
  0xa8, 0x08,                         //   test al, 8               a first byte has bit 3
  0x74, 0x40,                         //   jz   .eoi                set; drop it if not
  0x88, 0x47, 0x28,                   // .store: mov [bx+0x28], al
  0x43,                               //   inc  bx
  0xa0, 0x27, 0x00,                   //   mov  al, [0x27]
  0x24, 0x07,                         //   and  al, 7               packet size
  0x38, 0xc3,                         //   cmp  bl, al
  0x72, 0x2f,                         //   jb   .partial
  0xc6, 0x06, 0x26, 0x00, 0x00,       //   mov  byte [0x26], 0
  0xf6, 0x06, 0x27, 0x00, 0x80,       //   test byte [0x27], 0x80   reporting enabled?
  0x74, 0x27,                         //   jz   .eoi
  0xa1, 0x22, 0x00,                   //   mov  ax, [0x22]          and a handler?
  0x0b, 0x06, 0x24, 0x00,             //   or   ax, [0x24]
  0x74, 0x1e,                         //   jz   .eoi
  0x30, 0xe4,                         //   xor  ah, ah
  0xa0, 0x28, 0x00, 0x50,             //   mov  al, [0x28]; push ax  status
  0xa0, 0x29, 0x00, 0x50,             //   mov  al, [0x29]; push ax  X
  0xa0, 0x2a, 0x00, 0x50,             //   mov  al, [0x2a]; push ax  Y
  0x30, 0xc0, 0x50,                   //   xor  al, al; push ax      Z
  0xff, 0x1e, 0x22, 0x00,             //   call far [0x22]
  0x83, 0xc4, 0x08,                   //   add  sp, 8
  0xeb, 0x04,                         //   jmp  .eoi
  0x88, 0x1e, 0x26, 0x00,             // .partial: mov [0x26], bl
  0xb0, 0x20,                         // .eoi: mov al, 0x20
  0xe6, 0xa0,                         //   out  0xa0, al
  0xe6, 0x20,                         //   out  0x20, al
  0x61,                               //   popa
  0x07,                               //   pop  es
  0x1f,                               //   pop  ds
  0xcf,                               //   iret
];

// Every other line still has to be acknowledged.  Leaving one in service
// blocks it and everything below it from then on.
const EOI_MASTER = [0x50, 0xb0, 0x20, 0xe6, 0x20, 0x58, 0xcf];
const EOI_BOTH = [0x50, 0xb0, 0x20, 0xe6, 0xa0, 0xe6, 0x20, 0x58, 0xcf];

const IRQ_HANDLERS = [
  [[0x08], IRQ0_HANDLER],
  [[0x09], IRQ1_HANDLER],
  [[0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f], EOI_MASTER],
  [[0x70, 0x71, 0x72, 0x73, 0x75], EOI_BOTH],
  [[0x74], IRQ12_HANDLER],
  [[0x76, 0x77], IRQ_DISK_HANDLER],
];

// ---- video from ROM code ---------------------------------------------------
//  Under Windows 95 a DOS box is a virtual-8086 machine, and its VDD keeps a
//  copy of that machine's VGA registers, learnt from the port writes it traps.
//  A mode set or cursor move made from this file went straight to the
//  hardware: a windowed MS-DOS prompt switched the real screen to text, and
//  VDD, its copy still all zeros, took the row length to be 0 on the first
//  scroll and marked a million pages dirty -- through VKD's data and on until
//  VMM faulted.  From a virtual-8086 machine these two therefore program the
//  VGA with OUTs, as a VGA BIOS would; the display follows the registers.
//  The source is src/asm/vga_rom.s.
const VGA_ROM_OFF = 0x2000;
const VGA_PARAMS_OFF = 0x2100;        // a 69-byte block per mode
const VGA_DAC_OFF = 0x2300;           // the EGA and 256-colour DAC tables

const VGA_SET_MODE = [                // AX = parameter block; bit 15: keep memory
  0x1e,                             //  push  ds
  0x06,                             //  push  es
  0x56,                             //  push  si
  0x57,                             //  push  di
  0x52,                             //  push  dx
  0x51,                             //  push  cx
  0x53,                             //  push  bx
  0x50,                             //  push  ax
  0x80, 0xe4, 0x7f,                 //  and  ah, 0x7f
  0x89, 0xc6,                       //  mov  si, ax
  0x0e,                             //  push  cs
  0x1f,                             //  pop  ds
  0xfc,                             //  cld
  0xba, 0xc4, 0x03,                 //  mov  dx, 0x3c4
  0xb8, 0x00, 0x01,                 //  mov  ax, 0x0100   sequencer: synchronous reset
  0xef,                             //  out  dx, ax
  0xba, 0xc2, 0x03,                 //  mov  dx, 0x3c2
  0xac,                             //  lodsb  miscellaneous output
  0xee,                             //  out  dx, al
  0xba, 0xc4, 0x03,                 //  mov  dx, 0x3c4
  0xb3, 0x01,                       //  mov  bl, 1
  0x88, 0xd8,                       // .1: mov  al, bl
  0xee,                             //  out  dx, al
  0x42,                             //  inc  dx
  0xac,                             //  lodsb
  0xee,                             //  out  dx, al
  0x4a,                             //  dec  dx
  0xfe, 0xc3,                       //  inc  bl
  0x80, 0xfb, 0x05,                 //  cmp  bl, 5
  0x72, 0xf2,                       //  jb   1b
  0xb8, 0x00, 0x03,                 //  mov  ax, 0x0300   end the reset
  0xef,                             //  out  dx, ax
  0xba, 0xd4, 0x03,                 //  mov  dx, 0x3d4
  0xb8, 0x11, 0x00,                 //  mov  ax, 0x0011   unlock CRTC 0-7
  0xef,                             //  out  dx, ax
  0x30, 0xdb,                       //  xor  bl, bl
  0x88, 0xd8,                       // .2: mov  al, bl
  0xee,                             //  out  dx, al
  0x42,                             //  inc  dx
  0xac,                             //  lodsb
  0xee,                             //  out  dx, al
  0x4a,                             //  dec  dx
  0xfe, 0xc3,                       //  inc  bl
  0x80, 0xfb, 0x19,                 //  cmp  bl, 25
  0x72, 0xf2,                       //  jb   2b
  0xba, 0xda, 0x03,                 //  mov  dx, 0x3da
  0xec,                             //  in   al, dx   attribute flip-flop to index
  0xba, 0xc0, 0x03,                 //  mov  dx, 0x3c0
  0x30, 0xdb,                       //  xor  bl, bl
  0x88, 0xd8,                       // .3: mov  al, bl
  0xee,                             //  out  dx, al
  0xac,                             //  lodsb
  0xee,                             //  out  dx, al
  0xfe, 0xc3,                       //  inc  bl
  0x80, 0xfb, 0x14,                 //  cmp  bl, 20
  0x72, 0xf4,                       //  jb   3b
  0xb0, 0x20,                       //  mov  al, 0x20   palette done: display on
  0xee,                             //  out  dx, al
  0xba, 0xce, 0x03,                 //  mov  dx, 0x3ce
  0x30, 0xdb,                       //  xor  bl, bl
  0x88, 0xd8,                       // .4: mov  al, bl
  0xee,                             //  out  dx, al
  0x42,                             //  inc  dx
  0xac,                             //  lodsb
  0xee,                             //  out  dx, al
  0x4a,                             //  dec  dx
  0xfe, 0xc3,                       //  inc  bl
  0x80, 0xfb, 0x09,                 //  cmp  bl, 9
  0x72, 0xf2,                       //  jb   4b
  0xad,                             //  lodsw  the DAC
  0x89, 0xc1,                       //  mov  cx, ax
  0xad,                             //  lodsw
  0x56,                             //  push  si
  0x89, 0xc6,                       //  mov  si, ax
  0xba, 0xc8, 0x03,                 //  mov  dx, 0x3c8
  0x30, 0xc0,                       //  xor  al, al
  0xee,                             //  out  dx, al
  0x42,                             //  inc  dx
  0xf3, 0x6e,                       //  rep  outsb
  0x5e,                             //  pop  si
  0xad,                             //  lodsw  video memory
  0x8e, 0xc0,                       //  mov  es, ax
  0xad,                             //  lodsw
  0x89, 0xc1,                       //  mov  cx, ax
  0xad,                             //  lodsw
  0x5b,                             //  pop  bx   the caller's AX: bit 15 keeps memory
  0xf6, 0xc7, 0x80,                 //  test  bh, 0x80
  0x75, 0x04,                       //  jnz  5f
  0x31, 0xff,                       //  xor  di, di
  0xf3, 0xab,                       //  rep  stosw
  0x5b,                             // .5: pop  bx
  0x59,                             //  pop  cx
  0x5a,                             //  pop  dx
  0x5f,                             //  pop  di
  0x5e,                             //  pop  si
  0x07,                             //  pop  es
  0x1f,                             //  pop  ds
  0xcf,                             //  iret
];

const VGA_SET_CURSOR = [              // the cursor position, from the BDA
  0x1e,                             //  push  ds
  0x50,                             //  push  ax
  0x53,                             //  push  bx
  0x51,                             //  push  cx
  0x52,                             //  push  dx
  0xb8, 0x40, 0x00,                 //  mov  ax, 0x40
  0x8e, 0xd8,                       //  mov  ds, ax
  0x8b, 0x16, 0x63, 0x00,           //  mov  dx, word [0x63]   CRTC port
  0x8a, 0x1e, 0x62, 0x00,           //  mov  bl, byte [0x62]   active page
  0x30, 0xff,                       //  xor  bh, bh
  0xd1, 0xe3,                       //  shl  bx, 1
  0x8a, 0x47, 0x51,                 //  mov  al, byte [bx + 0x51]   row
  0xf6, 0x26, 0x4a, 0x00,           //  mul  byte [0x4a]   * columns
  0x30, 0xed,                       //  xor  ch, ch
  0x8a, 0x4f, 0x50,                 //  mov  cl, byte [bx + 0x50]   + column
  0x01, 0xc8,                       //  add  ax, cx
  0x8b, 0x0e, 0x4e, 0x00,           //  mov  cx, word [0x4e]   + the page's start, in characters
  0xd1, 0xe9,                       //  shr  cx, 1
  0x01, 0xc1,                       //  add  cx, ax
  0xb0, 0x0e,                       //  mov  al, 0x0e
  0x88, 0xec,                       //  mov  ah, ch
  0xef,                             //  out  dx, ax
  0xb0, 0x0f,                       //  mov  al, 0x0f
  0x88, 0xcc,                       //  mov  ah, cl
  0xef,                             //  out  dx, ax
  0x5a,                             //  pop  dx
  0x59,                             //  pop  cx
  0x5b,                             //  pop  bx
  0x58,                             //  pop  ax
  0x1f,                             //  pop  ds
  0xcf,                             //  iret
];

// The register values IBM's VGA BIOS loads, in the order the code above
// sends them: misc output, sequencer 1-4, CRTC 0-24, attribute 0-19, and
// graphics 0-8.  Then the DAC to load, the memory to clear and with what,
// and what the BIOS data area records about the mode.
const VGA_PARAMS = new Map([
  [0x03, {
    misc: 0x67, seq: [0x00, 0x03, 0x00, 0x02],
    crtc: [0x5f, 0x4f, 0x50, 0x82, 0x55, 0x81, 0xbf, 0x1f, 0x00, 0x4f, 0x0d, 0x0e, 0x00,
           0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x28, 0x1f, 0x96, 0xb9, 0xa3, 0xff],
    attr: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07, 0x38, 0x39, 0x3a, 0x3b,
           0x3c, 0x3d, 0x3e, 0x3f, 0x0c, 0x00, 0x0f, 0x08],
    gc: [0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0e, 0x00, 0xff],
    dac: EGA_DAC, clear: [0xb800, 0x4000, 0x0720],
    cols: 80, rows: 25, charHeight: 16, pageSize: 0x1000,
  }],
  [0x12, {
    misc: 0xe3, seq: [0x01, 0x0f, 0x00, 0x06],
    crtc: [0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0x0b, 0x3e, 0x00, 0x40, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0xea, 0x8c, 0xdf, 0x28, 0x00, 0xe7, 0x04, 0xe3, 0xff],
    attr: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07, 0x38, 0x39, 0x3a, 0x3b,
           0x3c, 0x3d, 0x3e, 0x3f, 0x01, 0x00, 0x0f, 0x00],
    gc: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x0f, 0xff],
    dac: EGA_DAC, clear: [0xa000, 0x8000, 0x0000],
    cols: 80, rows: 30, charHeight: 16, pageSize: 0xa000,
  }],
  [0x13, {
    misc: 0x63, seq: [0x01, 0x0f, 0x00, 0x0e],
    crtc: [0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0xbf, 0x1f, 0x00, 0x41, 0x00, 0x00, 0x00,
           0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x28, 0x40, 0x96, 0xb9, 0xa3, 0xff],
    attr: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
           0x0c, 0x0d, 0x0e, 0x0f, 0x41, 0x00, 0x0f, 0x00],
    gc: [0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x05, 0x0f, 0xff],
    dac: DEFAULT_DAC, clear: [0xa000, 0x8000, 0x0000],
    cols: 40, rows: 25, charHeight: 8, pageSize: 0xfa00,
  }],
]);
[...VGA_PARAMS.values()].forEach((p, i) => { p.offset = VGA_PARAMS_OFF + i * 0x48; });

// registers, by the index the CPU core uses
const RAX = 0, RCX = 1, RDX = 2, RBX = 3, RSP = 4, RBP = 5, RSI = 6, RDI = 7;
const ES = 0, CS = 1, SS = 2, DS = 3;

/**
 * Guest memory as the code that called the BIOS sees it.
 *
 * In real mode that is physical memory behind the A20 gate.  A call from
 * virtual-8086 mode -- how Windows 95 and EMM386 reach the BIOS -- runs under
 * paging, so its addresses go through the guest's page tables just as the
 * CPU's would.  Taking them as physical only works where the monitor happens
 * to map memory one to one, and DOS buffers in upper memory are exactly where
 * it does not.
 */
class GuestMemory {
  constructor(bios) {
    this.bios = bios;
    this.m = bios.m;
    this.unmapped = 0;
  }

  /** Physical address of one linear byte, or null if nothing is there. */
  resolve(a, write) {
    if (!this.m.pagingOn) return this.bios.gateA20(a);
    let pa = this.m.translateFor(a, write);
    // A page the monitor has write-protected, to notice writes, cannot fault
    // from inside a BIOS call; the write lands anyway, as a DMA would.
    if (pa === null && write) pa = this.m.translateFor(a, false);
    if (pa === null && this.unmapped++ < 4) {
      this.bios.log(`linear 0x${a.toString(16)} is not mapped; access dropped`);
    }
    return pa;
  }

  rd8(a) { const pa = this.resolve(a, false); return pa === null ? 0xff : this.m.rd8(pa); }
  wr8(a, v) { const pa = this.resolve(a, true); if (pa !== null) this.m.wr8(pa, v & 0xff); }
  rd16(a) { return this.rd8(a) | (this.rd8(a + 1) << 8); }
  wr16(a, v) { this.wr8(a, v); this.wr8(a + 1, v >> 8); }
  rd32(a) { return (this.rd16(a) | (this.rd16(a + 2) << 16)) >>> 0; }
  wr32(a, v) { this.wr16(a, v); this.wr16(a + 2, v >>> 16); }
  rd64(a) { return BigInt(this.rd32(a)) | (BigInt(this.rd32(a + 4)) << 32n); }
  wr64(a, v) {
    v = BigInt(v);
    this.wr32(a, Number(v & 0xffffffffn));
    this.wr32(a + 4, Number((v >> 32n) & 0xffffffffn));
  }

  // Bulk transfers go a page at a time, since consecutive linear pages need
  // not be consecutive in physical memory.
  readBytes(a, len) {
    const out = new Uint8Array(len);
    for (let done = 0; done < len;) {
      const n = Math.min(len - done, 0x1000 - ((a + done) & 0xfff));
      const pa = this.resolve(a + done, false);
      if (pa !== null) out.set(this.m.readBytes(pa, n), done);
      done += n;
    }
    return out;
  }

  writeBytes(a, bytes) {
    for (let done = 0; done < bytes.length;) {
      const n = Math.min(bytes.length - done, 0x1000 - ((a + done) & 0xfff));
      const pa = this.resolve(a + done, true);
      if (pa !== null) this.m.writeBytes(pa, bytes.subarray(done, done + n));
      done += n;
    }
  }
}

export class BIOS {
  constructor(emulator) {
    this.emu = emulator;
    this.m = emulator.machine;
    this.mem = new GuestMemory(this);
    this.disks = [];              // attached Disk objects
    this.bootDisk = null;
    this.elTorito = null;
    this.keyBuffer = [];          // {ascii, scan}
    this.e820 = [];
    this.log = () => {};
    // 80x25 colour, one floppy, a math coprocessor and a PS/2 mouse.  Bit 1
    // has to be set or a guest concludes there is no x87 and runs with
    // CR0.EM, which also turns every SSE instruction into #UD.  Bit 2 is the
    // mouse: Windows 95 looks for it here and, finding it clear, never probes
    // the mouse port at all.
    this.equipment = 0x0027;
    this.callCounts = new Map();  // vector -> times invoked, for diagnostics
  }

  /** Summary of which BIOS services the guest actually used. */
  get callSummary() {
    return [...this.callCounts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([v, n]) => `int ${v.toString(16)}: ${n}`)
      .join(', ');
  }

  attach(disk) {
    if (disk.kind === DISK_FLOPPY) {
      disk.driveNumber = this.disks.filter((d) => d.kind === DISK_FLOPPY).length;
    } else if (disk.kind === DISK_HDD) {
      disk.driveNumber = 0x80 + this.disks.filter((d) => d.kind === DISK_HDD).length;
    } else {
      disk.driveNumber = 0xe0 + this.disks.filter((d) => d.kind === DISK_CDROM).length;
    }
    this.disks.push(disk);
    return disk;
  }

  findDisk(drive) {
    return this.disks.find((d) => d.driveNumber === drive) ?? null;
  }

  // ---- guest register and memory access ---------------------------------
  r16(i) { return Number(this.m.getReg(i) & 0xffffn); }
  r8lo(i) { return Number(this.m.getReg(i) & 0xffn); }
  r8hi(i) { return Number((this.m.getReg(i) >> 8n) & 0xffn); }
  r32(i) { return Number(this.m.getReg(i) & 0xffffffffn); }

  setR16(i, v) {
    const cur = this.m.getReg(i);
    this.m.setReg(i, (cur & ~0xffffn) | BigInt(v & 0xffff));
  }
  setR8lo(i, v) {
    const cur = this.m.getReg(i);
    this.m.setReg(i, (cur & ~0xffn) | BigInt(v & 0xff));
  }
  setR8hi(i, v) {
    const cur = this.m.getReg(i);
    this.m.setReg(i, (cur & ~0xff00n) | (BigInt(v & 0xff) << 8n));
  }
  setR32(i, v) { this.m.setReg(i, BigInt(v >>> 0)); }

  segBase(s) { return Number(this.m.segBaseFast(s)); }

  // Physical addresses wrap at 1 MiB only while the A20 gate is off, as they
  // do for the CPU.  With it on, FFFF:0010 and up is the HMA -- where DOS=HIGH
  // puts itself, its disk buffers and the packets it hands INT 13h.  Always
  // wrapping read Windows 95's packets as zeros out of the interrupt table and
  // wrote its sectors over it.
  gateA20(addr) { return this.emu.io.a20 ? addr : addr - (addr & 0x100000); }

  // A segment:offset as the caller sees it.  This is a linear address, which
  // `this.mem` takes through paging and the A20 gate.
  linear(seg, off) { return this.segBase(seg) + (off & 0xffff); }

  // The IRET at the end of each stub restores FLAGS from the stack, so a
  // handler's carry flag has to be written there rather than into RFLAGS.
  setReturnCarry(set) {
    const addr = this.linear(SS, this.r16(RSP) + 4);
    let fl = this.mem.rd16(addr);
    fl = set ? (fl | 1) : (fl & ~1);
    this.mem.wr16(addr, fl);
  }

  setReturnZero(set) {
    const addr = this.linear(SS, this.r16(RSP) + 4);
    let fl = this.mem.rd16(addr);
    fl = set ? (fl | 0x40) : (fl & ~0x40);
    this.mem.wr16(addr, fl);
  }

  /**
   * Copy the ACPI tables into the option-ROM hole.  Anything newer than XP
   * refuses to boot without them, and the region is outside the E820 map, so
   * no guest will allocate over the top of them.
   */
  installAcpi() {
    if (this.acpiOptions === null) { this.log('[bios] ACPI tables disabled'); return; }
    const { bytes, base } = buildAcpiTables(this.acpiOptions ?? {});
    this.m.writeBytes(base, bytes);
    this.acpiBase = base;
    this.log(`[bios] ACPI tables at 0x${base.toString(16)} (${bytes.length} bytes)`);
  }

  // ---- ROM, IVT and BIOS data area --------------------------------------
  install(e820) {
    const m = this.m;
    this.e820 = e820;
    this.installAcpi();

    // trampolines for every vector plus the boot pseudo-vector
    for (let v = 0; v <= BOOT_VECTOR; v++) {
      const at = ROM_BASE + v * 4;
      m.wr8(at + 0, 0xe6);            // out imm8, al
      m.wr8(at + 1, BIOS_PORT);
      m.wr8(at + 2, 0xcf);            // iret
      m.wr8(at + 3, 0x90);            // nop
    }
    // the boot trampoline must not return
    m.wr8(ROM_BASE + BOOT_VECTOR * 4 + 2, 0xf4);   // hlt

    // reset vector: jmp far F000:0400 (the boot trampoline)
    m.wr8(0xffff0, 0xea);
    m.wr16(0xffff1, BOOT_VECTOR * 4);
    m.wr16(0xffff3, ROM_SEG);

    // The character generator, for guests that render text themselves rather
    // than writing into the text buffer.
    m.writeBytes(ROM_BASE + FONT_OFF, FONT_8X16);

    // interrupt vector table
    for (let v = 0; v < 256; v++) {
      m.wr16(v * 4 + 0, v * 4);
      m.wr16(v * 4 + 2, ROM_SEG);
    }
    // the hardware interrupts go to code of their own
    let at = IRQ_CODE_OFF;
    for (const [vectors, code] of IRQ_HANDLERS) {
      m.writeBytes(ROM_BASE + at, new Uint8Array(code));
      for (const v of vectors) m.wr16(v * 4, at);
      at += code.length;
    }

    // video from ROM code, with each mode's registers and DAC
    m.writeBytes(ROM_BASE + VGA_ROM_OFF, new Uint8Array([...VGA_SET_MODE, ...VGA_SET_CURSOR]));
    const dacAt = new Map([[EGA_DAC, VGA_DAC_OFF], [DEFAULT_DAC, VGA_DAC_OFF + 0x100]]);
    for (const [dac, off] of dacAt) m.writeBytes(ROM_BASE + off, dac);
    for (const p of VGA_PARAMS.values()) {
      const le = (v) => [v & 0xff, v >> 8];
      m.writeBytes(ROM_BASE + p.offset, new Uint8Array([
        p.misc, ...p.seq, ...p.crtc, ...p.attr, ...p.gc,
        ...le(p.dac.length), ...le(dacAt.get(p.dac)), ...p.clear.flatMap(le)]));
    }

    // BIOS data area
    for (let i = 0; i < 256; i += 2) m.wr16(BDA + i, 0);
    m.wr16(BDA + 0x00, 0x3f8);                 // COM1
    m.wr16(BDA + 0x10, this.equipment);
    // Conventional memory stops where the EBDA begins, as the E820 map says.
    m.wr16(BDA + 0x13, EBDA_SEG >> 6);         // conventional memory, KiB
    m.wr16(BDA + 0x0e, EBDA_SEG);
    for (let i = 0; i < 1024; i++) m.wr8(EBDA_SEG * 16 + i, 0);
    m.wr8(EBDA_SEG * 16, 1);                   // its size, KiB
    m.wr16(BDA + 0x1a, 0x1e);                  // keyboard buffer head
    m.wr16(BDA + 0x1c, 0x1e);                  // keyboard buffer tail
    m.wr16(BDA + 0x80, 0x1e);                  // buffer start
    m.wr16(BDA + 0x82, 0x3e);                  // buffer end
    m.wr8(BDA + 0x49, 0x03);                   // video mode 3 (80x25 colour)
    m.wr16(BDA + 0x4a, 80);                    // columns
    m.wr16(BDA + 0x4c, 4096);                  // regen buffer size
    m.wr8(BDA + 0x60, 14); m.wr8(BDA + 0x61, 13);   // cursor shape
    m.wr8(BDA + 0x62, 0);                      // active page
    m.wr16(BDA + 0x63, 0x3d4);                 // CRTC base
    m.wr8(BDA + 0x84, 24);                     // rows - 1
    m.wr16(BDA + 0x85, 16);                    // character height
    m.wr8(BDA + 0x75, this.disks.filter((d) => d.kind === DISK_HDD).length);

    this.programPic();

    // VBE data that callers receive far pointers to
    const oem = 'x64emu VGA\0';
    for (let i = 0; i < oem.length; i++) {
      m.wr8(ROM_BASE + OEM_STRING_OFF + i, oem.charCodeAt(i));
    }
    let p = ROM_BASE + MODE_LIST_OFF;
    for (const mode of (this.emu.vga?.vbeModes.keys() ?? [])) { m.wr16(p, mode); p += 2; }
    m.wr16(p, 0xffff);

    // a recognisable ROM signature and date
    const tag = '01/01/26';
    for (let i = 0; i < tag.length; i++) m.wr8(0xffff5 + i, tag.charCodeAt(i));
    m.wr8(0xffffe, 0xfc);                      // model byte: PC/AT
  }

  /**
   * Program the interrupt controllers the way POST does, so IRQ 0 lands on
   * INT 08h and IRQ 1 on INT 09h.
   *
   * A reset leaves the controller masking everything, which is what the
   * hardware does; it is POST that unmasks it again.  So this has to run after
   * every reset, not only the first -- otherwise a guest that reboots through
   * the reset vector comes back to a machine where the timer interrupt can
   * never be delivered, and anything waiting on the tick counter waits for
   * good.
   */
  programPic() {
    const pic = this.emu.io.pic;
    for (const [p8, base, isMaster] of [[0x20, 0x08, true], [0xa0, 0x70, false]]) {
      pic.io(p8, 1, 0x11, true);                 // ICW1: edge, cascade, ICW4
      pic.io(p8 + 1, 1, base, true);             // ICW2: vector base
      pic.io(p8 + 1, 1, isMaster ? 0x04 : 0x02, true);   // ICW3: cascade wiring
      pic.io(p8 + 1, 1, 0x01, true);             // ICW4: 8086 mode
      pic.io(p8 + 1, 1, 0x00, true);             // OCW1: unmask everything
    }
  }

  /** Point the CPU at the boot trampoline in real mode. */
  startBoot() {
    const m = this.m;
    m.reset();
    m.setSeg(CS, ROM_SEG, ROM_BASE, 0xffff, 0x1007);
    for (const s of [ES, SS, DS, 4, 5]) m.setSeg(s, 0, 0, 0xffff, 0x1003);
    m.rip = BOOT_VECTOR * 4;
    m.setReg(RSP, 0x7000);
    m.flags = 0x2;
  }

  // A store can report "not resident yet".  Rewinding past the two-byte OUT
  // makes the guest re-issue the same BIOS call once the data has arrived,
  // which lets an asynchronous source be serviced from a synchronous INT.
  retryLater() {
    this.m.rip = Number(this.m.rip) - 2;
    this.emu.ioWait = true;
  }

  // ---- the trap entry point ---------------------------------------------
  //  Called from the I/O bus when the guest writes to BIOS_PORT.
  handleTrap() {
    // RIP already points past the two-byte OUT
    const vector = (Number(this.m.rip) - 2) >> 2;
    this.callCounts.set(vector, (this.callCounts.get(vector) ?? 0) + 1);
    try {
      this.dispatch(vector);
    } catch (err) {
      this.log(`BIOS int ${vector.toString(16)} ah=${this.r8hi(RAX).toString(16)} ` +
               `failed: ${err.message}`);
      // Carry alone leaves a disk caller inspecting a stale status byte, and
      // bootmgr will retry such a call forever.  Report a definite error.
      if (vector === 0x13) {
        this.setR8hi(RAX, 0x01);
        this.mem.wr8(BDA + 0x74, 0x01);
      }
      this.setReturnCarry(true);
    }
  }

  dispatch(v) {
    switch (v) {
      case BOOT_VECTOR:
        // Reaching the boot vector again means the guest jumped to the reset
        // vector -- which is how DOS and Windows 95 reboot, rather than through
        // the keyboard controller.  The peripherals have to go back to
        // power-on, or the next system inherits a display in the old mode, a
        // stuck interrupt and a half-finished controller command.
        //
        // Once per attempt: a boot sector that is not resident yet re-enters
        // here through retryLater(), and resetting on every retry would stop
        // the boot ever completing.
        if (!this.bootResetDone) {
          this.bootResetDone = true;
          this.emu.resetPeripherals();
          // POST runs again too, and rebuilding the interrupt vector table is
          // the part that matters: the previous system hooked INT 13h, INT 16h
          // and the rest to handlers inside itself, and those hooks outlive the
          // reboot.  Leaving them in place sends the next boot sector into the
          // old kernel's code, which is long gone as far as it is concerned --
          // control wanders off into whatever is still in memory.
          this.install(this.e820);
        }
        return this.boot();
      case 0x10: return this.int10();
      case 0x11: return this.setR16(RAX, this.equipment);
      case 0x12: return this.setR16(RAX, this.mem.rd16(BDA + 0x13));
      case 0x13: return this.int13();
      case 0x15: return this.int15();
      case 0x16: return this.int16();
      case 0x14: return this.int14();
      case 0x17: return this.int17();
      case 0x1a: return this.int1a();
      case 0x18:
      case 0x19:
        // The bootstrap interrupt is a warm reboot: the guest expects to come
        // back to a machine in its power-on state, display included.
        this.emu.vga?.reset();
        return this.boot();
      case 0x1c: return;                    // user timer hook, nothing to do
      default:
        // A CPU exception vector reaching the BIOS means the guest faulted with
        // no handler of its own installed; report where, once.
        //
        // Vectors 0x10 to 0x1F are claimed by both the CPU and the BIOS -- INT
        // 14h and exception 20 are the same number -- so an unhandled one there
        // is far more likely to be a service this BIOS does not provide than a
        // fault, and calling it an exception sends the reader hunting for a CPU
        // bug that is not there.  Only the vectors the CPU alone uses are
        // reported that way.
        if (v < 0x10 && (this.faultReports ?? 0) < 3) {
          this.faultReports = (this.faultReports ?? 0) + 1;
          const sp = this.linear(SS, this.r16(RSP));
          const ip = this.mem.rd16(sp);
          const cs = this.mem.rd16(sp + 2);
          const fl = this.mem.rd16(sp + 4);
          const at = (cs << 4) + ip;
          const hex = (n, w) => n.toString(16).padStart(w, '0');
          const before = [...this.mem.readBytes(Math.max(0, at - 16), 16)]
            .map((b) => hex(b, 2)).join(' ');
          const after = [...this.mem.readBytes(at, 16)].map((b) => hex(b, 2)).join(' ');
          this.log(`exception 0x${hex(v, 2)} at ${hex(cs, 4)}:${hex(ip, 4)} ` +
                   `flags=${hex(fl, 4)} ` +
                   `cr0=${hex(Number(this.m.getCR(0)), 8)} mode=${this.m.mode}`);
          this.log(`  before: ${before}`);
          this.log(`  at:     ${after}`);
        }
        // Unclaimed vectors return with carry set, which most callers read as
        // "service not supported".
        this.setReturnCarry(true);
        return;
    }
  }

  // ---- INT 19h: load and enter the boot image ---------------------------
  boot() {
    const m = this.m;
    const disk = this.bootDisk ?? this.disks[0];
    if (!disk) {
      this.log('no bootable image attached');
      this.emu.io.shutdownRequested = true;
      return;
    }

    if (disk.kind === DISK_CDROM) return this.bootElTorito(disk);

    const sector = disk.read(0, 1);
    if (sector === null) return this.retryLater();
    if (!sector) { this.log('cannot read boot sector'); return; }
    if (sector[510] !== 0x55 || sector[511] !== 0xaa) {
      this.log(`no 0xAA55 signature on ${disk.name}; booting it anyway`);
    }
    for (let i = 0; i < 512; i++) m.wr8(0x7c00 + i, sector[i]);

    this.log(`booting ${disk.name} from its boot sector`);
    this.enter(0x0000, 0x7c00, disk.driveNumber);
  }

  bootElTorito(disk) {
    const et = parseElTorito(disk);
    if (et === NEED_DATA) return this.retryLater();
    if (!et) {
      this.log(`${disk.name} has no El Torito boot record`);
      this.emu.io.shutdownRequested = true;
      return;
    }
    this.elTorito = et;
    const count = et.sectorCount || 4;
    const bytes = count * 512;
    // The image is addressed in 2 KiB CD sectors but sized in 512-byte ones.
    const start = et.imageLba * 2048;
    const img = disk.store.readSync(start, bytes);
    if (img === null) return this.retryLater();
    if (!img) {
      this.log('El Torito boot image runs past the end of the image');
      return;
    }
    const seg = et.loadSegment;
    this.m.writeBytes(seg * 16, img);

    this.log(`El Torito: ${count} sectors from LBA ${et.imageLba} to ` +
             `${seg.toString(16)}:0000 (media type ${et.mediaType})`);

    if (et.mediaType === 0) {
      // No emulation: enter at the load segment with DL naming the CD.
      this.enter(seg, 0, disk.driveNumber);
    } else {
      this.enter(0x0000, 0x7c00, this.installEmulatedDrive(disk, et));
    }
  }

  /**
   * El Torito floppy and hard disk emulation.
   *
   * Only the first sector is loaded to 0x7C00.  Everything after it the boot
   * code reads for itself through INT 13h, so the boot image has to be present
   * as a drive in its own right -- otherwise that first read fails and DOS
   * reports a disk I/O error.
   */
  installEmulatedDrive(cd, et) {
    const FLOPPY_BYTES = { 1: 1200 * 1024, 2: 1440 * 1024, 3: 2880 * 1024 };
    const start = et.imageLba * 2048;
    const size = FLOPPY_BYTES[et.mediaType] ?? Math.max(0, cd.store.size - start);
    const floppy = et.mediaType !== 4;
    const emulated = new Disk(new SliceStore(cd.store, start, size),
                              floppy ? DISK_FLOPPY : DISK_HDD,
                              `${cd.name} (El Torito)`);
    const drive = floppy ? 0x00 : 0x80;
    // A reboot runs this again, so any drive left over from the previous boot
    // has to go first.  Accumulating them pushed the real drives up a number
    // each time round and handed the guest a different disk than the one it
    // booted from.
    this.disks = this.disks.filter((d) => !d.elTorito);
    emulated.elTorito = true;
    // The emulated drive takes the boot drive number and anything already
    // there moves up, which is what a real BIOS does.
    for (const d of this.disks) {
      if (d.kind === emulated.kind && d.driveNumber >= drive) d.driveNumber++;
    }
    emulated.driveNumber = drive;
    this.disks.unshift(emulated);
    this.log(`El Torito: ${(size / 1024).toFixed(0)} KiB ` +
             `${floppy ? 'floppy' : 'hard disk'} emulated as drive 0x${drive.toString(16)}`);
    return drive;
  }

  enter(seg, off, drive) {
    const m = this.m;
    this.bootResetDone = false;          // the next boot resets again
    m.setSeg(CS, seg, seg * 16, 0xffff, 0x1007);
    for (const s of [ES, SS, DS, 4, 5]) m.setSeg(s, 0, 0, 0xffff, 0x1003);
    m.rip = off;
    m.setReg(RSP, 0x7c00);
    this.setR8lo(RDX, drive);
    this.setR8hi(RDX, 0);
    m.flags = 0x202;                 // interrupts enabled, as after a real POST
    this.emu.machine.wake();
  }

  // ---- INT 10h: video ----------------------------------------------------
  int10() {
    const ah = this.r8hi(RAX);
    const vga = this.emu.vga;
    switch (ah) {
      case 0x00: {                                   // set video mode
        const mode = this.r8lo(RAX) & 0x7f;
        const params = VGA_PARAMS.get(mode);
        if (params && this.m.vm) {
          // From a virtual-8086 machine the registers are set by ROM code, so
          // whatever virtualises the display sees them (see VGA_SET_MODE).
          this.modeBda(mode, params);
          this.setR16(RAX, params.offset | (this.r8lo(RAX) & 0x80 ? 0x8000 : 0));
          this.m.rip = VGA_ROM_OFF;
          return;
        }
        vga?.setBiosMode(mode);
        this.mem.wr8(BDA + 0x49, mode);
        this.mem.wr16(BDA + 0x4a, vga?.textCols ?? 80);
        this.setCursor(0, 0, 0);
        return;
      }
      case 0x01:                                     // cursor shape
        this.mem.wr8(BDA + 0x61, this.r8hi(RCX));      // start scan line
        this.mem.wr8(BDA + 0x60, this.r8lo(RCX));      // end scan line
        return;
      case 0x02: {                                   // set cursor position
        const page = this.r8hi(RBX) & 7;
        this.setCursor(page, this.r8lo(RDX), this.r8hi(RDX));
        this.hardwareCursor();
        return;
      }
      case 0x03: {                                   // get cursor position
        const page = this.r8hi(RBX) & 7;
        const col = this.mem.rd8(BDA + 0x50 + page * 2);
        const row = this.mem.rd8(BDA + 0x51 + page * 2);
        this.setR8lo(RDX, col);
        this.setR8hi(RDX, row);
        this.setR16(RCX, (this.mem.rd8(BDA + 0x60) << 8) | this.mem.rd8(BDA + 0x61));
        return;
      }
      case 0x05:
        this.mem.wr8(BDA + 0x62, this.r8lo(RAX) & 7);
        return;
      case 0x06:
      case 0x07:
        this.scroll(ah === 0x06);
        return;
      case 0x08: {                                   // read char and attribute
        const page = this.r8hi(RBX) & 7;
        const col = this.mem.rd8(BDA + 0x50 + page * 2);
        const row = this.mem.rd8(BDA + 0x51 + page * 2);
        const at = 0xb8000 + (row * 80 + col) * 2;
        this.setR8lo(RAX, this.mem.rd8(at));
        this.setR8hi(RAX, this.mem.rd8(at + 1));
        return;
      }
      case 0x09:
      case 0x0a: {                                   // write char (with attr)
        const page = this.r8hi(RBX) & 7;
        const ch = this.r8lo(RAX);
        const attr = ah === 0x09 ? this.r8lo(RBX) : null;
        let count = this.r16(RCX) || 1;
        let col = this.mem.rd8(BDA + 0x50 + page * 2);
        let row = this.mem.rd8(BDA + 0x51 + page * 2);
        while (count-- > 0) {
          const at = 0xb8000 + (row * 80 + col) * 2;
          this.mem.wr8(at, ch);
          if (attr !== null) this.mem.wr8(at + 1, attr);
          if (++col >= 80) { col = 0; row++; }
        }
        return;
      }
      case 0x0e:                                     // teletype output
        // BL is a colour only in graphics modes.  In text the cell keeps the
        // attribute it has; Windows 95's boot menu prints its countdown with
        // the count still in BL, which painted each digit a different colour.
        this.teletype(this.r8lo(RAX), null);
        this.hardwareCursor();
        return;
      case 0x0f:                                     // get video mode
        this.setR8lo(RAX, this.mem.rd8(BDA + 0x49));
        this.setR8hi(RAX, this.mem.rd16(BDA + 0x4a));
        this.setR8hi(RBX, this.mem.rd8(BDA + 0x62));
        return;
      case 0x11:                                     // character generator
        if (this.r8lo(RAX) === 0x30) {               // get font information
          // ES:BP is the whole point of this call: the caller draws glyphs
          // straight out of the table.  Returning BP=0 with ES untouched, as
          // this used to, hands back a pointer into whatever the caller's ES
          // happened to be, and every character it renders comes out as
          // garbage -- which for the Windows boot manager meant its menu and
          // its error messages were drawn, invisibly, in noise.
          //
          // BH selects which of the several ROM fonts is wanted.  Only one
          // exists here, so the same table is returned whatever was asked for
          // and CX reports its true stride; a caller that honours CX renders
          // correctly even if it asked for the 8x14 or 8x8 variant.
          this.m.setSeg(ES, ROM_SEG, ROM_BASE, 0xffff, 0x1003);
          this.setR16(RBP, FONT_OFF);
          this.setR16(RCX, FONT_HEIGHT);             // bytes per character
          this.setR8lo(RDX, 25 - 1);                 // rows on screen - 1
        }
        return;
      case 0x12:                                     // alternate select
        this.setR8lo(RBX, 0x03);
        return;
      case 0x13: {                                   // write string
        let off = this.r16(RBP);
        let count = this.r16(RCX);
        const mode = this.r8lo(RAX);
        this.setCursor(this.r8hi(RBX) & 7, this.r8lo(RDX), this.r8hi(RDX));
        while (count-- > 0) {
          const ch = this.mem.rd8(this.linear(ES, off++));
          const attr = (mode & 2) ? this.mem.rd8(this.linear(ES, off++))
                                  : this.r8lo(RBX);
          this.teletype(ch, attr);
        }
        this.hardwareCursor();
        return;
      }
      case 0x10:                                     // palette and DAC
        return this.palette();
      // AH=1Ah, the display combination code, is deliberately left
      // unanswered.  Reporting a VGA makes Windows 95's IO.SYS show its
      // animated boot logo, and with the logo running the IDE driver's
      // initialisation later fails and Windows shuts down.  Without it the
      // logo is skipped and Windows starts.
      case 0x4f:                                     // VESA BIOS extensions
        return this.vbe();
      default:
        return;
    }
  }

  /**
   * INT 10h AH=10h: the attribute palette and the DAC.
   *
   * Windows' 16-colour driver sets two DAC registers through this -- its two
   * greys, the face of every dialog and button -- and leaves the other
   * fourteen colours to the EGA palette the mode set loaded.  Without it the
   * greys stayed EGA lavender and blue-grey.
   */
  palette() {
    const vga = this.emu.vga;
    const al = this.r8lo(RAX);
    const bl = this.r8lo(RBX), bh = this.r8hi(RBX);
    const table = this.linear(ES, this.r16(RDX));
    const dac = (i) => (i & 0xff) * 3;
    switch (al) {
      case 0x00: vga.attr[bl & 0x0f] = bh; break;            // one palette register
      case 0x01: vga.attr[0x11] = bh; break;                 // border
      case 0x02:                                             // all sixteen, and the border
        for (let i = 0; i < 16; i++) vga.attr[i] = this.mem.rd8(table + i);
        vga.attr[0x11] = this.mem.rd8(table + 16);
        break;
      case 0x03:                                             // blink or bright background
        vga.attr[0x10] = (vga.attr[0x10] & ~0x08) | (bl ? 0x08 : 0);
        break;
      case 0x07: this.setR8hi(RBX, vga.attr[bl & 0x1f]); break;
      case 0x08: this.setR8hi(RBX, vga.attr[0x11]); break;
      case 0x09:
        for (let i = 0; i < 16; i++) this.mem.wr8(table + i, vga.attr[i]);
        this.mem.wr8(table + 16, vga.attr[0x11]);
        break;
      case 0x10: {                                           // one DAC register
        const at = dac(this.r16(RBX));
        vga.palette[at] = this.r8hi(RDX) & 0x3f;
        vga.palette[at + 1] = this.r8hi(RCX) & 0x3f;
        vga.palette[at + 2] = this.r8lo(RCX) & 0x3f;
        break;
      }
      case 0x12:                                             // a block of DAC registers
        for (let n = 0; n < this.r16(RCX); n++) {
          const at = dac(this.r16(RBX) + n);
          for (let c = 0; c < 3; c++) vga.palette[at + c] = this.mem.rd8(table + n * 3 + c) & 0x3f;
        }
        break;
      case 0x15: {
        const at = dac(this.r16(RBX));
        this.setR8hi(RDX, vga.palette[at]);
        this.setR8hi(RCX, vga.palette[at + 1]);
        this.setR8lo(RCX, vga.palette[at + 2]);
        break;
      }
      case 0x17:
        for (let n = 0; n < this.r16(RCX); n++) {
          const at = dac(this.r16(RBX) + n);
          for (let c = 0; c < 3; c++) this.mem.wr8(table + n * 3 + c, vga.palette[at + c]);
        }
        break;
      case 0x19: this.setR8lo(RBX, 0xff); break;             // PEL mask: all bits pass
      case 0x1a: this.setR16(RBX, 0); break;                 // colour page: one page
      default: return;
    }
    vga.dirty = true;
  }

  setCursor(page, col, row) {
    this.mem.wr8(BDA + 0x50 + page * 2, col);
    this.mem.wr8(BDA + 0x51 + page * 2, row);
  }

  /** In a virtual-8086 machine, leave through ROM code that moves the
   *  hardware cursor to where the BDA now says, with port writes. */
  hardwareCursor() {
    if (this.m.vm) this.m.rip = VGA_ROM_OFF + VGA_SET_MODE.length;
  }

  /** What the BIOS data area records about a mode just set. */
  modeBda(mode, p) {
    const m = this.mem;
    m.wr8(BDA + 0x49, mode);
    m.wr16(BDA + 0x4a, p.cols);
    m.wr16(BDA + 0x4c, p.pageSize);
    m.wr16(BDA + 0x4e, 0);
    for (let i = 0; i < 16; i++) m.wr8(BDA + 0x50 + i, 0);   // every page's cursor
    m.wr8(BDA + 0x62, 0);
    m.wr16(BDA + 0x63, 0x3d4);
    m.wr8(BDA + 0x84, p.rows - 1);
    m.wr16(BDA + 0x85, p.charHeight);
  }

  // attr null leaves the cell's existing attribute in place.
  teletype(ch, attr = 0x07) {
    const m = this.mem;
    const page = m.rd8(BDA + 0x62) & 7;
    let col = m.rd8(BDA + 0x50 + page * 2);
    let row = m.rd8(BDA + 0x51 + page * 2);
    const cols = 80, rows = 25;

    if (ch === 0x0d) col = 0;
    else if (ch === 0x0a) row++;
    else if (ch === 0x08) { if (col > 0) col--; }
    else if (ch === 0x07) { /* bell */ }
    else {
      const at = 0xb8000 + (row * cols + col) * 2;
      m.wr8(at, ch);
      if (attr !== null) m.wr8(at + 1, attr || 0x07);
      if (++col >= cols) { col = 0; row++; }
    }
    if (row >= rows) {
      this.scrollUp(1);
      row = rows - 1;
    }
    this.setCursor(page, col, row);
    // mirror to the serial log so headless runs still show BIOS output
    this.emu.onBiosChar?.(ch);
  }

  scrollUp(lines) {
    const m = this.mem;
    const cols = 80, rows = 25;
    const stride = cols * 2;
    for (let r = 0; r < rows - lines; r++) {
      for (let i = 0; i < stride; i++) {
        m.wr8(0xb8000 + r * stride + i, m.rd8(0xb8000 + (r + lines) * stride + i));
      }
    }
    for (let r = rows - lines; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        m.wr16(0xb8000 + r * stride + c * 2, 0x0720);
      }
    }
  }

  scroll(up) {
    const lines = this.r8lo(RAX);
    if (lines === 0) {
      // a count of zero means blank the whole window
      const attr = this.r8hi(RBX);
      for (let r = 0; r < 25; r++) {
        for (let c = 0; c < 80; c++) {
          this.mem.wr16(0xb8000 + (r * 80 + c) * 2, (attr << 8) | 0x20);
        }
      }
      return;
    }
    if (up) this.scrollUp(lines);
  }

  // ---- VESA BIOS extensions ---------------------------------------------
  vbe() {
    const vga = this.emu.vga;
    const al = this.r8lo(RAX);
    if (!vga) { this.setR16(RAX, 0x014f); return; }

    if (al === 0x00) {                                // controller info
      const at = this.linear(ES, this.r16(RDI));
      const m = this.mem;
      const put = (o, str) => {
        for (let i = 0; i < str.length; i++) m.wr8(at + o + i, str.charCodeAt(i));
      };
      put(0, 'VESA');
      m.wr16(at + 4, 0x0200);                         // VBE 2.0
      m.wr32(at + 6, (ROM_SEG << 16) | OEM_STRING_OFF);
      m.wr32(at + 10, 0x0001);                        // capabilities: 8-bit DAC
      // The mode list lives in ROM, so the far pointer stays valid after the
      // caller's buffer goes away.
      m.wr32(at + 14, (ROM_SEG << 16) | MODE_LIST_OFF);
      m.wr16(at + 18, vga.memSize >> 16);             // memory in 64 KiB blocks
      this.setR16(RAX, 0x004f);
      return;
    }

    if (al === 0x01) {                                // mode info
      const mode = this.r16(RCX) & 0x1ff;
      const info = vga.vbeModes.get(mode);
      if (!info) { this.setR16(RAX, 0x014f); return; }
      const at = this.linear(ES, this.r16(RDI));
      const m = this.mem;
      for (let i = 0; i < 256; i++) m.wr8(at + i, 0);
      m.wr16(at + 0x00, 0x00bb);        // supported, colour, graphics, LFB
      m.wr8(at + 0x19, info.bpp);
      m.wr8(at + 0x1b, info.bpp === 8 ? 4 : 6);   // memory model: packed / direct
      m.wr16(at + 0x12, info.w);
      m.wr16(at + 0x14, info.h);
      m.wr16(at + 0x10, info.w * (info.bpp >> 3)); // bytes per scan line
      m.wr8(at + 0x1c, 1);              // number of planes
      m.wr8(at + 0x1d, 1);              // banks
      m.wr32(at + 0x28, vga.lfbBase);   // physical address of the framebuffer
      if (info.bpp === 32 || info.bpp === 24) {
        m.wr8(at + 0x1f, 8); m.wr8(at + 0x20, 16);   // red
        m.wr8(at + 0x21, 8); m.wr8(at + 0x22, 8);    // green
        m.wr8(at + 0x23, 8); m.wr8(at + 0x24, 0);    // blue
      }
      this.setR16(RAX, 0x004f);
      return;
    }

    if (al === 0x02) {                                // set mode
      const bx = this.r16(RBX);
      const mode = bx & 0x1ff;
      // Mode numbers below 0x100 are the ordinary VGA modes, and the VBE
      // interface is required to set them just as INT 10h AH=00 would.
      // TempleOS asks for mode 0x12 this way; refusing it made it fall back to
      // drawing its desktop as text.
      if (mode < 0x100) {
        vga.setBiosMode(mode);
        this.mem.wr8(BDA + 0x49, mode);
        this.setR16(RAX, 0x004f);
        return;
      }
      const ok = vga.setVbeMode(mode, (bx & 0x4000) !== 0);
      this.setR16(RAX, ok ? 0x004f : 0x014f);
      return;
    }

    if (al === 0x03) {                                // get mode
      this.setR16(RBX, vga.lfbEnabled
        ? (vga.currentVbeMode | 0x4000)
        : (vga.biosMode & 0xff));
      this.setR16(RAX, 0x004f);
      return;
    }

    this.setR16(RAX, 0x014f);
  }

  // ---- INT 13h: disk -----------------------------------------------------
  int13() {
    const ah = this.r8hi(RAX);
    const drive = this.r8lo(RDX);
    const disk = this.findDisk(drive);

    const fail = (code) => {
      this.setR8hi(RAX, code);
      this.mem.wr8(BDA + 0x74, code);
      this.setReturnCarry(true);
    };
    const ok = () => {
      this.setR8hi(RAX, 0);
      this.mem.wr8(BDA + 0x74, 0);
      this.setReturnCarry(false);
    };

    switch (ah) {
      case 0x00:                                     // reset
      case 0x0d:
        return ok();

      case 0x01:                                     // last status
        this.setR8hi(RAX, this.mem.rd8(BDA + 0x74));
        return this.setReturnCarry(false);

      case 0x02: {                                   // read sectors, CHS
        if (!disk) return fail(0x01);
        const count = this.r8lo(RAX);
        const cl = this.r8lo(RCX);
        const sector = cl & 0x3f;
        const cylinder = this.r8hi(RCX) | ((cl & 0xc0) << 2);
        const head = this.r8hi(RDX);
        if (sector === 0) return fail(0x01);
        const lba = disk.chsToLba(cylinder, head, sector);
        const data = disk.read(lba, count);
        if (data === null) return this.retryLater();
        if (!data) return fail(0x04);
        const at = this.linear(ES, this.r16(RBX));
        this.mem.writeBytes(at, data);
        this.setR8lo(RAX, count);
        return ok();
      }

      case 0x03: {                                   // write sectors, CHS
        if (!disk) return fail(0x01);
        if (!disk.writable) return fail(0x03);       // write protected
        const count = this.r8lo(RAX);
        const cl = this.r8lo(RCX);
        const sector = cl & 0x3f;
        const cylinder = this.r8hi(RCX) | ((cl & 0xc0) << 2);
        const head = this.r8hi(RDX);
        if (sector === 0) return fail(0x01);
        const lba = disk.chsToLba(cylinder, head, sector);
        const at = this.linear(ES, this.r16(RBX));
        const src = this.mem.readBytes(at, count * disk.sectorSize);
        const wrote = disk.write(lba, src);
        if (wrote === NEED_DATA) return this.retryLater();
        if (!wrote) return fail(0x04);
        this.setR8lo(RAX, count);
        return ok();
      }

      case 0x04:                                     // verify
        return ok();

      case 0x08: {                                   // drive parameters
        if (!disk) return fail(0x01);
        const g = disk.geometry;
        const maxC = Math.max(0, g.c - 1);
        this.setR8hi(RCX, maxC & 0xff);
        this.setR8lo(RCX, ((maxC >> 2) & 0xc0) | (g.s & 0x3f));
        this.setR8hi(RDX, Math.max(0, g.h - 1));
        this.setR8lo(RDX, this.disks.filter((d) => d.kind === disk.kind).length);
        this.setR8lo(RBX, g.type);
        this.setR8hi(RAX, 0);
        return ok();
      }

      case 0x15: {                                   // disk type
        if (!disk) { this.setR8hi(RAX, 0); return this.setReturnCarry(true); }
        if (disk.kind === DISK_FLOPPY) { this.setR8hi(RAX, 1); return this.setReturnCarry(false); }
        const sectors = Math.floor(disk.store.size / 512);
        this.setR8hi(RAX, 3);
        this.setR16(RCX, (sectors >>> 16) & 0xffff);
        this.setR16(RDX, sectors & 0xffff);
        return this.setReturnCarry(false);
      }

      case 0x05:                                     // format track: unsupported
        return fail(0x03);

      case 0x41:                                     // extensions present?
        if (!disk) return fail(0x01);
        this.setR16(RBX, 0xaa55);
        this.setR8hi(RAX, 0x21);                     // version 1.1
        this.setR16(RCX, 0x0007);                    // packet access, lock, EDD
        return this.setReturnCarry(false);

      case 0x42: {                                   // extended read
        if (!disk) return fail(0x01);
        const pkt = this.linear(DS, this.r16(RSI));
        const count = this.mem.rd16(pkt + 2);
        const off = this.mem.rd16(pkt + 4);
        const seg = this.mem.rd16(pkt + 6);
        const lba = Number(this.mem.rd64(pkt + 8) & 0xffffffffffffn);
        const data = disk.read(lba, count);
        if (data === null) return this.retryLater();
        if (!data) return fail(0x04);
        this.mem.writeBytes(seg * 16 + off, data);
        return ok();
      }

      case 0x43: {                                   // extended write
        if (!disk) return fail(0x01);
        if (!disk.writable) return fail(0x03);
        const pkt = this.linear(DS, this.r16(RSI));
        const count = this.mem.rd16(pkt + 2);
        const off = this.mem.rd16(pkt + 4);
        const seg = this.mem.rd16(pkt + 6);
        const lba = Number(this.mem.rd64(pkt + 8) & 0xffffffffffffn);
        const src = this.mem.readBytes(seg * 16 + off, count * disk.sectorSize);
        const wrote = disk.write(lba, src);
        if (wrote === NEED_DATA) return this.retryLater();
        if (!wrote) return fail(0x04);
        return ok();
      }

      case 0x48: {                                   // extended drive parameters
        if (!disk) return fail(0x01);
        const buf = this.linear(DS, this.r16(RSI));
        const size = this.mem.rd16(buf);
        this.mem.wr16(buf, Math.min(size, 0x1e));
        this.mem.wr16(buf + 2, 0x0002);                // geometry may be invalid
        const g = disk.geometry;
        this.mem.wr32(buf + 4, g.c);
        this.mem.wr32(buf + 8, g.h);
        this.mem.wr32(buf + 12, g.s);
        this.mem.wr64(buf + 16, BigInt(disk.sectorCount));
        this.mem.wr16(buf + 24, disk.sectorSize);
        return ok();
      }

      case 0x4b: {                                   // El Torito emulation status
        if (!this.elTorito || !disk) return fail(0x01);
        const buf = this.linear(DS, this.r16(RSI));
        const et = this.elTorito;
        for (let i = 0; i < 0x13; i++) this.mem.wr8(buf + i, 0);
        this.mem.wr8(buf + 0x00, 0x13);
        this.mem.wr8(buf + 0x01, et.mediaType);
        this.mem.wr8(buf + 0x02, drive);
        this.mem.wr8(buf + 0x03, 0);                   // controller index
        this.mem.wr32(buf + 0x04, et.imageLba);
        this.mem.wr16(buf + 0x08, drive);
        this.mem.wr16(buf + 0x0a, et.loadSegment);
        this.mem.wr16(buf + 0x0c, et.sectorCount);
        return ok();
      }

      default:
        return fail(0x01);
    }
  }

  // ---- INT 15h: miscellaneous system services ----------------------------
  int15() {
    const ah = this.r8hi(RAX);
    const ax = this.r16(RAX);

    if (ax === 0xe820) {                             // memory map
      const idx = this.r32(RBX);
      if (this.r32(RDX) !== 0x534d4150) {            // "SMAP"
        this.setReturnCarry(true);
        return;
      }
      if (idx >= this.e820.length) { this.setReturnCarry(true); return; }
      const e = this.e820[idx];
      const at = this.linear(ES, this.r16(RDI));
      this.mem.wr64(at, BigInt(e.base));
      this.mem.wr64(at + 8, BigInt(e.size));
      this.mem.wr32(at + 16, e.type);
      if (this.r32(RCX) >= 24) this.mem.wr32(at + 20, 1);
      this.setR32(RAX, 0x534d4150);
      this.setR32(RCX, 20);
      this.setR32(RBX, idx + 1 < this.e820.length ? idx + 1 : 0);
      this.setReturnCarry(false);
      return;
    }

    if (ax === 0xe801) {                             // extended memory size
      const kb = Math.floor((this.emu.ramSize - 0x100000) / 1024);
      const below16 = Math.min(kb, 15 * 1024);
      const above16 = Math.max(0, Math.floor((kb - 15 * 1024) / 64));
      this.setR16(RAX, below16);
      this.setR16(RBX, Math.min(0xffff, above16));
      this.setR16(RCX, below16);
      this.setR16(RDX, Math.min(0xffff, above16));
      this.setReturnCarry(false);
      return;
    }

    switch (ah) {
      case 0x88: {                                   // extended memory, KiB
        const kb = Math.min(0xffff, Math.floor((this.emu.ramSize - 0x100000) / 1024));
        this.setR16(RAX, kb);
        this.setReturnCarry(false);
        return;
      }
      case 0x24: {                                   // A20 gate
        const al = this.r8lo(RAX);
        if (al === 0x00 || al === 0x01) this.emu.io.setA20(al === 0x01);
        else if (al === 0x02) this.setR8lo(RAX, this.emu.io.a20 ? 1 : 0);
        else if (al === 0x03) this.setR16(RBX, 0x0003);  // via 8042 and port 92
        else { this.setR8hi(RAX, 0x86); this.setReturnCarry(true); return; }
        this.setR8hi(RAX, 0);
        this.setReturnCarry(false);
        return;
      }
      case 0xc2:                                     // PS/2 pointing device
        return this.pointingDevice();
      case 0x86: {                                   // wait, in microseconds
        this.setReturnCarry(false);
        return;
      }
      case 0x87:                                     // move block to extended memory
        return this.moveBlock();
      case 0x41:
      case 0x4f:
      case 0x53:
      case 0xc0:
      case 0xc1:
      default:
        this.setR8hi(RAX, 0x86);
        this.setReturnCarry(true);
        return;
    }
  }

  /**
   * INT 15h AH=C2h, the PS/2 pointing device interface.  Windows 95 finds and
   * drives the mouse through it: initialise, install a handler, enable.  The
   * device is set up directly rather than through the controller, so no
   * acknowledgement bytes reach the INT 74h handler as packet data.
   */
  pointingDevice() {
    const ps2 = this.emu.ps2;
    const al = this.r8lo(RAX), bh = this.r8hi(RBX);
    const ebda = EBDA_SEG * 16;
    const flags = () => this.mem.rd8(ebda + EBDA_MOUSE_FLAGS);
    const setFlags = (v) => {
      this.mem.wr8(ebda + EBDA_MOUSE_FLAGS, v);
      this.mem.wr8(ebda + EBDA_MOUSE_INDEX, 0);  // start a fresh packet
    };
    let status = 0;
    switch (al) {
      case 0x00:                                     // enable (BH=1) or disable
        if (bh > 1) { status = 0x01; break; }
        if (bh && !this.mem.rd32(ebda + EBDA_MOUSE_HANDLER)) { status = 0x05; break; }
        ps2.setMouseReporting(bh === 1);
        setFlags((flags() & 0x07) | (bh ? 0x80 : 0));
        break;
      case 0x01:                                     // reset
        ps2.resetMouse();
        setFlags(flags() & 0x07);
        this.setR16(RBX, 0x00aa);                    // device id 0, self-test passed
        break;
      case 0x02:                                     // sample rate
        if (bh > 6) { status = 0x02; break; }
        ps2.mouseRate = [10, 20, 40, 60, 80, 100, 200][bh];
        break;
      case 0x03:                                     // resolution
        if (bh > 3) { status = 0x02; break; }
        ps2.mouseResolution = bh;
        break;
      case 0x04:                                     // device type
        this.setR8hi(RBX, 0x00);
        break;
      case 0x05:                                     // initialise, BH = packet size
        if (bh < 1 || bh > 8) { status = 0x02; break; }
        ps2.resetMouse();
        setFlags(bh === 8 ? 0 : bh);
        break;
      case 0x06:                                     // status, or scaling
        if (bh === 0) {
          this.setR8lo(RBX, (ps2.mouseReporting ? 0x20 : 0) | (ps2.mouseScaling2 ? 0x10 : 0));
          this.setR8lo(RCX, ps2.mouseResolution);
          this.setR8lo(RDX, ps2.mouseRate);
        } else if (bh === 1 || bh === 2) {
          ps2.mouseScaling2 = bh === 2;
        } else {
          status = 0x01;
        }
        break;
      case 0x07:                                     // the handler, ES:BX
        this.mem.wr16(ebda + EBDA_MOUSE_HANDLER, this.r16(RBX));
        this.mem.wr16(ebda + EBDA_MOUSE_HANDLER + 2, this.m.segSelFast(ES));
        break;
      default:
        status = 0x01;                               // invalid function
    }
    this.setR8hi(RAX, status);
    this.setReturnCarry(status !== 0);
  }

  // INT 15h AH=87: copy using a caller-supplied descriptor table, the way
  // pre-A20 loaders reach memory above 1 MiB.
  moveBlock() {
    const gdt = this.linear(ES, this.r16(RSI));
    const words = this.r16(RCX);                     // count in 16-bit words
    const descBase = (o) => this.mem.rd16(gdt + o + 2) |
                            (this.mem.rd8(gdt + o + 4) << 16) |
                            (this.mem.rd8(gdt + o + 7) << 24);
    const src = descBase(0x10) >>> 0;
    const dst = descBase(0x18) >>> 0;
    const bytes = words * 2;
    if (src + bytes > this.emu.ramSize || dst + bytes > this.emu.ramSize) {
      this.setR8hi(RAX, 0x02);
      this.setReturnCarry(true);
      return;
    }
    this.m.writeBytes(dst, this.m.readBytes(src, bytes).slice());
    this.setR8hi(RAX, 0);
    this.setReturnCarry(false);
  }

  // ---- INT 16h: keyboard -------------------------------------------------
  pushKey(ascii, scan) {
    this.keyBuffer.push({ ascii: ascii & 0xff, scan: scan & 0xff });
    if (this.keyBuffer.length > 32) this.keyBuffer.shift();
  }

  int16() {
    const ah = this.r8hi(RAX);
    switch (ah) {
      case 0x00:
      case 0x10: {
        const k = this.keyBuffer.shift();
        if (!k) {
          // Nothing buffered: rewind so the guest re-executes the INT rather
          // than spinning inside a busy-wait with stale registers.
          this.m.rip = Number(this.m.rip) - 2;
          this.emu.idleWait = true;
          return;
        }
        this.setR8lo(RAX, k.ascii);
        this.setR8hi(RAX, k.scan);
        return;
      }
      case 0x01:
      case 0x11: {
        const k = this.keyBuffer[0];
        if (!k) { this.setReturnZero(true); this.emu.idleWait = true; return; }
        this.setR8lo(RAX, k.ascii);
        this.setR8hi(RAX, k.scan);
        this.setReturnZero(false);
        return;
      }
      case 0x02:
      case 0x12:
        this.setR8lo(RAX, this.mem.rd8(BDA + 0x17));
        return;
      case 0x03:
      case 0x05:
        return;
      default:
        return;
    }
  }

  /**
   * INT 14h, the serial port service.
   *
   * No UART is presented to the guest -- the equipment word reports zero serial
   * ports -- but Windows probes the service anyway, so it has to answer.  Bit 7
   * of the returned line status is the timeout bit, which is how a caller is
   * told there is nothing on the other end; the alternative, falling through to
   * the unhandled-vector path, made a routine probe look like a CPU fault.
   */
  int14() {
    this.setR8hi(RAX, 0x80);            // line status: timeout
    this.setR8lo(RAX, 0x00);            // modem status: nothing asserted
  }

  /**
   * INT 17h, the parallel printer service.
   *
   * Likewise absent, and reported as such: bit 0 of the status is the timeout
   * that says no printer answered.
   */
  int17() {
    this.setR8hi(RAX, 0x01);            // status: timeout, nothing attached
  }

  // ---- INT 1Ah: time -----------------------------------------------------
  int1a() {
    const ah = this.r8hi(RAX);
    const bcd = (n) => ((Math.floor(n / 10) << 4) | (n % 10)) & 0xff;
    const now = new Date();
    switch (ah) {
      case 0x00: {
        const ticks = this.mem.rd32(BDA + 0x6c);
        this.setR16(RCX, (ticks >>> 16) & 0xffff);
        this.setR16(RDX, ticks & 0xffff);
        this.setR8lo(RAX, 0);
        return;
      }
      case 0x01:
        this.mem.wr32(BDA + 0x6c, ((this.r16(RCX) << 16) | this.r16(RDX)) >>> 0);
        return;
      case 0x02:
        this.setR8hi(RCX, bcd(now.getUTCHours()));
        this.setR8lo(RCX, bcd(now.getUTCMinutes()));
        this.setR8hi(RDX, bcd(now.getUTCSeconds()));
        this.setReturnCarry(false);
        return;
      case 0x04:
        this.setR8hi(RCX, bcd(Math.floor(now.getUTCFullYear() / 100)));
        this.setR8lo(RCX, bcd(now.getUTCFullYear() % 100));
        this.setR8hi(RDX, bcd(now.getUTCMonth() + 1));
        this.setR8lo(RDX, bcd(now.getUTCDate()));
        this.setReturnCarry(false);
        return;
      default:
        this.setReturnCarry(true);
        return;
    }
  }
}


