# x64emu

An x86-64 CPU emulator written in **WebAssembly text format (WAT)**, with a
JavaScript platform around it — VGA adapter, virtual BIOS, ATA controller,
PS/2 keyboard, interrupt controllers, timer, UART, RTC — and an HTML front end
with a canvas display. It boots real, unmodified bootable images.

Guest RAM, disk size and image size are all unbounded by design: RAM lives in
its own 64-bit WebAssembly memory, the RAM drive allocates only what is written,
and images are read in pieces as the guest asks for them.

```
src/wat/     the CPU core, hand-written WAT, assembled into one module
src/js/      machine glue, devices, VGA, BIOS, boot protocols, browser UI
tests/       assembly test programs + Node runners
tools/       headless boot harnesses
build.sh     concatenates the WAT fragments and runs wat2wasm
```

## Build and run

```sh
./build.sh                 # needs wat2wasm (wabt)
npm test                   # CPU + BIOS/VGA suites (needs clang + python3)

# boot any bootable image through the BIOS (ISO, floppy, hard disk)
node tools/bootimg.mjs path/to/image.iso --ram 8G --hdd 256G

# or load a Linux kernel directly, skipping the BIOS
node tools/boot.mjs path/to/vmlinuz path/to/initrd.gz

# browser
python3 -m http.server 8000     # then open http://localhost:8000
```

The browser UI takes images from file pickers, so nothing needs to be bundled
with the page. It offers two paths: **Boot image** runs an arbitrary bootable
image under the BIOS, and **Boot kernel** enters a Linux kernel directly.

## What actually runs

An unmodified **Linux 6.6.8** kernel (Tiny Core `vmlinuz` + `core.gz`, 12 MB
initramfs) boots end to end, starts userspace, and reaches a **busybox shell
prompt on the serial console**:

```
$ node tools/boot.mjs images/tinycore-vmlinuz images/tinycore-initrd.gz \
      --cmdline "console=ttyS0,115200 nokaslr rdinit=/bin/sh"
| Linux version 6.6.8-tinycore (tc@box) (gcc 13.2.0) #666 SMP ...
| Trying to unpack rootfs image as initramfs...
| Freeing initrd memory: 12464K
| Run /bin/sh as init process
| ~ #
```

That path exercises self-decompression, E820 parsing, page-table setup, IDT
installation, the 8259/8254/16550/CMOS drivers, initramfs unpacking, the
`SYSENTER` syscall fast path, ring 3, copy-on-write faults, and the dynamic
loader plus libc in userspace.

Speed is roughly **50 million instructions per second** in Node on an M-series
Mac; a full boot to shell is about 1.5 billion instructions and takes around
31 seconds. See [Performance](#performance) for what that took.

### Booting an arbitrary image

`Core-current.iso` (Tiny Core, an El Torito CD) boots the way it would on real
hardware — BIOS POST, boot catalog, ISOLINUX, its menu, then Linux — and lands
on a shell at the VGA text console:

```
$ node tools/bootimg.mjs Core-current.iso --type "\n" --after "boot:"
image    Core-current.iso
type     cdrom, drive 0xe0, 9090 sectors of 2048 bytes
| [bios] El Torito: 4 sectors from LBA 37 to 7c0:0000 (media type 0)
| ISOLINUX 4.05 0x4f92e181 ETCD
--- text screen ---
>    ( '>')
>   /) TC (\   Core is distributed with ABSOLUTELY NO WARRANTY.
>  (/-_--_-\)           www.tinycorelinux.net
>
> tc@box:~$
```

Nothing about the image is special-cased: the BIOS reads its boot sector, and
everything after that is the image's own code running on the emulated CPU.

Images tried so far:

| image | result |
| --- | --- |
| Tiny Core `Core-current.iso` | ISOLINUX menu, then Linux to a `tc@box:~$` shell |
| `osakaOS.iso` (GRUB) | GRUB menu, then all three hardware stages to its `$:` shell; the Windows key switches it into 320x200x256 and it draws |
| a 1.44 MB floppy built by the test suite | boots, prints through `INT 10h`, paints mode 13h |
| `TempleOS.ISO` | boots its 64-bit kernel, mounts its own disc over ATAPI, stops at `MultiCore Start` |
| a non-bootable data ISO | reported as having no El Torito boot record, machine stops |

Both of the real bootloaders ran to completion with **zero CPU exceptions**
taken, which is the useful signal: the decoder and the real/protected-mode
plumbing are handling their code as-is.

### Windows

A Windows 10 22H2 x64 ISO (5.7 GB, read on demand) gets **partway through the
boot loader and then stops**. It does not reach the installer. What does happen:

- the BIOS boots it from its El Torito record and Windows Boot Manager runs
- `bootmgr` sets a 1024x768x32 framebuffer through the VBE calls
- ~10,800 sectors are read over `INT 13h`, loading `bootmgr` and `winload`
- the CPU enters long mode and runs about a billion instructions of 64-bit code

Getting that far exposed four genuinely missing instruction groups, all of which
are now implemented: the half-register moves and unpacks (`0F 12`-`0F 17`,
including the `MOVLHPS` inside Windows' inline `memset`), the packed integer
group (compares, unpacks, shuffles, logicals, add/subtract, `MOVNTDQ`,
`PMOVMSKB`), the packed shifts (`0F 71`-`0F 73`, `0F D1`-`0F F3`), and
`PCMPGT`. After those the loader executes with **no unimplemented instructions
at all**.

It then lands on `eb fe` — `jmp $`, followed by `int3` padding — and stays
there, issuing no port I/O and no further BIOS calls. That is a deliberate
dead stop in the loader's fatal path, not a hang waiting on a device. The
likely reasons are the ones listed under [Not implemented](#not-implemented):
there are no ACPI tables for `winload` to find an RSDP in, no local APIC, no
PCI, and no ATAPI, so nothing can reach the install media once real mode is
behind it. Advertising `PREFETCHW` (a documented Windows 8.1+ requirement, and
now reported) did not change where it stops.

Synthesising ACPI tables is the next thing to try, and is bounded work; the
rest is the same list that stands between here and Ubuntu.

### Windows 95

A Windows 95 hard disk image (a FAT16 partition converted from a VM's qcow2)
boots to the desktop in 640x480x16: through its MBR and `IO.SYS`, the Startup
Menu, `HIMEM.SYS` with DOS loaded high, the 32-bit VMM and every VxD, the
protected-mode IDE driver, the 16-bit kernel, and the display driver, and the
mouse moves the pointer and clicks. An MS-DOS prompt opens in a window or full
screen.

The mouse needed two things from the BIOS. The equipment word (`INT 11h`) has
to report a pointing device, or Windows never looks for one. Windows then
drives it through `INT 15h AH=C2h`, which needs a far-call handler run from
IRQ 12: the `INT 74h` code in the ROM, with its state in an EBDA. Conventional
memory is 639 KiB to make room, as the E820 map already said.

It is about six seconds of emulation from the Startup Menu to the desktop.
Choosing **Logged** at the menu writes `C:\BOOTLOG.TXT` into the disk's write
overlay, which is the quickest way to see how far a boot got.

Getting into the VMM took four fixes:

- **The BIOS wrapped addresses at 1 MiB** although the CPU does not. With
  `DOS=HIGH`, DOS hands `INT 13h` a packet at `FFFF:xxxx` in the HMA; the BIOS
  read it from low memory as zeros and wrote sectors over the interrupt table.
- **A zero-length read fetched the whole image.** The zeroed packet asked for
  zero sectors at LBA 0, and `(0 + 0 - 1) >>> 20` is chunk 4095. In a browser
  the read could never be satisfied, and the tab hung re-reading the image.
- **The A20 gate is real now.** Port `0x92`, the 8042 output port and
  `INT 15h AX=24xx` switch it, and the CPU wraps physical addresses at 1 MiB
  while it is off. HIMEM checks for the wrap after every disable; when it never
  came, each call spent a million instructions in a timeout.
- **`LAR`, `LSL`, `VERR` and `VERW`.** VMM validates selectors with them;
  `LAR` was an invalid-opcode fault and a "Windows protection error".

Also, teletype output (`INT 10h AH=0Eh`) no longer takes its colour from `BL` in
text mode. The boot menu prints its countdown with the count in `BL`, so every
digit came out a different colour.

Getting from the VMM to the desktop took these:

- **Virtual-8086 mode**, with the TSS I/O permission bitmap. Windows runs DOS,
  its real-mode drivers and the BIOS in V86 mode, and the bitmap is how it
  picks which ports to emulate. `t_v86` is a minimal monitor that exercises
  both.
- **Hardware interrupt handlers in the ROM.** The BIOS used to acknowledge
  IRQs from the host, straight to the real PIC. Under Windows the PIC is
  virtualised, so the DOS session never acknowledged its timer interrupt, never
  got another, and VMM's scheduler waited for it forever. The handlers are now
  x86 code that does `OUT 20h` like any BIOS.
- **Restartable faults.** A fault restores RSP as well as RIP, and `IRET` checks
  CS and SS before changing privilege. Windows demand-loads 16-bit code by
  letting an `IRET` to a not-present segment fault and reading the frame.
- **16-bit interrupt gates** push 16-bit frames. Windows routes its 16-bit
  clients' interrupts through them.
- **Expand-down segments.** The 16-bit kernel keeps a flat selector whose
  limit is a lower bound, so that null pointers fault.
- **The VGA palette.** A mode set loads the EGA colours into the DAC, as the
  BIOS does, and `INT 10h AH=10h` sets palette and DAC registers. Windows'
  16-colour driver uses both.
- **Video BIOS calls from a DOS box go through the ports.** An MS-DOS prompt
  is a virtual-8086 machine whose VGA registers Windows' VDD keeps a copy
  of, learnt from the port writes it traps. The BIOS set modes and moved the
  cursor from JavaScript, around VDD. Opening a prompt switched the real
  screen to text, and VDD, its copy of the registers all zeros, took the row
  length to be 0 on the first scroll. It marked a million pages dirty, through
  VKD's data, and VMM blue-screened ("exception 0D ... in VxD VMM"). From a
  virtual-8086 machine, `INT 10h` now sets modes and the cursor with ROM code
  (`src/asm/vga_rom.s`) that programs the VGA with `OUT`s, as a VGA BIOS
  would. The display follows the registers. The prompt runs windowed and full
  screen, and Alt+Enter switches between them.

`INT 10h AH=1Ah` (display combination) is deliberately unanswered. Reporting a
VGA makes `IO.SYS` show the animated boot logo, and with the logo running the
IDE driver's initialisation later fails. That is the next thing to look at.

### Debian

Debian 13 (kernel 6.12, a 3 GiB disk with an ext4 root) boots through GRUB,
its initramfs, a journal replay by `fsck`, and systemd to `debian login:` on
tty1. That takes about seven minutes in Node. Getting there needed these, in
the order the boot ran into them:

- **SSE2 integer arithmetic.** glibc's string functions are SSE2 throughout,
  and userspace died with `SIGILL` on the first opcode that was missing.
- **PCI, behind an ACPI root bridge.** Once ACPI is on, Linux scans PCI only
  below a root bridge in the DSDT, so the DSDT declares one, and config space
  shows the PIIX3 IDE function that `ata_piix` drives in PIO mode.
- **PIO the way the specification has it.** An interrupt for each block of a
  transfer, `READ/WRITE MULTIPLE`, LBA48's register order (the high byte goes
  first), and a command waiting on image data staying busy rather than failing.
- **`FXSAVE`/`FXRSTOR`.** They did nothing, so every process shared one set of
  XMM registers. A task switch in the middle of glibc's SSE2 string code
  handed it another process's data, which showed up as systemd assertions.
- **32-bit data port writes.** Linux writes sectors with `rep outsd`, and the
  controller kept only the low byte of each dword. The disk had been shut down
  uncleanly, so `fsck` replays its journal on every boot, and every block the
  replay wrote came out three-quarters zeros. That read as a corrupt
  filesystem rather than a device bug. Replaying the journal independently and
  comparing the result block by block is what showed the pattern.
- **A local APIC.** `CPUID` reports one, so Linux uses it. When systemd started,
  the kernel sent itself an IPI and waited forever for the busy bit of a
  register that read as all ones, which showed up as soft lockups.

### Windows XP

Windows XP Professional SP3 boots to its desktop at 640x480 in 16 colours, and
the keyboard and mouse work. The disk image is 20 GiB of FAT32 that was installed
under QEMU with the "ACPI Uniprocessor PC" HAL. That disk had not been shut down
cleanly, so the first boot goes through the Windows Error Recovery menu (it
starts normally after 30 seconds) and `autochk`. `autochk` reads through the
whole volume and finds nothing wrong, which is a good end-to-end test of the
disk path. The boot needed these, in order:

- **A local APIC and an I/O APIC.** XP keeps the HAL it was installed with, and
  this one runs every interrupt through the APICs. Its first read of the task
  priority register page-faulted, again and again, until the stack ran out and
  the machine triple faulted.
- **`CPUID` leaf 2.** AL says how many times to query it, and every CPU says 1.
  This one said 0, and XP counted down from it: four billion `CPUID`s with
  interrupts off.
- **The RTC's periodic interrupt.** The HAL takes its clock tick from IRQ 8 at
  64 Hz. The CMOS never raised it, so the clock never ticked.
- **An ATA geometry a CHS command can express.** `IDENTIFY` reported the BIOS's
  255 heads, which made the disk look addressable by CHS, so XP used CHS. A CHS
  command has only four bits for the head, so the reads went to the wrong
  sectors: STOP 0x7B, `INACCESSIBLE_BOOT_DEVICE`. The drive now reports at most
  16 heads, and `INITIALIZE DEVICE PARAMETERS` sets the translation.
- **`IRET`'s privilege checks.** The kernel runs video BIOS calls in
  virtual-8086 mode and ends each one with an `IRET` that is meant to fault: it
  goes to the ring-0 code selector with RPL 3, and XP's `#GP` handler
  recognises the frame. Here the `IRET` went through and ran kernel code at
  ring 3, and the thread died holding the display driver's mutex: STOP
  0x4000008A in `videoprt.sys`.
- **MMX.** `win32k.sys` blends alpha with `PMULLW`. MMX was missing, which is
  STOP 0x8E with an illegal instruction.
- **`#NM` while `CR0.TS` is set.** XP swaps x87, MMX and SSE state lazily, from
  that fault. Without it, threads ran on each other's registers.
- **The keyboard and mouse in the DSDT.** With an ACPI HAL, XP finds legacy
  devices only in the DSDT. Without them, its desktop had no input. They have
  to be below the ISA bridge. Declared at the root, they were started before
  the PCI bus, and `ACPI.sys` crashed (STOP 0x7E).

There is no PCI display adapter for XP's own drivers, so it runs on its generic
VGA driver.

### TempleOS

`TempleOS.ISO` boots through the BIOS, enters long mode, brings up its **64-bit
kernel**, and reaches its CD/DVD configuration screen with no faults:

```
> Enable IRQ's
> Port: 01F0,0000 Unit: 00   Nope
> Port: 01F0,0000 Unit: 01   Nope
> Port: 0170,0000 Unit: 00   Nope
> Port: 0170,0000 Unit: 01   Nope
>
> Don't worry.  This is not a product
> registration.   TempleOS just needs the
> I/O port numbers for the CD/DVD.
```

It now boots to its desktop in 640x480 sixteen-colour graphics. Getting there
needed the FPU (its startup does floating point work that used to hang) and one
BIOS fix: TempleOS asks for its graphics mode with `INT 10h AX=4F02, BX=0x12`.
Mode numbers below `0x100` are the ordinary VGA modes, and the VBE interface is
required to set them exactly as `AH=00` would. Refusing that call made TempleOS
fall back to drawing its desktop as text.

Along the way it finds and mounts its own disc:

```
> Port: 0170,0000 Unit: 00   ATAPI Started Found
> Defined Drives:
> B REDSEA   RAM        0000 0000 00
> T REDSEA   ATAPI      0170 0000 00
> Home Dir:"T:/Home"
> MultiCore Start
```

It runs about half as fast as other guests, around 23 MIPS against 50. That is
the FPU doing real work: HolyC represents every number as a double, so TempleOS
executes far more x87 than a C-derived system would, and the transcendentals
call out to the host. It is the price of the instructions actually computing
something. The version number printing as a long run of zeros is the missing
floating point — HolyC uses doubles for every number, and there is no x87 or SSE
arithmetic to convert them with.

Give it `--ram 1G`; TempleOS asks for at least 512 MiB.

Getting here turned up four real bugs, all now fixed:

- **CPL was being set in real mode.** `RETF` treated the low two bits of the
  target selector as a requested privilege level unconditionally. TempleOS far
  returns to segment `0x07C2`, whose low bits are `2`, which left the CPU at
  privilege 2 in real mode — and the next `LGDT` raised `#GP`. Real mode has no
  privilege levels; the RPL only means anything once `CR0.PE` is set.
- **REX.R was being applied to opcode-extension fields.** The ModRM `reg` field
  selects an operation rather than a register in every group opcode, and REX.R
  is not part of it. `44 f6 46 10 ff` — `REX.R` plus `TEST` — was decoding as
  `IDIV` and raising a divide error. The decoder now keeps the raw field
  separately, and every group handler uses it.
- **An empty ATA channel reported a ready drive.** The alternate status port
  answered `DRDY` whether or not a device was attached. With nothing selected
  every register now reads back zero — not `0xFF`, which would set `BSY` and
  hang anything polling for it to clear.
- **Readahead was stalling the guest.** The browser run loop waited on any
  outstanding chunk fetch, including speculative ones nothing was waiting for,
  which throttled it to roughly one fetch per frame. It now waits only when a
  BIOS call could not be served.

### The shell prompt

The prompt used to appear only some of the time, and typed input never echoed.
Kernel messages always came through, because `printk` polls the UART; the shell
writes through the tty layer, which enables the transmitter-empty interrupt and
waits for it. A 16550 raises that interrupt the moment it is enabled while the
transmitter is empty, and this one only raised it after a byte had been
written, so the first tty write never started. The UART now follows the 16550:
the line is up while any enabled condition holds, enabling the transmitter
interrupt raises it at once, and reading IIR clears it.

Two things helped around it. A request raised by a port write now reaches the
CPU at its next instruction rather than at the end of the slice, and the core
drops its interrupt line once the PIC has nothing to give, instead of asking on
every instruction for the rest of the slice; that alone made the boot about 10%
faster. And `tools/boot.mjs --type` was queueing its input on a microtask, which
never ran while the boot loop was going.

```
$ node tools/boot.mjs images/tinycore-vmlinuz images/tinycore-initrd.gz \
      --cmdline "console=ttyS0,115200 nokaslr rdinit=/bin/sh" \
      --type 'echo hello from $((6*7))\n' --after '~ # '
| ~ # echo hello from $((6*7))
| hello from 42
| ~ #
```

Note also that this is a **32-bit** kernel, because it is the only Linux image
available locally to test against. The 64-bit path is exercised by the test
suite (`t_arith64`, `t_modes` and `t_paging` all run in long mode) and the
loader implements both the 32-bit and 64-bit boot protocols, but a 64-bit kernel
boot has not been verified.

## Memory, disks and sizes

Nothing here has a configured ceiling. Three separate mechanisms make that work.

### Guest RAM lives in a 64-bit memory

A single wasm32 linear memory tops out at 4 GiB, which would cap guest RAM. The
core therefore imports **two** memories:

```wat
(import "env" "state" (memory $state 1))       ;; 64 KiB, 32-bit indexed
(import "env" "ram"   (memory $ram i64 1))     ;; guest RAM, 64-bit indexed
```

Instructions without an explicit memory operand address memory 0, so every CPU
state access stays a cheap 32-bit load, while guest physical addresses index
memory 1 directly — there is no base offset to add and no 4 GiB wall. Verified
working at 12 GiB; the practical limit is what the host will hand out.

This does mean the module requires the **memory64** and **multi-memory**
proposals. Node 20+ and current Chrome/Firefox have both; older browsers cannot
load it at all.

### The memory hard drive

`--hdd 256G` attaches a blank writable drive backed by a sparse store: 1 MiB
chunks allocated on first write, unwritten regions reading as zeros. A 256 GiB
drive costs nothing until the guest starts using it — the test suite creates one
and finds 2 MiB actually committed after the guest has exercised it.

It is reachable two ways, because a BIOS call cannot be made from protected mode:

- **`INT 13h`** — CHS and LBA reads *and writes*, for bootloaders and real-mode
  software.
- **An ATA/IDE PIO controller** at `0x1F0`/`0x170`, with `IDENTIFY`, LBA28 and
  LBA48 reads and writes. Hard disks land on the primary channel and optical
  drives on the secondary. Linux probes it as `pata_legacy` and brings it up as
  a normal block device:

```
| ata1: PATA max PIO4 cmd 0x1f0 ctl 0x3f6 irq 14
| ata1.00: ATA-6: x64emu RAM disk, 1.0, max UDMA/100
| ata1.00: 16777216 sectors, multi 0: LBA48
| sd 0:0:0:0: [sda] 16777216 512-byte logical blocks: (8.59 GB/8.00 GiB)
| sd 0:0:0:0: [sda] Write Protect is off
```

The drive is RAM-backed and does not survive a reload; the browser UI offers a
**Download image** button that materialises the committed chunks so work can be
kept.

### Optical drives (ATAPI)

A CD image is reachable two ways, for the same reason a disk is. `INT 13h` gets
a boot loader started; once an OS is in protected mode it needs the packet
protocol instead. `src/js/ata.js` implements it: `IDENTIFY DEVICE` aborts and
leaves the `01 01 14 EB` signature so the host switches to `IDENTIFY PACKET
DEVICE`, and `PACKET` carries `TEST UNIT READY`, `REQUEST SENSE`, `INQUIRY`,
`READ CAPACITY`, `READ(10)`, `READ(12)`, `READ TOC`, `MODE SENSE`, `GET
CONFIGURATION` and `GET EVENT STATUS`.

Responses honour the byte-count limit in the cylinder registers, so a transfer
larger than one block arrives in several DRQ rounds with the interrupt-reason
bits set as the protocol requires. When a read lands on an image chunk that has
not arrived yet, the device stays busy and re-runs the command the next time the
guest polls status — which is what the guest is doing anyway.

### Images are read on demand

An image is never loaded whole. A `ChunkStore` fetches 1 MiB pieces from the
source and caches them, so a multi-gigabyte ISO costs only the cache. Writes go
to an overlay, leaving the backing file untouched.

The awkward part is that `INT 13h` is synchronous while a browser `File` read is
not. A store may answer "not resident yet", and the BIOS responds by rewinding
the guest past the two-byte `OUT` that trapped into it, so the same disk call is
re-issued once the bytes have landed. Node reads synchronously and never takes
that path.

"Not resident yet" has to stay distinguishable from "not there". A boot catalog
can sit anywhere on a disc — osakaOS keeps its at 3.19 MiB — and reading it as
absent because the chunk had not arrived reported a perfectly good image as
having no boot record. Reads that need more data return a `NEED_DATA` sentinel
and the BIOS retries; only a genuine miss means the image is not bootable.

Two more things make that path usable rather than merely correct. Each miss pulls
the following chunks in behind it, because boot loaders read forward; and the
browser run loop awaits an outstanding read directly instead of letting the guest
spin until the next animation frame. Without the second one, a large image is limited
to roughly one chunk per frame, which shows up as the emulator apparently running
at a few MIPS while it is really just waiting. The test suite exercises the
asynchronous path with `X64EMU_ISO=<image> npm test`.

## Graphical mode

The VGA adapter puts video memory inside guest RAM, so the CPU writes pixels at
full speed and the renderer reads the same bytes back each frame instead of
trapping to the host per access.

| region | use |
| --- | --- |
| `0xB8000` | text mode character/attribute pairs |
| `0xA0000` | 64 KiB window, linear in mode 13h |
| top of RAM | linear framebuffer for the high-resolution modes |

- **Text modes** (`0x00`–`0x03`, `0x07`) render as glyphs on a canvas using the
  browser's monospace font, with code page 437 mapped for the box-drawing
  characters bootloader menus are made of. Only changed cells are redrawn.
- **Mode 13h** (320x200x256) renders through the VGA palette.
- **Planar modes** (`0x0D`, `0x0E`, `0x10`, `0x11`, `0x12`) are the four-plane
  EGA/VGA layouts, where one byte holds a single bit of eight pixels in each of
  four planes. While one is active the `0xA0000` window is taken away from
  memory and handed to the adapter, so writes run through the graphics
  controller: map mask, set/reset, the rotate and logic ops, the bit mask and
  the four latches, in all four write modes and both read modes.
- **High resolution** goes through the Bochs `dispi` register pair at
  `0x01CE/0x01CF`, driven by the VBE calls (`INT 10h AX=4F00–4F03`) the BIOS
  implements. Modes up to 1024x768x32 are offered, at 8, 16, 24 and 32 bpp.

A mode the adapter cannot draw no longer falls back to text in silence — it says
so on the console, because a guest happily drawing into a mode that is not being
displayed looks exactly like a broken emulator.

Keyboard input reaches the guest two ways: through the emulated 8042 as
scancode-set-1 bytes on IRQ 1, and through the BIOS keyboard buffer so that
software polling `INT 16h` works without a driver.

The PS/2 mouse is reachable the same two ways. Linux's `psmouse` drives the
8042 directly and finds it as a "PS/2 Generic Mouse"; Windows 95 goes through
the BIOS (`INT 15h AH=C2h`). In the browser, clicking the screen captures the
pointer and Esc releases it.

## The virtual BIOS

There is no BIOS binary. The ROM area contains only trampolines — for interrupt
vector `v`, the four bytes at `F000:v*4` are

```
E6 FA     out 0xFA, al      ; traps to the host
CF        iret
90        nop
```

The `OUT` preserves every register, the vector is recovered from the return
address, and handlers in `src/js/bios.js` read and write the guest's registers
directly. Because `IRET` restores flags from the stack, a handler's carry flag
is written into that saved image rather than into `RFLAGS`.

Implemented: `INT 10h` (modes, cursor, teletype, scrolling, write string,
palette and DAC, VBE), `INT 11h`, `INT 12h`, `INT 13h` (CHS and LBA reads, drive
parameters, extensions check, El Torito emulation status), `INT 15h` (`E820`,
`E801`, `AH=88`, A20, `AH=87` block move, `AH=C2` PS/2 mouse), `INT 16h`,
`INT 1Ah` and `INT 19h`. The hardware interrupt handlers (`INT 08h`, `09h`,
`0Ah`–`0Fh`, `70h`–`77h`) are not traps but x86 code in the ROM, so their `IN`
and `OUT` reach whatever virtualises the devices. `INT 74h`, IRQ 12, assembles
mouse packets and far-calls the handler installed through `INT 15h C207h`.
Calls made from virtual-8086 mode have their addresses translated through the
guest's page tables, the way the CPU would.

Images are recognised by content: an ISO 9660 signature makes it a CD (booted
through its El Torito boot catalog, no-emulation and floppy/hard-disk emulation
both handled), a known floppy size makes it a floppy, anything else is a hard
disk booted from its MBR. Writes are rejected — images are read-only.

## The CPU core

`src/wat/` is assembled in filename order into a single module.

| file | contents |
| --- | --- |
| `00_prologue.wat` | imports, globals, the state-block memory map |
| `10_state.wat` | register file, RFLAGS, control registers, mode tracking |
| `20_mem.wat` | exceptions, physical memory, TLB, page walkers, linear access |
| `30_seg.wat` | descriptors, segment loading, interrupts, IRET, SYSCALL |
| `40_decode.wat` | ModRM/SIB decoding, all addressing modes, stack access |
| `50_alu.wat` | arithmetic, shifts, 128-bit multiply and divide |
| `60_exec.wat` | prefix decoding and one-byte opcode handlers |
| `70_groups.wat` | group opcodes, string instructions, x87 stubs |
| `80_0f.wat` | two-byte opcodes: CPUID, MSRs, CR access, bit ops, SSE moves |
| `90_run.wat` | dispatch tables, step function, run loop, exports |

Design notes:

- **Dispatch** is a 256-entry byte map per opcode page, indexing a `funcref`
  table via `call_indirect`. Handlers are grouped by instruction family.
- **Faults** unwind through a `$fault` global rather than wasm exceptions.
  Memory helpers become no-ops once it is set, so a sequence of accesses is
  safe to write without a check after every one.
- **Guest RAM** lives in the same linear memory as CPU state, based at
  `0x10000`. Physical addresses past the end of RAM are routed to the host as
  MMIO.
- **Paging** implements all three walkers — legacy 2-level, PAE 3-level, and
  long-mode 4-level — with 2 MiB/1 GiB large pages, accessed/dirty bits, NX,
  CR0.WP, and a 1024-entry direct-mapped TLB.
- **Modes**: real, protected 16-bit, protected 32-bit, and long mode, with the
  operand/address-size rules and `d64` defaults each one implies.

### The x87 unit

`src/wat/75_x87.wat` implements the floating point stack. Registers are held as
`f64` rather than the architectural 80-bit format, which loses the extended
precision real hardware keeps between operations but makes ordinary computation
come out right. `ST(i)` names register `(top + i) & 7`, with a tag word and a
status word whose `TOP` field is folded in when it is read.

Covered: loads and stores for 32- and 64-bit reals, the 80-bit format, and 16,
32 and 64-bit integers; the arithmetic set with its reversed, popping and
integer forms; `FCOM`/`FUCOM`/`FCOMI` families feeding both the status word's
condition codes and the integer flags; the constant loads; `FSQRT`, `FRNDINT`,
`FSCALE`, `FPREM`, `FXCH`, `FABS`, `FCHS`; and the transcendentals. WebAssembly
has no sine, cosine, logarithm or exponential, so those are imported from the
host's `Math`.

This was not an abstract gap. osakaOS's graphical mode calls `pow()`, which is a
loop that multiplies an accumulator while incrementing a floating point counter
and testing it with `FCOMIP`. With the FPU doing nothing the counter never
advanced and the comparison never set flags, so the loop never exited: the mode
was set, nothing was drawn, and the screen stayed black. Nothing about that
looked like a floating point problem from the outside.

The MMX registers alias the x87 stack, as on hardware: MMX register *i* is the
64-bit significand of physical register *i*. The x87 registers are held as f64,
which cannot carry that, so a register written by MMX keeps its 80-bit form
beside the f64. x87 reads convert it, and `FXSAVE`/`FXRSTOR` save and restore
it bit for bit.

### Implemented

The full integer instruction set a kernel uses: all ALU forms, shifts and
rotates including `RCL`/`RCR`, `SHLD`/`SHRD`, 8/16/32/64-bit `MUL`/`IMUL` and
`DIV`/`IDIV` (including 128÷64), string instructions with `REP` prefixes,
bit instructions, `CMOVcc`, `SETcc`, `BSF`/`BSR`/`POPCNT`, `BSWAP`, `XADD`,
`CMPXCHG`, `CMPXCHG8B/16B`, `LGDT`/`LIDT`/`LLDT`/`LTR`, `MOV` to/from control
and debug registers, `CPUID`, `RDMSR`/`WRMSR`, `RDTSC`, `SWAPGS`, `SYSCALL`/
`SYSRET`, `INT`/`IRET`, far jumps and calls, `LAR`/`LSL`/`VERR`/`VERW`/`ARPL`,
and port I/O checked against IOPL and the TSS I/O permission bitmap.

Interrupt delivery covers real-mode IVT, 16- and 32-bit protected gates, and
long-mode 16-byte gates with IST and TSS-driven stack switching on privilege
changes.

**Virtual-8086 mode** works the 386 way, without VME (which is not advertised).
An `IRET` from ring 0 with `VM` set enters it. Segments load real-mode style at
CPL 3, and an interrupt or exception leaves it through a ring-0 gate with the
data segments pushed. `CLI`, `STI`, `PUSHF`, `POPF`, `INT n` and `IRET` trap
below IOPL 3, and port I/O always goes through the bitmap.

### Not implemented

These are real gaps, not oversights:

- **Anything past SSE2.** MMX, SSE and SSE2 are there (float and
  packed-integer arithmetic, compares, conversions, shuffles,
  `FXSAVE`/`FXRSTOR`, `MXCSR`),
  but there is no SSE3, SSSE3, SSE4 or AVX. `CPUID` advertises none of them, so
  glibc picks its SSE2 routines.
- **SMP.** One processor. A guest that waits for others to start waits
  forever; this is what stops TempleOS reaching its desktop.
- **More than one APIC.** There is one local APIC (its timer, self-IPIs, and
  priority) and one I/O APIC (`src/js/apic.js`), described by the MADT. Nothing
  answers INIT or startup IPIs, NMI delivery is not modelled, and there is no
  x2APIC.
- **Most of PCI, and DMI.** PCI config space (mechanism #1) shows a 440FX host
  bridge, a PIIX3 ISA bridge and its IDE function, and the ACPI DSDT declares
  a root bridge so Linux scans the bus. That is the whole bus: no BARs to
  speak of, no bus-master DMA, nothing else to find.
- **Network devices, and disks other than IDE.** No AHCI/NVMe, no virtio.
- **Task gates and hardware task switching** (`0x05` gate type).
- **The DMA controller.** Ports `0x00`–`0x0F` and `0xC0`–`0xDF` read as `FF`.
- **CGA and 4-colour modes** (`0x04`–`0x06`) and the mode 13h "Mode X" variants.
- **DMA.** The ATA and ATAPI controllers are PIO only; there is no bus-master
  IDE, so a guest that insists on DMA transfers will not get them.
- **Optical writing.** ATAPI is read-only; there is no burning.
- **Persistence.** The RAM drive is exactly that — memory. Nothing is written
  back to the source image, and nothing survives a reload unless exported.

## Booting Ubuntu: what stands between here and there

The headline goal was "run latest Ubuntu". This emulator boots a Linux kernel to
userspace, which is the hard, load-bearing half of that. The remaining half is
platform surface, and it is substantial:

1. ~~**A root filesystem needs a block device.**~~ Done: the ATA controller
   presents disks to a protected-mode OS, and images stream in chunks rather
   than being held in memory. Ubuntu's installer would still want a CD it can
   read after leaving real mode, which needs ATAPI.
2. ~~**Ubuntu's kernel is SMP-first and APIC-driven.**~~ Done for one processor:
   a local APIC and an I/O APIC, which Linux runs in symmetric I/O mode.
3. ~~**ACPI.**~~ Done: RSDP, RSDT/XSDT, FADT and a DSDT with a PCI root bridge
   are synthesised (`src/js/acpi.js`). The MADT stays off until there is a
   local APIC behind it.
4. ~~**SSE2 arithmetic is mandatory**~~ Done: glibc's SSE2 string routines and
   gcc-built floating point run, and `FXSAVE`/`FXRSTOR` let the kernel keep
   each process's XMM registers apart. Debian 13 userspace runs on it (see
   [Debian](#debian)).
5. **Performance.** At ~50 MIPS an Ubuntu boot would take on the order of an
   hour. Reaching usable speed needs a JIT that translates basic blocks to
   WebAssembly at run time, not an interpreter.

Items 1–4 are each a well-understood, bounded piece of work. Item 5 is a
different project.

## Performance

`node tools/bench.mjs` runs five microbenchmarks — register ALU, memory,
branches, mixed, and `rep movsq` — against the assembly in `tests/asm/bench.s`.

|                    | before | after |
| --- | ---: | ---: |
| register ALU       | 40.7 | 63.9 |
| memory             | 32.5 | 48.9 |
| branches           | 46.7 | 72.3 |
| mixed              | 36.4 | 53.3 |
| `rep movsq`        | 29.4 | 52.0 |
| **average**        | **37.1** | **59.6** |
| Linux boot to userspace | 33.1 MIPS / 47s | 49.9 MIPS / 31s |

What actually moved the needle, in order:

**Address caches (biggest).** Translating `CS:RIP` through the segment and TLB
machinery for *every byte* of every instruction dominated the profile. The core
now keeps the physical base of the current code page in a global, so fetching a
byte is a compare and an add. The same idea covers data: one cached page for
loads and one for stores, kept separate so they do not evict each other. This is
what took `rep movsq` from 29 to 52 MIPS. Every cache is dropped on a TLB flush,
`INVLPG`, a CPL change, a mode change or a CS reload, and is bypassed entirely
while `$sysacc` is set, so a descriptor read cannot leave behind a translation
that skipped the user/supervisor check.

**One flag store instead of six.** Each ALU operation wrote CF, PF, AF, ZF, SF
and OF individually — six read-modify-writes of RFLAGS. They are now assembled
into one value and stored once.

**Jump tables for the fixed dispatches.** Condition codes (every `Jcc`, `SETcc`
and `CMOVcc`) and the eight ALU operations went from comparison chains to
`br_table`. Operand-size and sign-bit masks come from small tables instead of
being recomputed with a variable shift. A 256-byte prefix map replaces a dozen
comparisons on the ~80% of instructions that carry no prefix.

**A leaner run loop.** The interrupt line is tested before the flags rather than
after, the post-`STI` shadow is only cleared when set, and the TSC is a global.

### Two things that were tried and reverted

Both are in the commentary because they are the obvious next ideas and they do
not work here:

- **Lazy flags** — deferring flag computation until something reads it. Measured
  **slower** (52.7 vs 56.0 average). A comparison is nearly always consumed by
  the branch immediately after it, so the deferral bookkeeping costs more than
  the arithmetic it avoids.
- **Manual inlining** of the hot helpers (`$trunc`, `$parity`, `$msb`) into the
  ALU primitives. Made no measurable difference: V8 already inlines small wasm
  functions, so the cost is the arithmetic, not the call. Moving RIP and RFLAGS
  from memory into globals likewise changed nothing, because constant-address
  loads from a hot 64 KiB memory are already about as cheap as globals.

### A second round, and where the ceiling is

A later pass added an **instruction window**: rather than a page check and a
memory load per instruction byte, the next eight bytes are pulled into a
register once per instruction and the decoder shifts them out. The run loop also
stopped touching memory on every iteration — the interrupt line is sampled every
64 instructions, the two slice-ending conditions share one test, and the
timestamp counter doubles as the loop counter. Together those moved the average
from 58 to roughly 61.

Four other changes were tried in that round and **reverted after measurement**:
jump tables for the size-generic register accessors, hand-assembled flag words
that place each bit where it already sits, skipping the per-instruction decoder
reset, and trimming the run loop further. Each was either neutral or slightly
negative — V8 was already doing better than the hand-written version.

That is the honest ceiling for this design, around **60 MIPS**. Profiling puts
roughly 40% of the time in the run loop with `step` and the fetch path inlined
into it, and the rest spread thinly across handlers with no single item above
10%. There is no remaining fat to trim; the cost is that every instruction is
decoded from scratch every time it executes.

Going materially faster needs that to stop being true:

- **A decoded-instruction cache** keyed by physical address, holding the
  handler, the prefix state, the decoded ModRM fields, the displacement and the
  immediate. Handlers would read operands from the record instead of re-fetching
  them, which means touching every handler that consumes an immediate. This
  removes the prefix loop, the opcode map lookup, ModRM decoding and immediate
  fetching from every repeat execution — plausibly 85-100 MIPS.
- **A basic-block JIT** emitting WebAssembly at run time, which is the only way
  past that and a different project again.

Neither is a tuning exercise, and both carry real regression risk against a test
suite that currently passes in full.

## Things that turned out to matter more than expected

A few defaults and details caused failures that looked like much bigger
problems, and are worth writing down.

**A machine with no hard disk hangs guests.** osakaOS polls the ATA status port
forever waiting for a drive, and spends five million reads doing it. Real
machines have a disk even when booting from CD, so one is attached by default
now: a sparse RAM drive costs nothing until written. The headless tools had a
different default from the browser, which is why a failure reported from the
browser could not be reproduced here — the tools now match the UI.

**The PIT has to be a real clock.** Guests latch the counter and read it back to
measure time. A counter that free-runs at an arbitrary rate, ignoring the latch
command, makes those loops measure nonsense or spin. It is now derived from the
machine's virtual clock, with the latch honoured.

**The CRTC index mask was wrong, and had been from the start.** Masking the
index with `0x2f` clears bit 4, so register `0x11` aliased onto `0x01`, `0x12`
onto `0x02` and `0x17` onto `0x07` — quietly corrupting vertical timing, the
row offset and the line compare for every guest. It is `0x3f` now, with a
regression test that writes those registers and checks they stay put.

**Plenty of software never calls the BIOS to change video mode.** osakaOS
programs the sequencer, CRTC and graphics controller itself to reach mode 13h.
The displayed geometry is therefore derived from the registers — graphics or
alphanumeric from the graphics controller, chain-4 from the sequencer, width
and height from the CRTC with its overflow and scan-doubling bits — and not
only from whatever `INT 10h` was last asked for.

**VGA registers are almost always written 16 bits at a time.** `mov ax,0x0102;
out dx,ax` writes an index and its data in one instruction. Masking the value to
eight bits silently discarded every map mask, bit mask and mode setting, which
made planar output blank even once the planar code existed.

## Testing

`tests/run.mjs` assembles each case with `clang`, applies relocations with
`tests/elf2bin.py` (there is no ELF linker in this toolchain), loads the flat
binary, and checks the guest's self-report on port `0xE9`.

| case | covers |
| --- | --- |
| `t_arith64` | 22 checks: carry/overflow, operand-size rules, shifts, 128-bit multiply and divide, `REP MOVSB`/`STOSQ`/`SCASQ`, bit ops, `CMOV`, `XADD`, `CMPXCHG` |
| `t_modes` | real mode segmentation → protected mode → page tables → long mode, `FS_BASE` via MSR, `#PF` with `CR2`, `INT`/`IRET`, `SYSCALL`/`SYSRET` down to ring 3 |
| `t_paging` | four-level mapping, `CR0.WP`, page-fault error codes, TLB staleness and `INVLPG` |
| `t_v86` | a minimal 386 monitor: virtual-8086 entry and exit frames, IOPL-sensitive instructions at IOPL 0 and 3, the I/O permission bitmap, `ARPL` as `#UD`, 16-bit gates, expand-down segments, and an `IRET` that faults without changing anything |
| `t_lar` | `LAR`, `LSL`, `VERR`, `VERW`: results, ZF, privilege rules, and bad selectors that must not fault |
| `t_sse2int` | the SSE2 integer set glibc is built from, generated by `tests/gen_sse2int.py` |
| `t_mmx` | every MMX form, and what MMX does to the x87 tags, TOP and `FXSAVE` image, generated by `tests/gen_mmx.py` |
| `t_fxsave` | the `FXSAVE` layout and an exact round trip of x87 and XMM state |

The two generators take their expected values from a model of the manual, not
from the emulator. Run with `--verify`, each builds the same cases into a native
x86-64 program (under Rosetta on Apple silicon) and checks the model against
the real CPU.

`t_x87` checks the FPU: arithmetic and stores against known bit patterns,
integer conversion, both comparison paths, and the `pow`-shaped loop above,
which hangs forever if any part of it is missing.

`tests/run_bios.mjs` covers the platform rather than the CPU:

- a floppy whose boot sector prints through `INT 10h`, switches to mode 13h and
  paints a known pattern — checked against the framebuffer bytes and the RGBA
  the renderer derives from them
- a boot sector that writes and reads the RAM drive through both the CHS and LBA
  `INT 13h` entry points, including that an unwritten sector reads back as zeros
  and that a 256 GiB drive commits only megabytes
- the browser renderer driven end to end through a stub canvas, asserting that
  text, mode 13h, planar and VBE modes each actually produce a picture — "the
  mode was set" and "the screen shows something" being different claims
- the ATA controller driven register by register the way a driver would:
  `IDENTIFY`, 48-bit capacity, the DRQ handshake, write-then-read, and that an
  unknown command aborts instead of hanging. Also per-block interrupts, LBA48,
  32-bit data transfers, CHS geometry, and disks past 4 GiB
- the local APIC, the I/O APIC and the RTC: self-IPIs, priority, EOI, edge and
  level pins, the timer firing on time, and the RTC's periodic interrupt

## Requirements

`wat2wasm` (wabt) to build. `clang` and `python3` to run the test suite. Node 20+
or any browser with WebAssembly for running.
