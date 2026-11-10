  ;; =========================================================================
  ;;  Part 90: dispatch tables, the step function, the run loop, exports
  ;; =========================================================================

  (func $mark_prefix (param $b i32)
    (i32.store8 (i32.add (i32.const 0x6300) (local.get $b)) (i32.const 1)))

  ;; MOVNTI (0F C3) stores a register to memory, bypassing caches we do not model
  (func $h0f_movnti (param $op i32)
    (call $decode_modrm)
    (call $rm_write (global.get $opsize) (call $reg_read (global.get $opsize))))

  (table $ops 95 funcref)
  (elem (table $ops) (i32.const 0) func
    $h_invalid        $h_alu            $h_pushpop_seg    $h_bcd            ;;  0..3
    $h_incdec_r       $h_push_r         $h_pop_r          $h_pusha          ;;  4..7
    $h_popa           $h_movsxd         $h_push_imm       $h_imul3          ;;  8..11
    $h_jcc8           $h_test           $h_xchg           $h_mov_rm_r       ;; 12..15
    $h_mov_seg        $h_lea            $h_pop_rm         $h_xchg_ax        ;; 16..19
    $h_cbw            $h_cwd            $h_callf          $h_nop            ;; 20..23
    $h_pushf          $h_popf           $h_sahf_lahf      $h_mov_moffs      ;; 24..27
    $h_test_a_imm     $h_mov_r_imm      $h_ret            $h_retf           ;; 28..31
    $h_mov_rm_imm     $h_enter          $h_leave          $h_int            ;; 32..35
    $h_iret           $h_aam            $h_xlat           $h_loop           ;; 36..39
    $h_inout_imm      $h_inout_dx       $h_call_jmp       $h_jmpf           ;; 40..43
    $h_hlt            $h_flagops        $h_lsf            $h_grp1           ;; 44..47
    $h_grp2           $h_grp3           $h_grp5           $h_string         ;; 48..51
    $h_ins_outs       $h_x87            $h0f_grp6         $h0f_grp7         ;; 52..55
    $h0f_syscall      $h0f_clts         $h0f_ud2          $h0f_nop          ;; 56..59
    $h0f_movcr        $h0f_msr          $h0f_cpuid        $h0f_cmov         ;; 60..63
    $h0f_jcc          $h0f_setcc        $h0f_pushpop_fsgs $h0f_bt           ;; 64..67
    $h0f_grp8         $h0f_shldshrd     $h0f_imul         $h0f_cmpxchg      ;; 68..71
    $h0f_xadd         $h0f_grp9         $h0f_movzx        $h0f_movsx        ;; 72..75
    $h0f_bsf          $h0f_popcnt       $h0f_bswap        $h0f_grp15        ;; 76..79
    $h0f_movxmm       $h0f_movd         $h0f_sse_arith    $h0f_movnti       ;; 80..83
    $h0f_sysenter     $h0f_movlh        $h0f_psimd        $h0f_pshift       ;; 84..87
    $h0f_ssef         $h0f_cvtsi        $h0f_comis        $h0f_movq_st      ;; 88..91
    $h0f_movmsk       $h0f_lar_lsl      $h0f_sse2x)                         ;; 92..94

  (func $init_tables
    (local $i i32)

    ;; operand-size masks and sign-bit masks, indexed by size in bytes
    (i64.store (i32.const 0x6208) (i64.const 0xFF))
    (i64.store (i32.const 0x6210) (i64.const 0xFFFF))
    (i64.store (i32.const 0x6220) (i64.const 0xFFFFFFFF))
    (i64.store (i32.const 0x6240) (i64.const -1))
    (i64.store (i32.const 0x6250) (i64.const 0x80))
    (i64.store (i32.const 0x6258) (i64.const 0x8000))
    (i64.store (i32.const 0x6268) (i64.const 0x80000000))
    (i64.store (i32.const 0x6288) (i64.const 0x8000000000000000))

    ;; prefix map
    (local.set $i (i32.const 0))
    (block $pe (loop $pl
      (br_if $pe (i32.ge_u (local.get $i) (i32.const 256)))
      (i32.store8 (i32.add (i32.const 0x6300) (local.get $i)) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $pl)))
    (i32.store8 (i32.const 0x6300) (i32.const 0))
    (call $mark_prefix (i32.const 0x26)) (call $mark_prefix (i32.const 0x2E))
    (call $mark_prefix (i32.const 0x36)) (call $mark_prefix (i32.const 0x3E))
    (call $mark_prefix (i32.const 0x64)) (call $mark_prefix (i32.const 0x65))
    (call $mark_prefix (i32.const 0x66)) (call $mark_prefix (i32.const 0x67))
    (call $mark_prefix (i32.const 0xF0)) (call $mark_prefix (i32.const 0xF2))
    (call $mark_prefix (i32.const 0xF3))
    (local.set $i (i32.const 0x40))
    (block $re (loop $rl                       ;; REX, only in 64-bit mode
      (br_if $re (i32.gt_u (local.get $i) (i32.const 0x4F)))
      (call $mark_prefix (local.get $i))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $rl)))

    (call $map1_range (i32.const 0) (i32.const 255) (i32.const 0))
    (call $map2_range (i32.const 0) (i32.const 255) (i32.const 0))

    ;; ---- one-byte map ----
    (call $map1_range (i32.const 0x00) (i32.const 0x05) (i32.const 1))
    (call $map1_range (i32.const 0x06) (i32.const 0x07) (i32.const 2))
    (call $map1_range (i32.const 0x08) (i32.const 0x0D) (i32.const 1))
    (call $map1_set   (i32.const 0x0E) (i32.const 2))
    (call $map1_range (i32.const 0x10) (i32.const 0x15) (i32.const 1))
    (call $map1_range (i32.const 0x16) (i32.const 0x17) (i32.const 2))
    (call $map1_range (i32.const 0x18) (i32.const 0x1D) (i32.const 1))
    (call $map1_range (i32.const 0x1E) (i32.const 0x1F) (i32.const 2))
    (call $map1_range (i32.const 0x20) (i32.const 0x25) (i32.const 1))
    (call $map1_set   (i32.const 0x27) (i32.const 3))
    (call $map1_range (i32.const 0x28) (i32.const 0x2D) (i32.const 1))
    (call $map1_set   (i32.const 0x2F) (i32.const 3))
    (call $map1_range (i32.const 0x30) (i32.const 0x35) (i32.const 1))
    (call $map1_set   (i32.const 0x37) (i32.const 3))
    (call $map1_range (i32.const 0x38) (i32.const 0x3D) (i32.const 1))
    (call $map1_set   (i32.const 0x3F) (i32.const 3))
    (call $map1_range (i32.const 0x40) (i32.const 0x4F) (i32.const 4))
    (call $map1_range (i32.const 0x50) (i32.const 0x57) (i32.const 5))
    (call $map1_range (i32.const 0x58) (i32.const 0x5F) (i32.const 6))
    (call $map1_set   (i32.const 0x60) (i32.const 7))
    (call $map1_set   (i32.const 0x61) (i32.const 8))
    (call $map1_set   (i32.const 0x63) (i32.const 9))
    (call $map1_set   (i32.const 0x68) (i32.const 10))
    (call $map1_set   (i32.const 0x69) (i32.const 11))
    (call $map1_set   (i32.const 0x6A) (i32.const 10))
    (call $map1_set   (i32.const 0x6B) (i32.const 11))
    (call $map1_range (i32.const 0x6C) (i32.const 0x6F) (i32.const 52))
    (call $map1_range (i32.const 0x70) (i32.const 0x7F) (i32.const 12))
    (call $map1_range (i32.const 0x80) (i32.const 0x83) (i32.const 47))
    (call $map1_range (i32.const 0x84) (i32.const 0x85) (i32.const 13))
    (call $map1_range (i32.const 0x86) (i32.const 0x87) (i32.const 14))
    (call $map1_range (i32.const 0x88) (i32.const 0x8B) (i32.const 15))
    (call $map1_set   (i32.const 0x8C) (i32.const 16))
    (call $map1_set   (i32.const 0x8D) (i32.const 17))
    (call $map1_set   (i32.const 0x8E) (i32.const 16))
    (call $map1_set   (i32.const 0x8F) (i32.const 18))
    (call $map1_range (i32.const 0x90) (i32.const 0x97) (i32.const 19))
    (call $map1_set   (i32.const 0x98) (i32.const 20))
    (call $map1_set   (i32.const 0x99) (i32.const 21))
    (call $map1_set   (i32.const 0x9A) (i32.const 22))
    (call $map1_set   (i32.const 0x9B) (i32.const 23))
    (call $map1_set   (i32.const 0x9C) (i32.const 24))
    (call $map1_set   (i32.const 0x9D) (i32.const 25))
    (call $map1_range (i32.const 0x9E) (i32.const 0x9F) (i32.const 26))
    (call $map1_range (i32.const 0xA0) (i32.const 0xA3) (i32.const 27))
    (call $map1_range (i32.const 0xA4) (i32.const 0xA7) (i32.const 51))
    (call $map1_range (i32.const 0xA8) (i32.const 0xA9) (i32.const 28))
    (call $map1_range (i32.const 0xAA) (i32.const 0xAF) (i32.const 51))
    (call $map1_range (i32.const 0xB0) (i32.const 0xBF) (i32.const 29))
    (call $map1_range (i32.const 0xC0) (i32.const 0xC1) (i32.const 48))
    (call $map1_range (i32.const 0xC2) (i32.const 0xC3) (i32.const 30))
    (call $map1_range (i32.const 0xC4) (i32.const 0xC5) (i32.const 46))
    (call $map1_range (i32.const 0xC6) (i32.const 0xC7) (i32.const 32))
    (call $map1_set   (i32.const 0xC8) (i32.const 33))
    (call $map1_set   (i32.const 0xC9) (i32.const 34))
    (call $map1_range (i32.const 0xCA) (i32.const 0xCB) (i32.const 31))
    (call $map1_range (i32.const 0xCC) (i32.const 0xCE) (i32.const 35))
    (call $map1_set   (i32.const 0xCF) (i32.const 36))
    (call $map1_range (i32.const 0xD0) (i32.const 0xD3) (i32.const 48))
    (call $map1_range (i32.const 0xD4) (i32.const 0xD5) (i32.const 37))
    (call $map1_set   (i32.const 0xD7) (i32.const 38))
    (call $map1_range (i32.const 0xD8) (i32.const 0xDF) (i32.const 53))
    (call $map1_range (i32.const 0xE0) (i32.const 0xE3) (i32.const 39))
    (call $map1_range (i32.const 0xE4) (i32.const 0xE7) (i32.const 40))
    (call $map1_range (i32.const 0xE8) (i32.const 0xE9) (i32.const 42))
    (call $map1_set   (i32.const 0xEA) (i32.const 43))
    (call $map1_set   (i32.const 0xEB) (i32.const 42))
    (call $map1_range (i32.const 0xEC) (i32.const 0xEF) (i32.const 41))
    (call $map1_set   (i32.const 0xF4) (i32.const 44))
    (call $map1_set   (i32.const 0xF5) (i32.const 45))
    (call $map1_range (i32.const 0xF6) (i32.const 0xF7) (i32.const 49))
    (call $map1_range (i32.const 0xF8) (i32.const 0xFD) (i32.const 45))
    (call $map1_range (i32.const 0xFE) (i32.const 0xFF) (i32.const 50))

    ;; ---- two-byte map ----
    (call $map2_set   (i32.const 0x00) (i32.const 54))
    (call $map2_set   (i32.const 0x01) (i32.const 55))
    (call $map2_range (i32.const 0x02) (i32.const 0x03) (i32.const 93))
    (call $map2_set   (i32.const 0x05) (i32.const 56))
    (call $map2_set   (i32.const 0x06) (i32.const 57))
    (call $map2_set   (i32.const 0x07) (i32.const 56))
    (call $map2_range (i32.const 0x08) (i32.const 0x09) (i32.const 23))
    (call $map2_set   (i32.const 0x0B) (i32.const 58))
    (call $map2_range (i32.const 0x0D) (i32.const 0x0F) (i32.const 59))
    (call $map2_range (i32.const 0x10) (i32.const 0x11) (i32.const 80))
    (call $map2_range (i32.const 0x12) (i32.const 0x17) (i32.const 85))
    (call $map2_range (i32.const 0x18) (i32.const 0x1F) (i32.const 59))
    (call $map2_range (i32.const 0x20) (i32.const 0x23) (i32.const 60))
    (call $map2_range (i32.const 0x28) (i32.const 0x29) (i32.const 80))
    (call $map2_range (i32.const 0x30) (i32.const 0x33) (i32.const 61))
    (call $map2_range (i32.const 0x34) (i32.const 0x35) (i32.const 84))
    (call $map2_range (i32.const 0x40) (i32.const 0x4F) (i32.const 63))
    (call $map2_set   (i32.const 0x54) (i32.const 82))
    (call $map2_range (i32.const 0x56) (i32.const 0x57) (i32.const 82))
    (call $map2_set   (i32.const 0x6E) (i32.const 81))
    (call $map2_set   (i32.const 0x6F) (i32.const 80))
    (call $map2_set   (i32.const 0x7E) (i32.const 81))
    (call $map2_set   (i32.const 0x7F) (i32.const 80))
    (call $map2_range (i32.const 0x80) (i32.const 0x8F) (i32.const 64))
    (call $map2_range (i32.const 0x90) (i32.const 0x9F) (i32.const 65))
    (call $map2_range (i32.const 0xA0) (i32.const 0xA1) (i32.const 66))
    (call $map2_set   (i32.const 0xA2) (i32.const 62))
    (call $map2_set   (i32.const 0xA3) (i32.const 67))
    (call $map2_range (i32.const 0xA4) (i32.const 0xA5) (i32.const 69))
    (call $map2_range (i32.const 0xA8) (i32.const 0xA9) (i32.const 66))
    (call $map2_set   (i32.const 0xAB) (i32.const 67))
    (call $map2_range (i32.const 0xAC) (i32.const 0xAD) (i32.const 69))
    (call $map2_set   (i32.const 0xAE) (i32.const 79))
    (call $map2_set   (i32.const 0xAF) (i32.const 70))
    (call $map2_range (i32.const 0xB0) (i32.const 0xB1) (i32.const 71))
    (call $map2_set   (i32.const 0xB2) (i32.const 46))
    (call $map2_set   (i32.const 0xB3) (i32.const 67))
    (call $map2_range (i32.const 0xB4) (i32.const 0xB5) (i32.const 46))
    (call $map2_range (i32.const 0xB6) (i32.const 0xB7) (i32.const 74))
    (call $map2_set   (i32.const 0xB8) (i32.const 77))
    (call $map2_set   (i32.const 0xBA) (i32.const 68))
    (call $map2_set   (i32.const 0xBB) (i32.const 67))
    (call $map2_range (i32.const 0xBC) (i32.const 0xBD) (i32.const 76))
    (call $map2_range (i32.const 0xBE) (i32.const 0xBF) (i32.const 75))
    (call $map2_range (i32.const 0xC0) (i32.const 0xC1) (i32.const 72))
    (call $map2_set   (i32.const 0xC3) (i32.const 83))
    (call $map2_set   (i32.const 0xC7) (i32.const 73))
    (call $map2_range (i32.const 0xC8) (i32.const 0xCF) (i32.const 78))
    ;; SSE/SSE2 floating point.  The prefix picks packed/scalar and
    ;; single/double, so one handler covers four encodings of each opcode.
    (call $map2_set   (i32.const 0x2A) (i32.const 89))   ;; CVTSI2SS/SD
    (call $map2_range (i32.const 0x2C) (i32.const 0x2D) (i32.const 89))
    (call $map2_range (i32.const 0x2E) (i32.const 0x2F) (i32.const 90))  ;; UCOMIS/COMIS
    (call $map2_set   (i32.const 0x51) (i32.const 88))   ;; SQRT
    (call $map2_set   (i32.const 0x55) (i32.const 88))   ;; ANDN
    (call $map2_range (i32.const 0x58) (i32.const 0x5F) (i32.const 88))  ;; arith + cvt
    (call $map2_set   (i32.const 0xC2) (i32.const 88))   ;; CMP
    (call $map2_set   (i32.const 0xD6) (i32.const 91))   ;; MOVQ store

    (call $map2_set   (i32.const 0xC6) (i32.const 88))   ;; SHUFPS / SHUFPD
    (call $map2_set   (i32.const 0x50) (i32.const 92))   ;; MOVMSKPS / MOVMSKPD
    (call $map2_set   (i32.const 0xD4) (i32.const 86))   ;; PADDQ

    ;; packed shifts
    (call $map2_range (i32.const 0x71) (i32.const 0x73) (i32.const 87))
    (call $map2_range (i32.const 0xD1) (i32.const 0xD3) (i32.const 87))
    (call $map2_range (i32.const 0xE1) (i32.const 0xE2) (i32.const 87))
    (call $map2_range (i32.const 0xF1) (i32.const 0xF3) (i32.const 87))

    ;; packed integer group
    (call $map2_set   (i32.const 0x2B) (i32.const 86))    ;; MOVNTPS
    (call $map2_range (i32.const 0x60) (i32.const 0x62) (i32.const 86))
    (call $map2_range (i32.const 0x64) (i32.const 0x66) (i32.const 86))
    (call $map2_range (i32.const 0x68) (i32.const 0x6A) (i32.const 86))
    (call $map2_set   (i32.const 0x6C) (i32.const 86))
    (call $map2_set   (i32.const 0x6D) (i32.const 86))
    (call $map2_set   (i32.const 0x70) (i32.const 86))
    (call $map2_range (i32.const 0x74) (i32.const 0x76) (i32.const 86))
    (call $map2_set   (i32.const 0xD6) (i32.const 86))
    (call $map2_set   (i32.const 0xD7) (i32.const 86))
    (call $map2_set   (i32.const 0xDB) (i32.const 86))
    (call $map2_set   (i32.const 0xDF) (i32.const 86))
    (call $map2_set   (i32.const 0xE7) (i32.const 86))
    (call $map2_set   (i32.const 0xEB) (i32.const 86))
    (call $map2_range (i32.const 0xF8) (i32.const 0xFE) (i32.const 86))
    (call $map2_set   (i32.const 0xEF) (i32.const 82))
    ;; the rest of the SSE2 integer set: packs, saturating arithmetic, min,
    ;; max, average, the multiplies, PMADDWD and PSADBW
    (call $map2_set   (i32.const 0x63) (i32.const 86))
    (call $map2_set   (i32.const 0x67) (i32.const 86))
    (call $map2_set   (i32.const 0x6B) (i32.const 86))
    (call $map2_set   (i32.const 0xD5) (i32.const 86))
    (call $map2_range (i32.const 0xD8) (i32.const 0xDA) (i32.const 86))
    (call $map2_range (i32.const 0xDC) (i32.const 0xDE) (i32.const 86))
    (call $map2_set   (i32.const 0xE0) (i32.const 86))
    (call $map2_range (i32.const 0xE3) (i32.const 0xE5) (i32.const 86))
    (call $map2_range (i32.const 0xE8) (i32.const 0xEA) (i32.const 86))
    (call $map2_range (i32.const 0xEC) (i32.const 0xEE) (i32.const 86))
    (call $map2_range (i32.const 0xF4) (i32.const 0xF6) (i32.const 86))
    ;; and the ones with operands of their own
    (call $map2_range (i32.const 0x52) (i32.const 0x53) (i32.const 94))  ;; RSQRT, RCP
    (call $map2_set   (i32.const 0x77) (i32.const 94))                   ;; EMMS
    (call $map2_range (i32.const 0xC4) (i32.const 0xC5) (i32.const 94))  ;; PINSRW, PEXTRW
    (call $map2_set   (i32.const 0xE6) (i32.const 94))                   ;; CVT*PD2DQ, CVTDQ2PD
    (call $map2_set   (i32.const 0xF7) (i32.const 94)))                  ;; MASKMOVDQU

  ;; =========================================================================
  ;;  decode one instruction and execute it
  ;; =========================================================================
  (func $step
    (local $b i32) (local $op i32) (local $h i32) (local $two i32)

    (global.set $rip0 (global.get $rip_g))
    (global.set $rsp0 (i64.load (i32.const 0x20)))
    (if (global.get $trace_on) (then (call $trace_record)))
    (call $fill_window)
    ;; Most instructions carry no prefixes, and then the decoder state is
    ;; already at its defaults from the last reset.
    (if (global.get $pfx_dirty)
      (then
        (global.set $rex (i32.const 0))
        (global.set $segovr (i32.const -1))
        (global.set $rep (i32.const 0))
        (global.set $lockp (i32.const 0))
        (global.set $op66 (i32.const 0))
        (global.set $opsize (global.get $def_op))
        (global.set $addrsize (global.get $def_addr))
        (global.set $pfx_dirty (i32.const 0))))

    ;; ---- prefix loop ----
    (block $pfx_done
      (loop $pfx
        (local.set $b (call $fetch8))
        (if (global.get $fault) (then (return)))

        ;; Most opcodes are not prefixed, so one table lookup replaces the
        ;; dozen comparisons below in the common case.
        (br_if $pfx_done
          (i32.eqz (i32.load8_u (i32.add (i32.const 0x6300) (local.get $b)))))
        (global.set $pfx_dirty (i32.const 1))

        ;; REX must be the final prefix; any later prefix cancels it
        (if (i32.and (i32.eq (global.get $mode) (i32.const 3))
                     (i32.eq (i32.and (local.get $b) (i32.const 0xF0)) (i32.const 0x40)))
          (then
            (global.set $rex (local.get $b))
            (if (i32.and (local.get $b) (i32.const 8))
              (then (global.set $opsize (i32.const 8))))
            (br $pfx)))

        (if (i32.eq (local.get $b) (i32.const 0x66))
          (then (global.set $rex (i32.const 0)) (global.set $op66 (i32.const 1))
                (if (i32.ne (global.get $opsize) (i32.const 8))
                  (then (global.set $opsize
                          (if (result i32) (i32.eq (call $default_opsize) (i32.const 2))
                            (then (i32.const 4)) (else (i32.const 2))))))
                (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0x67))
          (then (global.set $rex (i32.const 0))
                (global.set $addrsize
                  (if (result i32) (i32.eq (global.get $mode) (i32.const 3))
                    (then (i32.const 4))
                    (else (if (result i32) (i32.eq (call $default_addrsize) (i32.const 2))
                            (then (i32.const 4)) (else (i32.const 2))))))
                (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0x2E))
          (then (global.set $rex (i32.const 0)) (global.set $segovr (i32.const 1)) (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0x36))
          (then (global.set $rex (i32.const 0)) (global.set $segovr (i32.const 2)) (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0x3E))
          (then (global.set $rex (i32.const 0)) (global.set $segovr (i32.const 3)) (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0x26))
          (then (global.set $rex (i32.const 0)) (global.set $segovr (i32.const 0)) (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0x64))
          (then (global.set $rex (i32.const 0)) (global.set $segovr (i32.const 4)) (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0x65))
          (then (global.set $rex (i32.const 0)) (global.set $segovr (i32.const 5)) (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0xF0))
          (then (global.set $rex (i32.const 0)) (global.set $lockp (i32.const 1)) (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0xF2))
          (then (global.set $rex (i32.const 0)) (global.set $rep (i32.const 2)) (br $pfx)))
        (if (i32.eq (local.get $b) (i32.const 0xF3))
          (then (global.set $rex (i32.const 0)) (global.set $rep (i32.const 3)) (br $pfx)))
        (br $pfx_done)))

    ;; segment overrides in 64-bit mode only apply to FS and GS
    (if (i32.and (i32.eq (global.get $mode) (i32.const 3))
                 (i32.lt_s (global.get $segovr) (i32.const 4)))
      (then (global.set $segovr (i32.const -1))))

    (local.set $op (local.get $b))
    (if (i32.eq (local.get $op) (i32.const 0x0F))
      (then
        (local.set $op (call $fetch8))
        (if (global.get $fault) (then (return)))
        (local.set $two (i32.const 1))))

    (if (local.get $two)
      (then (local.set $h (i32.load8_u (i32.add (i32.const 0x700) (local.get $op)))))
      (else (local.set $h (i32.load8_u (i32.add (i32.const 0x600) (local.get $op))))))

    (call_indirect $ops (type $ophandler) (local.get $op) (local.get $h)))

  ;; =========================================================================
  ;;  exception delivery and the outer run loop
  ;; =========================================================================
  ;; Faults are logged to a ring buffer at 0x900 (rip0, vector, error) so the
  ;; host can say exactly which instruction faulted and why.
  (func $log_fault (param $vec i32) (param $err i64)
    (local $slot i32)
    (local.set $slot (i32.add (i32.const 0x5910)
      (i32.shl (i32.and (i32.load (i32.const 0x5900)) (i32.const 63)) (i32.const 5))))
    (i64.store (local.get $slot) (global.get $rip0))
    (i32.store (i32.add (local.get $slot) (i32.const 8)) (local.get $vec))
    (i64.store (i32.add (local.get $slot) (i32.const 16)) (local.get $err))
    (i32.store (i32.add (local.get $slot) (i32.const 24)) (global.get $mode))
    (i32.store (i32.const 0x5900) (i32.add (i32.load (i32.const 0x5900)) (i32.const 1))))

  (func $deliver_fault
    (local $vec i32) (local $err i64) (local $has i32)
    (local.set $vec (i32.load (i32.const 0xC8)))
    (local.set $has (i32.load (i32.const 0xCC)))
    (local.set $err (i64.load (i32.const 0xD0)))
    (call $log_fault (local.get $vec) (local.get $err))
    (global.set $fault (i32.const 0))
    ;; Faults report the address of the instruction that caused them, and
    ;; find the stack as it was before it.  A handler that restarts or
    ;; examines the instruction depends on that: an IRET that faults on a
    ;; not-present segment must leave its frame where the handler can read it,
    ;; which is how Windows 95 demand-loads 16-bit code.
    (call $set_rip (global.get $rip0))
    (i64.store (i32.const 0x20) (global.get $rsp0))
    (call $do_interrupt (local.get $vec) (local.get $err) (local.get $has)
                        (i32.const 0) (global.get $rip0))
    (if (global.get $fault)
      (then
        ;; a fault while delivering a fault escalates to #DF
        (global.set $fault (i32.const 0))
        (call $do_interrupt (i32.const 8) (i64.const 0) (i32.const 1)
                            (i32.const 0) (global.get $rip0))
        (if (global.get $fault)
          (then (global.set $fault (i32.const 0))
                (global.set $exit_req (i32.const 3)))))))    ;; triple fault

  ;; exit codes: 0 budget exhausted, 1 halted, 2 host stop, 3 triple fault
  ;;
  ;;  Interrupts are examined before every instruction.  Sampling the line
  ;;  periodically instead was tried and measured no faster, while changing when
  ;;  interrupts reach the guest and when the post-STI shadow clears, so it was
  ;;  put back.  The instruction count is also kept separately from the
  ;;  timestamp counter: a guest may write the TSC through WRMSR, and the loop
  ;;  bound must not depend on a value the guest controls.
  (func $run (param $budget i32) (result i32)
    (local $n i32) (local $vec i32) (local $slot i32) (local $k i32) (local $shadow i32)
    (global.set $exit_req (i32.const 0))
    (block $stop
      (loop $l
        (br_if $stop (i32.ge_u (local.get $n) (local.get $budget)))

        (if (i32.load (i32.const 0xD8))
          (then
            (if (i32.and (call $iff) (i32.eqz (i32.load (i32.const 0xDC))))
              (then
                (local.set $vec (call $irq_ack))
                (if (i32.ge_s (local.get $vec) (i32.const 0))
                  (then
                    (global.set $halted (i32.const 0))
                    (i32.store (i32.const 0xBC) (i32.const 0))
                    ;; between instructions: a fault while delivering this
                    ;; belongs to the next one
                    (global.set $rip0 (global.get $rip_g))
                    (global.set $rsp0 (i64.load (i32.const 0x20)))
                    (call $do_interrupt (local.get $vec) (i64.const 0) (i32.const 0)
                                        (i32.const 0) (call $rip))
                    (if (global.get $fault) (then (call $deliver_fault))))
                  ;; Nothing deliverable: drop the line until the host raises
                  ;; it again, rather than asking on every instruction.
                  (else (i32.store (i32.const 0xD8) (i32.const 0))))))))
        ;; STI and MOV SS hold interrupts off for exactly one instruction.
        ;; That instruction is interpreted on its own rather than as the start
        ;; of a compiled block, so the interrupt check comes round again right
        ;; after it.  "sti; nop; cli" is how VMM opens a window for pending
        ;; interrupts, and running nop and cli together in one block closed it
        ;; every time: Windows 95 waited forever for an event with IF clear.
        (local.set $shadow (i32.load (i32.const 0xDC)))
        (if (local.get $shadow)
          (then (i32.store (i32.const 0xDC) (i32.const 0))))

        (if (global.get $halted)
          (then (global.set $exit_req (i32.const 1)) (br $stop)))

        ;; A compiled block replaces a whole run of $step calls.  It does its
        ;; own accounting because it may retire several instructions, or stop
        ;; early on a fault, and the interpreter's fixed increment of one would
        ;; be wrong either way.
        (block $interp
          (br_if $interp (i32.eqz (global.get $jit_on)))
          (br_if $interp (local.get $shadow))
          ;; Only branch targets are candidates, so straight-line interpreted
          ;; code pays one predictable branch and never touches the cache.
          (br_if $interp (i32.eqz (i32.or (global.get $jit_head)
                                          (global.get $jit_all_heads))))
          (global.set $jit_head (i32.const 0))
          (local.set $slot (call $jit_lookup))
          (br_if $interp (i32.eqz (local.get $slot)))
          (global.set $jit_exit (i32.const 0))
          (global.set $jit_budget (i32.sub (local.get $budget) (local.get $n)))
          (local.set $k (call_indirect $jit (type $jitblk)
                                       (i32.sub (local.get $slot) (i32.const 1))))
          ;; Wherever the block left off is itself a place worth looking up.
          (global.set $jit_head (i32.const 1))
          ;; The block has already advanced the timestamp counter, so that the
          ;; instructions it interprets along the way see it current.
          (global.set $jit_blocks_run (i64.add (global.get $jit_blocks_run) (i64.const 1)))
          (global.set $jit_instrs_run (i64.add (global.get $jit_instrs_run)
                                               (i64.extend_i32_u (local.get $k))))
          (local.set $n (i32.add (local.get $n) (local.get $k)))
          (if (global.get $fault) (then (call $deliver_fault)))
          (if (global.get $exit_req) (then (br $stop)))
          (br $l))

        (call $step)
        (if (global.get $fault) (then (call $deliver_fault)))
        (if (global.get $exit_req) (then (br $stop)))

        (global.set $tsc_g (i64.add (global.get $tsc_g) (i64.const 1)))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (br $l)))
    (i64.store (i32.const 0xC0)
               (i64.add (i64.load (i32.const 0xC0)) (i64.extend_i32_u (local.get $n))))
    (global.get $exit_req))

  ;; =========================================================================
  ;;  exports
  ;; =========================================================================
  (func (export "init") (param $ram i64)
    (global.set $ram_size (local.get $ram))
    (call $init_tables))

  (func (export "reset")
    (local $i i32)
    (global.set $fault (i32.const 0))
    (global.set $halted (i32.const 0))
    (global.set $exit_req (i32.const 0))
    ;; zero the architectural state, leaving the opcode maps intact
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 0x600)))
      (i64.store (local.get $i) (i64.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 8)))
      (br $l)))
    (global.set $a20_mask (i64.const -1))
    (global.set $vm (i32.const 0))
    (call $tlb_flush)
    (global.set $tsc_g (i64.const 0))
    (global.set $cs_base (i64.const 0))
    (call $set_cr0 (i64.const 0x60000010))
    ;; IA32_APIC_BASE: the local APIC at its default address, globally enabled,
    ;; on the bootstrap processor
    (i64.store (i32.const 0x2D0) (i64.const 0xFEE00900))
    ;; The x87 has architectural state at reset too.  FNINIT gives the right
    ;; stack and status word; the control word after RESET is 0x0040 rather
    ;; than the 0x037F FNINIT leaves behind.
    (call $fpu_init)
    (i32.store (i32.const 0x508) (i32.const 0x0040))
    (i32.store (i32.const 0x500) (i32.const 0x1F80))       ;; MXCSR: all masked
    (call $set_flags (i64.const 2))
    (call $set_rip (i64.const 0xFFF0))
    (call $seg_store (i32.const 1) (i32.const 0xF000) (i64.const 0xFFFF0000)
          (i32.const 0xFFFF) (i32.const 0x1007))   ;; 16-bit code segment
    (call $seg_store (i32.const 2) (i32.const 0) (i64.const 0) (i32.const 0xFFFF) (i32.const 0x1003))
    (call $seg_store (i32.const 0) (i32.const 0) (i64.const 0) (i32.const 0xFFFF) (i32.const 0x1003))
    (call $seg_store (i32.const 3) (i32.const 0) (i64.const 0) (i32.const 0xFFFF) (i32.const 0x1003))
    (call $seg_store (i32.const 4) (i32.const 0) (i64.const 0) (i32.const 0xFFFF) (i32.const 0x1003))
    (call $seg_store (i32.const 5) (i32.const 0) (i64.const 0) (i32.const 0xFFFF) (i32.const 0x1003))
    (call $set_cpl (i32.const 0))
    (call $recompute_mode))

  (func (export "run") (param i32) (result i32) (call $run (local.get 0)))

  (func (export "get_reg") (param $r i32) (result i64) (call $reg64 (local.get $r)))
  (func (export "set_reg") (param $r i32) (param $v i64) (call $setreg64 (local.get $r) (local.get $v)))
  (func (export "get_rip") (result i64) (call $rip))
  (func (export "set_rip") (param $v i64) (call $set_rip (local.get $v)))
  (func (export "get_flags") (result i64) (call $flags))
  (func (export "set_flags") (param $v i64) (call $set_flags (local.get $v)))
  (func (export "get_mode") (result i32) (global.get $mode))
  (func (export "get_vm") (result i32) (global.get $vm))
  (func (export "get_cpl") (result i32) (call $cpl))
  (func (export "is_halted") (result i32) (global.get $halted))
  (func (export "get_cycles") (result i64) (i64.load (i32.const 0xC0)))
  ;; Unlike the cycle count, kept current inside a slice; device clocks use it.
  (func (export "get_tsc") (result i64) (global.get $tsc_g))

  (func (export "set_seg") (param $s i32) (param $sel i32) (param $base i64)
                           (param $limit i32) (param $attr i32)
    (call $seg_store (local.get $s) (local.get $sel) (local.get $base)
          (local.get $limit) (local.get $attr))
    (call $recompute_mode))

  (func (export "get_seg_sel") (param $s i32) (result i32) (call $seg_sel (local.get $s)))
  (func (export "get_seg_base") (param $s i32) (result i64) (call $seg_base (local.get $s)))

  (func (export "set_cr") (param $i i32) (param $v i64)
    (block $d
      (if (i32.eq (local.get $i) (i32.const 0)) (then (call $set_cr0 (local.get $v)) (br $d)))
      (if (i32.eq (local.get $i) (i32.const 2)) (then (call $set_cr2 (local.get $v)) (br $d)))
      (if (i32.eq (local.get $i) (i32.const 3)) (then (call $set_cr3 (local.get $v)) (br $d)))
      (if (i32.eq (local.get $i) (i32.const 4)) (then (call $set_cr4 (local.get $v)) (br $d))))
    (call $tlb_flush)
    (call $recompute_mode))

  (func (export "get_cr") (param $i i32) (result i64)
    (block $d (result i64)
      (if (i32.eq (local.get $i) (i32.const 0)) (then (br $d (call $cr0))))
      (if (i32.eq (local.get $i) (i32.const 2)) (then (br $d (call $cr2))))
      (if (i32.eq (local.get $i) (i32.const 3)) (then (br $d (call $cr3))))
      (if (i32.eq (local.get $i) (i32.const 4)) (then (br $d (call $cr4))))
      (call $efer)))

  (func (export "set_efer") (param $v i64) (call $set_efer (local.get $v)) (call $recompute_mode))

  (func (export "set_gdtr") (param $base i64) (param $limit i32)
    (i64.store (i32.const 0x200) (local.get $base))
    (i32.store (i32.const 0x208) (local.get $limit)))
  (func (export "set_idtr") (param $base i64) (param $limit i32)
    (i64.store (i32.const 0x210) (local.get $base))
    (i32.store (i32.const 0x218) (local.get $limit)))

  ;; the host raises and clears the interrupt line here
  (func (export "set_irq_line") (param $v i32) (i32.store (i32.const 0xD8) (local.get $v)))
  (func (export "wake") (global.set $halted (i32.const 0)) (i32.store (i32.const 0xBC) (i32.const 0)))
  (func (export "stop") (global.set $exit_req (i32.const 2)))
  (func (export "ram_base") (result i32) (call $ram_base))
  (func (export "get_ram_size") (result i64) (global.get $ram_size))
  (func (export "set_ram_size") (param $v i64) (global.set $ram_size (local.get $v)))
  (func (export "tlb_flush") (call $tlb_flush))

  ;; Route the 0xA0000 window through the host while a planar mode is active.
  ;; 0 off; 1 the 64 KiB window at 0xA0000; 2 that and the SVGA's registers
  ;; at 0xB8000 as well.
  (func (export "set_vga_mmio") (param $v i32)
    (global.set $vga_mmio (local.get $v))
    (global.set $vga_win_hi (select (i64.const 0xB8100) (i64.const 0xB0000)
                                    (i32.eq (local.get $v) (i32.const 2))))
    (call $flush_addr_caches)
    ;; translations of the window were made under the old routing
    (call $jtlb_flush_all))

  ;; Route a range of RAM to the host (see $trap_lo).  Translations of it that
  ;; were cached while it was plain memory have to go.
  (func (export "set_trap") (param $lo i64) (param $hi i64)
    (global.set $trap_lo (local.get $lo))
    (global.set $trap_hi (local.get $hi))
    (call $flush_addr_caches)
    (call $jtlb_flush_all))

  ;; The A20 gate.  Cached translations were formed under the old mask, and
  ;; compiled blocks are keyed on them, so all of it goes.
  (func (export "set_a20") (param $on i32)
    (global.set $a20_mask (select (i64.const -1) (i64.const 0xFFFFFFFFFFEFFFFF)
                                  (local.get $on)))
    (call $tlb_flush))

  (func (export "fault_trace_index") (result i32) (i32.load (i32.const 0x5900)))
  (func (export "fault_trace_rip") (param $i i32) (result i64)
    (i64.load (i32.add (i32.const 0x5910) (i32.shl (i32.and (local.get $i) (i32.const 63)) (i32.const 5)))))
  (func (export "fault_trace_vec") (param $i i32) (result i32)
    (i32.load (i32.add (i32.const 0x5918) (i32.shl (i32.and (local.get $i) (i32.const 63)) (i32.const 5)))))
  (func (export "fault_trace_err") (param $i i32) (result i64)
    (i64.load (i32.add (i32.const 0x5920) (i32.shl (i32.and (local.get $i) (i32.const 63)) (i32.const 5)))))
  (func (export "fault_trace_mode") (param $i i32) (result i32)
    (i32.load (i32.add (i32.const 0x5928) (i32.shl (i32.and (local.get $i) (i32.const 63)) (i32.const 5)))))

  (func (export "cpl_trace_index") (result i32) (i32.load (i32.const 0x5000)))
  (func (export "cpl_trace_rip") (param $i i32) (result i64)
    (i64.load (i32.add (i32.const 0x5010) (i32.shl (i32.and (local.get $i) (i32.const 127)) (i32.const 4)))))
  (func (export "cpl_trace_old") (param $i i32) (result i32)
    (i32.load (i32.add (i32.const 0x5018) (i32.shl (i32.and (local.get $i) (i32.const 127)) (i32.const 4)))))
  (func (export "cpl_trace_new") (param $i i32) (result i32)
    (i32.load (i32.add (i32.const 0x501C) (i32.shl (i32.and (local.get $i) (i32.const 127)) (i32.const 4)))))

  ;; let the host advance the timestamp counter across idle periods
  ;; ---- execution tracing -------------------------------------------------
  ;;  A ring of the addresses actually executed.  Where a fault happened is
  ;;  rarely where the mistake was made, and this is the difference between
  ;;  bisecting backwards from a bad value and guessing which instruction to
  ;;  suspect next.
  (func $trace_record
    (local $at i32)
    (local.set $at (i32.add (i32.const 0x7008)
      (i32.shl (i32.and (i32.load (i32.const 0x7000)) (i32.const 1023)) (i32.const 4))))
    (i64.store (local.get $at) (global.get $rip_g))
    ;; one register travels with the address, which is what turns "the path ran
    ;; through here" into "and the pointer was already wrong by this point"
    ;; Register number 16 means the linear address instead, for code whose
    ;; CS base varies, where RIP alone does not say where it ran.
    (i64.store (i32.add (local.get $at) (i32.const 8))
               (if (result i64) (i32.eq (global.get $trace_reg) (i32.const 16))
                 (then (i64.add (global.get $cs_base) (global.get $rip_g)))
                 (else (call $reg64 (global.get $trace_reg)))))
    (i32.store (i32.const 0x7000) (i32.add (i32.load (i32.const 0x7000)) (i32.const 1))))

  (func (export "set_trace") (param $on i32) (param $reg i32)
    (global.set $trace_on (local.get $on))
    (global.set $trace_reg (select (i32.const 16) (i32.and (local.get $reg) (i32.const 15))
                                   (i32.eq (local.get $reg) (i32.const 16))))
    (i32.store (i32.const 0x7000) (i32.const 0)))

  (func (export "trace_reg") (param $i i32) (result i64)
    (i64.load (i32.add (i32.add (i32.const 0x7008)
      (i32.shl (i32.and (local.get $i) (i32.const 1023)) (i32.const 4))) (i32.const 8))))

  ;; total instructions recorded; the ring holds the last 2048 of them
  (func (export "trace_count") (result i32) (i32.load (i32.const 0x7000)))
  (func (export "trace_rip") (param $i i32) (result i64)
    (i64.load (i32.add (i32.const 0x7008)
                       (i32.shl (i32.and (local.get $i) (i32.const 1023)) (i32.const 4)))))

  ;; ---- memory watchpoint -------------------------------------------------
  ;;  Records every write that touches a linear range, with the address of the
  ;;  instruction responsible.  This is how a structure that ends up holding
  ;;  the wrong thing gets traced back to whatever wrote it.
  (func $watch_record (param $la i64) (param $size i32) (param $v i64)
    (local $i i32) (local $at i32)
    (local.set $i (i32.and (i32.load (i32.const 0xB010)) (i32.const 63)))
    (local.set $at (i32.add (i32.const 0xB018) (i32.shl (local.get $i) (i32.const 5))))
    (i64.store (local.get $at) (global.get $rip0))
    (i64.store (i32.add (local.get $at) (i32.const 8)) (local.get $la))
    (i64.store (i32.add (local.get $at) (i32.const 16)) (local.get $v))
    (i32.store (i32.add (local.get $at) (i32.const 24)) (local.get $size))
    (i32.store (i32.const 0xB010) (i32.add (i32.load (i32.const 0xB010)) (i32.const 1))))

  (func (export "set_watch") (param $addr i64) (param $len i32)
    (global.set $watch_lo (local.get $addr))
    (global.set $watch_len (local.get $len))
    (i32.store (i32.const 0xB010) (i32.const 0)))

  (func (export "watch_count") (result i32) (i32.load (i32.const 0xB010)))
  (func (export "watch_rip") (param $i i32) (result i64)
    (i64.load (i32.add (i32.const 0xB018)
                       (i32.shl (i32.and (local.get $i) (i32.const 63)) (i32.const 5)))))
  (func (export "watch_addr") (param $i i32) (result i64)
    (i64.load (i32.add (i32.add (i32.const 0xB018)
                       (i32.shl (i32.and (local.get $i) (i32.const 63)) (i32.const 5)))
                       (i32.const 8))))
  (func (export "watch_val") (param $i i32) (result i64)
    (i64.load (i32.add (i32.add (i32.const 0xB018)
                       (i32.shl (i32.and (local.get $i) (i32.const 63)) (i32.const 5)))
                       (i32.const 16))))

  (func (export "add_tsc") (param $n i64) (call $tsc_add (local.get $n)))

  ;; translate a guest virtual address for the debugger; -1 when not mapped
  (func (export "x87_seen") (param $i i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0xF800) (i32.and (local.get $i) (i32.const 2047)))))

  ;; Resolve a linear address for the host BIOS acting on behalf of the code
  ;; that called it -- user-mode checks in virtual-8086 mode, accessed and
  ;; dirty bits set.  -1 when the access would fault; the BIOS cannot deliver
  ;; one, so CR2 is left as it was.
  (func (export "lin_translate") (param $va i64) (param $write i32) (result i64)
    (local $pa i64) (local $cr2 i64)
    (local.set $cr2 (call $cr2))
    (local.set $pa (call $translate (local.get $va) (local.get $write)))
    (if (global.get $fault)
      (then (global.set $fault (i32.const 0))
            (call $set_cr2 (local.get $cr2))
            (return (i64.const -1))))
    (local.get $pa))

  (func (export "debug_translate") (param $va i64) (result i64)
    (local $pa i64)
    (local.set $pa (call $translate (local.get $va) (i32.const 0)))
    (if (global.get $fault) (then (global.set $fault (i32.const 0)) (return (i64.const -1))))
    (local.get $pa))
