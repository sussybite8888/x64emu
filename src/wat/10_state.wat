  ;; =========================================================================
  ;;  Part 10: register file, RFLAGS, mode tracking
  ;; =========================================================================

  ;; ---- general purpose registers ----------------------------------------
  (func $reg64 (param $r i32) (result i64)
    (i64.load (i32.shl (local.get $r) (i32.const 3))))

  (func $setreg64 (param $r i32) (param $v i64)
    (i64.store (i32.shl (local.get $r) (i32.const 3)) (local.get $v)))

  (func $reg32 (param $r i32) (result i32)
    (i32.load (i32.shl (local.get $r) (i32.const 3))))

  ;; 32-bit writes zero the upper half (x86-64 rule)
  (func $setreg32 (param $r i32) (param $v i32)
    (i64.store (i32.shl (local.get $r) (i32.const 3))
               (i64.extend_i32_u (local.get $v))))

  (func $reg16 (param $r i32) (result i32)
    (i32.load16_u (i32.shl (local.get $r) (i32.const 3))))

  ;; 16-bit writes preserve the upper 48 bits
  (func $setreg16 (param $r i32) (param $v i32)
    (i32.store16 (i32.shl (local.get $r) (i32.const 3)) (local.get $v)))

  ;; 8-bit access.  Without a REX prefix registers 4..7 address AH/CH/DH/BH.
  (func $reg8 (param $r i32) (result i32)
    (if (result i32)
      (i32.and (i32.eqz (global.get $rex)) (i32.ge_u (local.get $r) (i32.const 4)))
      (then (i32.load8_u
              (i32.add (i32.shl (i32.sub (local.get $r) (i32.const 4)) (i32.const 3))
                       (i32.const 1))))
      (else (i32.load8_u (i32.shl (local.get $r) (i32.const 3))))))

  (func $setreg8 (param $r i32) (param $v i32)
    (if (i32.and (i32.eqz (global.get $rex)) (i32.ge_u (local.get $r) (i32.const 4)))
      (then (i32.store8
              (i32.add (i32.shl (i32.sub (local.get $r) (i32.const 4)) (i32.const 3))
                       (i32.const 1))
              (local.get $v)))
      (else (i32.store8 (i32.shl (local.get $r) (i32.const 3)) (local.get $v)))))

  ;; Size-generic register access.  A jump table was tried here and measured
  ;; slower than the ordered tests: 8 and 4 dominate, so they are checked first.
  (func $regN (param $r i32) (param $size i32) (result i64)
    (block $done (result i64)
      (if (i32.eq (local.get $size) (i32.const 8))
        (then (br $done (call $reg64 (local.get $r)))))
      (if (i32.eq (local.get $size) (i32.const 4))
        (then (br $done (i64.extend_i32_u (call $reg32 (local.get $r))))))
      (if (i32.eq (local.get $size) (i32.const 2))
        (then (br $done (i64.extend_i32_u (call $reg16 (local.get $r))))))
      (i64.extend_i32_u (call $reg8 (local.get $r)))))

  (func $setregN (param $r i32) (param $size i32) (param $v i64)
    (block $done
      (if (i32.eq (local.get $size) (i32.const 8))
        (then (call $setreg64 (local.get $r) (local.get $v)) (br $done)))
      (if (i32.eq (local.get $size) (i32.const 4))
        (then (call $setreg32 (local.get $r) (i32.wrap_i64 (local.get $v))) (br $done)))
      (if (i32.eq (local.get $size) (i32.const 2))
        (then (call $setreg16 (local.get $r) (i32.wrap_i64 (local.get $v))) (br $done)))
      (call $setreg8 (local.get $r) (i32.wrap_i64 (local.get $v)))))

  ;; ---- RIP ---------------------------------------------------------------
  (func $rip (result i64) (global.get $rip_g))
  ;; No need to touch the instruction window: it is refilled from RIP at the
  ;; top of every instruction, so it never outlives the one that set this.
  ;; Every control transfer comes through here, which makes it the one place
  ;; that can tell the block cache a branch target is about to be executed.
  (func $set_rip (param $v i64)
    (global.set $rip_g (local.get $v))
    (global.set $jit_head (i32.const 1)))
  (func $rip_add (param $d i64)
    (global.set $rip_g (i64.add (global.get $rip_g) (local.get $d))))

  ;; ---- RFLAGS ------------------------------------------------------------
  ;;  bit0 CF  bit2 PF  bit4 AF  bit6 ZF  bit7 SF  bit8 TF  bit9 IF
  ;;  bit10 DF bit11 OF bit12-13 IOPL bit14 NT bit16 RF bit17 VM bit18 AC
  (func $flags (result i64) (global.get $flags_g))
  (func $set_flags (param $v i64)
    (global.set $flags_g
      (i64.or (i64.and (local.get $v) (i64.const 0x3F7FD5))
              (i64.const 2))))          ;; bit1 always 1, reserved bits cleared

  (func $get_flag (param $bit i32) (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g)
                                      (i64.extend_i32_u (local.get $bit)))
                           (i64.const 1))))

  (func $set_flag (param $bit i32) (param $v i32)
    (global.set $flags_g
      (i64.or (i64.and (global.get $flags_g)
                       (i64.xor (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $bit)))
                                (i64.const -1)))
              (i64.shl (i64.extend_i32_u (i32.ne (local.get $v) (i32.const 0)))
                       (i64.extend_i32_u (local.get $bit))))))

  (func $cf (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 0))
                           (i64.const 1))))
  (func $pf (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 2))
                           (i64.const 1))))
  (func $af (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 4))
                           (i64.const 1))))
  (func $zf (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 6))
                           (i64.const 1))))
  (func $sf (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 7))
                           (i64.const 1))))
  (func $tf (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 8))
                           (i64.const 1))))
  (func $iff (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 9))
                           (i64.const 1))))
  (func $df (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 10))
                           (i64.const 1))))
  (func $of (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 11))
                           (i64.const 1))))

  ;; bulk flag update: mask selects which bits to replace
  (func $flags_merge (param $mask i64) (param $val i64)
    (global.set $flags_g
      (i64.or (i64.and (global.get $flags_g)
                       (i64.xor (local.get $mask) (i64.const -1)))
              (i64.and (local.get $val) (local.get $mask)))))

  ;; ---- control registers -------------------------------------------------
  (func $cr0  (result i64) (i64.load (i32.const 0x90)))
  (func $cr2  (result i64) (i64.load (i32.const 0x98)))
  (func $cr3  (result i64) (i64.load (i32.const 0xA0)))
  (func $cr4  (result i64) (i64.load (i32.const 0xA8)))
  (func $efer (result i64) (i64.load (i32.const 0xB0)))
  (func $set_cr0 (param $v i64)
    (i64.store (i32.const 0x90) (local.get $v))
    (global.set $cr0_wp
      (i32.wrap_i64 (i64.and (i64.shr_u (local.get $v) (i64.const 16)) (i64.const 1)))))
  (func $set_cr2  (param $v i64) (i64.store (i32.const 0x98) (local.get $v)))
  (func $set_cr3  (param $v i64) (i64.store (i32.const 0xA0) (local.get $v)))
  (func $set_cr4  (param $v i64) (i64.store (i32.const 0xA8) (local.get $v)))
  (func $set_efer (param $v i64) (i64.store (i32.const 0xB0) (local.get $v)))

  (func $cpl (result i32) (i32.load (i32.const 0xB8)))

  ;; Every privilege change is recorded in a small ring buffer at 0x800 so the
  ;; host can show how the CPU got where it did.  Entry: rip0(u64), old, new.
  (func $set_cpl (param $v i32)
    (local $slot i32)
    (if (i32.ne (local.get $v) (i32.load (i32.const 0xB8)))
      (then
        (local.set $slot (i32.add (i32.const 0x5010)
          (i32.shl (i32.and (i32.load (i32.const 0x5000)) (i32.const 127)) (i32.const 4))))
        (i64.store (local.get $slot) (global.get $rip0))
        (i32.store (i32.add (local.get $slot) (i32.const 8)) (i32.load (i32.const 0xB8)))
        (i32.store (i32.add (local.get $slot) (i32.const 12)) (local.get $v))
        (i32.store (i32.const 0x5000) (i32.add (i32.load (i32.const 0x5000)) (i32.const 1)))
        (call $flush_addr_caches)))
    (global.set $cpl_g (local.get $v))
    ;; Cached translations are tagged with the privilege they were checked
    ;; at, so they stay valid across the change; lookups just look for the
    ;; other tag from now on.
    (global.set $jtlb_bits
      (i32.or (i32.const 1) (i32.shl (i32.eq (local.get $v) (i32.const 3)) (i32.const 1))))
    (i32.store (i32.const 0xB8) (local.get $v)))

  ;; paging enabled?  CR0.PG (bit 31)
  (func $paging_on (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (call $cr0) (i64.const 31)) (i64.const 1))))
  ;; protected mode?  CR0.PE (bit 0)
  (func $pe_on (result i32)
    (i32.wrap_i64 (i64.and (call $cr0) (i64.const 1))))
  ;; long mode active?  EFER.LMA (bit 10)
  (func $lma (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (call $efer) (i64.const 10)) (i64.const 1))))
  ;; PAE?  CR4.PAE (bit 5)
  (func $pae_on (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (call $cr4) (i64.const 5)) (i64.const 1))))

  ;; ---- segment cache -----------------------------------------------------
  ;;  seg index: 0 ES, 1 CS, 2 SS, 3 DS, 4 FS, 5 GS
  (func $seg_off (param $s i32) (result i32)
    (i32.add (i32.const 0x100) (i32.shl (local.get $s) (i32.const 5))))

  (func $seg_sel (param $s i32) (result i32)
    (i32.load (call $seg_off (local.get $s))))
  (func $seg_base (param $s i32) (result i64)
    (i64.load (i32.add (call $seg_off (local.get $s)) (i32.const 8))))
  (func $seg_limit (param $s i32) (result i32)
    (i32.load (i32.add (call $seg_off (local.get $s)) (i32.const 16))))
  (func $seg_attr (param $s i32) (result i32)
    (i32.load (i32.add (call $seg_off (local.get $s)) (i32.const 20))))

  (func $seg_store (param $s i32) (param $sel i32) (param $base i64)
                   (param $limit i32) (param $attr i32)
    (local $o i32)
    (local.set $o (call $seg_off (local.get $s)))
    (i32.store (local.get $o) (local.get $sel))
    (i64.store (i32.add (local.get $o) (i32.const 8)) (local.get $base))
    (i32.store (i32.add (local.get $o) (i32.const 16)) (local.get $limit))
    (i32.store (i32.add (local.get $o) (i32.const 20)) (local.get $attr))
    ;; The fast limit compiled code checks: the limit itself, or -1 to send
    ;; every access through $seg_lin when the segment is expand-down, whose
    ;; limit is a lower bound rather than an upper one.
    (i64.store (i32.add (i32.const 0x1C0) (i32.shl (local.get $s) (i32.const 3)))
      (if (result i64) (i32.eq (i32.and (local.get $attr) (i32.const 0xC)) (i32.const 8))
        (then (i64.const -1))
        (else (i64.extend_i32_u (local.get $limit)))))
    ;; a new code segment moves every instruction address
    (if (i32.eq (local.get $s) (i32.const 1))
      (then (global.set $cs_base (local.get $base))
            (global.set $fetch_page (i64.const -1))))
    ;; A compiled block was built for one code segment's default sizes and one
    ;; stack width; a new CS or SS ends it.
    (if (i32.le_u (i32.sub (local.get $s) (i32.const 1)) (i32.const 1))
      (then (global.set $jit_exit (i32.const 1)))))

  ;; attr bit helpers
  (func $seg_is_code (param $s i32) (result i32)
    (i32.and (i32.shr_u (call $seg_attr (local.get $s)) (i32.const 2)) (i32.const 1)))
  (func $seg_long (param $s i32) (result i32)
    (i32.and (i32.shr_u (call $seg_attr (local.get $s)) (i32.const 4)) (i32.const 1)))
  (func $seg_db (param $s i32) (result i32)
    (i32.and (i32.shr_u (call $seg_attr (local.get $s)) (i32.const 5)) (i32.const 1)))
  (func $seg_dpl (param $s i32) (result i32)
    (i32.and (i32.shr_u (call $seg_attr (local.get $s)) (i32.const 8)) (i32.const 3)))

  ;; ---- descriptor table registers ---------------------------------------
  (func $gdt_base  (result i64) (i64.load (i32.const 0x200)))
  (func $gdt_limit (result i32) (i32.load (i32.const 0x208)))
  (func $idt_base  (result i64) (i64.load (i32.const 0x210)))
  (func $idt_limit (result i32) (i32.load (i32.const 0x218)))

  ;; ---- execution mode ----------------------------------------------------
  ;;  0 = real mode / vm86 (16-bit), told apart by $vm
  ;;  1 = protected 16-bit
  ;;  2 = protected 32-bit
  ;;  3 = long mode 64-bit
  (func $recompute_mode
    (call $flush_addr_caches)
    (global.set $jit_exit (i32.const 1))
    (global.set $vm (i32.const 0))
    (if (i32.eqz (call $pe_on))
      (then (global.set $mode (i32.const 0))
            ;; real mode always runs at privilege 0
            (if (i32.ne (global.get $cpl_g) (i32.const 0))
              (then (call $set_cpl (i32.const 0)))))
      (else
        (if (call $get_flag (i32.const 17))
          (then
            ;; virtual-8086: real-mode addressing, always at privilege 3
            (global.set $vm (i32.const 1))
            (global.set $mode (i32.const 0))
            (if (i32.ne (global.get $cpl_g) (i32.const 3))
              (then (call $set_cpl (i32.const 3)))))
          (else
            (if (i32.and (call $lma) (call $seg_long (i32.const 1)))
              (then (global.set $mode (i32.const 3)))
              (else
                (if (call $seg_db (i32.const 1))
                  (then (global.set $mode (i32.const 2)))
                  (else (global.set $mode (i32.const 1))))))))))
    (call $cache_mode_defaults))

  (func $iopl (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (global.get $flags_g) (i64.const 12)) (i64.const 3))))

  ;; default operand / address size for the current mode, cached by
  ;; default operand / address size for the current mode, cached by
  ;; $recompute_mode so the decoder just reads a global
  (func $default_opsize (result i32) (global.get $def_op))
  (func $default_addrsize (result i32) (global.get $def_addr))

  (func $cache_mode_defaults
    (global.set $pfx_dirty (i32.const 1))     ;; the defaults just moved
    (global.set $rip_mask
      (if (result i64) (i32.eq (global.get $mode) (i32.const 3))
        (then (i64.const -1)) (else (i64.const 0xFFFFFFFF))))
    (if (i32.eq (global.get $mode) (i32.const 3))
      (then (global.set $def_op (i32.const 4)) (global.set $def_addr (i32.const 8)))
      (else (if (i32.eq (global.get $mode) (i32.const 2))
              (then (global.set $def_op (i32.const 4)) (global.set $def_addr (i32.const 4)))
              (else (global.set $def_op (i32.const 2)) (global.set $def_addr (i32.const 2)))))))

  ;; ---- stack pointer, honours 16/32/64-bit stack width -------------------
  (func $stack_size (result i32)
    (if (result i32) (i32.eq (global.get $mode) (i32.const 3))
      (then (i32.const 8))
      (else (if (result i32) (call $seg_db (i32.const 2))
              (then (i32.const 4))
              (else (i32.const 2))))))

  ;; ---- TSC / cycles ------------------------------------------------------
  (func $tsc (result i64) (global.get $tsc_g))
  (func $tsc_set (param $v i64) (global.set $tsc_g (local.get $v)))
  (func $tsc_add (param $n i64)
    (global.set $tsc_g (i64.add (global.get $tsc_g) (local.get $n))))
