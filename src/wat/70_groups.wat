  ;; =========================================================================
  ;;  Part 70: group opcodes, string instructions, x87 stubs
  ;; =========================================================================

  ;; 0x80/0x81/0x83 - ALU with immediate
  (func $h_grp1 (param $op i32)
    (local $size i32) (local $a i64) (local $b i64) (local $r i64) (local $aluop i32)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $aluop (global.get $mrm_ext))
    (if (i32.eq (local.get $op) (i32.const 0x83))
      (then (local.set $b (call $fetch_imm (i32.const 1))))
      (else (local.set $b (call $fetch_imm
              (if (result i32) (i32.eq (local.get $size) (i32.const 1)) (then (i32.const 1))
                (else (if (result i32) (i32.eq (local.get $size) (i32.const 2))
                        (then (i32.const 2)) (else (i32.const 4)))))))))
    (local.set $a (call $rm_read (local.get $size)))
    (if (global.get $fault) (then (return)))
    (local.set $r (call $alu (i32.and (local.get $aluop) (i32.const 7))
                             (local.get $a) (local.get $b) (local.get $size)))
    (if (i32.ne (i32.and (local.get $aluop) (i32.const 7)) (i32.const 7))
      (then (call $rm_write (local.get $size) (local.get $r)))))

  ;; 0xC0/0xC1/0xD0-0xD3 - shifts and rotates
  (func $h_grp2 (param $op i32)
    (local $size i32) (local $cnt i32) (local $v i64) (local $r i64)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (block $d
      (if (i32.lt_u (local.get $op) (i32.const 0xD0))
        (then (local.set $cnt (call $fetch8)) (br $d)))
      (if (i32.lt_u (local.get $op) (i32.const 0xD2))
        (then (local.set $cnt (i32.const 1)) (br $d)))
      (local.set $cnt (call $reg8 (i32.const 1))))
    (local.set $v (call $rm_read (local.get $size)))
    (if (global.get $fault) (then (return)))
    (local.set $r (call $do_shift (global.get $mrm_ext) (local.get $v)
                                  (local.get $cnt) (local.get $size)))
    (call $rm_write (local.get $size) (local.get $r)))

  ;; 0xF6/0xF7 - TEST/NOT/NEG/MUL/IMUL/DIV/IDIV
  (func $h_grp3 (param $op i32)
    (local $size i32) (local $v i64) (local $imm i64) (local $sub i32)
    (local $lo i64) (local $hi i64) (local $q i64) (local $r i64)
    (local $a i64) (local $b i64) (local $ovf i32)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $sub (global.get $mrm_ext))

    ;; TEST r/m, imm
    (if (i32.lt_u (local.get $sub) (i32.const 2))
      (then
        (local.set $imm (call $fetch_imm
          (if (result i32) (i32.eq (local.get $size) (i32.const 1)) (then (i32.const 1))
            (else (if (result i32) (i32.eq (local.get $size) (i32.const 2))
                    (then (i32.const 2)) (else (i32.const 4)))))))
        (local.set $v (call $rm_read (local.get $size)))
        (if (global.get $fault) (then (return)))
        (drop (call $do_logic (i64.and (local.get $v) (local.get $imm)) (local.get $size)))
        (return)))

    (local.set $v (call $rm_read (local.get $size)))
    (if (global.get $fault) (then (return)))

    (block $d
      (if (i32.eq (local.get $sub) (i32.const 2))          ;; NOT
        (then (call $rm_write (local.get $size)
                (call $trunc (i64.xor (local.get $v) (i64.const -1)) (local.get $size)))
              (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 3))          ;; NEG
        (then (call $rm_write (local.get $size) (call $do_neg (local.get $v) (local.get $size)))
              (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 4))          ;; MUL
        (then
          (local.set $a (call $trunc (call $regN (i32.const 0) (local.get $size)) (local.get $size)))
          (local.set $b (call $trunc (local.get $v) (local.get $size)))
          (if (i32.eq (local.get $size) (i32.const 8))
            (then
              (local.set $lo (i64.mul (local.get $a) (local.get $b)))
              (local.set $hi (call $mulu_hi (local.get $a) (local.get $b))))
            (else
              (local.set $lo (call $trunc (i64.mul (local.get $a) (local.get $b)) (local.get $size)))
              (local.set $hi (call $trunc
                (i64.shr_u (i64.mul (local.get $a) (local.get $b))
                           (i64.extend_i32_u (i32.shl (local.get $size) (i32.const 3))))
                (local.get $size)))))
          (if (i32.eq (local.get $size) (i32.const 1))
            (then (call $setreg16 (i32.const 0)
                    (i32.wrap_i64 (i64.or (local.get $lo) (i64.shl (local.get $hi) (i64.const 8))))))
            (else
              (call $setregN (i32.const 0) (local.get $size) (local.get $lo))
              (call $setregN (i32.const 2) (local.get $size) (local.get $hi))))
          (call $set_flag (i32.const 0) (i64.ne (local.get $hi) (i64.const 0)))
          (call $set_flag (i32.const 11) (i64.ne (local.get $hi) (i64.const 0)))
          (call $set_szp (local.get $lo) (local.get $size))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 5))          ;; IMUL
        (then
          (local.set $a (call $sext (call $regN (i32.const 0) (local.get $size)) (local.get $size)))
          (local.set $b (call $sext (local.get $v) (local.get $size)))
          (if (i32.eq (local.get $size) (i32.const 8))
            (then
              (local.set $lo (i64.mul (local.get $a) (local.get $b)))
              (local.set $hi (call $muls_hi (local.get $a) (local.get $b))))
            (else
              (local.set $lo (call $trunc (i64.mul (local.get $a) (local.get $b)) (local.get $size)))
              (local.set $hi (call $trunc
                (i64.shr_s (i64.mul (local.get $a) (local.get $b))
                           (i64.extend_i32_u (i32.shl (local.get $size) (i32.const 3))))
                (local.get $size)))))
          (if (i32.eq (local.get $size) (i32.const 1))
            (then (call $setreg16 (i32.const 0)
                    (i32.wrap_i64 (i64.or (call $trunc (local.get $lo) (i32.const 1))
                                          (i64.shl (local.get $hi) (i64.const 8))))))
            (else
              (call $setregN (i32.const 0) (local.get $size) (local.get $lo))
              (call $setregN (i32.const 2) (local.get $size) (local.get $hi))))
          ;; CF/OF are set when the high half is not a sign extension of the
          ;; low half.  At 64 bits the product does not fit in an i64 at all,
          ;; so the separately computed high half has to be used: i64.mul
          ;; yields only the low half, which would be compared against itself
          ;; and never differ.
          (if (i32.eq (local.get $size) (i32.const 8))
            (then
              (local.set $ovf (i64.ne (local.get $hi)
                                      (i64.shr_s (local.get $lo) (i64.const 63)))))
            (else
              (local.set $ovf (i64.ne (i64.mul (local.get $a) (local.get $b))
                                      (call $sext (local.get $lo) (local.get $size))))))
          (call $set_flag (i32.const 0) (local.get $ovf))
          (call $set_flag (i32.const 11) (local.get $ovf))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 6))          ;; DIV
        (then
          (local.set $b (call $trunc (local.get $v) (local.get $size)))
          (if (i64.eqz (local.get $b)) (then (call $raise_de) (return)))
          (if (i32.eq (local.get $size) (i32.const 1))
            (then
              (local.set $lo (i64.extend_i32_u (call $reg16 (i32.const 0))))
              (if (i64.gt_u (i64.div_u (local.get $lo) (local.get $b)) (i64.const 255))
                (then (call $raise_de) (return)))
              (call $setreg8 (i32.const 0) (i32.wrap_i64 (i64.div_u (local.get $lo) (local.get $b))))
              ;; The remainder goes to AH, which is the second byte of RAX and
              ;; must be written directly.  Reaching it through $setreg8 with
              ;; register 4 only means AH while no REX prefix is present, and
              ;; naming r8b..r15b as the divisor requires one -- so that route
              ;; silently put the remainder in SPL instead.
              (i32.store8 (i32.const 1)
                (i32.wrap_i64 (i64.rem_u (local.get $lo) (local.get $b)))))
            (else
              (local.set $lo (call $trunc (call $regN (i32.const 0) (local.get $size)) (local.get $size)))
              (local.set $hi (call $trunc (call $regN (i32.const 2) (local.get $size)) (local.get $size)))
              (if (i32.eq (local.get $size) (i32.const 8))
                (then
                  (local.set $q (call $divu128 (local.get $hi) (local.get $lo) (local.get $b)))
                  (if (global.get $fault) (then (return)))
                  (local.set $r (call $div_rem)))
                (else
                  (local.set $lo (i64.or (local.get $lo)
                    (i64.shl (local.get $hi)
                             (i64.extend_i32_u (i32.shl (local.get $size) (i32.const 3))))))
                  (local.set $q (i64.div_u (local.get $lo) (local.get $b)))
                  (local.set $r (i64.rem_u (local.get $lo) (local.get $b)))
                  (if (i64.gt_u (local.get $q)
                        (i64.sub (i64.shl (i64.const 1)
                                          (i64.extend_i32_u (i32.shl (local.get $size) (i32.const 3))))
                                 (i64.const 1)))
                    (then (call $raise_de) (return)))))
              (call $setregN (i32.const 0) (local.get $size) (local.get $q))
              (call $setregN (i32.const 2) (local.get $size) (local.get $r))))
          (br $d)))
      ;; IDIV
      (local.set $b (call $sext (local.get $v) (local.get $size)))
      (if (i64.eqz (local.get $b)) (then (call $raise_de) (return)))
      (if (i32.eq (local.get $size) (i32.const 1))
        (then
          (local.set $lo (i64.extend_i32_s (i32.extend16_s (call $reg16 (i32.const 0)))))
          (local.set $q (i64.div_s (local.get $lo) (local.get $b)))
          (if (i32.or (i64.gt_s (local.get $q) (i64.const 127))
                      (i64.lt_s (local.get $q) (i64.const -128)))
            (then (call $raise_de) (return)))
          (call $setreg8 (i32.const 0) (i32.wrap_i64 (local.get $q)))
          (i32.store8 (i32.const 1)                     ;; AH, see DIV above
            (i32.wrap_i64 (i64.rem_s (local.get $lo) (local.get $b)))))
        (else
          (if (i32.eq (local.get $size) (i32.const 8))
            (then
              ;; sign-magnitude reduction onto the unsigned 128/64 divider
              (local.set $hi (call $regN (i32.const 2) (i32.const 8)))
              (local.set $lo (call $regN (i32.const 0) (i32.const 8)))
              (call $idiv128 (local.get $hi) (local.get $lo) (local.get $b))
              (if (global.get $fault) (then (return)))
              (call $setreg64 (i32.const 0) (i64.load (i32.const 0x3E0)))
              (call $setreg64 (i32.const 2) (i64.load (i32.const 0x3E8))))
            (else
              (local.set $lo (i64.or
                (call $trunc (call $regN (i32.const 0) (local.get $size)) (local.get $size))
                (i64.shl (call $trunc (call $regN (i32.const 2) (local.get $size)) (local.get $size))
                         (i64.extend_i32_u (i32.shl (local.get $size) (i32.const 3))))))
              (local.set $lo (call $sext (local.get $lo) (i32.shl (local.get $size) (i32.const 1))))
              (local.set $q (i64.div_s (local.get $lo) (local.get $b)))
              (if (i64.ne (call $sext (local.get $q) (local.get $size)) (local.get $q))
                (then (call $raise_de) (return)))
              (call $setregN (i32.const 0) (local.get $size) (local.get $q))
              (call $setregN (i32.const 2) (local.get $size)
                    (i64.rem_s (local.get $lo) (local.get $b)))))))))

  ;; signed 128/64 division, results left at 0x3E0 (quotient) and 0x3E8 (remainder)
  (func $idiv128 (param $hi i64) (param $lo i64) (param $d i64)
    (local $neg_n i32) (local $neg_d i32) (local $q i64) (local $r i64)
    (local.set $neg_n (i64.lt_s (local.get $hi) (i64.const 0)))
    (local.set $neg_d (i64.lt_s (local.get $d) (i64.const 0)))
    ;; two's complement of the 128-bit numerator: ~hi carries in only when the
    ;; low half is zero
    (if (local.get $neg_n)
      (then
        (local.set $hi (i64.add (i64.xor (local.get $hi) (i64.const -1))
                                (i64.extend_i32_u (i64.eqz (local.get $lo)))))
        (local.set $lo (i64.sub (i64.const 0) (local.get $lo)))))
    (if (local.get $neg_d) (then (local.set $d (i64.sub (i64.const 0) (local.get $d)))))
    (local.set $q (call $divu128 (local.get $hi) (local.get $lo) (local.get $d)))
    (if (global.get $fault) (then (return)))
    (local.set $r (call $div_rem))
    (if (i32.xor (local.get $neg_n) (local.get $neg_d))
      (then (local.set $q (i64.sub (i64.const 0) (local.get $q)))))
    (if (local.get $neg_n) (then (local.set $r (i64.sub (i64.const 0) (local.get $r)))))
    (i64.store (i32.const 0x3E0) (local.get $q))
    (i64.store (i32.const 0x3E8) (local.get $r)))

  ;; 0xFE/0xFF - INC/DEC/CALL/JMP/PUSH
  (func $h_grp5 (param $op i32)
    (local $size i32) (local $sub i32) (local $v i64) (local $sel i32)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $sub (global.get $mrm_ext))

    (if (i32.eq (local.get $sub) (i32.const 0))
      (then (local.set $v (call $rm_read (local.get $size)))
            (if (global.get $fault) (then (return)))
            (call $rm_write (local.get $size) (call $do_inc (local.get $v) (local.get $size)))
            (return)))
    (if (i32.eq (local.get $sub) (i32.const 1))
      (then (local.set $v (call $rm_read (local.get $size)))
            (if (global.get $fault) (then (return)))
            (call $rm_write (local.get $size) (call $do_dec (local.get $v) (local.get $size)))
            (return)))
    (if (i32.eq (local.get $op) (i32.const 0xFE)) (then (call $raise_ud) (return)))

    ;; the remaining forms default to 64-bit operands in long mode
    (local.set $size (call $opsize_d64))
    (block $d
      (if (i32.eq (local.get $sub) (i32.const 2))          ;; CALL r/m
        (then
          (local.set $v (call $rm_read (local.get $size)))
          (if (global.get $fault) (then (return)))
          (call $push (call $rip) (local.get $size))
          (if (global.get $fault) (then (return)))
          (call $jump_to (local.get $v))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 3))          ;; CALL far m
        (then
          (if (i32.eqz (global.get $mrm_mem)) (then (call $raise_ud) (return)))
          (local.set $v (call $rm_read (global.get $opsize)))
          (local.set $sel (i32.wrap_i64 (call $seg_read (global.get $mrm_seg)
            (i64.add (call $mrm_off) (i64.extend_i32_u (global.get $opsize))) (i32.const 2))))
          (if (global.get $fault) (then (return)))
          (call $push (i64.extend_i32_u (call $seg_sel (i32.const 1))) (global.get $opsize))
          (call $push (call $rip) (global.get $opsize))
          (if (global.get $fault) (then (return)))
          (call $far_jump (local.get $sel) (local.get $v))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 4))          ;; JMP r/m
        (then
          (local.set $v (call $rm_read (local.get $size)))
          (if (global.get $fault) (then (return)))
          (call $jump_to (local.get $v))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 5))          ;; JMP far m
        (then
          (if (i32.eqz (global.get $mrm_mem)) (then (call $raise_ud) (return)))
          (local.set $v (call $rm_read (global.get $opsize)))
          (local.set $sel (i32.wrap_i64 (call $seg_read (global.get $mrm_seg)
            (i64.add (call $mrm_off) (i64.extend_i32_u (global.get $opsize))) (i32.const 2))))
          (if (global.get $fault) (then (return)))
          (call $far_jump (local.get $sel) (local.get $v))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 6))          ;; PUSH r/m
        (then
          (local.set $v (call $rm_read (local.get $size)))
          (if (global.get $fault) (then (return)))
          (call $push (local.get $v) (local.get $size))
          (br $d)))
      (call $raise_ud)))

  ;; =========================================================================
  ;;  string instructions
  ;; =========================================================================
  ;;  A repeated instruction executes one iteration per step and rewinds RIP,
  ;;  which keeps interrupt latency bounded.

  (func $str_delta (param $size i32) (result i64)
    (if (result i64) (call $df)
      (then (i64.sub (i64.const 0) (i64.extend_i32_u (local.get $size))))
      (else (i64.extend_i32_u (local.get $size)))))

  (func $adv_si_di (param $which i32) (param $size i32)
    (local $d i64)
    (local.set $d (call $str_delta (local.get $size)))
    (if (i32.and (local.get $which) (i32.const 1))
      (then (call $setregN (i32.const 6) (global.get $addrsize)
              (i64.add (call $regN (i32.const 6) (global.get $addrsize)) (local.get $d)))))
    (if (i32.and (local.get $which) (i32.const 2))
      (then (call $setregN (i32.const 7) (global.get $addrsize)
              (i64.add (call $regN (i32.const 7) (global.get $addrsize)) (local.get $d))))))

  (func $h_string (param $op i32)
    (local $size i32) (local $seg i32) (local $v i64) (local $v2 i64) (local $done i32)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (local.set $seg (if (result i32) (i32.eq (global.get $segovr) (i32.const -1))
                      (then (i32.const 3)) (else (global.get $segovr))))

    ;; a repeat prefix with a zero count skips the instruction entirely
    (if (global.get $rep)
      (then
        (if (i64.eqz (call $trunc (call $regN (i32.const 1) (global.get $addrsize))
                                  (global.get $addrsize)))
          (then (return)))))

    (block $d
      ;; MOVS
      (if (i32.lt_u (local.get $op) (i32.const 0xA6))
        (then
          (local.set $v (call $seg_read (local.get $seg)
                          (call $regN (i32.const 6) (global.get $addrsize)) (local.get $size)))
          (if (global.get $fault) (then (return)))
          (call $seg_write (i32.const 0)
                (call $regN (i32.const 7) (global.get $addrsize)) (local.get $size) (local.get $v))
          (if (global.get $fault) (then (return)))
          (call $adv_si_di (i32.const 3) (local.get $size))
          (br $d)))
      ;; CMPS
      (if (i32.lt_u (local.get $op) (i32.const 0xA8))
        (then
          (local.set $v (call $seg_read (local.get $seg)
                          (call $regN (i32.const 6) (global.get $addrsize)) (local.get $size)))
          (local.set $v2 (call $seg_read (i32.const 0)
                           (call $regN (i32.const 7) (global.get $addrsize)) (local.get $size)))
          (if (global.get $fault) (then (return)))
          (drop (call $do_sub (local.get $v) (local.get $v2) (local.get $size)))
          (call $adv_si_di (i32.const 3) (local.get $size))
          (br $d)))
      ;; STOS
      (if (i32.lt_u (local.get $op) (i32.const 0xAC))
        (then
          (call $seg_write (i32.const 0) (call $regN (i32.const 7) (global.get $addrsize))
                (local.get $size) (call $regN (i32.const 0) (local.get $size)))
          (if (global.get $fault) (then (return)))
          (call $adv_si_di (i32.const 2) (local.get $size))
          (br $d)))
      ;; LODS
      (if (i32.lt_u (local.get $op) (i32.const 0xAE))
        (then
          (local.set $v (call $seg_read (local.get $seg)
                          (call $regN (i32.const 6) (global.get $addrsize)) (local.get $size)))
          (if (global.get $fault) (then (return)))
          (call $setregN (i32.const 0) (local.get $size) (local.get $v))
          (call $adv_si_di (i32.const 1) (local.get $size))
          (br $d)))
      ;; SCAS
      (local.set $v2 (call $seg_read (i32.const 0)
                       (call $regN (i32.const 7) (global.get $addrsize)) (local.get $size)))
      (if (global.get $fault) (then (return)))
      (drop (call $do_sub (call $regN (i32.const 0) (local.get $size)) (local.get $v2)
                          (local.get $size)))
      (call $adv_si_di (i32.const 2) (local.get $size)))

    ;; repeat bookkeeping
    (if (global.get $rep)
      (then
        (call $setregN (i32.const 1) (global.get $addrsize)
              (i64.sub (call $regN (i32.const 1) (global.get $addrsize)) (i64.const 1)))
        (local.set $done (i64.eqz (call $trunc (call $regN (i32.const 1) (global.get $addrsize))
                                               (global.get $addrsize))))
        ;; REPE/REPNE also terminate on the zero flag for CMPS and SCAS
        (if (i32.or (i32.and (i32.ge_u (local.get $op) (i32.const 0xA6))
                             (i32.lt_u (local.get $op) (i32.const 0xA8)))
                    (i32.ge_u (local.get $op) (i32.const 0xAE)))
          (then
            (if (i32.eq (global.get $rep) (i32.const 3))
              (then (if (i32.eqz (call $zf)) (then (local.set $done (i32.const 1)))))
              (else (if (call $zf) (then (local.set $done (i32.const 1))))))))
        (if (i32.eqz (local.get $done))
          (then (call $set_rip (global.get $rip0)))))))    ;; re-execute

  ;; INS / OUTS
  (func $h_ins_outs (param $op i32)
    (local $size i32) (local $port i32) (local $v i64) (local $seg i32)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (if (result i32) (i32.eq (global.get $opsize) (i32.const 2))
                               (then (i32.const 2)) (else (i32.const 4))))
                       (else (i32.const 1))))
    (local.set $port (call $reg16 (i32.const 2)))
    (if (i32.eqz (call $io_allowed (local.get $port) (local.get $size))) (then (return)))
    (if (global.get $rep)
      (then (if (i64.eqz (call $trunc (call $regN (i32.const 1) (global.get $addrsize))
                                      (global.get $addrsize)))
              (then (return)))))
    (if (i32.lt_u (local.get $op) (i32.const 0x6E))
      (then
        (call $seg_write (i32.const 0) (call $regN (i32.const 7) (global.get $addrsize))
              (local.get $size)
              (i64.extend_i32_u (call $io_read (local.get $port) (local.get $size))))
        (if (global.get $fault) (then (return)))
        (call $adv_si_di (i32.const 2) (local.get $size)))
      (else
        (local.set $seg (if (result i32) (i32.eq (global.get $segovr) (i32.const -1))
                          (then (i32.const 3)) (else (global.get $segovr))))
        (local.set $v (call $seg_read (local.get $seg)
                        (call $regN (i32.const 6) (global.get $addrsize)) (local.get $size)))
        (if (global.get $fault) (then (return)))
        (call $io_write (local.get $port) (local.get $size) (i32.wrap_i64 (local.get $v)))
        (call $adv_si_di (i32.const 1) (local.get $size))))
    (if (global.get $rep)
      (then
        (call $setregN (i32.const 1) (global.get $addrsize)
              (i64.sub (call $regN (i32.const 1) (global.get $addrsize)) (i64.const 1)))
        (if (i64.ne (call $trunc (call $regN (i32.const 1) (global.get $addrsize))
                                 (global.get $addrsize)) (i64.const 0))
          (then (call $set_rip (global.get $rip0)))))))
