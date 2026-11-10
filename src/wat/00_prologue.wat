;; ===========================================================================
;;  x64emu - x86-64 CPU core, WebAssembly Text format
;;  Part 00: module prologue, imports, globals, state layout
;; ===========================================================================
;;
;;  MEMORIES
;;    memory 0 ($state)  64 KiB, 32-bit indexed: all CPU state and the TLB
;;    memory 1 ($ram)    guest physical RAM, 64-bit indexed and growable
;;
;;  Guest physical address P indexes $ram directly while P < ram_size; anything
;;  at or above ram_size is routed to the host as MMIO.  Keeping RAM in its own
;;  64-bit memory is what lifts the 4 GiB ceiling a single wasm32 memory imposes,
;;  and it means state accesses stay cheap 32-bit loads.
;;
;;  STATE BLOCK OFFSETS
;;    0x0000  GPR[16] u64   RAX RCX RDX RBX RSP RBP RSI RDI R8..R15
;;    0x0080  RIP
;;    0x0088  RFLAGS
;;    0x0090  CR0   0x0098 CR2   0x00A0 CR3   0x00A8 CR4   0x00B0 EFER
;;    0x00B8  CPL(u32)  0x00BC halted(u32)
;;    0x00C0  cycle counter (u64)
;;    0x00C8  exc_vector(u32) 0x00CC exc_has_error(u32)
;;    0x00D0  exc_error(u64)
;;    0x00D8  irq_pending(u32) 0x00DC inhibit_irq(u32)
;;    0x00E0  tsc(u64)
;;    0x00E8  exit_reason(u32) 0x00EC last_instr_len(u32)
;;    0x00F0  spare (the A20 mask is the global $a20_mask)
;;    0x00F8  nmi_pending(u32)  0x00FC smp_id(u32)
;;
;;    0x0100  segment cache, 6 x 32 bytes: ES CS SS DS FS GS
;;              +0  selector (u32)
;;              +8  base (u64)
;;              +16 limit (u32, byte granular, already scaled)
;;              +20 attr (u32)  bit0 present, bit1 writable/readable,
;;                              bit2 code, bit3 expand-down/conforming,
;;                              bit4 long(L), bit5 default32(D/B),
;;                              bits8-9 DPL, bit10 accessed, bit11 unusable
;;              +24 raw descriptor high dword (u32)
;;    0x0200  GDTR base(u64) / 0x0208 limit(u32)
;;    0x0210  IDTR base(u64) / 0x0218 limit(u32)
;;    0x0220  LDTR cache (32 bytes)
;;    0x0240  TR   cache (32 bytes)
;;    0x0260  KERNEL_GS_BASE(u64)
;;    0x0268  STAR  0x0270 LSTAR  0x0278 CSTAR  0x0280 SFMASK
;;    0x0288  TSC_AUX
;;    0x0290  DR0..DR7 (8 x u64)
;;    0x02D0  APIC_BASE   0x02D8 PAT   0x02E0 MISC_ENABLE  0x02E8 MTRR_DEF
;;    0x02F0  EFER shadow / spare
;;
;;    0x0300  decoder scratch (see part 40)
;;    0x0400  XMM[16] x 16 bytes
;;    0x0500  MXCSR(u32) 0x0504 fpu_sw 0x0508 fpu_cw 0x050C spare
;;    0x0510  x87 register file, 8 x f64 by physical index -> 0x0510..0x054F
;;    0x0590  fpu top-of-stack (u32)   0x0594 tag word, 2 bits per register
;;
;;    0x0600  one-byte opcode map   0x0700  two-byte opcode map
;;    0x1000  TLB: 1024 entries x 16 bytes = 16 KiB
;;              +0  tag  (u64) = (virt_page << 12) | valid<<0 | global<<1
;;              +8  data (u64) = (phys_page << 12) | user<<0 | write<<1 | nx<<2
;;    0x5000  privilege-change ring buffer (index, then 128 x 16 bytes)
;;    0x5900  exception ring buffer (index, then 64 x 32 bytes)
;;    0x6200  operand-size masks, indexed by size in bytes
;;    0x6248  sign-bit masks, indexed by size in bytes
;;    0x6300  prefix map: non-zero for every byte that is a prefix
;;    0x7000  execution ring (index, then 1024 x 16 bytes at 0x7008)
;;              +0 rip   +8 the register named by $trace_reg
;;    0x1C0   per-segment fast limit (6 x i64): the highest offset an access
;;              may end at and still take compiled code's inline path, or -1
;;              when every access must go the slow way (expand-down segments).
;;              Kept by $seg_store.
;;
;;    The state memory is 4.5 MiB; everything from 0x10000 belongs to the JIT
;;    and is laid out in part 85.
;;
;;    0xF800  x87 form histogram: one byte per (escape opcode, ModRM) pair,
;;              set when that encoding executes.  Unimplemented x87 forms fall
;;              through and do nothing rather than faulting, so this is what
;;              turns "a float came out wrong" into a list of opcodes to check.
;;    0xB010  memory watch ring (index, then 64 x 32 bytes at 0xB018)
;;              +0 rip  +8 address  +16 value  +24 size
;; ===========================================================================

(module
  ;; ---- imports ---------------------------------------------------------
  ;;  Memory 0 is the state block; instructions without an explicit memory
  ;;  operand address it, so every state access below stays a plain i32 load.
  (import "env" "state" (memory $state 72))
  (import "env" "ram" (memory $ram i64 1))

  ;;  Compiled blocks are published here by the host and reached with one
  ;;  call_indirect, which is what keeps a JIT hit free of any JavaScript
  ;;  transition.  The table is empty, and the JIT disabled, until the host
  ;;  says otherwise, so a build that never compiles anything pays only for the
  ;;  one predictable branch that tests $jit_on.
  (import "env" "jit" (table $jit 1 funcref))

  ;; port I/O:  (port, size) -> value    /  (port, size, value)
  (import "env" "io_read"    (func $io_read  (param i32 i32) (result i32)))
  (import "env" "io_write"   (func $io_write (param i32 i32 i32)))

  ;; memory mapped I/O for physical addresses outside RAM
  (import "env" "mmio_read"  (func $mmio_read  (param i64 i32) (result i64)))
  (import "env" "mmio_write" (func $mmio_write (param i64 i32 i64)))

  ;; A store reached a 16-byte region holding compiled code: does it touch the
  ;; instructions themselves?  The host keeps the byte-exact map; asking it only
  ;; happens on this rare path.  Returns 1 if it does.
  (import "env" "jit_precise" (func $jit_precise (param i64 i32) (result i32)))

  ;; interrupt controller: returns vector 0..255, or -1 if nothing pending
  (import "env" "irq_ack"    (func $irq_ack (result i32)))

  ;; host notifications / debugging
  (import "env" "host_log"   (func $host_log (param i32 i64 i64)))

  ;; Transcendentals for the x87 unit.  WebAssembly has no sin/cos/log/exp, so
  ;; these come from the host's Math.
  (import "env" "f_sin"   (func $f_sin   (param f64) (result f64)))
  (import "env" "f_cos"   (func $f_cos   (param f64) (result f64)))
  (import "env" "f_atan2" (func $f_atan2 (param f64) (param f64) (result f64)))
  (import "env" "f_log2"  (func $f_log2  (param f64) (result f64)))
  (import "env" "f_exp2"  (func $f_exp2  (param f64) (result f64)))
  (import "env" "f_fmod"  (func $f_fmod  (param f64) (param f64) (result f64)))

  ;; ---- globals ---------------------------------------------------------
  (global $ram_size (mut i64) (i64.const 0))   ;; guest physical RAM bytes
  (global $fault    (mut i32) (i32.const 0))   ;; 1 = exception raised, unwind
  (global $mode     (mut i32) (i32.const 0))   ;; 0 real16, 2 prot32, 3 long64
  ;; Debug tracing.  Both are off by default and cost one predictable branch
  ;; per instruction when off, which is what keeps them affordable to leave in.
  (global $trace_on  (mut i32) (i32.const 0))
  (global $trace_reg (mut i32) (i32.const 1))  ;; GPR recorded alongside RIP
  (global $watch_lo  (mut i64) (i64.const 0))
  (global $watch_len (mut i32) (i32.const 0))
  (global $halted   (mut i32) (i32.const 0))
  (global $exit_req (mut i32) (i32.const 0))
  (global $sysacc   (mut i32) (i32.const 0))   ;; CPU-internal table access
  ;; When set, the 0xA0000-0xB0000 window is handed to the host instead of
  ;; being plain RAM, so the VGA's planar write logic can run.  Text mode at
  ;; 0xB8000 is deliberately left as ordinary memory.
  (global $vga_mmio (mut i32) (i32.const 0))
  ;; Where the routed window ends: 0xB0000 normally, 0xB8100 while the SVGA
  ;; also has its BitBLT registers at 0xB8000 (Cirrus SR17).
  (global $vga_win_hi (mut i64) (i64.const 0xB0000))
  ;; A range of physical addresses inside RAM that is nevertheless handed to
  ;; the host: the SVGA's BitBLT aperture, and the whole framebuffer while the
  ;; CPU is feeding the blitter.  Empty when $trap_hi is zero.
  (global $trap_lo (mut i64) (i64.const 0))
  (global $trap_hi (mut i64) (i64.const 0))
  ;; ANDed into every physical address.  All ones with A20 on; with the gate
  ;; off bit 20 is clear, so FFFF:0010 wraps to zero as on an 8086.  HIMEM
  ;; checks for that wrap and retries until it sees it.
  (global $a20_mask (mut i64) (i64.const -1))
  ;; Virtual-8086 mode: EFLAGS.VM under CR0.PE.  $mode reads 0 then, as in
  ;; real mode, because the operand and address defaults are the same; this is
  ;; what tells the two apart where they differ -- privilege, interrupts, I/O.
  (global $vm (mut i32) (i32.const 0))

  ;; decoder state kept in globals (hot path, avoids memory traffic)
  (global $rex      (mut i32) (i32.const 0))   ;; 0 = absent, else 0x40|WRXB
  (global $opsize   (mut i32) (i32.const 4))   ;; 1,2,4,8 bytes
  (global $addrsize (mut i32) (i32.const 4))   ;; 2,4,8 bytes
  (global $segovr   (mut i32) (i32.const -1))  ;; -1 = default
  (global $rep      (mut i32) (i32.const 0))   ;; 0 none, 2 repnz(F2), 3 repz(F3)
  (global $lockp    (mut i32) (i32.const 0))
  (global $op66     (mut i32) (i32.const 0))
  (global $mmx_lanes (mut i32) (i32.const 0))  ;; MMX operands staged for the SSE2 lane code
  (global $modrm    (mut i32) (i32.const 0))
  (global $mrm_reg  (mut i32) (i32.const 0))   ;; reg field, REX.R applied
  ;; The same field, without REX.R.  When the reg field selects an operation
  ;; rather than a register, REX.R is not part of it.
  (global $mrm_ext  (mut i32) (i32.const 0))
  (global $mrm_rm   (mut i32) (i32.const 0))   ;; rm register, REX.B applied
  (global $mrm_mem  (mut i32) (i32.const 0))   ;; 1 = memory operand
  (global $mrm_addr (mut i64) (i64.const 0))   ;; linear address of operand
  (global $mrm_seg  (mut i32) (i32.const 3))   ;; segment used for operand
  (global $rip0     (mut i64) (i64.const 0))   ;; RIP at instruction start
  (global $rsp0     (mut i64) (i64.const 0))   ;; RSP at instruction start
  ;; Set whenever a prefix (or a mode change) leaves the decoder state dirty.
  ;; When it is clear the state already holds its defaults, so the per
  ;; instruction reset can be skipped entirely.
  (global $pfx_dirty (mut i32) (i32.const 1))

  ;; ---- instruction fetch cache -----------------------------------------
  ;;  Translating CS:RIP for every byte of every instruction dominated the
  ;;  profile.  These hold the code page the last fetch resolved to, so the
  ;;  common case is a compare and an add.  $fetch_page is -1 when invalid,
  ;;  which no page-aligned address can match.
  ;; Cached copies of state the address path consults on every access, so it
  ;; does not have to reload CPL and CR0 from memory each time.
  (global $cpl_g   (mut i32) (i32.const 0))
  (global $cr0_wp  (mut i32) (i32.const 0))

  ;; RIP and RFLAGS are scalars touched several times per instruction, so they
  ;; live in globals; the state block copies at 0x80/0x88 are only refreshed for
  ;; the host's benefit.  The timestamp counter is a global for the same reason.
  (global $rip_g   (mut i64) (i64.const 0))
  (global $flags_g (mut i64) (i64.const 2))
  (global $tsc_g   (mut i64) (i64.const 0))


  ;; Default operand and address size for the current mode, recomputed only
  ;; when the mode changes instead of per instruction.
  (global $def_op  (mut i32) (i32.const 4))
  (global $def_addr (mut i32) (i32.const 4))

  ;; Instruction window.  Decoding an instruction used to cost one page check
  ;; and one memory load per byte; instead the next eight bytes are pulled into
  ;; a register once per instruction and the decoder shifts them out.
  (global $iw       (mut i64) (i64.const 0))   ;; the bytes, low byte first
  (global $iw_left  (mut i32) (i32.const 0))   ;; how many are still valid
  ;; RIP is masked to this after every advance, which avoids a mode test per byte
  (global $rip_mask (mut i64) (i64.const -1))

  (global $cs_base    (mut i64) (i64.const 0))
  (global $fetch_page (mut i64) (i64.const -1))
  (global $fetch_phys (mut i64) (i64.const 0))

  ;; Data accesses go through the translation cache in part 85 (the "JIT
  ;; TLB"), which the interpreter and compiled code share.  An entry's tag
  ;; carries the page and whether it was filled for user or supervisor access;
  ;; this is the bit pattern the current privilege looks for: bit 0 valid, bit
  ;; 1 user.  It changes with CPL, so a privilege change needs no flush.
  (global $jtlb_bits (mut i32) (i32.const 1))

  ;; Set by anything that leaves a running compiled block's assumptions wrong:
  ;; a write to a page holding compiled code, a mode or CS/SS change, a TLB
  ;; flush.  A block checks it after every call it makes out to the core.
  (global $jit_exit (mut i32) (i32.const 0))
  ;; Instructions a block may retire before it must return; compiled loops
  ;; consult it so a long loop cannot hold off the timer.
  (global $jit_budget (mut i32) (i32.const 0))

  ;; Guest RAM now starts at offset 0 of its own memory; kept as a function so
  ;; the host does not have to special-case anything.
  (func $ram_base (result i32) (i32.const 0))
