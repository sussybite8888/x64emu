  ;; =========================================================================
  ;;  Part 60: prefix decoding, dispatch tables, one-byte opcode handlers
  ;; =========================================================================

  (type $ophandler (func (param i32)))

  ;; Opcode maps live at 0x600 (one byte) and 0x700 (two byte); each entry is
  ;; the index of a handler in the function table below.
  (func $map1_set (param $op i32) (param $h i32)
    (i32.store8 (i32.add (i32.const 0x600) (local.get $op)) (local.get $h)))
  (func $map2_set (param $op i32) (param $h i32)
    (i32.store8 (i32.add (i32.const 0x700) (local.get $op)) (local.get $h)))
  (func $map1_range (param $from i32) (param $to i32) (param $h i32)
    (block $e (loop $l
      (br_if $e (i32.gt_u (local.get $from) (local.get $to)))
      (call $map1_set (local.get $from) (local.get $h))
      (local.set $from (i32.add (local.get $from) (i32.const 1)))
      (br $l))))
  (func $map2_range (param $from i32) (param $to i32) (param $h i32)
    (block $e (loop $l
      (br_if $e (i32.gt_u (local.get $from) (local.get $to)))
      (call $map2_set (local.get $from) (local.get $h))
      (local.set $from (i32.add (local.get $from) (i32.const 1)))
      (br $l))))

  ;; ---- condition code evaluation -----------------------------------------
  ;;  Dispatched through a jump table rather than a chain of comparisons: every
  ;;  Jcc, SETcc and CMOVcc goes through here.
  (func $cond (param $c i32) (result i32)
    (block $g (block $le (block $ge (block $l (block $np (block $p
    (block $ns (block $s (block $a (block $be (block $nz (block $z
    (block $nb (block $b (block $no (block $o
      (br_table $o $no $b $nb $z $nz $be $a $s $ns $p $np $l $ge $le $g
                (i32.and (local.get $c) (i32.const 15))))
      (return (call $of)))
      (return (i32.eqz (call $of))))
      (return (call $cf)))
      (return (i32.eqz (call $cf))))
      (return (call $zf)))
      (return (i32.eqz (call $zf))))
      (return (i32.or (call $cf) (call $zf))))
      (return (i32.eqz (i32.or (call $cf) (call $zf)))))
      (return (call $sf)))
      (return (i32.eqz (call $sf))))
      (return (call $pf)))
      (return (i32.eqz (call $pf))))
      (return (i32.ne (call $sf) (call $of))))
      (return (i32.eq (call $sf) (call $of))))
      (return (i32.or (call $zf) (i32.ne (call $sf) (call $of)))))
    (i32.eqz (i32.or (call $zf) (i32.ne (call $sf) (call $of)))))

  ;; operand size for instructions that default to 64-bit in long mode
  ;; (push, pop, call, jmp, ret, and the like)
  (func $opsize_d64 (result i32)
    (if (result i32) (i32.eq (global.get $mode) (i32.const 3))
      (then (if (result i32) (global.get $op66) (then (i32.const 2)) (else (i32.const 8))))
      (else (global.get $opsize))))

  ;; CLI and STI -- and in virtual-8086 mode PUSHF, POPF, INT n and IRET --
  ;; run at CPL <= IOPL and raise #GP otherwise, which is how a monitor gets
  ;; to emulate them.
  (func $iopl_ok (result i32)
    (if (i32.eqz (call $pe_on)) (then (return (i32.const 1))))
    (if (i32.le_u (call $cpl) (call $iopl)) (then (return (i32.const 1))))
    (call $raise_gp (i64.const 0))
    (i32.const 0))

  ;; Port access.  Outside virtual-8086 mode it is allowed at CPL <= IOPL.
  ;; Otherwise -- and always in virtual-8086 mode, where IOPL plays no part --
  ;; every port touched must have its bit clear in the TSS I/O permission
  ;; bitmap.  That bitmap is how Windows 95 chooses which ports of a DOS
  ;; session reach the hardware and which it emulates.
  (func $io_allowed (param $port i32) (param $size i32) (result i32)
    (local $tss i64) (local $lim i32) (local $at i32) (local $bits i32)
    (if (i32.eqz (call $pe_on)) (then (return (i32.const 1))))
    (if (i32.and (i32.eqz (global.get $vm)) (i32.le_u (call $cpl) (call $iopl)))
      (then (return (i32.const 1))))
    (block $deny
      ;; only a 32-bit TSS has a bitmap (cached attr bit 2 is type bit 3)
      (br_if $deny (i32.eqz (i32.and (i32.load (i32.const 0x254)) (i32.const 4))))
      (local.set $lim (i32.load (i32.const 0x250)))
      (br_if $deny (i32.lt_u (local.get $lim) (i32.const 0x67)))
      (local.set $tss (i64.load (i32.const 0x248)))
      (local.set $at (i32.add
        (i32.wrap_i64 (call $sys_read (i64.add (local.get $tss) (i64.const 0x66)) (i32.const 2)))
        (i32.shr_u (local.get $port) (i32.const 3))))
      ;; two bytes are always read, and both must lie inside the TSS
      (br_if $deny (i32.gt_u (i32.add (local.get $at) (i32.const 1)) (local.get $lim)))
      (local.set $bits (i32.wrap_i64 (call $sys_read
        (i64.add (local.get $tss) (i64.extend_i32_u (local.get $at))) (i32.const 2))))
      (if (global.get $fault) (then (return (i32.const 0))))
      (br_if $deny (i32.and (i32.shr_u (local.get $bits) (i32.and (local.get $port) (i32.const 7)))
                            (i32.sub (i32.shl (i32.const 1) (local.get $size)) (i32.const 1))))
      (return (i32.const 1)))
    (call $raise_gp (i64.const 0))
    (i32.const 0))

  ;; jump target truncation for the current mode
  (func $jump_to (param $t i64)
    (if (i32.eq (global.get $mode) (i32.const 3))
      (then (call $set_rip (local.get $t)))
      (else
        (if (i32.eq (global.get $opsize) (i32.const 2))
          (then (call $set_rip (i64.and (local.get $t) (i64.const 0xFFFF))))
          (else (call $set_rip (i64.and (local.get $t) (i64.const 0xFFFFFFFF))))))))

  ;; =========================================================================
  ;;  one-byte handlers
  ;; =========================================================================

  (func $h_invalid (param $op i32) (call $raise_ud))

  ;; 0x00-0x3D: the eight ALU operations in six operand forms
  (func $h_alu (param $op i32)
    (local $aluop i32) (local $form i32) (local $size i32) (local $a i64) (local $b i64) (local $r i64)
    (local.set $aluop (i32.and (i32.shr_u (local.get $op) (i32.const 3)) (i32.const 7)))
    (local.set $form (i32.and (local.get $op) (i32.const 7)))
    (local.set $size (if (result i32) (i32.and (local.get $form) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (block $d
      ;; form 0/1: r/m, reg
      (if (i32.lt_u (local.get $form) (i32.const 2))
        (then
          (call $decode_modrm)
          (local.set $a (call $rm_read (local.get $size)))
          (local.set $b (call $reg_read (local.get $size)))
          (if (global.get $fault) (then (return)))
          (local.set $r (call $alu (local.get $aluop) (local.get $a) (local.get $b) (local.get $size)))
          (if (i32.ne (local.get $aluop) (i32.const 7))
            (then (call $rm_write (local.get $size) (local.get $r))))
          (br $d)))
      ;; form 2/3: reg, r/m
      (if (i32.lt_u (local.get $form) (i32.const 4))
        (then
          (call $decode_modrm)
          (local.set $a (call $reg_read (local.get $size)))
          (local.set $b (call $rm_read (local.get $size)))
          (if (global.get $fault) (then (return)))
          (local.set $r (call $alu (local.get $aluop) (local.get $a) (local.get $b) (local.get $size)))
          (if (i32.ne (local.get $aluop) (i32.const 7))
            (then (call $reg_write (local.get $size) (local.get $r))))
          (br $d)))
      ;; form 4/5: accumulator, immediate
      (local.set $a (call $regN (i32.const 0) (local.get $size)))
      (local.set $b (call $fetch_imm
        (if (result i32) (i32.eq (local.get $size) (i32.const 1))
          (then (i32.const 1))
          (else (if (result i32) (i32.eq (local.get $size) (i32.const 2))
                  (then (i32.const 2)) (else (i32.const 4)))))))
      (if (global.get $fault) (then (return)))
      (local.set $r (call $alu (local.get $aluop) (local.get $a) (local.get $b) (local.get $size)))
      (if (i32.ne (local.get $aluop) (i32.const 7))
        (then (call $setregN (i32.const 0) (local.get $size) (local.get $r))))))

  ;; push/pop of a segment register (not encodable in 64-bit mode)
  (func $h_pushpop_seg (param $op i32)
    (local $s i32)
    (if (i32.eq (global.get $mode) (i32.const 3)) (then (call $raise_ud) (return)))
    (block $d
      (if (i32.eq (local.get $op) (i32.const 0x06)) (then (local.set $s (i32.const 0)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0x0E)) (then (local.set $s (i32.const 1)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0x16)) (then (local.set $s (i32.const 2)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0x1E)) (then (local.set $s (i32.const 3)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0x07)) (then (local.set $s (i32.const 0)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0x17)) (then (local.set $s (i32.const 2)) (br $d)))
      (local.set $s (i32.const 3)))
    (if (i32.and (local.get $op) (i32.const 1))
      (then (call $load_seg (local.get $s) (i32.wrap_i64 (call $pop (call $opsize_d64)))))
      (else (call $push (i64.extend_i32_u (call $seg_sel (local.get $s))) (call $opsize_d64)))))

  ;; DAA / DAS / AAA / AAS
  (func $h_bcd (param $op i32)
    (local $al i32) (local $old_al i32) (local $old_cf i32)
    (if (i32.eq (global.get $mode) (i32.const 3)) (then (call $raise_ud) (return)))
    (local.set $al (call $reg8 (i32.const 0)))
    (local.set $old_al (local.get $al))
    (local.set $old_cf (call $cf))
    (block $d
      (if (i32.eq (local.get $op) (i32.const 0x27))    ;; DAA
        (then
          (call $set_flag (i32.const 0) (i32.const 0))
          (if (i32.or (i32.gt_u (i32.and (local.get $al) (i32.const 15)) (i32.const 9)) (call $af))
            (then (local.set $al (i32.add (local.get $al) (i32.const 6)))
                  (call $set_flag (i32.const 0) (i32.or (local.get $old_cf)
                    (i32.gt_u (local.get $al) (i32.const 255))))
                  (call $set_flag (i32.const 4) (i32.const 1)))
            (else (call $set_flag (i32.const 4) (i32.const 0))))
          (if (i32.or (i32.gt_u (local.get $old_al) (i32.const 0x99)) (local.get $old_cf))
            (then (local.set $al (i32.add (local.get $al) (i32.const 0x60)))
                  (call $set_flag (i32.const 0) (i32.const 1))))
          (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0x2F))    ;; DAS
        (then
          (call $set_flag (i32.const 0) (i32.const 0))
          (if (i32.or (i32.gt_u (i32.and (local.get $al) (i32.const 15)) (i32.const 9)) (call $af))
            (then (local.set $al (i32.sub (local.get $al) (i32.const 6)))
                  (call $set_flag (i32.const 0) (i32.or (local.get $old_cf)
                    (i32.lt_s (local.get $al) (i32.const 0))))
                  (call $set_flag (i32.const 4) (i32.const 1)))
            (else (call $set_flag (i32.const 4) (i32.const 0))))
          (if (i32.or (i32.gt_u (local.get $old_al) (i32.const 0x99)) (local.get $old_cf))
            (then (local.set $al (i32.sub (local.get $al) (i32.const 0x60)))
                  (call $set_flag (i32.const 0) (i32.const 1))))
          (br $d)))
      ;; AAA / AAS
      (if (i32.or (i32.gt_u (i32.and (local.get $al) (i32.const 15)) (i32.const 9)) (call $af))
        (then
          (if (i32.eq (local.get $op) (i32.const 0x37))
            (then (local.set $al (i32.add (local.get $al) (i32.const 6)))
                  (call $setreg8 (i32.const 4) (i32.add (call $reg8 (i32.const 4)) (i32.const 1))))
            (else (local.set $al (i32.sub (local.get $al) (i32.const 6)))
                  (call $setreg8 (i32.const 4) (i32.sub (call $reg8 (i32.const 4)) (i32.const 1)))))
          (call $set_flag (i32.const 4) (i32.const 1))
          (call $set_flag (i32.const 0) (i32.const 1)))
        (else
          (call $set_flag (i32.const 4) (i32.const 0))
          (call $set_flag (i32.const 0) (i32.const 0))))
      (local.set $al (i32.and (local.get $al) (i32.const 15))))
    (call $setreg8 (i32.const 0) (i32.and (local.get $al) (i32.const 255)))
    (call $set_szp (i64.extend_i32_u (i32.and (local.get $al) (i32.const 255))) (i32.const 1)))

  ;; 0x40-0x4F INC/DEC r16/32 (legacy modes only)
  (func $h_incdec_r (param $op i32)
    (local $r i32) (local $size i32)
    (local.set $r (i32.and (local.get $op) (i32.const 7)))
    (local.set $size (global.get $opsize))
    (if (i32.and (local.get $op) (i32.const 8))
      (then (call $setregN (local.get $r) (local.get $size)
              (call $do_dec (call $regN (local.get $r) (local.get $size)) (local.get $size))))
      (else (call $setregN (local.get $r) (local.get $size)
              (call $do_inc (call $regN (local.get $r) (local.get $size)) (local.get $size))))))

  (func $h_push_r (param $op i32)
    (call $push (call $regN
                  (i32.or (i32.and (local.get $op) (i32.const 7))
                          (i32.shl (i32.and (global.get $rex) (i32.const 1)) (i32.const 3)))
                  (call $opsize_d64))
                (call $opsize_d64)))

  (func $h_pop_r (param $op i32)
    (local $v i64)
    (local.set $v (call $pop (call $opsize_d64)))
    (if (global.get $fault) (then (return)))
    (call $setregN (i32.or (i32.and (local.get $op) (i32.const 7))
                           (i32.shl (i32.and (global.get $rex) (i32.const 1)) (i32.const 3)))
                   (call $opsize_d64) (local.get $v)))

  (func $h_pusha (param $op i32)
    (local $sp i64) (local $i i32)
    (if (i32.eq (global.get $mode) (i32.const 3)) (then (call $raise_ud) (return)))
    (local.set $sp (call $reg64 (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 8)))
      (if (i32.eq (local.get $i) (i32.const 4))
        (then (call $push (local.get $sp) (global.get $opsize)))
        (else (call $push (call $regN (local.get $i) (global.get $opsize)) (global.get $opsize))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))

  (func $h_popa (param $op i32)
    (local $i i32) (local $v i64)
    (if (i32.eq (global.get $mode) (i32.const 3)) (then (call $raise_ud) (return)))
    (local.set $i (i32.const 7))
    (block $e (loop $l
      (local.set $v (call $pop (global.get $opsize)))
      (if (global.get $fault) (then (return)))
      (if (i32.ne (local.get $i) (i32.const 4))
        (then (call $setregN (local.get $i) (global.get $opsize) (local.get $v))))
      (br_if $e (i32.eqz (local.get $i)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $l))))

  ;; 0x63: MOVSXD in long mode, ARPL otherwise
  (func $h_movsxd (param $op i32)
    (local $v i64)
    (if (i32.ne (global.get $mode) (i32.const 3)) (then (call $arpl) (return)))
    (call $decode_modrm)
    (local.set $v (call $rm_read (i32.const 4)))
    (if (global.get $fault) (then (return)))
    (call $reg_write (global.get $opsize)
          (if (result i64) (i32.eq (global.get $opsize) (i32.const 8))
            (then (i64.extend_i32_s (i32.wrap_i64 (local.get $v))))
            (else (local.get $v)))))

  ;; ARPL raises a selector's RPL to at least another's.  Outside protected
  ;; mode it is invalid, and that is its main use there: Windows 95 plants it
  ;; as the breakpoint by which DOS code in virtual-8086 mode calls back into
  ;; the 32-bit system.
  (func $arpl
    (local $dst i32) (local $src i32)
    (call $decode_modrm)
    (if (i32.or (i32.eqz (call $pe_on)) (global.get $vm)) (then (call $raise_ud) (return)))
    (local.set $dst (i32.wrap_i64 (call $rm_read (i32.const 2))))
    (if (global.get $fault) (then (return)))
    (local.set $src (call $reg16 (global.get $mrm_reg)))
    (if (i32.lt_u (i32.and (local.get $dst) (i32.const 3)) (i32.and (local.get $src) (i32.const 3)))
      (then
        (call $rm_write (i32.const 2) (i64.extend_i32_u
          (i32.or (i32.and (local.get $dst) (i32.const 0xFFFC)) (i32.and (local.get $src) (i32.const 3)))))
        (if (global.get $fault) (then (return)))
        (call $set_flag (i32.const 6) (i32.const 1)))
      (else (call $set_flag (i32.const 6) (i32.const 0)))))

  (func $h_push_imm (param $op i32)
    (local $v i64)
    (if (i32.eq (local.get $op) (i32.const 0x6A))
      (then (local.set $v (call $fetch_imm (i32.const 1))))
      (else (local.set $v (call $fetch_imm
              (if (result i32) (i32.eq (global.get $opsize) (i32.const 2))
                (then (i32.const 2)) (else (i32.const 4)))))))
    (if (global.get $fault) (then (return)))
    (call $push (local.get $v) (call $opsize_d64)))

  ;; IMUL r, r/m, imm
  (func $h_imul3 (param $op i32)
    (local $a i64) (local $b i64) (local $r i64) (local $hi i64) (local $size i32)
    (local $ovf i32)
    (local.set $size (global.get $opsize))
    (call $decode_modrm)
    (if (i32.eq (local.get $op) (i32.const 0x6B))
      (then (local.set $b (call $fetch_imm (i32.const 1))))
      (else (local.set $b (call $fetch_imm
              (if (result i32) (i32.eq (local.get $size) (i32.const 2))
                (then (i32.const 2)) (else (i32.const 4)))))))
    (local.set $a (call $sext (call $rm_read (local.get $size)) (local.get $size)))
    (if (global.get $fault) (then (return)))
    (local.set $r (i64.mul (local.get $a) (local.get $b)))
    (call $reg_write (local.get $size) (local.get $r))
    ;; CF/OF say the full product did not fit the destination.  At eight bytes
    ;; the product is wider than the register holding it, so the test has to be
    ;; against the real high half: comparing sext(r) with r asks whether r
    ;; equals itself, which is never true and left the flags permanently clear.
    (if (i32.eq (local.get $size) (i32.const 8))
      (then (local.set $ovf (i64.ne (call $muls_hi (local.get $a) (local.get $b))
                                    (i64.shr_s (local.get $r) (i64.const 63)))))
      (else (local.set $ovf (i64.ne (call $sext (local.get $r) (local.get $size))
                                    (local.get $r)))))
    (call $set_flag (i32.const 0) (local.get $ovf))
    (call $set_flag (i32.const 11) (local.get $ovf))
    (call $set_szp (call $trunc (local.get $r) (local.get $size)) (local.get $size)))

  (func $h_jcc8 (param $op i32)
    (local $d i64)
    (local.set $d (call $fetch_imm (i32.const 1)))
    (if (global.get $fault) (then (return)))
    (if (call $cond (i32.and (local.get $op) (i32.const 15)))
      (then (call $jump_to (i64.add (call $rip) (local.get $d))))))

  (func $h_test (param $op i32)
    (local $size i32) (local $a i64) (local $b i64)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $a (call $rm_read (local.get $size)))
    (local.set $b (call $reg_read (local.get $size)))
    (if (global.get $fault) (then (return)))
    (drop (call $do_logic (i64.and (local.get $a) (local.get $b)) (local.get $size))))

  (func $h_xchg (param $op i32)
    (local $size i32) (local $a i64) (local $b i64)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $a (call $rm_read (local.get $size)))
    (local.set $b (call $reg_read (local.get $size)))
    (if (global.get $fault) (then (return)))
    (call $rm_write (local.get $size) (local.get $b))
    (if (global.get $fault) (then (return)))
    (call $reg_write (local.get $size) (local.get $a)))

  ;; 0x88-0x8B MOV
  (func $h_mov_rm_r (param $op i32)
    (local $size i32) (local $v i64)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (if (i32.and (local.get $op) (i32.const 2))
      (then
        (local.set $v (call $rm_read (local.get $size)))
        (if (global.get $fault) (then (return)))
        (call $reg_write (local.get $size) (local.get $v)))
      (else
        (local.set $v (call $reg_read (local.get $size)))
        (call $rm_write (local.get $size) (local.get $v)))))

  ;; 0x8C / 0x8E MOV to/from a segment register
  (func $h_mov_seg (param $op i32)
    (local $s i32) (local $v i64)
    (call $decode_modrm)
    (local.set $s (global.get $mrm_ext))
    (if (i32.gt_u (local.get $s) (i32.const 5)) (then (call $raise_ud) (return)))
    (if (i32.eq (local.get $op) (i32.const 0x8C))
      (then
        (if (global.get $mrm_mem)
          (then (call $rm_write (i32.const 2) (i64.extend_i32_u (call $seg_sel (local.get $s)))))
          (else (call $setregN (global.get $mrm_rm) (global.get $opsize)
                  (i64.extend_i32_u (call $seg_sel (local.get $s)))))))
      (else
        (if (i32.eq (local.get $s) (i32.const 1)) (then (call $raise_ud) (return)))
        (local.set $v (call $rm_read (i32.const 2)))
        (if (global.get $fault) (then (return)))
        (call $load_seg (local.get $s) (i32.wrap_i64 (local.get $v))))))

  (func $h_lea (param $op i32)
    (call $decode_modrm)
    (if (i32.eqz (global.get $mrm_mem)) (then (call $raise_ud) (return)))
    (call $reg_write (global.get $opsize)
          (call $trunc (call $mrm_off) (global.get $opsize))))

  (func $h_pop_rm (param $op i32)
    (local $v i64)
    (local.set $v (call $pop (call $opsize_d64)))
    (if (global.get $fault) (then (return)))
    (call $decode_modrm)
    (call $rm_write (call $opsize_d64) (local.get $v)))

  ;; 0x90-0x97 XCHG rAX, r  (0x90 alone is NOP / PAUSE)
  (func $h_xchg_ax (param $op i32)
    (local $r i32) (local $t i64) (local $size i32)
    (local.set $r (i32.or (i32.and (local.get $op) (i32.const 7))
                          (i32.shl (i32.and (global.get $rex) (i32.const 1)) (i32.const 3))))
    (if (i32.eqz (local.get $r)) (then (return)))          ;; NOP
    (local.set $size (global.get $opsize))
    (local.set $t (call $regN (i32.const 0) (local.get $size)))
    (call $setregN (i32.const 0) (local.get $size) (call $regN (local.get $r) (local.get $size)))
    (call $setregN (local.get $r) (local.get $size) (local.get $t)))

  (func $h_cbw (param $op i32)
    (block $d
      (if (i32.eq (global.get $opsize) (i32.const 8))
        (then (call $setreg64 (i32.const 0) (i64.extend_i32_s (call $reg32 (i32.const 0)))) (br $d)))
      (if (i32.eq (global.get $opsize) (i32.const 4))
        (then (call $setreg32 (i32.const 0) (i32.extend16_s (call $reg16 (i32.const 0)))) (br $d)))
      (call $setreg16 (i32.const 0) (i32.extend8_s (call $reg8 (i32.const 0))))))

  (func $h_cwd (param $op i32)
    (block $d
      (if (i32.eq (global.get $opsize) (i32.const 8))
        (then (call $setreg64 (i32.const 2) (i64.shr_s (call $reg64 (i32.const 0)) (i64.const 63))) (br $d)))
      (if (i32.eq (global.get $opsize) (i32.const 4))
        (then (call $setreg32 (i32.const 2) (i32.shr_s (call $reg32 (i32.const 0)) (i32.const 31))) (br $d)))
      (call $setreg16 (i32.const 2)
            (i32.shr_s (i32.extend16_s (call $reg16 (i32.const 0))) (i32.const 31)))))

  (func $h_callf (param $op i32)
    (local $off i64) (local $sel i32)
    (if (i32.eq (global.get $mode) (i32.const 3)) (then (call $raise_ud) (return)))
    (local.set $off (i64.extend_i32_u (if (result i32) (i32.eq (global.get $opsize) (i32.const 2))
                      (then (call $fetch16)) (else (call $fetch32)))))
    (local.set $sel (call $fetch16))
    (if (global.get $fault) (then (return)))
    (call $push (i64.extend_i32_u (call $seg_sel (i32.const 1))) (global.get $opsize))
    (call $push (call $rip) (global.get $opsize))
    (if (global.get $fault) (then (return)))
    (call $far_jump (local.get $sel) (local.get $off)))

  (func $h_nop (param $op i32))

  ;; In virtual-8086 mode PUSHF and POPF are IOPL-sensitive, so that a monitor
  ;; can keep a virtual interrupt flag for the DOS session.
  (func $h_pushf (param $op i32)
    (if (global.get $vm) (then (if (i32.eqz (call $iopl_ok)) (then (return)))))
    (call $push (i64.and (call $flags) (i64.const 0x00FCFFFF)) (call $opsize_d64)))

  (func $h_popf (param $op i32)
    (local $v i64) (local $size i32) (local $old i64) (local $mask i64)
    (if (global.get $vm) (then (if (i32.eqz (call $iopl_ok)) (then (return)))))
    (local.set $size (call $opsize_d64))
    (local.set $v (call $pop (local.get $size)))
    (if (global.get $fault) (then (return)))
    (local.set $old (call $flags))
    ;; IOPL and IF are only writable at sufficient privilege
    (local.set $mask (i64.const 0x257FD5))
    (if (i32.ne (call $cpl) (i32.const 0))
      (then (local.set $mask (i64.and (local.get $mask) (i64.const 0xFFFFFFFFFFFFCFFF)))))
    (if (i32.gt_u (call $cpl)
                  (i32.wrap_i64 (i64.and (i64.shr_u (local.get $old) (i64.const 12)) (i64.const 3))))
      (then (local.set $mask (i64.and (local.get $mask) (i64.const 0xFFFFFFFFFFFFFDFF)))))
    (if (i32.eq (local.get $size) (i32.const 2))
      (then (local.set $mask (i64.and (local.get $mask) (i64.const 0xFFFF)))))
    (call $set_flags (i64.or (i64.and (local.get $old)
                                      (i64.xor (local.get $mask) (i64.const -1)))
                             (i64.and (local.get $v) (local.get $mask)))))

  (func $h_sahf_lahf (param $op i32)
    (if (i32.eq (local.get $op) (i32.const 0x9E))
      (then (call $flags_merge (i64.const 0xD5)
                               (i64.extend_i32_u (call $reg8 (i32.const 4)))))
      (else (call $setreg8 (i32.const 4)
              (i32.or (i32.wrap_i64 (i64.and (call $flags) (i64.const 0xD5))) (i32.const 2))))))

  ;; 0xA0-0xA3 MOV accumulator <-> absolute address
  (func $h_mov_moffs (param $op i32)
    (local $addr i64) (local $size i32) (local $seg i32)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (block $d
      (if (i32.eq (global.get $addrsize) (i32.const 8))
        (then (local.set $addr (call $fetch64)) (br $d)))
      (if (i32.eq (global.get $addrsize) (i32.const 4))
        (then (local.set $addr (i64.extend_i32_u (call $fetch32))) (br $d)))
      (local.set $addr (i64.extend_i32_u (call $fetch16))))
    (if (global.get $fault) (then (return)))
    (local.set $seg (if (result i32) (i32.eq (global.get $segovr) (i32.const -1))
                      (then (i32.const 3)) (else (global.get $segovr))))
    (if (i32.and (local.get $op) (i32.const 2))
      (then (call $seg_write (local.get $seg) (local.get $addr) (local.get $size)
                             (call $regN (i32.const 0) (local.get $size))))
      (else
        (call $setregN (i32.const 0) (local.get $size)
              (call $seg_read (local.get $seg) (local.get $addr) (local.get $size))))))

  (func $h_test_a_imm (param $op i32)
    (local $size i32) (local $b i64)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (local.set $b (call $fetch_imm
      (if (result i32) (i32.eq (local.get $size) (i32.const 1)) (then (i32.const 1))
        (else (if (result i32) (i32.eq (local.get $size) (i32.const 2))
                (then (i32.const 2)) (else (i32.const 4)))))))
    (if (global.get $fault) (then (return)))
    (drop (call $do_logic (i64.and (call $regN (i32.const 0) (local.get $size)) (local.get $b))
                          (local.get $size))))

  ;; 0xB0-0xBF MOV reg, imm
  (func $h_mov_r_imm (param $op i32)
    (local $r i32) (local $size i32) (local $v i64)
    (local.set $r (i32.or (i32.and (local.get $op) (i32.const 7))
                          (i32.shl (i32.and (global.get $rex) (i32.const 1)) (i32.const 3))))
    (if (i32.and (local.get $op) (i32.const 8))
      (then
        (local.set $size (global.get $opsize))
        ;; the 64-bit form takes a full 64-bit immediate
        (block $d
          (if (i32.eq (local.get $size) (i32.const 8))
            (then (local.set $v (call $fetch64)) (br $d)))
          (if (i32.eq (local.get $size) (i32.const 4))
            (then (local.set $v (i64.extend_i32_u (call $fetch32))) (br $d)))
          (local.set $v (i64.extend_i32_u (call $fetch16)))))
      (else
        (local.set $size (i32.const 1))
        (local.set $v (i64.extend_i32_u (call $fetch8)))))
    (if (global.get $fault) (then (return)))
    (call $setregN (local.get $r) (local.get $size) (local.get $v)))

  (func $h_ret (param $op i32)
    (local $t i64) (local $imm i32) (local $size i32)
    (local.set $size (call $opsize_d64))
    (if (i32.eq (local.get $op) (i32.const 0xC2))
      (then (local.set $imm (call $fetch16))))
    (local.set $t (call $pop (local.get $size)))
    (if (global.get $fault) (then (return)))
    (if (local.get $imm)
      (then (call $setreg64 (i32.const 4)
              (i64.add (call $reg64 (i32.const 4)) (i64.extend_i32_u (local.get $imm))))))
    (call $set_rip (local.get $t)))

  (func $h_retf (param $op i32)
    (local $t i64) (local $sel i32) (local $imm i32) (local $size i32)
    (local.set $size (global.get $opsize))
    (if (i32.eq (local.get $op) (i32.const 0xCA))
      (then (local.set $imm (call $fetch16))))
    (local.set $t (call $pop (local.get $size)))
    (local.set $sel (i32.wrap_i64 (call $pop (local.get $size))))
    (if (global.get $fault) (then (return)))
    (if (local.get $imm)
      (then (call $setreg64 (i32.const 4)
              (i64.add (call $reg64 (i32.const 4)) (i64.extend_i32_u (local.get $imm))))))
    ;; The low two bits of a selector are a requested privilege level only in
    ;; protected mode.  In real mode they are just part of the segment value,
    ;; and treating them as an RPL leaves the CPU at a bogus privilege level.
    (if (i32.and (call $pe_on) (i32.eqz (global.get $vm)))
      (then
        (if (i32.gt_u (i32.and (local.get $sel) (i32.const 3)) (call $cpl))
          (then (call $set_cpl (i32.and (local.get $sel) (i32.const 3)))))))
    (call $far_jump (local.get $sel) (local.get $t)))

  (func $h_mov_rm_imm (param $op i32)
    (local $size i32) (local $v i64)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $v (call $fetch_imm
      (if (result i32) (i32.eq (local.get $size) (i32.const 1)) (then (i32.const 1))
        (else (if (result i32) (i32.eq (local.get $size) (i32.const 2))
                (then (i32.const 2)) (else (i32.const 4)))))))
    (if (global.get $fault) (then (return)))
    (call $rm_write (local.get $size) (local.get $v)))

  (func $h_enter (param $op i32)
    (local $alloc i32) (local $level i32) (local $fp i64) (local $size i32) (local $i i32)
    (local.set $alloc (call $fetch16))
    (local.set $level (i32.and (call $fetch8) (i32.const 31)))
    (if (global.get $fault) (then (return)))
    (local.set $size (call $opsize_d64))
    (call $push (call $regN (i32.const 5) (local.get $size)) (local.get $size))
    (if (global.get $fault) (then (return)))
    (local.set $fp (call $reg64 (i32.const 4)))
    (local.set $i (i32.const 1))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (local.get $level)))
      (call $setreg64 (i32.const 5)
            (i64.sub (call $reg64 (i32.const 5)) (i64.extend_i32_u (local.get $size))))
      (call $push (call $lin_read (call $reg64 (i32.const 5)) (local.get $size)) (local.get $size))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (if (local.get $level) (then (call $push (local.get $fp) (local.get $size))))
    (call $setregN (i32.const 5) (local.get $size) (local.get $fp))
    (call $setreg64 (i32.const 4)
          (i64.sub (call $reg64 (i32.const 4)) (i64.extend_i32_u (local.get $alloc)))))

  (func $h_leave (param $op i32)
    (local $v i64) (local $size i32)
    (local.set $size (call $opsize_d64))
    (call $setreg64 (i32.const 4) (call $reg64 (i32.const 5)))
    (local.set $v (call $pop (local.get $size)))
    (if (global.get $fault) (then (return)))
    (call $setregN (i32.const 5) (local.get $size) (local.get $v)))

  (func $h_int (param $op i32)
    (local $v i32)
    (block $d
      (if (i32.eq (local.get $op) (i32.const 0xCC)) (then (local.set $v (i32.const 3)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xCE))
        (then (if (i32.eqz (call $of)) (then (return))) (local.set $v (i32.const 4)) (br $d)))
      (local.set $v (call $fetch8)))
    (if (global.get $fault) (then (return)))
    ;; INT n -- not INT3 or INTO -- is IOPL-sensitive in virtual-8086 mode
    (if (i32.and (global.get $vm) (i32.eq (local.get $op) (i32.const 0xCD)))
      (then (if (i32.eqz (call $iopl_ok)) (then (return)))))
    (call $do_interrupt (local.get $v) (i64.const 0) (i32.const 0) (i32.const 1) (call $rip)))

  (func $h_iret (param $op i32) (call $do_iret (call $opsize_d64)))

  (func $h_aam (param $op i32)
    (local $b i32) (local $al i32)
    (if (i32.eq (global.get $mode) (i32.const 3)) (then (call $raise_ud) (return)))
    (local.set $b (call $fetch8))
    (if (global.get $fault) (then (return)))
    (local.set $al (call $reg8 (i32.const 0)))
    (if (i32.eq (local.get $op) (i32.const 0xD4))
      (then
        (if (i32.eqz (local.get $b)) (then (call $raise_de) (return)))
        (call $setreg8 (i32.const 4) (i32.div_u (local.get $al) (local.get $b)))
        (call $setreg8 (i32.const 0) (i32.rem_u (local.get $al) (local.get $b))))
      (else
        (call $setreg8 (i32.const 0)
          (i32.and (i32.add (local.get $al)
                            (i32.mul (call $reg8 (i32.const 4)) (local.get $b)))
                   (i32.const 255)))
        (call $setreg8 (i32.const 4) (i32.const 0))))
    (call $set_szp (i64.extend_i32_u (call $reg8 (i32.const 0))) (i32.const 1)))

  (func $h_xlat (param $op i32)
    (local $a i64)
    (local.set $a (i64.add (call $regN (i32.const 3) (global.get $addrsize))
                           (i64.extend_i32_u (call $reg8 (i32.const 0)))))
    (call $setreg8 (i32.const 0) (i32.wrap_i64 (call $seg_read
      (if (result i32) (i32.eq (global.get $segovr) (i32.const -1))
        (then (i32.const 3)) (else (global.get $segovr)))
      (local.get $a) (i32.const 1)))))

  (func $h_loop (param $op i32)
    (local $d i64) (local $c i64) (local $take i32)
    (local.set $d (call $fetch_imm (i32.const 1)))
    (if (global.get $fault) (then (return)))
    (if (i32.eq (local.get $op) (i32.const 0xE3))
      (then
        ;; JRCXZ / JECXZ
        (local.set $take (i64.eqz (call $regN (i32.const 1) (global.get $addrsize)))))
      (else
        (local.set $c (i64.sub (call $regN (i32.const 1) (global.get $addrsize)) (i64.const 1)))
        (call $setregN (i32.const 1) (global.get $addrsize) (local.get $c))
        (local.set $c (call $trunc (local.get $c) (global.get $addrsize)))
        (local.set $take (i64.ne (local.get $c) (i64.const 0)))
        (if (i32.eq (local.get $op) (i32.const 0xE0))       ;; LOOPNE
          (then (local.set $take (i32.and (local.get $take) (i32.eqz (call $zf))))))
        (if (i32.eq (local.get $op) (i32.const 0xE1))       ;; LOOPE
          (then (local.set $take (i32.and (local.get $take) (call $zf)))))))
    (if (local.get $take)
      (then (call $jump_to (i64.add (call $rip) (local.get $d))))))

  (func $h_inout_imm (param $op i32)
    (local $port i32) (local $size i32)
    (local.set $port (call $fetch8))
    (if (global.get $fault) (then (return)))
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (if (result i32) (i32.eq (global.get $opsize) (i32.const 2))
                               (then (i32.const 2)) (else (i32.const 4))))
                       (else (i32.const 1))))
    (if (i32.eqz (call $io_allowed (local.get $port) (local.get $size))) (then (return)))
    (if (i32.and (local.get $op) (i32.const 2))
      (then (call $io_write (local.get $port) (local.get $size)
                            (i32.wrap_i64 (call $regN (i32.const 0) (local.get $size)))))
      (else (call $setregN (i32.const 0) (local.get $size)
              (i64.extend_i32_u (call $io_read (local.get $port) (local.get $size)))))))

  (func $h_inout_dx (param $op i32)
    (local $port i32) (local $size i32)
    (local.set $port (call $reg16 (i32.const 2)))
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (if (result i32) (i32.eq (global.get $opsize) (i32.const 2))
                               (then (i32.const 2)) (else (i32.const 4))))
                       (else (i32.const 1))))
    (if (i32.eqz (call $io_allowed (local.get $port) (local.get $size))) (then (return)))
    (if (i32.and (local.get $op) (i32.const 2))
      (then (call $io_write (local.get $port) (local.get $size)
                            (i32.wrap_i64 (call $regN (i32.const 0) (local.get $size)))))
      (else (call $setregN (i32.const 0) (local.get $size)
              (i64.extend_i32_u (call $io_read (local.get $port) (local.get $size)))))))

  (func $h_call_jmp (param $op i32)
    (local $d i64)
    (if (i32.eq (local.get $op) (i32.const 0xEB))
      (then (local.set $d (call $fetch_imm (i32.const 1))))
      (else (local.set $d (call $fetch_imm
              (if (result i32) (i32.eq (global.get $opsize) (i32.const 2))
                (then (i32.const 2)) (else (i32.const 4)))))))
    (if (global.get $fault) (then (return)))
    (if (i32.eq (local.get $op) (i32.const 0xE8))
      (then
        (call $push (call $rip) (call $opsize_d64))
        (if (global.get $fault) (then (return)))))
    (call $jump_to (i64.add (call $rip) (local.get $d))))

  (func $h_jmpf (param $op i32)
    (local $off i64) (local $sel i32)
    (if (i32.eq (global.get $mode) (i32.const 3)) (then (call $raise_ud) (return)))
    (local.set $off (i64.extend_i32_u (if (result i32) (i32.eq (global.get $opsize) (i32.const 2))
                      (then (call $fetch16)) (else (call $fetch32)))))
    (local.set $sel (call $fetch16))
    (if (global.get $fault) (then (return)))
    (call $far_jump (local.get $sel) (local.get $off)))

  (func $h_hlt (param $op i32)
    (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
    (global.set $halted (i32.const 1))
    (i32.store (i32.const 0xBC) (i32.const 1)))

  (func $h_flagops (param $op i32)
    (block $d
      (if (i32.eq (local.get $op) (i32.const 0xF5))
        (then (call $set_flag (i32.const 0) (i32.eqz (call $cf))) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xF8))
        (then (call $set_flag (i32.const 0) (i32.const 0)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xF9))
        (then (call $set_flag (i32.const 0) (i32.const 1)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xFA))
        (then (if (i32.eqz (call $iopl_ok)) (then (return)))
              (call $set_flag (i32.const 9) (i32.const 0)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xFB))
        (then (if (i32.eqz (call $iopl_ok)) (then (return)))
              (call $set_flag (i32.const 9) (i32.const 1))
              ;; interrupts stay blocked for one instruction after STI
              (i32.store (i32.const 0xDC) (i32.const 1))
              (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xFC))
        (then (call $set_flag (i32.const 10) (i32.const 0)) (br $d)))
      (call $set_flag (i32.const 10) (i32.const 1))))

  ;; LES/LDS/LSS/LFS/LGS
  (func $h_lsf (param $op i32)
    (local $s i32) (local $off i64) (local $sel i32) (local $size i32)
    ;; 0xC4/0xC5 are VEX prefixes in long mode, not LES/LDS
    (if (i32.and (i32.eq (global.get $mode) (i32.const 3))
                 (i32.lt_u (local.get $op) (i32.const 0xC6)))
      (then (call $raise_ud) (return)))
    (block $d
      (if (i32.eq (local.get $op) (i32.const 0xC4)) (then (local.set $s (i32.const 0)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xC5)) (then (local.set $s (i32.const 3)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xB2)) (then (local.set $s (i32.const 2)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xB4)) (then (local.set $s (i32.const 4)) (br $d)))
      (local.set $s (i32.const 5)))
    (local.set $size (global.get $opsize))
    (call $decode_modrm)
    (if (i32.eqz (global.get $mrm_mem)) (then (call $raise_ud) (return)))
    (local.set $off (call $rm_read (local.get $size)))
    (local.set $sel (i32.wrap_i64 (call $seg_read (global.get $mrm_seg)
      (i64.add (call $mrm_off) (i64.extend_i32_u (local.get $size))) (i32.const 2))))
    (if (global.get $fault) (then (return)))
    (call $load_seg (local.get $s) (local.get $sel))
    (if (global.get $fault) (then (return)))
    (call $reg_write (local.get $size) (local.get $off)))
