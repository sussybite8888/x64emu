  ;; =========================================================================
  ;;  Part 40: ModRM / SIB decoding and operand access
  ;; =========================================================================

  (global $riprel (mut i32) (i32.const 0))   ;; operand is RIP-relative

  ;; Mask a value to `size` bytes.  The mask comes from a table because this is
  ;; called two or three times per ALU operation and computing it involved a
  ;; variable shift and a subtract every time.
  (func $trunc (param $v i64) (param $size i32) (result i64)
    (i64.and (local.get $v)
             (i64.load (i32.add (i32.const 0x6200)
                                (i32.shl (local.get $size) (i32.const 3))))))

  ;; sign-extend a size-byte value to 64 bits
  (func $sext (param $v i64) (param $size i32) (result i64)
    (local $sh i64)
    (local.set $sh (i64.extend_i32_u (i32.sub (i32.const 64)
                                      (i32.shl (local.get $size) (i32.const 3)))))
    (i64.shr_s (i64.shl (local.get $v) (local.get $sh)) (local.get $sh)))

  ;; most significant bit mask for a size, likewise from a table
  (func $msb (param $size i32) (result i64)
    (i64.load (i32.add (i32.const 0x6248) (i32.shl (local.get $size) (i32.const 3)))))

  ;; ---- 16-bit addressing forms -------------------------------------------
  (func $addr16 (param $mod i32) (param $rm i32) (result i64)
    (local $a i32) (local $seg i32)
    (local.set $seg (i32.const 3))                 ;; DS unless BP is involved
    (block $d
      (if (i32.eq (local.get $rm) (i32.const 0))
        (then (local.set $a (i32.add (call $reg16 (i32.const 3)) (call $reg16 (i32.const 6)))) (br $d)))
      (if (i32.eq (local.get $rm) (i32.const 1))
        (then (local.set $a (i32.add (call $reg16 (i32.const 3)) (call $reg16 (i32.const 7)))) (br $d)))
      (if (i32.eq (local.get $rm) (i32.const 2))
        (then (local.set $a (i32.add (call $reg16 (i32.const 5)) (call $reg16 (i32.const 6))))
              (local.set $seg (i32.const 2)) (br $d)))
      (if (i32.eq (local.get $rm) (i32.const 3))
        (then (local.set $a (i32.add (call $reg16 (i32.const 5)) (call $reg16 (i32.const 7))))
              (local.set $seg (i32.const 2)) (br $d)))
      (if (i32.eq (local.get $rm) (i32.const 4))
        (then (local.set $a (call $reg16 (i32.const 6))) (br $d)))
      (if (i32.eq (local.get $rm) (i32.const 5))
        (then (local.set $a (call $reg16 (i32.const 7))) (br $d)))
      (if (i32.eq (local.get $rm) (i32.const 6))
        (then
          (if (i32.eq (local.get $mod) (i32.const 0))
            (then (local.set $a (call $fetch16)))
            (else (local.set $a (call $reg16 (i32.const 5)))
                  (local.set $seg (i32.const 2))))
          (br $d)))
      (local.set $a (call $reg16 (i32.const 3))))
    (if (i32.eq (local.get $mod) (i32.const 1))
      (then (local.set $a (i32.add (local.get $a) (i32.extend8_s (call $fetch8))))))
    (if (i32.eq (local.get $mod) (i32.const 2))
      (then (local.set $a (i32.add (local.get $a) (call $fetch16)))))
    (if (i32.eq (global.get $segovr) (i32.const -1))
      (then (global.set $mrm_seg (local.get $seg)))
      (else (global.set $mrm_seg (global.get $segovr))))
    (i64.extend_i32_u (i32.and (local.get $a) (i32.const 0xFFFF))))

  ;; ---- 32/64-bit addressing ----------------------------------------------
  (func $addr32 (param $mod i32) (param $rm i32) (result i64)
    (local $a i64) (local $sib i32) (local $base i32) (local $index i32)
    (local $scale i32) (local $seg i32) (local $have_base i32)
    (local.set $seg (i32.const 3))
    (local.set $have_base (i32.const 1))
    (local.set $a (i64.const 0))

    (if (i32.eq (local.get $rm) (i32.const 4))
      (then
        ;; SIB byte
        (local.set $sib (call $fetch8))
        (local.set $scale (i32.shr_u (local.get $sib) (i32.const 6)))
        (local.set $index (i32.or (i32.and (i32.shr_u (local.get $sib) (i32.const 3)) (i32.const 7))
                                  (i32.shl (i32.and (i32.shr_u (global.get $rex) (i32.const 1)) (i32.const 1))
                                           (i32.const 3))))
        (local.set $base (i32.or (i32.and (local.get $sib) (i32.const 7))
                                 (i32.shl (i32.and (global.get $rex) (i32.const 1)) (i32.const 3))))
        ;; index 4 with REX.X clear means "no index"
        (if (i32.ne (local.get $index) (i32.const 4))
          (then (local.set $a (i64.shl (call $reg64 (local.get $index))
                                       (i64.extend_i32_u (local.get $scale))))))
        (if (i32.and (i32.eq (i32.and (local.get $sib) (i32.const 7)) (i32.const 5))
                     (i32.eq (local.get $mod) (i32.const 0)))
          (then
            (local.set $a (i64.add (local.get $a) (i64.extend_i32_s (call $fetch32))))
            (local.set $have_base (i32.const 0)))
          (else
            (local.set $a (i64.add (local.get $a) (call $reg64 (local.get $base))))
            (if (i32.or (i32.eq (i32.and (local.get $base) (i32.const 7)) (i32.const 4))
                        (i32.eq (i32.and (local.get $base) (i32.const 7)) (i32.const 5)))
              (then (local.set $seg (i32.const 2)))))))   ;; RSP/RBP based -> SS
      (else
        (if (i32.and (i32.eq (local.get $rm) (i32.const 5)) (i32.eq (local.get $mod) (i32.const 0)))
          (then
            ;; disp32, RIP-relative in 64-bit mode
            (local.set $a (i64.extend_i32_s (call $fetch32)))
            (if (i32.eq (global.get $mode) (i32.const 3))
              (then (global.set $riprel (i32.const 1))))
            (local.set $have_base (i32.const 0)))
          (else
            (local.set $a (call $reg64
                            (i32.or (local.get $rm)
                                    (i32.shl (i32.and (global.get $rex) (i32.const 1)) (i32.const 3)))))
            (if (i32.eq (local.get $rm) (i32.const 5))
              (then (local.set $seg (i32.const 2))))))))  ;; RBP based -> SS

    (if (i32.eq (local.get $mod) (i32.const 1))
      (then (local.set $a (i64.add (local.get $a) (i64.extend_i32_s (i32.extend8_s (call $fetch8)))))))
    (if (i32.eq (local.get $mod) (i32.const 2))
      (then (local.set $a (i64.add (local.get $a) (i64.extend_i32_s (call $fetch32))))))

    (if (i32.eq (global.get $segovr) (i32.const -1))
      (then (global.set $mrm_seg (local.get $seg)))
      (else (global.set $mrm_seg (global.get $segovr))))

    ;; 32-bit address size truncates
    (if (i32.eq (global.get $addrsize) (i32.const 4))
      (then (local.set $a (i64.and (local.get $a) (i64.const 0xFFFFFFFF)))))
    (local.get $a))

  ;; ---- decode the ModRM byte ---------------------------------------------
  (func $decode_modrm
    (local $m i32) (local $mod i32) (local $rm i32)
    (local.set $m (call $fetch8))
    (global.set $modrm (local.get $m))
    (global.set $riprel (i32.const 0))
    (local.set $mod (i32.shr_u (local.get $m) (i32.const 6)))
    (local.set $rm (i32.and (local.get $m) (i32.const 7)))
    (global.set $mrm_ext (i32.and (i32.shr_u (local.get $m) (i32.const 3)) (i32.const 7)))
    (global.set $mrm_reg
      (i32.or (global.get $mrm_ext)
              (i32.shl (i32.and (i32.shr_u (global.get $rex) (i32.const 2)) (i32.const 1))
                       (i32.const 3))))
    (if (i32.eq (local.get $mod) (i32.const 3))
      (then
        (global.set $mrm_mem (i32.const 0))
        (global.set $mrm_rm (i32.or (local.get $rm)
                              (i32.shl (i32.and (global.get $rex) (i32.const 1)) (i32.const 3))))
        (return)))
    (global.set $mrm_mem (i32.const 1))
    (if (i32.eq (global.get $addrsize) (i32.const 2))
      (then (global.set $mrm_addr (call $addr16 (local.get $mod) (local.get $rm))))
      (else (global.set $mrm_addr (call $addr32 (local.get $mod) (local.get $rm))))))

  ;; effective offset of the memory operand (resolves RIP-relative lazily,
  ;; which is why every handler fetches its immediate before touching memory)
  (func $mrm_off (result i64)
    (if (result i64) (global.get $riprel)
      (then (i64.add (global.get $mrm_addr) (call $rip)))
      (else (global.get $mrm_addr))))

  ;; ---- operand read / write ----------------------------------------------
  (func $rm_read (param $size i32) (result i64)
    (if (result i64) (global.get $mrm_mem)
      (then (call $seg_read (global.get $mrm_seg) (call $mrm_off) (local.get $size)))
      (else (call $regN (global.get $mrm_rm) (local.get $size)))))

  (func $rm_write (param $size i32) (param $v i64)
    (if (global.get $mrm_mem)
      (then (call $seg_write (global.get $mrm_seg) (call $mrm_off) (local.get $size) (local.get $v)))
      (else (call $setregN (global.get $mrm_rm) (local.get $size) (local.get $v)))))

  (func $reg_read (param $size i32) (result i64)
    (call $regN (global.get $mrm_reg) (local.get $size)))

  (func $reg_write (param $size i32) (param $v i64)
    (call $setregN (global.get $mrm_reg) (local.get $size) (local.get $v)))

  ;; ---- stack -------------------------------------------------------------
  (func $push (param $v i64) (param $size i32)
    (local $sp i64)
    (if (i32.eq (global.get $mode) (i32.const 3))
      (then
        (local.set $sp (i64.sub (call $reg64 (i32.const 4)) (i64.extend_i32_u (local.get $size))))
        (call $lin_write (local.get $sp) (local.get $size) (local.get $v))
        (if (global.get $fault) (then (return)))
        (call $setreg64 (i32.const 4) (local.get $sp))
        (return)))
    (if (call $seg_db (i32.const 2))
      (then
        (local.set $sp (i64.and (i64.sub (call $reg64 (i32.const 4))
                                         (i64.extend_i32_u (local.get $size)))
                                (i64.const 0xFFFFFFFF)))
        (call $seg_write (i32.const 2) (local.get $sp) (local.get $size) (local.get $v))
        (if (global.get $fault) (then (return)))
        (call $setreg32 (i32.const 4) (i32.wrap_i64 (local.get $sp))))
      (else
        (local.set $sp (i64.and (i64.sub (call $reg64 (i32.const 4))
                                         (i64.extend_i32_u (local.get $size)))
                                (i64.const 0xFFFF)))
        (call $seg_write (i32.const 2) (local.get $sp) (local.get $size) (local.get $v))
        (if (global.get $fault) (then (return)))
        (call $setreg16 (i32.const 4) (i32.wrap_i64 (local.get $sp))))))

  (func $pop (param $size i32) (result i64)
    (local $sp i64) (local $v i64)
    (if (i32.eq (global.get $mode) (i32.const 3))
      (then
        (local.set $sp (call $reg64 (i32.const 4)))
        (local.set $v (call $lin_read (local.get $sp) (local.get $size)))
        (if (global.get $fault) (then (return (i64.const 0))))
        (call $setreg64 (i32.const 4) (i64.add (local.get $sp) (i64.extend_i32_u (local.get $size))))
        (return (local.get $v))))
    (if (call $seg_db (i32.const 2))
      (then
        (local.set $sp (i64.and (call $reg64 (i32.const 4)) (i64.const 0xFFFFFFFF)))
        (local.set $v (call $seg_read (i32.const 2) (local.get $sp) (local.get $size)))
        (if (global.get $fault) (then (return (i64.const 0))))
        (call $setreg32 (i32.const 4)
              (i32.wrap_i64 (i64.add (local.get $sp) (i64.extend_i32_u (local.get $size))))))
      (else
        (local.set $sp (i64.and (call $reg64 (i32.const 4)) (i64.const 0xFFFF)))
        (local.set $v (call $seg_read (i32.const 2) (local.get $sp) (local.get $size)))
        (if (global.get $fault) (then (return (i64.const 0))))
        (call $setreg16 (i32.const 4)
              (i32.wrap_i64 (i64.add (local.get $sp) (i64.extend_i32_u (local.get $size)))))))
    (local.get $v))
