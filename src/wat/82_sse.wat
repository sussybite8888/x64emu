  ;; =========================================================================
  ;;  Part 82: SSE/SSE2 floating point -- arithmetic, compares, conversions
  ;; =========================================================================
  ;;
  ;;  Every one of these opcodes selects its operand type from the prefixes
  ;;  rather than from the opcode byte:
  ;;
  ;;      (none)  packed single    four f32 lanes
  ;;      66      packed double    two f64 lanes
  ;;      F3      scalar single    one f32, the rest of the destination kept
  ;;      F2      scalar double    one f64, the upper half kept
  ;;
  ;;  The scalar forms keeping the rest of the destination is the part worth
  ;;  stating: ADDSD writes eight bytes and leaves the top eight alone, so
  ;;  treating it as a packed operation quietly corrupts whatever the compiler
  ;;  had parked there.
  ;;
  ;;  A normal x86-64 toolchain compiles every `double` to these instructions,
  ;;  so without them anything built by gcc or clang raises #UD on its first
  ;;  piece of floating point.

  (global $SSE_PS i32 (i32.const 0))
  (global $SSE_PD i32 (i32.const 1))
  (global $SSE_SS i32 (i32.const 2))
  (global $SSE_SD i32 (i32.const 3))

  (func $ssef_type (result i32)
    (if (result i32) (i32.eq (global.get $rep) (i32.const 3))
      (then (i32.const 2))                                   ;; F3 -> scalar single
      (else (if (result i32) (i32.eq (global.get $rep) (i32.const 2))
              (then (i32.const 3))                           ;; F2 -> scalar double
              (else (if (result i32) (global.get $op66)
                      (then (i32.const 1))                   ;; 66 -> packed double
                      (else (i32.const 0))))))))             ;; else packed single

  ;; How many bytes the r/m operand occupies for a given type.  A scalar form
  ;; must not read sixteen: it would fault on a page the instruction has no
  ;; business touching, and an operand four bytes from the end of a page is
  ;; perfectly legal.
  (func $ssef_width (param $t i32) (result i32)
    (if (result i32) (i32.eq (local.get $t) (i32.const 2))
      (then (i32.const 4))
      (else (if (result i32) (i32.eq (local.get $t) (i32.const 3))
              (then (i32.const 8))
              (else (i32.const 16))))))

  ;; Load the r/m operand into the source scratch at 0x6420.
  (func $ssef_src (param $bytes i32)
    (local $la i64) (local $off i32)
    (i64.store (i32.const 0x6420) (i64.const 0))
    (i64.store (i32.const 0x6428) (i64.const 0))
    (if (global.get $mrm_mem)
      (then
        (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off) (local.get $bytes)))
        (if (global.get $fault) (then (return)))
        (if (i32.eq (local.get $bytes) (i32.const 4))
          (then (i64.store (i32.const 0x6420) (call $lin_read (local.get $la) (i32.const 4))))
          (else
            (i64.store (i32.const 0x6420) (call $lin_read (local.get $la) (i32.const 8)))
            (if (i32.eq (local.get $bytes) (i32.const 16))
              (then (i64.store (i32.const 0x6428)
                      (call $lin_read (i64.add (local.get $la) (i64.const 8))
                                      (i32.const 8))))))))
      (else
        (local.set $off (call $xmm_off (global.get $mrm_rm)))
        (i64.store (i32.const 0x6420) (i64.load (local.get $off)))
        (i64.store (i32.const 0x6428) (i64.load (i32.add (local.get $off) (i32.const 8)))))))

  ;; ---- lane helpers ------------------------------------------------------
  (func $lane32 (param $v i64) (param $i i32) (result f32)
    (f32.reinterpret_i32 (i32.wrap_i64
      (i64.shr_u (local.get $v)
                 (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 5)))))))

  ;; Pick one of the four single-precision lanes of a 128-bit value.
  (func $sse_lane (param $lo i64) (param $hi i64) (param $i i32) (result f32)
    (call $lane32
      (if (result i64) (i32.lt_u (local.get $i) (i32.const 2))
        (then (local.get $lo)) (else (local.get $hi)))
      (i32.and (local.get $i) (i32.const 1))))

  (func $pack32 (param $a f32) (param $b f32) (result i64)
    (i64.or (i64.extend_i32_u (i32.reinterpret_f32 (local.get $a)))
            (i64.shl (i64.extend_i32_u (i32.reinterpret_f32 (local.get $b)))
                     (i64.const 32))))

  ;; MINPS and MAXPS are specified as a comparison rather than as a function:
  ;; the result is the second operand whenever the comparison is not true, so a
  ;; NaN in either place, and the pair (-0.0, +0.0), both yield the source.
  ;; WebAssembly's own min and max settle those cases the other way, so they
  ;; cannot be used here.
  (func $sse_min32 (param $a f32) (param $b f32) (result f32)
    (if (result f32) (f32.lt (local.get $a) (local.get $b))
      (then (local.get $a)) (else (local.get $b))))
  (func $sse_max32 (param $a f32) (param $b f32) (result f32)
    (if (result f32) (f32.gt (local.get $a) (local.get $b))
      (then (local.get $a)) (else (local.get $b))))
  (func $sse_min64 (param $a f64) (param $b f64) (result f64)
    (if (result f64) (f64.lt (local.get $a) (local.get $b))
      (then (local.get $a)) (else (local.get $b))))
  (func $sse_max64 (param $a f64) (param $b f64) (result f64)
    (if (result f64) (f64.gt (local.get $a) (local.get $b))
      (then (local.get $a)) (else (local.get $b))))

  ;; x86 and WebAssembly disagree about the NaN an operation produces.  An
  ;; invalid operation -- 0/0, inf-inf, the square root of a negative -- yields
  ;; the "indefinite" QNaN, which has its sign bit *set*; WebAssembly produces a
  ;; positive canonical NaN.  And when an operand is already NaN, x86 passes
  ;; that operand through quieted rather than inventing a new one, preferring
  ;; the first.
  (func $sse_nan64 (param $r f64) (param $a f64) (param $b f64) (result f64)
    (if (f64.eq (local.get $r) (local.get $r)) (then (return (local.get $r))))
    (if (f64.ne (local.get $a) (local.get $a))
      (then (return (f64.reinterpret_i64 (i64.or (i64.reinterpret_f64 (local.get $a))
                                                 (i64.const 0x0008000000000000))))))
    (if (f64.ne (local.get $b) (local.get $b))
      (then (return (f64.reinterpret_i64 (i64.or (i64.reinterpret_f64 (local.get $b))
                                                 (i64.const 0x0008000000000000))))))
    (f64.reinterpret_i64 (i64.const 0xFFF8000000000000)))

  (func $sse_nan32 (param $r f32) (param $a f32) (param $b f32) (result f32)
    (if (f32.eq (local.get $r) (local.get $r)) (then (return (local.get $r))))
    (if (f32.ne (local.get $a) (local.get $a))
      (then (return (f32.reinterpret_i32 (i32.or (i32.reinterpret_f32 (local.get $a))
                                                 (i32.const 0x00400000))))))
    (if (f32.ne (local.get $b) (local.get $b))
      (then (return (f32.reinterpret_i32 (i32.or (i32.reinterpret_f32 (local.get $b))
                                                 (i32.const 0x00400000))))))
    (f32.reinterpret_i32 (i32.const 0xFFC00000)))

  (func $ssef_arith32 (param $op i32) (param $a f32) (param $b f32) (result f32)
    (call $sse_nan32
      (block $d (result f32)
      (if (i32.eq (local.get $op) (i32.const 0x51))
        (then (br $d (f32.sqrt (local.get $b)))))          ;; unary, on the source
      (if (i32.eq (local.get $op) (i32.const 0x58))
        (then (br $d (f32.add (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x59))
        (then (br $d (f32.mul (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x5C))
        (then (br $d (f32.sub (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x5D))
        (then (br $d (call $sse_min32 (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x5E))
        (then (br $d (f32.div (local.get $a) (local.get $b)))))
      (call $sse_max32 (local.get $a) (local.get $b)))     ;; 0x5F
      ;; SQRT takes only the source, so the destination must not be consulted
      ;; for NaN propagation.
      (if (result f32) (i32.eq (local.get $op) (i32.const 0x51))
        (then (local.get $b)) (else (local.get $a)))
      (local.get $b)))

  (func $ssef_arith64 (param $op i32) (param $a f64) (param $b f64) (result f64)
    (call $sse_nan64
      (block $d (result f64)
      (if (i32.eq (local.get $op) (i32.const 0x51))
        (then (br $d (f64.sqrt (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x58))
        (then (br $d (f64.add (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x59))
        (then (br $d (f64.mul (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x5C))
        (then (br $d (f64.sub (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x5D))
        (then (br $d (call $sse_min64 (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0x5E))
        (then (br $d (f64.div (local.get $a) (local.get $b)))))
      (call $sse_max64 (local.get $a) (local.get $b)))
      (if (result f64) (i32.eq (local.get $op) (i32.const 0x51))
        (then (local.get $b)) (else (local.get $a)))
      (local.get $b)))

  ;; CMPPS/CMPSS predicates, imm8 bits 0-2.  The result is a mask of all ones
  ;; or all zeros, which is what makes the compare compose with ANDPS/ANDNPS
  ;; into a branchless select.
  (func $ssef_cmp32 (param $p i32) (param $a f32) (param $b f32) (result i32)
    (local $u i32) (local $r i32)
    (local.set $u (i32.or (f32.ne (local.get $a) (local.get $a))
                          (f32.ne (local.get $b) (local.get $b))))
    (block $d
      (if (i32.eq (local.get $p) (i32.const 0))
        (then (local.set $r (f32.eq (local.get $a) (local.get $b))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 1))
        (then (local.set $r (f32.lt (local.get $a) (local.get $b))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 2))
        (then (local.set $r (f32.le (local.get $a) (local.get $b))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 3))
        (then (local.set $r (local.get $u)) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 4))
        (then (local.set $r (i32.eqz (f32.eq (local.get $a) (local.get $b)))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 5))
        (then (local.set $r (i32.eqz (f32.lt (local.get $a) (local.get $b)))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 6))
        (then (local.set $r (i32.eqz (f32.le (local.get $a) (local.get $b)))) (br $d)))
      (local.set $r (i32.eqz (local.get $u))))              ;; 7, ordered
    (if (result i32) (local.get $r) (then (i32.const -1)) (else (i32.const 0))))

  (func $ssef_cmp64 (param $p i32) (param $a f64) (param $b f64) (result i64)
    (local $u i32) (local $r i32)
    (local.set $u (i32.or (f64.ne (local.get $a) (local.get $a))
                          (f64.ne (local.get $b) (local.get $b))))
    (block $d
      (if (i32.eq (local.get $p) (i32.const 0))
        (then (local.set $r (f64.eq (local.get $a) (local.get $b))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 1))
        (then (local.set $r (f64.lt (local.get $a) (local.get $b))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 2))
        (then (local.set $r (f64.le (local.get $a) (local.get $b))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 3))
        (then (local.set $r (local.get $u)) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 4))
        (then (local.set $r (i32.eqz (f64.eq (local.get $a) (local.get $b)))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 5))
        (then (local.set $r (i32.eqz (f64.lt (local.get $a) (local.get $b)))) (br $d)))
      (if (i32.eq (local.get $p) (i32.const 6))
        (then (local.set $r (i32.eqz (f64.le (local.get $a) (local.get $b)))) (br $d)))
      (local.set $r (i32.eqz (local.get $u))))
    (if (result i64) (local.get $r) (then (i64.const -1)) (else (i64.const 0))))

  ;; =========================================================================
  ;;  0F 51, 55, 58, 59, 5C, 5D, 5E, 5F, 5A, 5B, C2
  ;; =========================================================================
  (func $h0f_ssef (param $op i32)
    (local $t i32) (local $d i32) (local $imm i32)
    (local $dlo i64) (local $dhi i64) (local $slo i64) (local $shi i64)
    (if (i32.eqz (call $sse_check)) (then (return)))
    (local.set $t (call $ssef_type))
    (call $decode_modrm)
    (local.set $d (call $xmm_off (global.get $mrm_reg)))

    ;; The compare predicate has to be fetched before the operand is read, not
    ;; after.  A RIP-relative address is resolved lazily against the current
    ;; RIP, so it is only correct once every byte of the instruction -- the
    ;; immediate included -- has been consumed.  Reading the operand first
    ;; picks up eight bytes starting one byte early.
    (if (i32.eq (local.get $op) (i32.const 0xC2))
      (then (local.set $imm (i32.and (call $fetch8) (i32.const 7)))
            (if (global.get $fault) (then (return)))))
    (if (i32.eq (local.get $op) (i32.const 0xC6))
      (then (local.set $imm (i32.and (call $fetch8) (i32.const 255)))
            (if (global.get $fault) (then (return)))))
    ;; Operand width does not always follow the prefix here.  CVTPS2PD reads
    ;; only the low eight bytes even though it carries no prefix at all, and
    ;; every form of 0F 5B reads a full sixteen even though CVTTPS2DQ carries
    ;; F3 -- which otherwise means "scalar, four bytes".
    (call $ssef_src
      (if (result i32) (i32.eq (local.get $op) (i32.const 0x5B))
        (then (i32.const 16))
        (else (if (result i32) (i32.eq (local.get $op) (i32.const 0x5A))
                (then (if (result i32) (i32.eq (local.get $t) (i32.const 0))
                        (then (i32.const 8))
                        (else (call $ssef_width (local.get $t)))))
                (else (call $ssef_width (local.get $t)))))))
    (if (global.get $fault) (then (return)))

    (local.set $slo (i64.load (i32.const 0x6420)))
    (local.set $shi (i64.load (i32.const 0x6428)))
    (local.set $dlo (i64.load (local.get $d)))
    (local.set $dhi (i64.load (i32.add (local.get $d) (i32.const 8))))

    (block $done
      ;; ---- ANDNPS / ANDNPD: the destination is complemented, not the source
      (if (i32.eq (local.get $op) (i32.const 0x55))
        (then
          (i64.store (local.get $d)
            (i64.and (i64.xor (local.get $dlo) (i64.const -1)) (local.get $slo)))
          (i64.store (i32.add (local.get $d) (i32.const 8))
            (i64.and (i64.xor (local.get $dhi) (i64.const -1)) (local.get $shi)))
          (br $done)))

      ;; ---- precision conversion -----------------------------------------
      (if (i32.eq (local.get $op) (i32.const 0x5A))
        (then
          (if (i32.eq (local.get $t) (i32.const 2))            ;; CVTSS2SD
            (then (i64.store (local.get $d) (i64.reinterpret_f64
                    (f64.promote_f32 (call $lane32 (local.get $slo) (i32.const 0)))))
                  (br $done)))
          (if (i32.eq (local.get $t) (i32.const 3))            ;; CVTSD2SS
            (then (i64.store (local.get $d) (i64.or
                    (i64.and (local.get $dlo) (i64.const 0xFFFFFFFF00000000))
                    (i64.extend_i32_u (i32.reinterpret_f32
                      (f32.demote_f64 (f64.reinterpret_i64 (local.get $slo)))))))
                  (br $done)))
          (if (i32.eq (local.get $t) (i32.const 0))            ;; CVTPS2PD
            (then
              (i64.store (local.get $d) (i64.reinterpret_f64
                (f64.promote_f32 (call $lane32 (local.get $slo) (i32.const 0)))))
              (i64.store (i32.add (local.get $d) (i32.const 8)) (i64.reinterpret_f64
                (f64.promote_f32 (call $lane32 (local.get $slo) (i32.const 1)))))
              (br $done)))
          ;; CVTPD2PS: two doubles into the low half, the top half cleared
          (i64.store (local.get $d) (call $pack32
            (f32.demote_f64 (f64.reinterpret_i64 (local.get $slo)))
            (f32.demote_f64 (f64.reinterpret_i64 (local.get $shi)))))
          (i64.store (i32.add (local.get $d) (i32.const 8)) (i64.const 0))
          (br $done)))

      ;; ---- integer <-> single, packed ------------------------------------
      (if (i32.eq (local.get $op) (i32.const 0x5B))
        (then
          (if (i32.eq (local.get $t) (i32.const 0))            ;; CVTDQ2PS
            (then
              (i64.store (local.get $d) (call $pack32
                (f32.convert_i32_s (i32.wrap_i64 (local.get $slo)))
                (f32.convert_i32_s (i32.wrap_i64 (i64.shr_u (local.get $slo) (i64.const 32))))))
              (i64.store (i32.add (local.get $d) (i32.const 8)) (call $pack32
                (f32.convert_i32_s (i32.wrap_i64 (local.get $shi)))
                (f32.convert_i32_s (i32.wrap_i64 (i64.shr_u (local.get $shi) (i64.const 32))))))
              (br $done)))
          ;; CVTPS2DQ rounds, CVTTPS2DQ truncates
          (i64.store (local.get $d) (i64.or
            (i64.extend_i32_u (call $ssef_toi32 (local.get $t)
              (call $lane32 (local.get $slo) (i32.const 0))))
            (i64.shl (i64.extend_i32_u (call $ssef_toi32 (local.get $t)
              (call $lane32 (local.get $slo) (i32.const 1)))) (i64.const 32))))
          (i64.store (i32.add (local.get $d) (i32.const 8)) (i64.or
            (i64.extend_i32_u (call $ssef_toi32 (local.get $t)
              (call $lane32 (local.get $shi) (i32.const 0))))
            (i64.shl (i64.extend_i32_u (call $ssef_toi32 (local.get $t)
              (call $lane32 (local.get $shi) (i32.const 1)))) (i64.const 32))))
          (br $done)))

      ;; ---- SHUFPS / SHUFPD ------------------------------------------------
      ;; The low half of the result comes from the destination and the high
      ;; half from the source, two bits of the immediate selecting each lane.
      ;; A compiled C library reaches for this constantly -- musl's SSE string
      ;; routines are built on it -- so without it a userspace process takes
      ;; #UD on its first string operation.
      (if (i32.eq (local.get $op) (i32.const 0xC6))
        (then
          (if (i32.eq (local.get $t) (i32.const 1))          ;; SHUFPD
            (then
              (i64.store (local.get $d)
                (if (result i64) (i32.and (local.get $imm) (i32.const 1))
                  (then (local.get $dhi)) (else (local.get $dlo))))
              (i64.store (i32.add (local.get $d) (i32.const 8))
                (if (result i64) (i32.and (local.get $imm) (i32.const 2))
                  (then (local.get $shi)) (else (local.get $slo))))
              (br $done)))
          (i64.store (local.get $d) (call $pack32
            (call $sse_lane (local.get $dlo) (local.get $dhi)
                  (i32.and (local.get $imm) (i32.const 3)))
            (call $sse_lane (local.get $dlo) (local.get $dhi)
                  (i32.and (i32.shr_u (local.get $imm) (i32.const 2)) (i32.const 3)))))
          (i64.store (i32.add (local.get $d) (i32.const 8)) (call $pack32
            (call $sse_lane (local.get $slo) (local.get $shi)
                  (i32.and (i32.shr_u (local.get $imm) (i32.const 4)) (i32.const 3)))
            (call $sse_lane (local.get $slo) (local.get $shi)
                  (i32.and (i32.shr_u (local.get $imm) (i32.const 6)) (i32.const 3)))))
          (br $done)))

      ;; ---- compare --------------------------------------------------------
      (if (i32.eq (local.get $op) (i32.const 0xC2))
        (then
          (if (i32.eq (local.get $t) (i32.const 3))            ;; CMPSD
            (then (i64.store (local.get $d) (call $ssef_cmp64 (local.get $imm)
                    (f64.reinterpret_i64 (local.get $dlo))
                    (f64.reinterpret_i64 (local.get $slo))))
                  (br $done)))
          (if (i32.eq (local.get $t) (i32.const 2))            ;; CMPSS
            (then (i64.store (local.get $d) (i64.or
                    (i64.and (local.get $dlo) (i64.const 0xFFFFFFFF00000000))
                    (i64.extend_i32_u (call $ssef_cmp32 (local.get $imm)
                      (call $lane32 (local.get $dlo) (i32.const 0))
                      (call $lane32 (local.get $slo) (i32.const 0))))))
                  (br $done)))
          (if (i32.eq (local.get $t) (i32.const 1))            ;; CMPPD
            (then
              (i64.store (local.get $d) (call $ssef_cmp64 (local.get $imm)
                (f64.reinterpret_i64 (local.get $dlo)) (f64.reinterpret_i64 (local.get $slo))))
              (i64.store (i32.add (local.get $d) (i32.const 8)) (call $ssef_cmp64 (local.get $imm)
                (f64.reinterpret_i64 (local.get $dhi)) (f64.reinterpret_i64 (local.get $shi))))
              (br $done)))
          ;; CMPPS
          (i64.store (local.get $d) (i64.or
            (i64.extend_i32_u (call $ssef_cmp32 (local.get $imm)
              (call $lane32 (local.get $dlo) (i32.const 0)) (call $lane32 (local.get $slo) (i32.const 0))))
            (i64.shl (i64.extend_i32_u (call $ssef_cmp32 (local.get $imm)
              (call $lane32 (local.get $dlo) (i32.const 1)) (call $lane32 (local.get $slo) (i32.const 1))))
              (i64.const 32))))
          (i64.store (i32.add (local.get $d) (i32.const 8)) (i64.or
            (i64.extend_i32_u (call $ssef_cmp32 (local.get $imm)
              (call $lane32 (local.get $dhi) (i32.const 0)) (call $lane32 (local.get $shi) (i32.const 0))))
            (i64.shl (i64.extend_i32_u (call $ssef_cmp32 (local.get $imm)
              (call $lane32 (local.get $dhi) (i32.const 1)) (call $lane32 (local.get $shi) (i32.const 1))))
              (i64.const 32))))
          (br $done)))

      ;; ---- arithmetic -----------------------------------------------------
      (if (i32.eq (local.get $t) (i32.const 3))                ;; scalar double
        (then (i64.store (local.get $d) (i64.reinterpret_f64
                (call $ssef_arith64 (local.get $op)
                  (f64.reinterpret_i64 (local.get $dlo))
                  (f64.reinterpret_i64 (local.get $slo)))))
              (br $done)))
      (if (i32.eq (local.get $t) (i32.const 2))                ;; scalar single
        (then (i64.store (local.get $d) (i64.or
                (i64.and (local.get $dlo) (i64.const 0xFFFFFFFF00000000))
                (i64.extend_i32_u (i32.reinterpret_f32
                  (call $ssef_arith32 (local.get $op)
                    (call $lane32 (local.get $dlo) (i32.const 0))
                    (call $lane32 (local.get $slo) (i32.const 0)))))))
              (br $done)))
      (if (i32.eq (local.get $t) (i32.const 1))                ;; packed double
        (then
          (i64.store (local.get $d) (i64.reinterpret_f64
            (call $ssef_arith64 (local.get $op)
              (f64.reinterpret_i64 (local.get $dlo)) (f64.reinterpret_i64 (local.get $slo)))))
          (i64.store (i32.add (local.get $d) (i32.const 8)) (i64.reinterpret_f64
            (call $ssef_arith64 (local.get $op)
              (f64.reinterpret_i64 (local.get $dhi)) (f64.reinterpret_i64 (local.get $shi)))))
          (br $done)))
      ;; packed single
      (i64.store (local.get $d) (call $pack32
        (call $ssef_arith32 (local.get $op)
          (call $lane32 (local.get $dlo) (i32.const 0)) (call $lane32 (local.get $slo) (i32.const 0)))
        (call $ssef_arith32 (local.get $op)
          (call $lane32 (local.get $dlo) (i32.const 1)) (call $lane32 (local.get $slo) (i32.const 1)))))
      (i64.store (i32.add (local.get $d) (i32.const 8)) (call $pack32
        (call $ssef_arith32 (local.get $op)
          (call $lane32 (local.get $dhi) (i32.const 0)) (call $lane32 (local.get $shi) (i32.const 0)))
        (call $ssef_arith32 (local.get $op)
          (call $lane32 (local.get $dhi) (i32.const 1)) (call $lane32 (local.get $shi) (i32.const 1)))))))

  ;; Truncating for the F3 form, rounding to nearest otherwise.  An out of
  ;; range value yields the "integer indefinite" 0x80000000 on real hardware,
  ;; which is what the saturating conversion produces for anything that
  ;; overflows negative -- close enough that no guest can tell, and far better
  ;; than trapping.
  (func $ssef_toi32 (param $t i32) (param $v f32) (result i32)
    (call $sse_f32_i32
      (if (result f32) (i32.eq (local.get $t) (i32.const 2))
        (then (local.get $v)) (else (f32.nearest (local.get $v))))))

  ;; A value that will not fit -- too large, infinite or NaN -- converts to the
  ;; "integer indefinite", which is the most negative value, in both
  ;; directions.  A saturating conversion would give the most *positive* value
  ;; for a large positive input, which is what the hardware does not do.
  (func $sse_f32_i32 (param $v f32) (result i32)
    (if (i32.or (f32.ne (local.get $v) (local.get $v))
                (i32.or (f32.ge (local.get $v) (f32.const 2147483648.0))
                        (f32.lt (local.get $v) (f32.const -2147483648.0))))
      (then (return (i32.const 0x80000000))))
    (i32.trunc_f32_s (local.get $v)))

  (func $sse_f64_i32 (param $v f64) (result i32)
    (if (i32.or (f64.ne (local.get $v) (local.get $v))
                (i32.or (f64.ge (local.get $v) (f64.const 2147483648.0))
                        (f64.lt (local.get $v) (f64.const -2147483648.0))))
      (then (return (i32.const 0x80000000))))
    (i32.trunc_f64_s (local.get $v)))

  (func $sse_f64_i64 (param $v f64) (result i64)
    (if (i32.or (f64.ne (local.get $v) (local.get $v))
                (i32.or (f64.ge (local.get $v) (f64.const 9223372036854775808.0))
                        (f64.lt (local.get $v) (f64.const -9223372036854775808.0))))
      (then (return (i64.const 0x8000000000000000))))
    (i64.trunc_f64_s (local.get $v)))

  (func $sse_f32_i64 (param $v f32) (result i64)
    (if (i32.or (f32.ne (local.get $v) (local.get $v))
                (i32.or (f32.ge (local.get $v) (f32.const 9223372036854775808.0))
                        (f32.lt (local.get $v) (f32.const -9223372036854775808.0))))
      (then (return (i64.const 0x8000000000000000))))
    (i64.trunc_f32_s (local.get $v)))

  ;; =========================================================================
  ;;  0F 2A CVTSI2SS/SD, 0F 2C CVTTxx2SI, 0F 2D CVTxx2SI
  ;; =========================================================================
  (func $h0f_cvtsi (param $op i32)
    (local $t i32) (local $size i32) (local $d i32) (local $v i64)
    (if (i32.eqz (call $sse_check)) (then (return)))
    (local.set $t (call $ssef_type))
    ;; Only the scalar forms exist here; the other two encodings are the MMX
    ;; conversions, which this core does not provide.
    (if (i32.lt_u (local.get $t) (i32.const 2)) (then (call $raise_ud) (return)))
    ;; REX.W selects the 64-bit integer, and nothing else does: these never
    ;; take their width from the 66 prefix, which is busy selecting the type.
    (local.set $size (if (result i32) (i32.and (global.get $rex) (i32.const 8))
                       (then (i32.const 8)) (else (i32.const 4))))
    (call $decode_modrm)

    (if (i32.eq (local.get $op) (i32.const 0x2A))
      (then
        (local.set $v (call $rm_read (local.get $size)))
        (if (global.get $fault) (then (return)))
        (local.set $d (call $xmm_off (global.get $mrm_reg)))
        (if (i32.eq (local.get $t) (i32.const 3))
          (then (i64.store (local.get $d) (i64.reinterpret_f64
                  (if (result f64) (i32.eq (local.get $size) (i32.const 8))
                    (then (f64.convert_i64_s (local.get $v)))
                    (else (f64.convert_i32_s (i32.wrap_i64 (local.get $v))))))))
          (else
            ;; CVTSI2SS writes only the low four bytes
            (i64.store (local.get $d) (i64.or
              (i64.and (i64.load (local.get $d)) (i64.const 0xFFFFFFFF00000000))
              (i64.extend_i32_u (i32.reinterpret_f32
                (if (result f32) (i32.eq (local.get $size) (i32.const 8))
                  (then (f32.convert_i64_s (local.get $v)))
                  (else (f32.convert_i32_s (i32.wrap_i64 (local.get $v)))))))))))
        (return)))

    ;; 2C and 2D go the other way: an XMM or memory source into a general
    ;; register, truncating for 2C and rounding for 2D.
    (call $ssef_src (if (result i32) (i32.eq (local.get $t) (i32.const 3))
                      (then (i32.const 8)) (else (i32.const 4))))
    (if (global.get $fault) (then (return)))
    (call $setregN (global.get $mrm_reg) (local.get $size)
      (if (result i64) (i32.eq (local.get $t) (i32.const 3))
        (then (call $ssef_f64toi (local.get $op) (local.get $size)
                (f64.reinterpret_i64 (i64.load (i32.const 0x6420)))))
        (else (call $ssef_f32toi (local.get $op) (local.get $size)
                (call $lane32 (i64.load (i32.const 0x6420)) (i32.const 0)))))))

  (func $ssef_f64toi (param $op i32) (param $size i32) (param $v f64) (result i64)
    (local $r f64)
    (local.set $r (if (result f64) (i32.eq (local.get $op) (i32.const 0x2C))
                    (then (local.get $v)) (else (f64.nearest (local.get $v)))))
    (if (result i64) (i32.eq (local.get $size) (i32.const 8))
      (then (call $sse_f64_i64 (local.get $r)))
      (else (i64.extend_i32_u (call $sse_f64_i32 (local.get $r))))))

  (func $ssef_f32toi (param $op i32) (param $size i32) (param $v f32) (result i64)
    (local $r f32)
    (local.set $r (if (result f32) (i32.eq (local.get $op) (i32.const 0x2C))
                    (then (local.get $v)) (else (f32.nearest (local.get $v)))))
    (if (result i64) (i32.eq (local.get $size) (i32.const 8))
      (then (call $sse_f32_i64 (local.get $r)))
      (else (i64.extend_i32_u (call $sse_f32_i32 (local.get $r))))))

  ;; =========================================================================
  ;;  0F 2E UCOMISS/UCOMISD, 0F 2F COMISS/COMISD
  ;; =========================================================================
  ;;  These are the compares a compiler emits for `a < b` on doubles.  They
  ;;  report into EFLAGS rather than into a mask, and the encoding is the one
  ;;  place where an unordered result is distinguishable: ZF, PF and CF all set
  ;;  at once happens for no ordinary comparison.
  (func $h0f_comis (param $op i32)
    (local $a f64) (local $b f64) (local $dbl i32)
    (if (i32.eqz (call $sse_check)) (then (return)))
    (local.set $dbl (global.get $op66))
    (call $decode_modrm)
    (call $ssef_src (if (result i32) (local.get $dbl)
                      (then (i32.const 8)) (else (i32.const 4))))
    (if (global.get $fault) (then (return)))
    (if (local.get $dbl)
      (then
        (local.set $a (f64.reinterpret_i64 (i64.load (call $xmm_off (global.get $mrm_reg)))))
        (local.set $b (f64.reinterpret_i64 (i64.load (i32.const 0x6420)))))
      (else
        (local.set $a (f64.promote_f32
          (call $lane32 (i64.load (call $xmm_off (global.get $mrm_reg))) (i32.const 0))))
        (local.set $b (f64.promote_f32
          (call $lane32 (i64.load (i32.const 0x6420)) (i32.const 0))))))

    (call $set_flag (i32.const 11) (i32.const 0))       ;; OF
    (call $set_flag (i32.const 4) (i32.const 0))        ;; AF
    (call $set_flag (i32.const 7) (i32.const 0))        ;; SF
    (if (i32.or (f64.ne (local.get $a) (local.get $a))
                (f64.ne (local.get $b) (local.get $b)))
      (then
        (call $set_flag (i32.const 0) (i32.const 1))
        (call $set_flag (i32.const 2) (i32.const 1))
        (call $set_flag (i32.const 6) (i32.const 1))
        (return)))
    (call $set_flag (i32.const 2) (i32.const 0))
    (call $set_flag (i32.const 0) (f64.lt (local.get $a) (local.get $b)))
    (call $set_flag (i32.const 6) (f64.eq (local.get $a) (local.get $b))))

  ;; =========================================================================
  ;;  0F 50 MOVMSKPS / MOVMSKPD
  ;; =========================================================================
  ;;  Gathers the sign bits of the lanes into a general register, which is how
  ;;  vectorised code turns a comparison into something it can branch on.
  (func $h0f_movmsk (param $op i32)
    (local $off i32) (local $lo i64) (local $hi i64) (local $r i32)
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)
    (if (global.get $mrm_mem) (then (call $raise_ud) (return)))
    (local.set $off (call $xmm_off (global.get $mrm_rm)))
    (local.set $lo (i64.load (local.get $off)))
    (local.set $hi (i64.load (i32.add (local.get $off) (i32.const 8))))
    (if (global.get $op66)
      (then                                             ;; MOVMSKPD, two lanes
        (local.set $r (i32.or
          (i32.wrap_i64 (i64.shr_u (local.get $lo) (i64.const 63)))
          (i32.shl (i32.wrap_i64 (i64.shr_u (local.get $hi) (i64.const 63)))
                   (i32.const 1)))))
      (else                                             ;; MOVMSKPS, four lanes
        ;; Shifting right by 63 leaves a single bit, but shifting by 31 leaves
        ;; everything above it as well, so the low lanes have to be masked to
        ;; one bit before they are placed.
        (local.set $r (i32.or
          (i32.or
            (i32.and (i32.wrap_i64 (i64.shr_u (local.get $lo) (i64.const 31)))
                     (i32.const 1))
            (i32.shl (i32.wrap_i64 (i64.shr_u (local.get $lo) (i64.const 63)))
                     (i32.const 1)))
          (i32.or
            (i32.shl (i32.and (i32.wrap_i64 (i64.shr_u (local.get $hi) (i64.const 31)))
                              (i32.const 1))
                     (i32.const 2))
            (i32.shl (i32.wrap_i64 (i64.shr_u (local.get $hi) (i64.const 63)))
                     (i32.const 3)))))))
    ;; The destination is a general register and is always written in full.
    (call $setregN (global.get $mrm_reg) (i32.const 4)
          (i64.extend_i32_u (i32.and (local.get $r) (i32.const 15)))))

  ;; =========================================================================
  ;;  66 0F D6 MOVQ xmm/m64, xmm
  ;; =========================================================================
  ;;  The store direction of MOVQ, and the usual way a compiler spills the low
  ;;  half of a register.  A register destination has its upper half cleared.
  (func $h0f_movq_st (param $op i32)
    (local $v i64) (local $off i32)
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)
    (local.set $v (i64.load (call $xmm_off (global.get $mrm_reg))))
    (if (global.get $mrm_mem)
      (then (call $seg_write (global.get $mrm_seg) (call $mrm_off) (i32.const 8) (local.get $v)))
      (else
        (local.set $off (call $xmm_off (global.get $mrm_rm)))
        (i64.store (local.get $off) (local.get $v))
        (i64.store (i32.add (local.get $off) (i32.const 8)) (i64.const 0)))))
