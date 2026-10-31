  ;; =========================================================================
  ;;  Part 50: arithmetic, logic, shifts, multiply/divide, flag generation
  ;; =========================================================================

  ;; Parity of the low byte, the way x86 defines PF.
  (func $parity (param $r i64) (result i32)
    (i32.eqz (i32.and (i32.popcnt (i32.wrap_i64 (i64.and (local.get $r) (i64.const 255))))
                      (i32.const 1))))

  (func $sign_of (param $r i64) (param $size i32) (result i32)
    (i32.wrap_i64 (i64.and
      (i64.shr_u (local.get $r)
                 (i64.extend_i32_u (i32.sub (i32.shl (local.get $size) (i32.const 3))
                                            (i32.const 1))))
      (i64.const 1))))

  ;; Write all six arithmetic flags in one read-modify-write.  Doing this a flag
  ;; at a time cost six loads and six stores per ALU operation, which was the
  ;; second-largest item in the profile after instruction fetch.
  ;; Every argument must already be 0 or 1.
  (func $put_flags (param $cf i32) (param $pf i32) (param $af i32)
                   (param $zf i32) (param $sf i32) (param $of i32)
    (global.set $flags_g
      (i64.or
        (i64.and (global.get $flags_g) (i64.const -2262))         ;; clear CF PF AF ZF SF OF
        (i64.or
          (i64.or (i64.extend_i32_u (local.get $cf))
                  (i64.shl (i64.extend_i32_u (local.get $pf)) (i64.const 2)))
          (i64.or
            (i64.or (i64.shl (i64.extend_i32_u (local.get $af)) (i64.const 4))
                    (i64.shl (i64.extend_i32_u (local.get $zf)) (i64.const 6)))
            (i64.or (i64.shl (i64.extend_i32_u (local.get $sf)) (i64.const 7))
                    (i64.shl (i64.extend_i32_u (local.get $of)) (i64.const 11))))))))

  ;; SF / ZF / PF from a truncated result, also in one store
  (func $set_szp (param $r i64) (param $size i32)
    (global.set $flags_g
      (i64.or
        (i64.and (global.get $flags_g) (i64.const -197))          ;; clear PF ZF SF
        (i64.or
          (i64.shl (i64.extend_i32_u (call $parity (local.get $r))) (i64.const 2))
          (i64.or
            (i64.shl (i64.extend_i32_u (i64.eqz (local.get $r))) (i64.const 6))
            (i64.shl (i64.extend_i32_u (call $sign_of (local.get $r) (local.get $size)))
                     (i64.const 7)))))))

  ;; Flags are produced eagerly.  Deferring them until a reader asks was tried
  ;; and measured slower: a comparison is nearly always consumed by the branch
  ;; that follows it, so the bookkeeping cost more than the arithmetic saved.
  (func $do_add (param $a i64) (param $b i64) (param $size i32) (result i64)
    (local $r i64)
    (local.set $r (call $trunc (i64.add (local.get $a) (local.get $b)) (local.get $size)))
    (call $put_flags
      (i64.lt_u (local.get $r) (call $trunc (local.get $a) (local.get $size)))
      (call $parity (local.get $r))
      (i32.wrap_i64 (i64.and (i64.shr_u
        (i64.xor (i64.xor (local.get $a) (local.get $b)) (local.get $r))
        (i64.const 4)) (i64.const 1)))
      (i64.eqz (local.get $r))
      (call $sign_of (local.get $r) (local.get $size))
      (i64.ne (i64.and (i64.and (i64.xor (local.get $a) (local.get $r))
                                (i64.xor (local.get $b) (local.get $r)))
                       (call $msb (local.get $size)))
              (i64.const 0)))
    (local.get $r))

  (func $do_sub (param $a i64) (param $b i64) (param $size i32) (result i64)
    (local $r i64) (local $ta i64) (local $tb i64)
    (local.set $ta (call $trunc (local.get $a) (local.get $size)))
    (local.set $tb (call $trunc (local.get $b) (local.get $size)))
    (local.set $r (call $trunc (i64.sub (local.get $a) (local.get $b)) (local.get $size)))
    (call $put_flags
      (i64.lt_u (local.get $ta) (local.get $tb))
      (call $parity (local.get $r))
      (i32.wrap_i64 (i64.and (i64.shr_u
        (i64.xor (i64.xor (local.get $a) (local.get $b)) (local.get $r))
        (i64.const 4)) (i64.const 1)))
      (i64.eqz (local.get $r))
      (call $sign_of (local.get $r) (local.get $size))
      (i64.ne (i64.and (i64.and (i64.xor (local.get $a) (local.get $b))
                                (i64.xor (local.get $a) (local.get $r)))
                       (call $msb (local.get $size)))
              (i64.const 0)))
    (local.get $r))

  (func $do_logic (param $r i64) (param $size i32) (result i64)
    (local.set $r (call $trunc (local.get $r) (local.get $size)))
    ;; the logical operations clear CF, AF and OF outright
    (call $put_flags (i32.const 0) (call $parity (local.get $r)) (i32.const 0)
                     (i64.eqz (local.get $r))
                     (call $sign_of (local.get $r) (local.get $size)) (i32.const 0))
    (local.get $r))

  (func $do_adc (param $a i64) (param $b i64) (param $size i32) (result i64)
    (local $r i64) (local $c i64) (local $ta i64)
    (local.set $c (i64.extend_i32_u (call $cf)))
    (local.set $ta (call $trunc (local.get $a) (local.get $size)))
    (local.set $r (call $trunc (i64.add (i64.add (local.get $a) (local.get $b)) (local.get $c))
                        (local.get $size)))
    (call $set_szp (local.get $r) (local.get $size))
    (if (i64.eqz (local.get $c))
      (then (call $set_flag (i32.const 0) (i64.lt_u (local.get $r) (local.get $ta))))
      (else (call $set_flag (i32.const 0) (i64.le_u (local.get $r) (local.get $ta)))))
    (call $set_flag (i32.const 4)
      (i32.wrap_i64 (i64.and (i64.shr_u (i64.xor (i64.xor (local.get $a) (local.get $b)) (local.get $r))
                                        (i64.const 4)) (i64.const 1))))
    (call $set_flag (i32.const 11)
      (i64.ne (i64.and (i64.and (i64.xor (local.get $a) (local.get $r))
                                (i64.xor (local.get $b) (local.get $r)))
                       (call $msb (local.get $size)))
              (i64.const 0)))
    (local.get $r))
  (func $do_sbb (param $a i64) (param $b i64) (param $size i32) (result i64)
    (local $r i64) (local $c i64) (local $ta i64) (local $tb i64)
    (local.set $c (i64.extend_i32_u (call $cf)))
    (local.set $ta (call $trunc (local.get $a) (local.get $size)))
    (local.set $tb (call $trunc (local.get $b) (local.get $size)))
    (local.set $r (call $trunc (i64.sub (i64.sub (local.get $a) (local.get $b)) (local.get $c))
                        (local.get $size)))
    (call $set_szp (local.get $r) (local.get $size))
    (if (i64.eqz (local.get $c))
      (then (call $set_flag (i32.const 0) (i64.lt_u (local.get $ta) (local.get $tb))))
      (else (call $set_flag (i32.const 0) (i64.le_u (local.get $ta) (local.get $tb)))))
    (call $set_flag (i32.const 4)
      (i32.wrap_i64 (i64.and (i64.shr_u (i64.xor (i64.xor (local.get $a) (local.get $b)) (local.get $r))
                                        (i64.const 4)) (i64.const 1))))
    (call $set_flag (i32.const 11)
      (i64.ne (i64.and (i64.and (i64.xor (local.get $a) (local.get $b))
                                (i64.xor (local.get $a) (local.get $r)))
                       (call $msb (local.get $size)))
              (i64.const 0)))
    (local.get $r))
  (func $do_inc (param $a i64) (param $size i32) (result i64)
    (local $r i64) (local $c i32)
    (local.set $c (call $cf))
    (local.set $r (call $do_add (local.get $a) (i64.const 1) (local.get $size)))
    (call $set_flag (i32.const 0) (local.get $c))    ;; INC preserves CF
    (local.get $r))

  (func $do_dec (param $a i64) (param $size i32) (result i64)
    (local $r i64) (local $c i32)
    (local.set $c (call $cf))
    (local.set $r (call $do_sub (local.get $a) (i64.const 1) (local.get $size)))
    (call $set_flag (i32.const 0) (local.get $c))
    (local.get $r))

  (func $do_neg (param $a i64) (param $size i32) (result i64)
    (local $r i64)
    (local.set $r (call $do_sub (i64.const 0) (local.get $a) (local.get $size)))
    (local.get $r))

  ;; generic ALU dispatch, op 0..7 = ADD OR ADC SBB AND SUB XOR CMP
  (func $alu (param $op i32) (param $a i64) (param $b i64) (param $size i32) (result i64)
    (block $cmp (block $xor (block $sub (block $and
    (block $sbb (block $adc (block $or (block $add
      (br_table $add $or $adc $sbb $and $sub $xor $cmp
                (i32.and (local.get $op) (i32.const 7))))
      (return (call $do_add (local.get $a) (local.get $b) (local.get $size))))
      (return (call $do_logic (i64.or (local.get $a) (local.get $b)) (local.get $size))))
      (return (call $do_adc (local.get $a) (local.get $b) (local.get $size))))
      (return (call $do_sbb (local.get $a) (local.get $b) (local.get $size))))
      (return (call $do_logic (i64.and (local.get $a) (local.get $b)) (local.get $size))))
      (return (call $do_sub (local.get $a) (local.get $b) (local.get $size))))
      (return (call $do_logic (i64.xor (local.get $a) (local.get $b)) (local.get $size))))
    (call $do_sub (local.get $a) (local.get $b) (local.get $size)))

  ;; ---- shifts and rotates ------------------------------------------------
  ;;  op: 0 ROL, 1 ROR, 2 RCL, 3 RCR, 4 SHL, 5 SHR, 6 SAL, 7 SAR
  (func $do_shift (param $op i32) (param $v i64) (param $cnt i32) (param $size i32) (result i64)
    (local $bits i32) (local $r i64) (local $c i32) (local $mask i32) (local $i i32)
    (local $tmp i64) (local $oldc i32)
    (local.set $bits (i32.shl (local.get $size) (i32.const 3)))
    ;; the count is masked to 5 bits (6 for 64-bit operands)
    (local.set $mask (if (result i32) (i32.eq (local.get $size) (i32.const 8))
                        (then (i32.const 63)) (else (i32.const 31))))
    (local.set $cnt (i32.and (local.get $cnt) (local.get $mask)))
    (local.set $v (call $trunc (local.get $v) (local.get $size)))
    (if (i32.eqz (local.get $cnt)) (then (return (local.get $v))))
    (local.set $oldc (call $cf))

    (block $d
      ;; ---- ROL ----
      (if (i32.eq (local.get $op) (i32.const 0))
        (then
          (local.set $cnt (i32.rem_u (local.get $cnt) (local.get $bits)))
          (if (i32.eqz (local.get $cnt))
            (then (local.set $r (local.get $v)))
            (else
              (local.set $r (call $trunc
                (i64.or (i64.shl (local.get $v) (i64.extend_i32_u (local.get $cnt)))
                        (i64.shr_u (local.get $v)
                                   (i64.extend_i32_u (i32.sub (local.get $bits) (local.get $cnt)))))
                (local.get $size)))))
          (call $set_flag (i32.const 0) (i32.wrap_i64 (i64.and (local.get $r) (i64.const 1))))
          (call $set_flag (i32.const 11)
            (i32.xor (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                              (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                            (i64.const 1)))
                     (call $cf)))
          (br $d)))
      ;; ---- ROR ----
      (if (i32.eq (local.get $op) (i32.const 1))
        (then
          (local.set $cnt (i32.rem_u (local.get $cnt) (local.get $bits)))
          (if (i32.eqz (local.get $cnt))
            (then (local.set $r (local.get $v)))
            (else
              (local.set $r (call $trunc
                (i64.or (i64.shr_u (local.get $v) (i64.extend_i32_u (local.get $cnt)))
                        (i64.shl (local.get $v)
                                 (i64.extend_i32_u (i32.sub (local.get $bits) (local.get $cnt)))))
                (local.get $size)))))
          (call $set_flag (i32.const 0)
            (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                     (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                   (i64.const 1))))
          (call $set_flag (i32.const 11)
            (i32.xor (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                              (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                            (i64.const 1)))
                     (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                              (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 2))))
                                            (i64.const 1)))))
          (br $d)))
      ;; ---- RCL / RCR: iterate, the carry makes it a bits+1 wide rotate ----
      (if (i32.or (i32.eq (local.get $op) (i32.const 2)) (i32.eq (local.get $op) (i32.const 3)))
        (then
          (local.set $cnt (i32.rem_u (local.get $cnt) (i32.add (local.get $bits) (i32.const 1))))
          (local.set $r (local.get $v))
          (local.set $c (call $cf))
          (local.set $i (i32.const 0))
          (block $e (loop $l
            (br_if $e (i32.ge_u (local.get $i) (local.get $cnt)))
            (if (i32.eq (local.get $op) (i32.const 2))
              (then
                (local.set $tmp (i64.and (i64.shr_u (local.get $r)
                                           (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                         (i64.const 1)))
                (local.set $r (call $trunc
                  (i64.or (i64.shl (local.get $r) (i64.const 1))
                          (i64.extend_i32_u (local.get $c)))
                  (local.get $size)))
                (local.set $c (i32.wrap_i64 (local.get $tmp))))
              (else
                (local.set $tmp (i64.and (local.get $r) (i64.const 1)))
                (local.set $r (i64.or (i64.shr_u (local.get $r) (i64.const 1))
                                      (i64.shl (i64.extend_i32_u (local.get $c))
                                               (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))))
                (local.set $c (i32.wrap_i64 (local.get $tmp)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $l)))
          ;; A rotate of zero bits through the carry changes nothing at all,
          ;; flags included.
          (if (local.get $cnt)
            (then
              (call $set_flag (i32.const 0) (local.get $c))
              ;; OF after a left rotate is the result's top bit against the
              ;; carry; after a right rotate it is the result's top two bits
              ;; against each other, which is the rule ROR follows.
              (if (i32.eq (local.get $op) (i32.const 2))
                (then
                  (call $set_flag (i32.const 11)
                    (i32.xor (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                              (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                            (i64.const 1))) (local.get $c))))
                (else
                  (call $set_flag (i32.const 11)
                    (i32.xor (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                              (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                            (i64.const 1))) (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                              (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 2))))
                                            (i64.const 1)))))))))
          (br $d)))
      ;; ---- SHL / SAL ----
      (if (i32.or (i32.eq (local.get $op) (i32.const 4)) (i32.eq (local.get $op) (i32.const 6)))
        (then
          (if (i32.gt_u (local.get $cnt) (local.get $bits))
            (then (local.set $c (i32.const 0)))
            (else (local.set $c (i32.wrap_i64 (i64.and
                    (i64.shr_u (local.get $v)
                               (i64.extend_i32_u (i32.sub (local.get $bits) (local.get $cnt))))
                    (i64.const 1))))))
          (local.set $r (call $trunc (i64.shl (local.get $v) (i64.extend_i32_u (local.get $cnt)))
                              (local.get $size)))
          (call $set_flag (i32.const 0) (local.get $c))
          (call $set_szp (local.get $r) (local.get $size))
          (call $set_flag (i32.const 11)
            (i32.xor (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                              (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                            (i64.const 1)))
                     (local.get $c)))
          (return (local.get $r))))
      ;; ---- SHR ----
      (if (i32.eq (local.get $op) (i32.const 5))
        (then
          (if (i32.gt_u (local.get $cnt) (local.get $bits))
            (then (local.set $c (i32.const 0)))
            (else (local.set $c (i32.wrap_i64 (i64.and
                    (i64.shr_u (local.get $v) (i64.extend_i32_u (i32.sub (local.get $cnt) (i32.const 1))))
                    (i64.const 1))))))
          (local.set $r (i64.shr_u (local.get $v) (i64.extend_i32_u (local.get $cnt))))
          (if (i32.ge_u (local.get $cnt) (local.get $bits)) (then (local.set $r (i64.const 0))))
          (call $set_flag (i32.const 0) (local.get $c))
          (call $set_szp (local.get $r) (local.get $size))
          (call $set_flag (i32.const 11)
            (i32.wrap_i64 (i64.and (i64.shr_u (local.get $v)
                                     (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                   (i64.const 1))))
          (return (local.get $r))))
      ;; ---- SAR ----
      (local.set $tmp (call $sext (local.get $v) (local.get $size)))
      (if (i32.ge_u (local.get $cnt) (local.get $bits))
        (then (local.set $c (i32.wrap_i64 (i64.and (i64.shr_s (local.get $tmp) (i64.const 63)) (i64.const 1))))
              (local.set $r (call $trunc (i64.shr_s (local.get $tmp) (i64.const 63)) (local.get $size))))
        (else
          (local.set $c (i32.wrap_i64 (i64.and
            (i64.shr_s (local.get $tmp) (i64.extend_i32_u (i32.sub (local.get $cnt) (i32.const 1))))
            (i64.const 1))))
          (local.set $r (call $trunc (i64.shr_s (local.get $tmp) (i64.extend_i32_u (local.get $cnt)))
                              (local.get $size)))))
      (call $set_flag (i32.const 0) (local.get $c))
      (call $set_szp (local.get $r) (local.get $size))
      (call $set_flag (i32.const 11) (i32.const 0))
      (return (local.get $r)))
    (local.get $r))

  ;; SHLD / SHRD
  (func $do_shld (param $dst i64) (param $src i64) (param $cnt i32) (param $size i32) (result i64)
    (local $bits i32) (local $r i64) (local $c i32)
    (local.set $bits (i32.shl (local.get $size) (i32.const 3)))
    (local.set $cnt (i32.and (local.get $cnt)
                      (if (result i32) (i32.eq (local.get $size) (i32.const 8))
                        (then (i32.const 63)) (else (i32.const 31)))))
    (if (i32.eqz (local.get $cnt)) (then (return (call $trunc (local.get $dst) (local.get $size)))))
    (if (i32.gt_u (local.get $cnt) (local.get $bits))
      (then (return (call $trunc (local.get $dst) (local.get $size)))))
    (local.set $dst (call $trunc (local.get $dst) (local.get $size)))
    (local.set $src (call $trunc (local.get $src) (local.get $size)))
    (local.set $c (i32.wrap_i64 (i64.and
      (i64.shr_u (local.get $dst) (i64.extend_i32_u (i32.sub (local.get $bits) (local.get $cnt))))
      (i64.const 1))))
    (local.set $r (call $trunc
      (i64.or (i64.shl (local.get $dst) (i64.extend_i32_u (local.get $cnt)))
              (if (result i64) (i32.eq (local.get $cnt) (local.get $bits))
                (then (i64.const 0))
                (else (i64.shr_u (local.get $src)
                                 (i64.extend_i32_u (i32.sub (local.get $bits) (local.get $cnt)))))))
      (local.get $size)))
    (call $set_flag (i32.const 0) (local.get $c))
    (call $set_szp (local.get $r) (local.get $size))
    (call $set_flag (i32.const 11)
      (i32.ne (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                       (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                     (i64.const 1)))
              (i32.wrap_i64 (i64.and (i64.shr_u (local.get $dst)
                                       (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                     (i64.const 1)))))
    (local.get $r))

  (func $do_shrd (param $dst i64) (param $src i64) (param $cnt i32) (param $size i32) (result i64)
    (local $bits i32) (local $r i64) (local $c i32)
    (local.set $bits (i32.shl (local.get $size) (i32.const 3)))
    (local.set $cnt (i32.and (local.get $cnt)
                      (if (result i32) (i32.eq (local.get $size) (i32.const 8))
                        (then (i32.const 63)) (else (i32.const 31)))))
    (if (i32.eqz (local.get $cnt)) (then (return (call $trunc (local.get $dst) (local.get $size)))))
    (if (i32.gt_u (local.get $cnt) (local.get $bits))
      (then (return (call $trunc (local.get $dst) (local.get $size)))))
    (local.set $dst (call $trunc (local.get $dst) (local.get $size)))
    (local.set $src (call $trunc (local.get $src) (local.get $size)))
    (local.set $c (i32.wrap_i64 (i64.and
      (i64.shr_u (local.get $dst) (i64.extend_i32_u (i32.sub (local.get $cnt) (i32.const 1))))
      (i64.const 1))))
    (local.set $r (call $trunc
      (i64.or (i64.shr_u (local.get $dst) (i64.extend_i32_u (local.get $cnt)))
              (if (result i64) (i32.eq (local.get $cnt) (local.get $bits))
                (then (i64.const 0))
                (else (i64.shl (local.get $src)
                               (i64.extend_i32_u (i32.sub (local.get $bits) (local.get $cnt)))))))
      (local.get $size)))
    (call $set_flag (i32.const 0) (local.get $c))
    (call $set_szp (local.get $r) (local.get $size))
    (call $set_flag (i32.const 11)
      (i32.ne (i32.wrap_i64 (i64.and (i64.shr_u (local.get $r)
                                       (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                     (i64.const 1)))
              (i32.wrap_i64 (i64.and (i64.shr_u (local.get $dst)
                                       (i64.extend_i32_u (i32.sub (local.get $bits) (i32.const 1))))
                                     (i64.const 1)))))
    (local.get $r))

  ;; ---- 64x64 -> 128 multiply helpers -------------------------------------
  (func $mulu_hi (param $a i64) (param $b i64) (result i64)
    (local $a0 i64) (local $a1 i64) (local $b0 i64) (local $b1 i64)
    (local $t i64) (local $w1 i64) (local $w2 i64) (local $k i64)
    (local.set $a0 (i64.and (local.get $a) (i64.const 0xFFFFFFFF)))
    (local.set $a1 (i64.shr_u (local.get $a) (i64.const 32)))
    (local.set $b0 (i64.and (local.get $b) (i64.const 0xFFFFFFFF)))
    (local.set $b1 (i64.shr_u (local.get $b) (i64.const 32)))
    (local.set $t (i64.mul (local.get $a0) (local.get $b0)))
    (local.set $k (i64.shr_u (local.get $t) (i64.const 32)))
    (local.set $t (i64.add (i64.mul (local.get $a1) (local.get $b0)) (local.get $k)))
    (local.set $w1 (i64.and (local.get $t) (i64.const 0xFFFFFFFF)))
    (local.set $w2 (i64.shr_u (local.get $t) (i64.const 32)))
    (local.set $t (i64.add (i64.mul (local.get $a0) (local.get $b1)) (local.get $w1)))
    (local.set $k (i64.shr_u (local.get $t) (i64.const 32)))
    (i64.add (i64.add (i64.mul (local.get $a1) (local.get $b1)) (local.get $w2)) (local.get $k)))

  (func $muls_hi (param $a i64) (param $b i64) (result i64)
    (local $hi i64)
    (local.set $hi (call $mulu_hi (local.get $a) (local.get $b)))
    (if (i64.lt_s (local.get $a) (i64.const 0))
      (then (local.set $hi (i64.sub (local.get $hi) (local.get $b)))))
    (if (i64.lt_s (local.get $b) (i64.const 0))
      (then (local.set $hi (i64.sub (local.get $hi) (local.get $a)))))
    (local.get $hi))

  ;; ---- 128 / 64 unsigned division (shift-subtract) -----------------------
  ;;  Returns the quotient; the remainder is left at scratch 0x3F0.
  ;;  Sets $fault via #DE when the quotient overflows 64 bits.
  (func $divu128 (param $hi i64) (param $lo i64) (param $d i64) (result i64)
    (local $q i64) (local $r i64) (local $i i32) (local $bit i64) (local $carry i64)
    (if (i64.eqz (local.get $d)) (then (call $raise_de) (return (i64.const 0))))
    (if (i64.ge_u (local.get $hi) (local.get $d)) (then (call $raise_de) (return (i64.const 0))))
    (local.set $q (i64.const 0))
    (local.set $r (local.get $hi))
    (local.set $i (i32.const 63))
    (block $e (loop $l
      (local.set $bit (i64.and (i64.shr_u (local.get $lo) (i64.extend_i32_u (local.get $i)))
                               (i64.const 1)))
      ;; the bit shifted out of the top of r is worth 2^64, which always
      ;; exceeds the divisor, so it forces a subtraction
      (local.set $carry (i64.shr_u (local.get $r) (i64.const 63)))
      (local.set $r (i64.or (i64.shl (local.get $r) (i64.const 1)) (local.get $bit)))
      (if (i32.or (i64.ne (local.get $carry) (i64.const 0))
                  (i64.ge_u (local.get $r) (local.get $d)))
        (then
          (local.set $r (i64.sub (local.get $r) (local.get $d)))
          (local.set $q (i64.or (local.get $q)
                                (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $i)))))))
      (br_if $e (i32.eqz (local.get $i)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $l)))
    (i64.store (i32.const 0x3F0) (local.get $r))
    (local.get $q))

  (func $div_rem (result i64) (i64.load (i32.const 0x3F0)))
