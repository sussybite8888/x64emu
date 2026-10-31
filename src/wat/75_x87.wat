  ;; =========================================================================
  ;;  Part 75: the x87 floating point unit
  ;; =========================================================================
  ;;  Eight registers held as f64 rather than the architectural 80-bit format.
  ;;  That loses the extended precision real hardware carries between
  ;;  operations, which is documented, but it makes every ordinary computation
  ;;  come out right.  ST(i) names the register (top + i) & 7.
  ;;
  ;;  Status word layout: C0 at bit 8, C1 at 9, C2 at 10, TOP at 11..13,
  ;;  C3 at bit 14.  TOP is kept separately and folded in when the word is read.

  (func $ftop (result i32) (i32.load (i32.const 0x590)))
  (func $ftop_set (param $v i32) (i32.store (i32.const 0x590) (i32.and (local.get $v) (i32.const 7))))

  (func $st_addr (param $i i32) (result i32)
    (i32.add (i32.const 0x510)
             (i32.shl (i32.and (i32.add (call $ftop) (local.get $i)) (i32.const 7))
                      (i32.const 3))))

  (func $st (param $i i32) (result f64)
    (local $p i32)
    (local.set $p (i32.and (i32.add (call $ftop) (local.get $i)) (i32.const 7)))
    (if (call $raw_held (local.get $p))
      (then (return (call $ext_f64 (call $raw_mant (local.get $p)) (call $raw_se (local.get $p))))))
    (f64.load (call $st_addr (local.get $i))))

  (func $st_set (param $i i32) (param $v f64)
    (local $p i32)
    (local.set $p (i32.and (i32.add (call $ftop) (local.get $i)) (i32.const 7)))
    (i32.store (i32.const 0x5A8)
               (i32.and (i32.load (i32.const 0x5A8))
                        (i32.xor (i32.shl (i32.const 1) (local.get $p)) (i32.const -1))))
    (f64.store (call $st_addr (local.get $i)) (local.get $v)))

  ;; ---- the MMX registers -----------------------------------------------------
  ;;  MMX register i is the 64-bit significand of physical x87 register i, with
  ;;  the sign and exponent set to all ones.  An f64 cannot carry that, so a
  ;;  register written by MMX -- or restored by FXRSTOR as a NaN or infinity,
  ;;  which is how an MMX value looks -- keeps its 80-bit form alongside: the
  ;;  significand at 0x550 + 8i, sign and exponent at 0x598 + 2i, and bit i of
  ;;  0x5A8 set.  x87 code reading the register gets it converted; writing it
  ;;  clears the bit.
  (func $raw_held (param $p i32) (result i32)
    (i32.and (i32.shr_u (i32.load (i32.const 0x5A8)) (local.get $p)) (i32.const 1)))
  (func $raw_mant (param $p i32) (result i64)
    (i64.load (i32.add (i32.const 0x550) (i32.shl (local.get $p) (i32.const 3)))))
  (func $raw_se (param $p i32) (result i32)
    (i32.load16_u (i32.add (i32.const 0x598) (i32.shl (local.get $p) (i32.const 1)))))
  (func $raw_put (param $p i32) (param $mant i64) (param $se i32)
    (i64.store (i32.add (i32.const 0x550) (i32.shl (local.get $p) (i32.const 3))) (local.get $mant))
    (i32.store16 (i32.add (i32.const 0x598) (i32.shl (local.get $p) (i32.const 1))) (local.get $se))
    (i32.store (i32.const 0x5A8)
               (i32.or (i32.load (i32.const 0x5A8)) (i32.shl (i32.const 1) (local.get $p)))))

  (func $mm_get (param $r i32) (result i64)
    (local $p i32)
    (local.set $p (i32.and (local.get $r) (i32.const 7)))
    (if (result i64) (call $raw_held (local.get $p))
      (then (call $raw_mant (local.get $p)))
      (else (call $f64_ext_mant
              (f64.load (i32.add (i32.const 0x510) (i32.shl (local.get $p) (i32.const 3))))))))

  (func $mm_set (param $r i32) (param $v i64)
    (call $raw_put (i32.and (local.get $r) (i32.const 7)) (local.get $v) (i32.const 0xFFFF)))

  ;; Every MMX instruction but EMMS leaves the stack at TOP 0 with every
  ;; register valid.
  (func $mmx_enter
    (i32.store (i32.const 0x590) (i32.const 0))
    (i32.store (i32.const 0x594) (i32.const 0)))

  ;; The x87, MMX and SSE all belong to whichever task last loaded them: with
  ;; CR0.TS set the first use is #NM, and the kernel swaps the state in then.
  ;; Windows switches that state lazily, so without the fault every thread
  ;; ran on the registers of the one before it.
  (func $fpu_ts (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (call $cr0) (i64.const 3)) (i64.const 1))))

  ;; tag word: 2 bits per physical register, 0 valid and 3 empty
  (func $tag_set (param $i i32) (param $empty i32)
    (local $phys i32) (local $sh i32)
    (local.set $phys (i32.and (i32.add (call $ftop) (local.get $i)) (i32.const 7)))
    (local.set $sh (i32.shl (local.get $phys) (i32.const 1)))
    (i32.store (i32.const 0x594)
      (i32.or (i32.and (i32.load (i32.const 0x594))
                       (i32.xor (i32.shl (i32.const 3) (local.get $sh)) (i32.const -1)))
              (i32.shl (if (result i32) (local.get $empty) (then (i32.const 3)) (else (i32.const 0)))
                       (local.get $sh)))))

  (func $tag_empty (param $i i32) (result i32)
    (local $phys i32)
    (local.set $phys (i32.and (i32.add (call $ftop) (local.get $i)) (i32.const 7)))
    (i32.eq (i32.and (i32.shr_u (i32.load (i32.const 0x594))
                                (i32.shl (local.get $phys) (i32.const 1)))
                     (i32.const 3))
            (i32.const 3)))

  (func $fpush (param $v f64)
    (call $ftop_set (i32.sub (call $ftop) (i32.const 1)))
    (call $st_set (i32.const 0) (local.get $v))
    (call $tag_set (i32.const 0) (i32.const 0)))

  (func $fpop
    (call $tag_set (i32.const 0) (i32.const 1))
    (call $ftop_set (i32.add (call $ftop) (i32.const 1))))

  ;; ---- condition codes ---------------------------------------------------
  (func $set_cc (param $c0 i32) (param $c2 i32) (param $c3 i32)
    (i32.store (i32.const 0x504)
      (i32.or (i32.and (i32.load (i32.const 0x504)) (i32.const 0xB8FF))
              (i32.or (i32.shl (local.get $c0) (i32.const 8))
                      (i32.or (i32.shl (local.get $c2) (i32.const 10))
                              (i32.shl (local.get $c3) (i32.const 14)))))))

  ;; FPREM computes x - y*trunc(x/y); FPREM1 the IEEE remainder, which rounds
  ;; the quotient to nearest rather than truncating, so the two differ by one
  ;; multiple of y whenever the fraction exceeds a half.  The low three bits of
  ;; that quotient are reported through C0, C3 and C1, which is how a library
  ;; reducing an angle learns which octant it landed in.
  ;;
  ;; C2 signals an incomplete reduction, which real hardware returns when the
  ;; exponents differ by 64 or more and it has only reduced part of the way.
  ;; The reduction here is always complete, so C2 is reported clear; software
  ;; loops while it is set, and a loop that never runs leaves the right answer.
  (func $fprem (param $ieee i32)
    (local $x f64) (local $y f64) (local $r f64) (local $n f64) (local $q i64)
    (local $ay f64) (local $half f64) (local $ar f64)
    (local.set $x (call $st (i32.const 0)))
    (local.set $y (call $st (i32.const 1)))
    (if (i32.or (f64.eq (local.get $y) (f64.const 0))
                (i32.or (f64.ne (local.get $x) (local.get $x))
                        (f64.ne (local.get $y) (local.get $y))))
      (then
        ;; An invalid operation yields the indefinite QNaN, which is negative.
        (call $st_set (i32.const 0) (f64.reinterpret_i64 (i64.const 0xFFF8000000000000)))
        (call $set_cc (i32.const 0) (i32.const 0) (i32.const 0))
        (return)))
    ;; Both start from the truncating remainder, which is exact.  Deriving the
    ;; IEEE one as x - y*nearest(x/y) instead loses bits once the quotient is
    ;; large, because y*n is no longer representable; adjusting the exact
    ;; remainder by one y is exact, since the two are within a factor of two of
    ;; each other whenever the adjustment applies.
    (local.set $r (call $f_fmod (local.get $x) (local.get $y)))
    (local.set $n (f64.abs (f64.trunc (f64.div (f64.sub (local.get $x) (local.get $r))
                                               (local.get $y)))))
    (if (local.get $ieee)
      (then
        (local.set $ay (f64.abs (local.get $y)))
        (local.set $half (f64.mul (local.get $ay) (f64.const 0.5)))
        (local.set $ar (f64.abs (local.get $r)))
        ;; Exactly half goes to the even quotient, the same tie rule as
        ;; round-to-nearest itself.
        (if (i32.or (f64.gt (local.get $ar) (local.get $half))
                    (i32.and (f64.eq (local.get $ar) (local.get $half))
                             (i32.wrap_i64 (i64.and (i64.trunc_sat_f64_s (local.get $n))
                                                    (i64.const 1)))))
          (then
            (local.set $r (f64.sub (local.get $r)
                                   (f64.copysign (local.get $ay) (local.get $r))))
            (local.set $n (f64.add (local.get $n) (f64.const 1)))))))
    ;; A remainder of zero keeps the sign of the dividend.
    (if (f64.eq (local.get $r) (f64.const 0))
      (then (local.set $r (f64.copysign (f64.const 0) (local.get $x)))))
    (call $st_set (i32.const 0) (local.get $r))
    (local.set $q (i64.trunc_sat_f64_s (local.get $n)))
    (call $set_cc
      (i32.wrap_i64 (i64.and (i64.shr_u (local.get $q) (i64.const 2)) (i64.const 1)))
      (i32.const 0)
      (i32.wrap_i64 (i64.and (i64.shr_u (local.get $q) (i64.const 1)) (i64.const 1))))
    ;; C1 carries the lowest quotient bit here, not a rounding direction.
    (i32.store (i32.const 0x504)
      (i32.or (i32.and (i32.load (i32.const 0x504)) (i32.const 0xFDFF))
              (i32.shl (i32.wrap_i64 (i64.and (local.get $q) (i64.const 1)))
                       (i32.const 9)))))

  (func $status_word (result i32)
    (i32.or (i32.and (i32.load (i32.const 0x504)) (i32.const 0xC7FF))
            (i32.shl (call $ftop) (i32.const 11))))

  ;; FCOM-style comparison of ST(0) against a value
  (func $fcompare (param $b f64)
    (local $a f64)
    (local.set $a (call $st (i32.const 0)))
    (if (i32.or (f64.ne (local.get $a) (local.get $a)) (f64.ne (local.get $b) (local.get $b)))
      (then (call $set_cc (i32.const 1) (i32.const 1) (i32.const 1)) (return)))
    (if (f64.lt (local.get $a) (local.get $b))
      (then (call $set_cc (i32.const 1) (i32.const 0) (i32.const 0)) (return)))
    (if (f64.eq (local.get $a) (local.get $b))
      (then (call $set_cc (i32.const 0) (i32.const 0) (i32.const 1)) (return)))
    (call $set_cc (i32.const 0) (i32.const 0) (i32.const 0)))

  ;; FCOMI-style comparison, which reports into EFLAGS instead
  (func $fcompare_eflags (param $b f64)
    (local $a f64)
    (local.set $a (call $st (i32.const 0)))
    ;; These report through ZF, PF and CF, and clear OF, SF and AF outright --
    ;; leaving the arithmetic flags as they were makes a following JS or JO read
    ;; whatever the last unrelated operation happened to leave behind.
    (call $set_flag (i32.const 4) (i32.const 0))     ;; AF
    (call $set_flag (i32.const 7) (i32.const 0))     ;; SF
    (call $set_flag (i32.const 11) (i32.const 0))    ;; OF
    (if (i32.or (f64.ne (local.get $a) (local.get $a)) (f64.ne (local.get $b) (local.get $b)))
      (then (call $set_flag (i32.const 0) (i32.const 1))
            (call $set_flag (i32.const 2) (i32.const 1))
            (call $set_flag (i32.const 6) (i32.const 1))
            (return)))
    (call $set_flag (i32.const 2) (i32.const 0))
    (call $set_flag (i32.const 0) (f64.lt (local.get $a) (local.get $b)))
    (call $set_flag (i32.const 6) (f64.eq (local.get $a) (local.get $b))))

  ;; ---- memory operands ---------------------------------------------------
  (func $fread_mem (param $kind i32) (result f64)
    ;; 0 m32real, 1 m64real, 2 m80real, 3 m16int, 4 m32int, 5 m64int
    (local $v i64) (local $lo i64) (local $hi i64) (local $exp i32) (local $r f64)
    (block $d (result f64)
      (if (i32.eq (local.get $kind) (i32.const 0))
        (then (br $d (f64.promote_f32 (f32.reinterpret_i32
                (i32.wrap_i64 (call $rm_read (i32.const 4))))))))
      (if (i32.eq (local.get $kind) (i32.const 1))
        (then (br $d (f64.reinterpret_i64 (call $rm_read (i32.const 8))))))
      (if (i32.eq (local.get $kind) (i32.const 2))
        (then
          ;; 80-bit: 64-bit mantissa with an explicit integer bit, then a
          ;; 15-bit exponent biased by 16383
          (local.set $lo (call $seg_read (global.get $mrm_seg) (call $mrm_off) (i32.const 8)))
          (local.set $hi (call $seg_read (global.get $mrm_seg)
                           (i64.add (call $mrm_off) (i64.const 8)) (i32.const 2)))
          (local.set $exp (i32.and (i32.wrap_i64 (local.get $hi)) (i32.const 0x7FFF)))
          (if (i32.and (i32.eqz (local.get $exp)) (i64.eqz (local.get $lo)))
            (then (br $d (f64.const 0))))
          (local.set $r (f64.mul (f64.convert_i64_u (local.get $lo))
                                 (call $f_exp2 (f64.convert_i32_s
                                   (i32.sub (local.get $exp) (i32.const 16446))))))
          (if (i64.ne (i64.and (local.get $hi) (i64.const 0x8000)) (i64.const 0))
            (then (local.set $r (f64.neg (local.get $r)))))
          (br $d (local.get $r))))
      (if (i32.eq (local.get $kind) (i32.const 3))
        (then (br $d (f64.convert_i64_s (call $sext (call $rm_read (i32.const 2)) (i32.const 2))))))
      (if (i32.eq (local.get $kind) (i32.const 4))
        (then (br $d (f64.convert_i64_s (call $sext (call $rm_read (i32.const 4)) (i32.const 4))))))
      (f64.convert_i64_s (call $rm_read (i32.const 8)))))

  ;; Round according to the control word's RC field rather than always to
  ;; nearest.  A guest that wants the integer part of a value sets RC and then
  ;; uses FRNDINT or an integer store; ignoring RC puts that integer out by one
  ;; whenever the fraction is at least a half, and when the value is a binary
  ;; exponent -- as it is when computing a power of ten -- being out by one
  ;; scales the answer by a factor of two.
  (func $fpu_round (param $v f64) (result f64)
    (local $rc i32)
    (local.set $rc (i32.and (i32.shr_u (i32.load (i32.const 0x508)) (i32.const 10))
                            (i32.const 3)))
    (if (i32.eq (local.get $rc) (i32.const 1))
      (then (return (f64.floor (local.get $v)))))        ;; toward -infinity
    (if (i32.eq (local.get $rc) (i32.const 2))
      (then (return (f64.ceil (local.get $v)))))         ;; toward +infinity
    (if (i32.eq (local.get $rc) (i32.const 3))
      (then (return (f64.trunc (local.get $v)))))        ;; toward zero
    (f64.nearest (local.get $v)))

  ;; A value that will not fit the destination -- too large, infinite or NaN --
  ;; stores as the "integer indefinite" for that width, which is the most
  ;; negative value.  Saturating to 64 bits and then truncating to the width
  ;; instead writes whatever the low bits happen to be.
  (func $fpu_to_int (param $v f64) (param $size i32) (result i64)
    (local $lim f64)
    (local.set $lim (if (result f64) (i32.eq (local.get $size) (i32.const 2))
      (then (f64.const 32768))
      (else (if (result f64) (i32.eq (local.get $size) (i32.const 4))
              (then (f64.const 2147483648))
              (else (f64.const 9223372036854775808))))))
    (if (i32.or (f64.ne (local.get $v) (local.get $v))
                (i32.or (f64.ge (local.get $v) (local.get $lim))
                        (f64.lt (local.get $v) (f64.neg (local.get $lim)))))
      (then (return (i64.shl (i64.const -1)
                             (i64.extend_i32_u (i32.sub (i32.shl (local.get $size)
                                                                 (i32.const 3))
                                                        (i32.const 1)))))))
    (i64.trunc_f64_s (local.get $v)))

  (func $fwrite_mem (param $kind i32) (param $v f64)
    (local $mant i64) (local $exp i32) (local $a f64) (local $sign i64)
    (block $d
      (if (i32.eq (local.get $kind) (i32.const 0))
        (then (call $rm_write (i32.const 4)
                (i64.extend_i32_u (i32.reinterpret_f32 (f32.demote_f64 (local.get $v)))))
              (br $d)))
      (if (i32.eq (local.get $kind) (i32.const 1))
        (then (call $rm_write (i32.const 8) (i64.reinterpret_f64 (local.get $v))) (br $d)))
      (if (i32.eq (local.get $kind) (i32.const 2))
        (then
          (local.set $sign (if (result i64) (f64.lt (local.get $v) (f64.const 0))
                             (then (i64.const 0x8000)) (else (i64.const 0))))
          (local.set $a (f64.abs (local.get $v)))
          (if (f64.eq (local.get $a) (f64.const 0))
            (then
              (call $seg_write (global.get $mrm_seg) (call $mrm_off) (i32.const 8) (i64.const 0))
              (call $seg_write (global.get $mrm_seg) (i64.add (call $mrm_off) (i64.const 8))
                    (i32.const 2) (local.get $sign))
              (br $d)))
          ;; scale the mantissa up so its integer bit is set, then bias
          (local.set $exp (i32.add (i32.trunc_f64_s (f64.floor (call $f_log2 (local.get $a))))
                                   (i32.const 16383)))
          (local.set $mant (i64.trunc_f64_u (f64.mul (local.get $a)
            (call $f_exp2 (f64.convert_i32_s (i32.sub (i32.const 16446) (local.get $exp)))))))
          (call $seg_write (global.get $mrm_seg) (call $mrm_off) (i32.const 8) (local.get $mant))
          (call $seg_write (global.get $mrm_seg) (i64.add (call $mrm_off) (i64.const 8))
                (i32.const 2)
                (i64.or (local.get $sign) (i64.extend_i32_u (i32.and (local.get $exp) (i32.const 0x7FFF)))))
          (br $d)))
      ;; FIST and FISTP round the way the control word says; only FISTTP is
      ;; unconditionally toward zero, and it has its own path.
      (if (i32.eq (local.get $kind) (i32.const 3))
        (then (call $rm_write (i32.const 2)
                (call $fpu_to_int (call $fpu_round (local.get $v)) (i32.const 2)))
              (br $d)))
      (if (i32.eq (local.get $kind) (i32.const 4))
        (then (call $rm_write (i32.const 4)
                (call $fpu_to_int (call $fpu_round (local.get $v)) (i32.const 4)))
              (br $d)))
      (call $rm_write (i32.const 8)
        (call $fpu_to_int (call $fpu_round (local.get $v)) (i32.const 8)))))

  ;; FISTTP stores ST(0) as an integer truncated toward zero and pops, and it
  ;; does so regardless of the rounding mode -- that is the whole point of the
  ;; instruction, and it is what a compiler emits for a float-to-integer cast.
  ;; The other integer stores honour the control word, so they cannot share
  ;; this path.
  (func $fisttp_write (param $size i32)
    (call $rm_write (local.get $size)
      (call $fpu_to_int (f64.trunc (call $st (i32.const 0))) (local.get $size)))
    (call $fpop))

  ;; op: 0 add, 1 mul, 2 com, 3 comp, 4 sub, 5 subr, 6 div, 7 divr
  (func $farith (param $op i32) (param $dst i32) (param $b f64) (param $pop i32)
    (local $a f64) (local $r f64)
    (local.set $a (call $st (local.get $dst)))
    (block $d
      (if (i32.eq (local.get $op) (i32.const 0)) (then (local.set $r (f64.add (local.get $a) (local.get $b))) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 1)) (then (local.set $r (f64.mul (local.get $a) (local.get $b))) (br $d)))
      (if (i32.lt_u (local.get $op) (i32.const 4))
        (then
          (call $fcompare (local.get $b))
          (if (local.get $pop) (then (call $fpop)))
          (if (i32.eq (local.get $op) (i32.const 3)) (then (call $fpop)))
          (return)))
      (if (i32.eq (local.get $op) (i32.const 4)) (then (local.set $r (f64.sub (local.get $a) (local.get $b))) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 5)) (then (local.set $r (f64.sub (local.get $b) (local.get $a))) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 6)) (then (local.set $r (f64.div (local.get $a) (local.get $b))) (br $d)))
      (local.set $r (f64.div (local.get $b) (local.get $a))))
    (call $st_set (local.get $dst) (local.get $r))
    (if (local.get $pop) (then (call $fpop))))

  (func $fpu_init
    (i32.store (i32.const 0x504) (i32.const 0))
    (i32.store (i32.const 0x508) (i32.const 0x037F))
    (i32.store (i32.const 0x590) (i32.const 0))
    (i32.store (i32.const 0x594) (i32.const 0xFFFF)))     ;; every register empty

  ;; =========================================================================
  ;;  D8-DF dispatch
  ;; =========================================================================
  (func $h_x87 (param $op i32)
    (local $m i32) (local $sub i32) (local $i i32) (local $kind i32)
    (local $a f64) (local $b f64)

    ;; CR0.EM requests emulation, and CR0.TS a context switch first
    (if (i32.or (i32.wrap_i64 (i64.and (i64.shr_u (call $cr0) (i64.const 2)) (i64.const 1)))
                (call $fpu_ts))
      (then (call $raise (i32.const 7) (i64.const 0) (i32.const 0)) (return)))

    (call $decode_modrm)
    (local.set $m (global.get $modrm))
    (local.set $sub (global.get $mrm_ext))
    (local.set $i (i32.and (local.get $m) (i32.const 7)))

    ;; Diagnostic: record that this (escape opcode, ModRM) pair was reached.
    ;; Unimplemented forms here fall through to $done and do nothing at all
    ;; rather than faulting, so a wrong answer leaves no trace otherwise --
    ;; this is what turns "some float came out zero" into a list of opcodes.
    (i32.store8
      (i32.add (i32.const 0xF800)
               (i32.add (i32.shl (i32.sub (local.get $op) (i32.const 0xD8)) (i32.const 8))
                        (local.get $m)))
      (i32.const 1))

    ;; ---------------- memory operand forms ----------------
    (if (global.get $mrm_mem)
      (then
        (block $done
          ;; D8 and DC: arithmetic against a real in memory
          (if (i32.or (i32.eq (local.get $op) (i32.const 0xD8))
                      (i32.eq (local.get $op) (i32.const 0xDC)))
            (then
              (local.set $b (call $fread_mem
                (if (result i32) (i32.eq (local.get $op) (i32.const 0xD8))
                  (then (i32.const 0)) (else (i32.const 1)))))
              (if (global.get $fault) (then (return)))
              (call $farith (local.get $sub) (i32.const 0) (local.get $b) (i32.const 0))
              (br $done)))
          ;; DA and DE: arithmetic against an integer in memory
          (if (i32.or (i32.eq (local.get $op) (i32.const 0xDA))
                      (i32.eq (local.get $op) (i32.const 0xDE)))
            (then
              (local.set $b (call $fread_mem
                (if (result i32) (i32.eq (local.get $op) (i32.const 0xDA))
                  (then (i32.const 4)) (else (i32.const 3)))))
              (if (global.get $fault) (then (return)))
              (call $farith (local.get $sub) (i32.const 0) (local.get $b) (i32.const 0))
              (br $done)))
          ;; D9: load/store a single-precision real, plus the control words
          (if (i32.eq (local.get $op) (i32.const 0xD9))
            (then
              (if (i32.eq (local.get $sub) (i32.const 0))
                (then (local.set $b (call $fread_mem (i32.const 0)))
                      (if (global.get $fault) (then (return)))
                      (call $fpush (local.get $b)) (br $done)))
              (if (i32.or (i32.eq (local.get $sub) (i32.const 2)) (i32.eq (local.get $sub) (i32.const 3)))
                (then (call $fwrite_mem (i32.const 0) (call $st (i32.const 0)))
                      (if (i32.eq (local.get $sub) (i32.const 3)) (then (call $fpop)))
                      (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 5))            ;; FLDCW
                (then (i32.store (i32.const 0x508)
                        (i32.wrap_i64 (call $rm_read (i32.const 2)))) (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 7))            ;; FNSTCW
                (then (call $rm_write (i32.const 2)
                        (i64.extend_i32_u (i32.load (i32.const 0x508)))) (br $done)))
              (br $done)))
          ;; DB: 32-bit integers and the 80-bit real form
          (if (i32.eq (local.get $op) (i32.const 0xDB))
            (then
              (if (i32.eq (local.get $sub) (i32.const 0))
                (then (local.set $b (call $fread_mem (i32.const 4)))
                      (if (global.get $fault) (then (return)))
                      (call $fpush (local.get $b)) (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 1))            ;; FISTTP m32int
                (then (call $fisttp_write (i32.const 4)) (br $done)))
              (if (i32.or (i32.eq (local.get $sub) (i32.const 2))
                          (i32.eq (local.get $sub) (i32.const 3)))
                (then (call $fwrite_mem (i32.const 4) (call $st (i32.const 0)))
                      (if (i32.eq (local.get $sub) (i32.const 3)) (then (call $fpop)))
                      (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 5))
                (then (local.set $b (call $fread_mem (i32.const 2)))
                      (if (global.get $fault) (then (return)))
                      (call $fpush (local.get $b)) (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 7))
                (then (call $fwrite_mem (i32.const 2) (call $st (i32.const 0)))
                      (call $fpop) (br $done)))
              (br $done)))
          ;; DD: double-precision loads and stores, and the status word
          (if (i32.eq (local.get $op) (i32.const 0xDD))
            (then
              (if (i32.eq (local.get $sub) (i32.const 0))
                (then (local.set $b (call $fread_mem (i32.const 1)))
                      (if (global.get $fault) (then (return)))
                      (call $fpush (local.get $b)) (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 1))            ;; FISTTP m64int
                (then (call $fisttp_write (i32.const 8)) (br $done)))
              (if (i32.or (i32.eq (local.get $sub) (i32.const 2))
                          (i32.eq (local.get $sub) (i32.const 3)))
                (then (call $fwrite_mem (i32.const 1) (call $st (i32.const 0)))
                      (if (i32.eq (local.get $sub) (i32.const 3)) (then (call $fpop)))
                      (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 7))            ;; FNSTSW m16
                (then (call $rm_write (i32.const 2)
                        (i64.extend_i32_u (call $status_word))) (br $done)))
              (br $done)))
          ;; DF: 16-bit integers, and the 64-bit integer forms
          (if (i32.eq (local.get $op) (i32.const 0xDF))
            (then
              (if (i32.eq (local.get $sub) (i32.const 0))
                (then (local.set $b (call $fread_mem (i32.const 3)))
                      (if (global.get $fault) (then (return)))
                      (call $fpush (local.get $b)) (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 1))            ;; FISTTP m16int
                (then (call $fisttp_write (i32.const 2)) (br $done)))
              (if (i32.or (i32.eq (local.get $sub) (i32.const 2))
                          (i32.eq (local.get $sub) (i32.const 3)))
                (then (call $fwrite_mem (i32.const 3) (call $st (i32.const 0)))
                      (if (i32.eq (local.get $sub) (i32.const 3)) (then (call $fpop)))
                      (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 5))
                (then (local.set $b (call $fread_mem (i32.const 5)))
                      (if (global.get $fault) (then (return)))
                      (call $fpush (local.get $b)) (br $done)))
              (if (i32.eq (local.get $sub) (i32.const 7))
                (then (call $fwrite_mem (i32.const 5) (call $st (i32.const 0)))
                      (call $fpop) (br $done)))
              (br $done))))
        (return)))

    ;; ---------------- register forms ----------------
    (block $rdone
      ;; D8 and DC: arithmetic between ST(0) and ST(i)
      (if (i32.eq (local.get $op) (i32.const 0xD8))
        (then (call $farith (i32.shr_u (i32.and (local.get $m) (i32.const 0x38)) (i32.const 3))
                            (i32.const 0) (call $st (local.get $i)) (i32.const 0))
              (br $rdone)))
      (if (i32.eq (local.get $op) (i32.const 0xDC))
        (then
          ;; the destination is ST(i), and subtract/divide swap sense
          (local.set $sub (i32.shr_u (i32.and (local.get $m) (i32.const 0x38)) (i32.const 3)))
          (if (i32.eq (local.get $sub) (i32.const 4)) (then (local.set $sub (i32.const 5)))
            (else (if (i32.eq (local.get $sub) (i32.const 5)) (then (local.set $sub (i32.const 4)))
              (else (if (i32.eq (local.get $sub) (i32.const 6)) (then (local.set $sub (i32.const 7)))
                (else (if (i32.eq (local.get $sub) (i32.const 7)) (then (local.set $sub (i32.const 6))))))))))
          (call $farith (local.get $sub) (local.get $i) (call $st (i32.const 0)) (i32.const 0))
          (br $rdone)))
      (if (i32.eq (local.get $op) (i32.const 0xDE))
        (then
          (if (i32.eq (local.get $m) (i32.const 0xD9))               ;; FCOMPP
            (then (call $fcompare (call $st (i32.const 1)))
                  (call $fpop) (call $fpop) (br $rdone)))
          (local.set $sub (i32.shr_u (i32.and (local.get $m) (i32.const 0x38)) (i32.const 3)))
          (if (i32.eq (local.get $sub) (i32.const 4)) (then (local.set $sub (i32.const 5)))
            (else (if (i32.eq (local.get $sub) (i32.const 5)) (then (local.set $sub (i32.const 4)))
              (else (if (i32.eq (local.get $sub) (i32.const 6)) (then (local.set $sub (i32.const 7)))
                (else (if (i32.eq (local.get $sub) (i32.const 7)) (then (local.set $sub (i32.const 6))))))))))
          (call $farith (local.get $sub) (local.get $i) (call $st (i32.const 0)) (i32.const 1))
          (br $rdone)))

      ;; D9: constants, unary operations and transcendentals
      (if (i32.eq (local.get $op) (i32.const 0xD9))
        (then
          (if (i32.lt_u (local.get $m) (i32.const 0xC8))             ;; FLD ST(i)
            (then (call $fpush (call $st (local.get $i))) (br $rdone)))
          (if (i32.lt_u (local.get $m) (i32.const 0xD0))             ;; FXCH
            (then (local.set $a (call $st (i32.const 0)))
                  (call $st_set (i32.const 0) (call $st (local.get $i)))
                  (call $st_set (local.get $i) (local.get $a))
                  (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xE0))               ;; FCHS
            (then (call $st_set (i32.const 0) (f64.neg (call $st (i32.const 0)))) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xE1))               ;; FABS
            (then (call $st_set (i32.const 0) (f64.abs (call $st (i32.const 0)))) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xE4))               ;; FTST
            (then (call $fcompare (f64.const 0)) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xE5))               ;; FXAM
            (then (call $set_cc
                    (i32.const 0) (i32.const 1)
                    (f64.eq (call $st (i32.const 0)) (f64.const 0)))
                  (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xE8))
            (then (call $fpush (f64.const 1)) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xE9))
            (then (call $fpush (f64.const 3.321928094887362)) (br $rdone)))   ;; log2(10)
          (if (i32.eq (local.get $m) (i32.const 0xEA))
            (then (call $fpush (f64.const 1.4426950408889634)) (br $rdone)))  ;; log2(e)
          (if (i32.eq (local.get $m) (i32.const 0xEB))
            (then (call $fpush (f64.const 3.141592653589793)) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xEC))
            (then (call $fpush (f64.const 0.30102999566398120)) (br $rdone)))  ;; log10(2)
          (if (i32.eq (local.get $m) (i32.const 0xED))
            (then (call $fpush (f64.const 0.69314718055994531)) (br $rdone)))  ;; ln(2)
          (if (i32.eq (local.get $m) (i32.const 0xEE))
            (then (call $fpush (f64.const 0)) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF0))               ;; F2XM1
            (then (call $st_set (i32.const 0)
                    (f64.sub (call $f_exp2 (call $st (i32.const 0))) (f64.const 1)))
                  (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF1))               ;; FYL2X
            (then (call $st_set (i32.const 1)
                    (f64.mul (call $st (i32.const 1)) (call $f_log2 (call $st (i32.const 0)))))
                  (call $fpop) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF2))               ;; FPTAN
            (then (call $st_set (i32.const 0)
                    (f64.div (call $f_sin (call $st (i32.const 0)))
                             (call $f_cos (call $st (i32.const 0)))))
                  (call $fpush (f64.const 1))
                  (call $set_cc (i32.const 0) (i32.const 0) (i32.const 0))
                  (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF3))               ;; FPATAN
            (then (call $st_set (i32.const 1)
                    (call $f_atan2 (call $st (i32.const 1)) (call $st (i32.const 0))))
                  (call $fpop) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF5))               ;; FPREM1
            (then (call $fprem (i32.const 1)) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF6))               ;; FDECSTP
            (then (call $ftop_set (i32.sub (call $ftop) (i32.const 1))) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF7))               ;; FINCSTP
            (then (call $ftop_set (i32.add (call $ftop) (i32.const 1))) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF8))               ;; FPREM
            (then (call $fprem (i32.const 0)) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xF9))               ;; FYL2XP1
            (then (call $st_set (i32.const 1)
                    (f64.mul (call $st (i32.const 1))
                             (call $f_log2 (f64.add (call $st (i32.const 0)) (f64.const 1)))))
                  (call $fpop) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xFA))               ;; FSQRT
            (then (call $st_set (i32.const 0) (f64.sqrt (call $st (i32.const 0)))) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xFB))               ;; FSINCOS
            (then (local.set $a (call $st (i32.const 0)))
                  (call $st_set (i32.const 0) (call $f_sin (local.get $a)))
                  (call $fpush (call $f_cos (local.get $a)))
                  (call $set_cc (i32.const 0) (i32.const 0) (i32.const 0))
                  (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xFC))               ;; FRNDINT
            (then (call $st_set (i32.const 0) (call $fpu_round (call $st (i32.const 0))))
                  (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xFD))               ;; FSCALE
            (then (call $st_set (i32.const 0)
                    (f64.mul (call $st (i32.const 0))
                             (call $f_exp2 (f64.trunc (call $st (i32.const 1))))))
                  (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xFE))               ;; FSIN
            (then (call $st_set (i32.const 0) (call $f_sin (call $st (i32.const 0))))
                  (call $set_cc (i32.const 0) (i32.const 0) (i32.const 0)) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xFF))               ;; FCOS
            (then (call $st_set (i32.const 0) (call $f_cos (call $st (i32.const 0))))
                  (call $set_cc (i32.const 0) (i32.const 0) (i32.const 0)) (br $rdone)))
          (br $rdone)))

      ;; DA: FUCOMPP and the conditional moves
      (if (i32.eq (local.get $op) (i32.const 0xDA))
        (then
          (if (i32.eq (local.get $m) (i32.const 0xE9))
            (then (call $fcompare (call $st (i32.const 1)))
                  (call $fpop) (call $fpop) (br $rdone)))
          (if (call $fcmov_cond (local.get $op) (local.get $m))
            (then (call $st_set (i32.const 0) (call $st (local.get $i)))))
          (br $rdone)))

      ;; DB: init, clear, and the ordered compares that write EFLAGS
      (if (i32.eq (local.get $op) (i32.const 0xDB))
        (then
          (if (i32.eq (local.get $m) (i32.const 0xE3))
            (then (call $fpu_init) (br $rdone)))
          (if (i32.eq (local.get $m) (i32.const 0xE2))
            (then (i32.store (i32.const 0x504)
                    (i32.and (i32.load (i32.const 0x504)) (i32.const 0x7F00))) (br $rdone)))
          (if (i32.ge_u (local.get $m) (i32.const 0xF0))             ;; FCOMI
            (then (call $fcompare_eflags (call $st (local.get $i))) (br $rdone)))
          (if (i32.ge_u (local.get $m) (i32.const 0xE8))             ;; FUCOMI
            (then (call $fcompare_eflags (call $st (local.get $i))) (br $rdone)))
          (if (call $fcmov_cond (local.get $op) (local.get $m))
            (then (call $st_set (i32.const 0) (call $st (local.get $i)))))
          (br $rdone)))

      ;; DD: free, store to a register, unordered compares
      (if (i32.eq (local.get $op) (i32.const 0xDD))
        (then
          (if (i32.lt_u (local.get $m) (i32.const 0xC8))             ;; FFREE
            (then (call $tag_set (local.get $i) (i32.const 1)) (br $rdone)))
          (if (i32.lt_u (local.get $m) (i32.const 0xE0))             ;; FST/FSTP ST(i)
            (then (call $st_set (local.get $i) (call $st (i32.const 0)))
                  (if (i32.ge_u (local.get $m) (i32.const 0xD8)) (then (call $fpop)))
                  (br $rdone)))
          (call $fcompare (call $st (local.get $i)))                 ;; FUCOM/FUCOMP
          (if (i32.ge_u (local.get $m) (i32.const 0xE8)) (then (call $fpop)))
          (br $rdone)))

      ;; DF: status word to AX, and the popping ordered compares
      (if (i32.eq (local.get $op) (i32.const 0xDF))
        (then
          (if (i32.eq (local.get $m) (i32.const 0xE0))               ;; FNSTSW AX
            (then (call $setreg16 (i32.const 0) (call $status_word)) (br $rdone)))
          (if (i32.ge_u (local.get $m) (i32.const 0xE8))
            (then (call $fcompare_eflags (call $st (local.get $i)))
                  (call $fpop) (br $rdone)))
          (br $rdone))))
    )

  ;; condition selector for FCMOVcc, encoded in bits 3-5 of the ModRM byte
  ;; The condition comes from EFLAGS, and which of the pair it is -- FCMOVB or
  ;; FCMOVNB -- comes from the escape opcode, DA against DB.  It cannot be read
  ;; out of the ModRM byte, which is identical for both: DA C0 and DB C0 differ
  ;; only in the opcode.  Deriving it from ModRM (and then not using the answer)
  ;; made every FCMOVN* behave as its non-negated twin.
  (func $fcmov_cond (param $op i32) (param $m i32) (result i32)
    (local $c i32) (local $r i32)
    (local.set $c (i32.and (i32.shr_u (local.get $m) (i32.const 3)) (i32.const 3)))
    (block $d
      (if (i32.eq (local.get $c) (i32.const 0))
        (then (local.set $r (call $cf)) (br $d)))
      (if (i32.eq (local.get $c) (i32.const 1))
        (then (local.set $r (call $zf)) (br $d)))
      (if (i32.eq (local.get $c) (i32.const 2))
        (then (local.set $r (i32.or (call $cf) (call $zf))) (br $d)))
      (local.set $r (call $pf)))
    (if (result i32) (i32.eq (local.get $op) (i32.const 0xDB))
      (then (i32.eqz (local.get $r)))
      (else (local.get $r))))
