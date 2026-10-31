  ;; =========================================================================
  ;;  Part 80: two-byte (0F) opcode handlers
  ;; =========================================================================

  ;; ---- 0F 00: SLDT / STR / LLDT / LTR / VERR / VERW ----------------------
  (func $h0f_grp6 (param $op i32)
    (local $sub i32) (local $sel i32) (local $d i64) (local $base i64) (local $off i32)
    (local $type i32)
    (call $decode_modrm)
    (local.set $sub (global.get $mrm_ext))
    (block $d
      (if (i32.eq (local.get $sub) (i32.const 0))
        (then (call $rm_write (i32.const 2) (i64.load (i32.const 0x220))) (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 1))
        (then (call $rm_write (i32.const 2) (i64.load (i32.const 0x240))) (br $d)))
      (if (i32.gt_u (local.get $sub) (i32.const 5)) (then (br $d)))
      (if (i32.gt_u (local.get $sub) (i32.const 3))                   ;; VERR / VERW
        (then
          (if (i32.or (i32.eqz (call $pe_on)) (global.get $vm)) (then (call $raise_ud) (return)))
          (local.set $sel (i32.wrap_i64 (call $rm_read (i32.const 2))))
          (if (global.get $fault) (then (return)))
          (local.set $d (call $sel_visible (local.get $sel)))
          (if (global.get $fault) (then (return)))
          (local.set $type (call $desc_type (local.get $d)))
          ;; VERR: data, or readable code.  VERW: writable data.
          (call $set_flag (i32.const 6)
            (if (result i32) (i32.eq (local.get $sub) (i32.const 4))
              (then (i32.or
                      (i32.eq (i32.and (local.get $type) (i32.const 0x18)) (i32.const 0x10))
                      (i32.eq (i32.and (local.get $type) (i32.const 0x1A)) (i32.const 0x1A))))
              (else (i32.eq (i32.and (local.get $type) (i32.const 0x1A)) (i32.const 0x12)))))
          (br $d)))
      (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
      (local.set $sel (i32.wrap_i64 (call $rm_read (i32.const 2))))
      (if (global.get $fault) (then (return)))
      (local.set $off (if (result i32) (i32.eq (local.get $sub) (i32.const 2))
                        (then (i32.const 0x220)) (else (i32.const 0x240))))
      (if (i32.eqz (i32.and (local.get $sel) (i32.const 0xFFFC)))
        (then (i32.store (local.get $off) (i32.const 0))
              (i64.store (i32.add (local.get $off) (i32.const 8)) (i64.const 0))
              (br $d)))
      (local.set $d (call $read_desc (local.get $sel)))
      (if (global.get $fault) (then (return)))
      (local.set $base (call $desc_base (local.get $d)))
      ;; a system descriptor in long mode carries 32 more base bits
      (if (i32.eq (global.get $mode) (i32.const 3))
        (then (local.set $base (i64.or (local.get $base)
                (i64.shl (i64.and (call $read_desc_hi (local.get $sel)) (i64.const 0xFFFFFFFF))
                         (i64.const 32))))))
      (i32.store (local.get $off) (local.get $sel))
      (i64.store (i32.add (local.get $off) (i32.const 8)) (local.get $base))
      (i32.store (i32.add (local.get $off) (i32.const 16)) (call $desc_limit (local.get $d)))
      (i32.store (i32.add (local.get $off) (i32.const 20)) (call $desc_attr (local.get $d)))))

  ;; ---- selector probes: LAR / LSL / VERR / VERW ----------------------------
  ;;  The descriptor a selector names, when it lies inside its table and is
  ;;  visible from here -- DPL at least max(CPL, RPL), or conforming code.
  ;;  Otherwise 0, which no usable descriptor is.  A bad selector is reported
  ;;  in ZF rather than faulting: that is the point of these instructions, and
  ;;  the Windows 95 VMM validates selectors with them.
  (func $sel_visible (param $sel i32) (result i64)
    (local $d i64) (local $dpl i32) (local $rpl i32)
    (if (i32.eqz (i32.and (local.get $sel) (i32.const 0xFFFC)))
      (then (return (i64.const 0))))
    (if (i32.gt_u (i32.or (local.get $sel) (i32.const 7))
                  (if (result i32) (i32.and (local.get $sel) (i32.const 4))
                    (then (i32.load (i32.const 0x230)))      ;; LDT cached limit
                    (else (call $gdt_limit))))
      (then (return (i64.const 0))))
    (local.set $d (call $read_desc (local.get $sel)))
    (if (global.get $fault) (then (return (i64.const 0))))
    (if (i32.eq (i32.and (call $desc_type (local.get $d)) (i32.const 0x1C)) (i32.const 0x1C))
      (then (return (local.get $d))))
    (local.set $dpl (i32.wrap_i64 (i64.and (i64.shr_u (local.get $d) (i64.const 45))
                                           (i64.const 3))))
    (local.set $rpl (i32.and (local.get $sel) (i32.const 3)))
    (if (i32.or (i32.lt_u (local.get $dpl) (call $cpl))
                (i32.lt_u (local.get $dpl) (local.get $rpl)))
      (then (return (i64.const 0))))
    (local.get $d))

  ;; ---- 0F 02 / 0F 03: LAR / LSL --------------------------------------------
  (func $h0f_lar_lsl (param $op i32)
    (local $d i64) (local $type i32) (local $ok i32)
    (call $decode_modrm)
    (if (i32.or (i32.eqz (call $pe_on)) (global.get $vm)) (then (call $raise_ud) (return)))
    (local.set $d (call $sel_visible (i32.wrap_i64 (call $rm_read (i32.const 2)))))
    (if (global.get $fault) (then (return)))
    (local.set $type (call $desc_type (local.get $d)))
    ;; Any code or data segment qualifies.  Of the system types LAR accepts the
    ;; TSSs, LDT and gates (bit n of the mask is type n), LSL only the ones that
    ;; have a limit, and long mode leaves out the 16-bit kinds.
    (local.set $ok
      (if (result i32) (i32.and (local.get $type) (i32.const 0x10))
        (then (i32.const 1))
        (else (i32.and (i32.shr_u
                (if (result i32) (i32.eq (local.get $op) (i32.const 0x02))
                  (then (select (i32.const 0x1A04) (i32.const 0x1A3E) (call $lma)))
                  (else (select (i32.const 0x0A04) (i32.const 0x0A0E) (call $lma))))
                (local.get $type))
              (i32.const 1)))))
    (call $set_flag (i32.const 6) (local.get $ok))
    (if (i32.eqz (local.get $ok)) (then (return)))
    (call $reg_write (global.get $opsize)
      (if (result i64) (i32.eq (local.get $op) (i32.const 0x02))
        (then (i64.and (i64.shr_u (local.get $d) (i64.const 32))
                       (select (i64.const 0xFF00) (i64.const 0x00FFFF00)
                               (i32.eq (global.get $opsize) (i32.const 2)))))
        (else (i64.extend_i32_u (call $desc_limit (local.get $d)))))))

  ;; ---- 0F 01: SGDT / SIDT / LGDT / LIDT / SMSW / LMSW / INVLPG ----------
  (func $h0f_grp7 (param $op i32)
    (local $sub i32) (local $m i32) (local $lim i32) (local $base i64) (local $tmp i64)
    (call $decode_modrm)
    (local.set $sub (global.get $mrm_ext))
    (local.set $m (global.get $modrm))

    ;; register forms
    (if (i32.eqz (global.get $mrm_mem))
      (then
        (if (i32.eq (local.get $m) (i32.const 0xF8))       ;; SWAPGS
          (then
            (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
            (local.set $tmp (call $seg_base (i32.const 5)))
            (i64.store (i32.add (call $seg_off (i32.const 5)) (i32.const 8))
                       (i64.load (i32.const 0x260)))
            (i64.store (i32.const 0x260) (local.get $tmp))
            (return)))
        (if (i32.eq (local.get $m) (i32.const 0xF9))       ;; RDTSCP
          (then
            (call $setreg32 (i32.const 0) (i32.wrap_i64 (call $tsc)))
            (call $setreg32 (i32.const 2) (i32.wrap_i64 (i64.shr_u (call $tsc) (i64.const 32))))
            (call $setreg32 (i32.const 1) (i32.wrap_i64 (i64.load (i32.const 0x288))))
            (return)))
        (if (i32.eq (local.get $sub) (i32.const 4))        ;; SMSW
          (then (call $setregN (global.get $mrm_rm) (global.get $opsize) (call $cr0)) (return)))
        (if (i32.eq (local.get $sub) (i32.const 6))        ;; LMSW
          (then
            (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
            (call $set_cr0 (i64.or (i64.and (call $cr0) (i64.const -16))
                                   (i64.and (call $regN (global.get $mrm_rm) (i32.const 2))
                                            (i64.const 15))))
            (call $recompute_mode)
            (return)))
        (call $raise_ud)
        (return)))

    (block $d
      (if (i32.eq (local.get $sub) (i32.const 0))          ;; SGDT
        (then
          (call $seg_write (global.get $mrm_seg) (call $mrm_off) (i32.const 2)
                (i64.extend_i32_u (call $gdt_limit)))
          (call $seg_write (global.get $mrm_seg) (i64.add (call $mrm_off) (i64.const 2))
                (if (result i32) (i32.eq (global.get $mode) (i32.const 3))
                  (then (i32.const 8)) (else (i32.const 4)))
                (call $gdt_base))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 1))          ;; SIDT
        (then
          (call $seg_write (global.get $mrm_seg) (call $mrm_off) (i32.const 2)
                (i64.extend_i32_u (call $idt_limit)))
          (call $seg_write (global.get $mrm_seg) (i64.add (call $mrm_off) (i64.const 2))
                (if (result i32) (i32.eq (global.get $mode) (i32.const 3))
                  (then (i32.const 8)) (else (i32.const 4)))
                (call $idt_base))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 7))          ;; INVLPG
        (then (call $tlb_flush_page (call $mrm_off)) (br $d)))
      (if (i32.gt_u (local.get $sub) (i32.const 3)) (then (call $raise_ud) (return)))
      ;; LGDT / LIDT
      (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
      (local.set $lim (i32.wrap_i64 (call $seg_read (global.get $mrm_seg)
                        (call $mrm_off) (i32.const 2))))
      (local.set $base (call $seg_read (global.get $mrm_seg)
                         (i64.add (call $mrm_off) (i64.const 2))
                         (if (result i32) (i32.eq (global.get $mode) (i32.const 3))
                           (then (i32.const 8)) (else (i32.const 4)))))
      (if (global.get $fault) (then (return)))
      ;; a 16-bit operand size truncates the base to 24 bits
      (if (i32.eq (global.get $opsize) (i32.const 2))
        (then (local.set $base (i64.and (local.get $base) (i64.const 0xFFFFFF)))))
      (if (i32.eq (local.get $sub) (i32.const 2))
        (then (i64.store (i32.const 0x200) (local.get $base))
              (i32.store (i32.const 0x208) (local.get $lim)))
        (else (i64.store (i32.const 0x210) (local.get $base))
              (i32.store (i32.const 0x218) (local.get $lim))))))

  (func $h0f_syscall (param $op i32)
    (if (i32.eq (local.get $op) (i32.const 0x05))
      (then
        (if (i32.eqz (i32.wrap_i64 (i64.and (i64.shr_u (call $efer) (i64.const 0)) (i64.const 1))))
          (then (call $raise_ud) (return)))
        (call $do_syscall))
      (else
        (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
        (call $do_sysret (global.get $opsize)))))

  (func $h0f_sysenter (param $op i32)
    (if (i32.eq (local.get $op) (i32.const 0x34))
      (then (call $do_sysenter))
      (else (call $do_sysexit))))

  (func $h0f_clts (param $op i32)
    (call $set_cr0 (i64.and (call $cr0) (i64.const -9))))     ;; clear TS

  (func $h0f_ud2 (param $op i32) (call $raise_ud))

  ;; multi-byte NOP and the prefetch/hint opcodes: decode the operand, do nothing
  (func $h0f_nop (param $op i32)
    (call $decode_modrm))

  ;; ---- 0F 20/22: MOV to/from control registers ----------------------------
  (func $h0f_movcr (param $op i32)
    (local $r i32) (local $v i64) (local $old i64)
    (call $decode_modrm)
    (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
    (local.set $r (global.get $mrm_reg))
    ;; debug registers: accept writes, return zero on reads
    (if (i32.or (i32.eq (local.get $op) (i32.const 0x21)) (i32.eq (local.get $op) (i32.const 0x23)))
      (then
        (if (i32.eq (local.get $op) (i32.const 0x21))
          (then (call $setreg64 (global.get $mrm_rm)
                  (i64.load (i32.add (i32.const 0x290) (i32.shl (local.get $r) (i32.const 3))))))
          (else (i64.store (i32.add (i32.const 0x290) (i32.shl (local.get $r) (i32.const 3)))
                           (call $reg64 (global.get $mrm_rm)))))
        (return)))

    (if (i32.eq (local.get $op) (i32.const 0x20))
      (then
        (block $d
          (if (i32.eq (local.get $r) (i32.const 0))
            (then (call $setreg64 (global.get $mrm_rm) (call $cr0)) (br $d)))
          (if (i32.eq (local.get $r) (i32.const 2))
            (then (call $setreg64 (global.get $mrm_rm) (call $cr2)) (br $d)))
          (if (i32.eq (local.get $r) (i32.const 3))
            (then (call $setreg64 (global.get $mrm_rm) (call $cr3)) (br $d)))
          (if (i32.eq (local.get $r) (i32.const 4))
            (then (call $setreg64 (global.get $mrm_rm) (call $cr4)) (br $d)))
          (call $setreg64 (global.get $mrm_rm) (i64.const 0)))
        (return)))

    (local.set $v (call $reg64 (global.get $mrm_rm)))
    (block $d
      (if (i32.eq (local.get $r) (i32.const 0))
        (then
          (local.set $old (call $cr0))
          ;; ET and the reserved bit 4 read as one
          (call $set_cr0 (i64.or (local.get $v) (i64.const 0x10)))
          ;; enabling paging with EFER.LME activates long mode
          (if (i32.and (i32.wrap_i64 (i64.and (i64.shr_u (local.get $v) (i64.const 31)) (i64.const 1)))
                       (i32.wrap_i64 (i64.and (i64.shr_u (call $efer) (i64.const 8)) (i64.const 1))))
            (then (call $set_efer (i64.or (call $efer) (i64.const 0x400)))))
          (if (i32.eqz (i32.wrap_i64 (i64.and (i64.shr_u (local.get $v) (i64.const 31)) (i64.const 1))))
            (then (call $set_efer (i64.and (call $efer) (i64.const -1025)))))
          (call $tlb_flush)
          (call $recompute_mode)
          (br $d)))
      (if (i32.eq (local.get $r) (i32.const 2))
        (then (call $set_cr2 (local.get $v)) (br $d)))
      (if (i32.eq (local.get $r) (i32.const 3))
        (then (call $set_cr3 (local.get $v)) (call $tlb_flush) (br $d)))
      (if (i32.eq (local.get $r) (i32.const 4))
        (then (call $set_cr4 (local.get $v)) (call $tlb_flush) (br $d)))))

  ;; ---- 0F 30/31/32: WRMSR / RDTSC / RDMSR ---------------------------------
  (func $msr_read (param $idx i32) (result i64)
    (block $d (result i64)
      (if (i32.eq (local.get $idx) (i32.const 0x10))     (then (br $d (call $tsc))))
      (if (i32.eq (local.get $idx) (i32.const 0x1B))     (then (br $d (i64.load (i32.const 0x2D0)))))
      (if (i32.eq (local.get $idx) (i32.const 0x277))    (then (br $d (i64.load (i32.const 0x2D8)))))
      (if (i32.eq (local.get $idx) (i32.const 0x1A0))    (then (br $d (i64.load (i32.const 0x2E0)))))
      (if (i32.eq (local.get $idx) (i32.const 0x174))    (then (br $d (i64.load (i32.const 0x300)))))
      (if (i32.eq (local.get $idx) (i32.const 0x175))    (then (br $d (i64.load (i32.const 0x308)))))
      (if (i32.eq (local.get $idx) (i32.const 0x176))    (then (br $d (i64.load (i32.const 0x310)))))
      (if (i32.eq (local.get $idx) (i32.const 0x2FF))    (then (br $d (i64.load (i32.const 0x2E8)))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000080)) (then (br $d (call $efer))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000081)) (then (br $d (i64.load (i32.const 0x268)))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000082)) (then (br $d (i64.load (i32.const 0x270)))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000083)) (then (br $d (i64.load (i32.const 0x278)))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000084)) (then (br $d (i64.load (i32.const 0x280)))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000100)) (then (br $d (call $seg_base (i32.const 4)))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000101)) (then (br $d (call $seg_base (i32.const 5)))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000102)) (then (br $d (i64.load (i32.const 0x260)))))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000103)) (then (br $d (i64.load (i32.const 0x288)))))
      (i64.const 0)))     ;; unknown MSRs read as zero

  (func $msr_write (param $idx i32) (param $v i64)
    (block $d
      (if (i32.eq (local.get $idx) (i32.const 0x10))
        (then (call $tsc_set (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0x1B))
        (then (i64.store (i32.const 0x2D0) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0x277))
        (then (i64.store (i32.const 0x2D8) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0x1A0))
        (then (i64.store (i32.const 0x2E0) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0x174))
        (then (i64.store (i32.const 0x300) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0x175))
        (then (i64.store (i32.const 0x308) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0x176))
        (then (i64.store (i32.const 0x310) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0x2FF))
        (then (i64.store (i32.const 0x2E8) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000080))
        (then
          (call $set_efer (local.get $v))
          ;; LMA tracks LME once paging is on
          (if (i32.and (call $paging_on)
                       (i32.wrap_i64 (i64.and (i64.shr_u (local.get $v) (i64.const 8)) (i64.const 1))))
            (then (call $set_efer (i64.or (call $efer) (i64.const 0x400)))))
          (call $recompute_mode)
          (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000081))
        (then (i64.store (i32.const 0x268) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000082))
        (then (i64.store (i32.const 0x270) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000083))
        (then (i64.store (i32.const 0x278) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000084))
        (then (i64.store (i32.const 0x280) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000100))
        (then (i64.store (i32.add (call $seg_off (i32.const 4)) (i32.const 8)) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000101))
        (then (i64.store (i32.add (call $seg_off (i32.const 5)) (i32.const 8)) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000102))
        (then (i64.store (i32.const 0x260) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $idx) (i32.const 0xC0000103))
        (then (i64.store (i32.const 0x288) (local.get $v)) (br $d)))))

  (func $h0f_msr (param $op i32)
    (local $idx i32) (local $v i64)
    (if (i32.eq (local.get $op) (i32.const 0x31))         ;; RDTSC
      (then
        (call $setreg32 (i32.const 0) (i32.wrap_i64 (call $tsc)))
        (call $setreg32 (i32.const 2) (i32.wrap_i64 (i64.shr_u (call $tsc) (i64.const 32))))
        (return)))
    (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
    (local.set $idx (call $reg32 (i32.const 1)))
    (if (i32.eq (local.get $op) (i32.const 0x32))         ;; RDMSR
      (then
        (local.set $v (call $msr_read (local.get $idx)))
        (call $setreg32 (i32.const 0) (i32.wrap_i64 (local.get $v)))
        (call $setreg32 (i32.const 2) (i32.wrap_i64 (i64.shr_u (local.get $v) (i64.const 32))))
        (return)))
    (if (i32.eq (local.get $op) (i32.const 0x30))         ;; WRMSR
      (then
        (call $msr_write (local.get $idx)
          (i64.or (i64.extend_i32_u (call $reg32 (i32.const 0)))
                  (i64.shl (i64.extend_i32_u (call $reg32 (i32.const 2))) (i64.const 32))))
        (return)))
    ;; RDPMC and the rest report zero
    (call $setreg32 (i32.const 0) (i32.const 0))
    (call $setreg32 (i32.const 2) (i32.const 0)))

  ;; ---- 0F A2: CPUID -------------------------------------------------------
  (func $h0f_cpuid (param $op i32)
    (local $leaf i32) (local $sub i32)
    (local.set $leaf (call $reg32 (i32.const 0)))
    (local.set $sub (call $reg32 (i32.const 1)))
    (block $d
      (if (i32.eq (local.get $leaf) (i32.const 0))
        (then
          ;; the vendor string is spelled out in EBX, then EDX, then ECX
          (call $setreg32 (i32.const 0) (i32.const 7))          ;; max basic leaf
          (call $setreg32 (i32.const 3) (i32.const 0x756E6547)) ;; EBX "Genu"
          (call $setreg32 (i32.const 2) (i32.const 0x49656E69)) ;; EDX "ineI"
          (call $setreg32 (i32.const 1) (i32.const 0x6C65746E)) ;; ECX "ntel"
          (br $d)))
      (if (i32.eq (local.get $leaf) (i32.const 1))
        (then
          (call $setreg32 (i32.const 0) (i32.const 0x00000663))  ;; family 6, model 6
          (call $setreg32 (i32.const 3) (i32.const 0x00010800))  ;; CLFLUSH size, initial APIC id
          ;; ECX: CX16 + hypervisor present
          (call $setreg32 (i32.const 1) (i32.const 0x80002000))
          ;; EDX: FPU DE PSE TSC MSR PAE MCE CX8 APIC SEP MTRR PGE MCA
          ;;      CMOV PAT PSE36 CLFSH MMX FXSR SSE SSE2
          ;; Not VME: virtual-8086 mode is plain 386 style, without the
          ;; virtual interrupt flag or the redirection bitmap.
          (call $setreg32 (i32.const 2) (i32.const 0x078BFBFD))
          (br $d)))
      ;; Cache descriptors.  AL is how many times to query this leaf, and every
      ;; processor says 1.  Windows XP counts it down after each query, so the
      ;; zero this used to return wrapped to four billion queries with
      ;; interrupts off, early in the kernel's processor setup.
      (if (i32.eq (local.get $leaf) (i32.const 2))
        (then
          (call $setreg32 (i32.const 0) (i32.const 0x00000001))
          (call $setreg32 (i32.const 3) (i32.const 0))
          (call $setreg32 (i32.const 1) (i32.const 0))
          ;; 32K L1 data, 32K L1 instruction, 2M L2; 8-way, 64-byte lines
          (call $setreg32 (i32.const 2) (i32.const 0x002C307D))
          (br $d)))
      (if (i32.eq (local.get $leaf) (i32.const 7))
        (then
          (call $setreg32 (i32.const 0) (i32.const 0))
          (call $setreg32 (i32.const 3) (i32.const 0))
          (call $setreg32 (i32.const 1) (i32.const 0))
          (call $setreg32 (i32.const 2) (i32.const 0))
          (br $d)))
      (if (i32.eq (local.get $leaf) (i32.const 0x80000000))
        (then
          (call $setreg32 (i32.const 0) (i32.const 0x80000008))
          (call $setreg32 (i32.const 3) (i32.const 0))
          (call $setreg32 (i32.const 1) (i32.const 0))
          (call $setreg32 (i32.const 2) (i32.const 0))
          (br $d)))
      (if (i32.eq (local.get $leaf) (i32.const 0x80000001))
        (then
          (call $setreg32 (i32.const 0) (i32.const 0))
          (call $setreg32 (i32.const 3) (i32.const 0))
          ;; LAHF/SAHF (bit 0) and PREFETCHW (bit 8).  Windows 8.1 and later
          ;; refuse to boot without both.
          (call $setreg32 (i32.const 1) (i32.const 0x101))
          ;; NX, RDTSCP, long mode, and the mandatory mirrored bits
          (call $setreg32 (i32.const 2) (i32.const 0x28100800))
          (br $d)))
      (if (i32.and (i32.ge_u (local.get $leaf) (i32.const 0x80000002))
                   (i32.le_u (local.get $leaf) (i32.const 0x80000004)))
        (then
          ;; brand string "x64emu WASM CPU"
          (call $setreg32 (i32.const 0) (i32.const 0x34367820))
          (call $setreg32 (i32.const 3) (i32.const 0x20756D65))
          (call $setreg32 (i32.const 1) (i32.const 0x4D534157))
          (call $setreg32 (i32.const 2) (i32.const 0x55504320))
          (if (i32.ne (local.get $leaf) (i32.const 0x80000002))
            (then (call $setreg32 (i32.const 0) (i32.const 0))
                  (call $setreg32 (i32.const 3) (i32.const 0))
                  (call $setreg32 (i32.const 1) (i32.const 0))
                  (call $setreg32 (i32.const 2) (i32.const 0))))
          (br $d)))
      (if (i32.eq (local.get $leaf) (i32.const 0x80000008))
        (then
          (call $setreg32 (i32.const 0) (i32.const 0x3028))      ;; 40-bit phys, 48-bit virt
          (call $setreg32 (i32.const 3) (i32.const 0))
          (call $setreg32 (i32.const 1) (i32.const 0))
          (call $setreg32 (i32.const 2) (i32.const 0))
          (br $d)))
      (call $setreg32 (i32.const 0) (i32.const 0))
      (call $setreg32 (i32.const 3) (i32.const 0))
      (call $setreg32 (i32.const 1) (i32.const 0))
      (call $setreg32 (i32.const 2) (i32.const 0))))

  ;; ---- 0F 40-4F: CMOVcc ---------------------------------------------------
  (func $h0f_cmov (param $op i32)
    (local $v i64)
    (call $decode_modrm)
    (local.set $v (call $rm_read (global.get $opsize)))
    (if (global.get $fault) (then (return)))
    (if (call $cond (i32.and (local.get $op) (i32.const 15)))
      (then (call $reg_write (global.get $opsize) (local.get $v)))
      ;; a 32-bit CMOV still zeroes the upper half when not taken
      (else (if (i32.eq (global.get $opsize) (i32.const 4))
              (then (call $reg_write (i32.const 4) (call $reg_read (i32.const 4))))))))

  ;; ---- 0F 80-8F: Jcc rel32 ------------------------------------------------
  (func $h0f_jcc (param $op i32)
    (local $d i64)
    (local.set $d (call $fetch_imm
      (if (result i32) (i32.eq (global.get $opsize) (i32.const 2))
        (then (i32.const 2)) (else (i32.const 4)))))
    (if (global.get $fault) (then (return)))
    (if (call $cond (i32.and (local.get $op) (i32.const 15)))
      (then (call $jump_to (i64.add (call $rip) (local.get $d))))))

  ;; ---- 0F 90-9F: SETcc ----------------------------------------------------
  (func $h0f_setcc (param $op i32)
    (call $decode_modrm)
    (call $rm_write (i32.const 1)
      (i64.extend_i32_u (call $cond (i32.and (local.get $op) (i32.const 15))))))

  ;; ---- 0F A0/A1/A8/A9: PUSH/POP FS and GS ---------------------------------
  (func $h0f_pushpop_fsgs (param $op i32)
    (local $s i32)
    (local.set $s (if (result i32) (i32.lt_u (local.get $op) (i32.const 0xA8))
                    (then (i32.const 4)) (else (i32.const 5))))
    (if (i32.and (local.get $op) (i32.const 1))
      (then (call $load_seg (local.get $s) (i32.wrap_i64 (call $pop (call $opsize_d64)))))
      (else (call $push (i64.extend_i32_u (call $seg_sel (local.get $s))) (call $opsize_d64)))))

  ;; ---- bit test family ----------------------------------------------------
  ;;  0F A3 BT, 0F AB BTS, 0F B3 BTR, 0F BB BTC, 0F BA group 8
  (func $bit_op (param $sub i32) (param $bitidx i64)
    (local $size i32) (local $v i64) (local $mask i64) (local $off i64) (local $bit i32)
    (local.set $size (global.get $opsize))
    ;; a memory operand indexes bits beyond the operand itself
    (if (global.get $mrm_mem)
      (then
        (local.set $off (i64.mul (i64.shr_s (local.get $bitidx)
                                            (i64.extend_i32_u (i32.add
                                              (i32.const 3)
                                              (if (result i32) (i32.eq (local.get $size) (i32.const 8))
                                                (then (i32.const 3))
                                                (else (if (result i32) (i32.eq (local.get $size) (i32.const 4))
                                                        (then (i32.const 2)) (else (i32.const 1))))))))
                                 (i64.extend_i32_u (local.get $size))))
        (global.set $mrm_addr (i64.add (global.get $mrm_addr) (local.get $off)))))
    (local.set $bitidx (i64.and (local.get $bitidx)
      (i64.extend_i32_u (i32.sub (i32.shl (local.get $size) (i32.const 3)) (i32.const 1)))))
    (local.set $v (call $rm_read (local.get $size)))
    (if (global.get $fault) (then (return)))
    (local.set $mask (i64.shl (i64.const 1) (local.get $bitidx)))
    (call $set_flag (i32.const 0)
      (i64.ne (i64.and (local.get $v) (local.get $mask)) (i64.const 0)))
    (block $d
      (if (i32.eq (local.get $sub) (i32.const 4)) (then (br $d)))          ;; BT
      (if (i32.eq (local.get $sub) (i32.const 5))                          ;; BTS
        (then (call $rm_write (local.get $size) (i64.or (local.get $v) (local.get $mask))) (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 6))                          ;; BTR
        (then (call $rm_write (local.get $size)
                (i64.and (local.get $v) (i64.xor (local.get $mask) (i64.const -1)))) (br $d)))
      (call $rm_write (local.get $size) (i64.xor (local.get $v) (local.get $mask)))))  ;; BTC

  (func $h0f_bt (param $op i32)
    (local $sub i32)
    (block $d
      (if (i32.eq (local.get $op) (i32.const 0xA3)) (then (local.set $sub (i32.const 4)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xAB)) (then (local.set $sub (i32.const 5)) (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0xB3)) (then (local.set $sub (i32.const 6)) (br $d)))
      (local.set $sub (i32.const 7)))
    (call $decode_modrm)
    (call $bit_op (local.get $sub) (call $sext (call $reg_read (global.get $opsize))
                                              (global.get $opsize))))

  (func $h0f_grp8 (param $op i32)
    (local $imm i64) (local $sub i32)
    (call $decode_modrm)
    (local.set $sub (global.get $mrm_ext))
    (local.set $imm (i64.extend_i32_u (call $fetch8)))
    (if (global.get $fault) (then (return)))
    (if (i32.lt_u (local.get $sub) (i32.const 4)) (then (call $raise_ud) (return)))
    ;; An immediate offset is taken modulo the operand size: unlike one in a
    ;; register, it never reaches into the memory beyond the operand.
    (call $bit_op (local.get $sub)
          (i64.and (local.get $imm)
                   (i64.extend_i32_u (i32.sub (i32.shl (global.get $opsize) (i32.const 3))
                                              (i32.const 1))))))

  ;; ---- 0F A4/A5/AC/AD: SHLD / SHRD ---------------------------------------
  (func $h0f_shldshrd (param $op i32)
    (local $cnt i32) (local $dst i64) (local $src i64) (local $size i32)
    (local.set $size (global.get $opsize))
    (call $decode_modrm)
    (if (i32.and (local.get $op) (i32.const 1))
      (then (local.set $cnt (call $reg8 (i32.const 1))))
      (else (local.set $cnt (call $fetch8))))
    (local.set $dst (call $rm_read (local.get $size)))
    (local.set $src (call $reg_read (local.get $size)))
    (if (global.get $fault) (then (return)))
    (if (i32.lt_u (local.get $op) (i32.const 0xAC))
      (then (call $rm_write (local.get $size)
              (call $do_shld (local.get $dst) (local.get $src) (local.get $cnt) (local.get $size))))
      (else (call $rm_write (local.get $size)
              (call $do_shrd (local.get $dst) (local.get $src) (local.get $cnt) (local.get $size))))))

  ;; ---- 0F AF: IMUL r, r/m -------------------------------------------------
  (func $h0f_imul (param $op i32)
    (local $a i64) (local $b i64) (local $r i64) (local $size i32) (local $ovf i32)
    (local.set $size (global.get $opsize))
    (call $decode_modrm)
    (local.set $a (call $sext (call $reg_read (local.get $size)) (local.get $size)))
    (local.set $b (call $sext (call $rm_read (local.get $size)) (local.get $size)))
    (if (global.get $fault) (then (return)))
    (local.set $r (i64.mul (local.get $a) (local.get $b)))
    (local.set $ovf (i64.ne (call $sext (local.get $r) (local.get $size)) (local.get $r)))
    ;; the 64-bit case needs the true 128-bit product to detect overflow
    (if (i32.eq (local.get $size) (i32.const 8))
      (then (local.set $ovf
              (i64.ne (call $muls_hi (local.get $a) (local.get $b))
                      (i64.shr_s (local.get $r) (i64.const 63))))))
    (call $reg_write (local.get $size) (local.get $r))
    (call $set_flag (i32.const 0) (local.get $ovf))
    (call $set_flag (i32.const 11) (local.get $ovf))
    (call $set_szp (call $trunc (local.get $r) (local.get $size)) (local.get $size)))

  ;; ---- 0F B0/B1: CMPXCHG --------------------------------------------------
  (func $h0f_cmpxchg (param $op i32)
    (local $size i32) (local $dst i64) (local $acc i64)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $dst (call $rm_read (local.get $size)))
    (if (global.get $fault) (then (return)))
    (local.set $acc (call $regN (i32.const 0) (local.get $size)))
    (drop (call $do_sub (local.get $acc) (local.get $dst) (local.get $size)))
    (if (call $zf)
      (then (call $rm_write (local.get $size) (call $reg_read (local.get $size))))
      (else
        ;; A failed compare still writes the destination back, with its own
        ;; value: hardware always does the write.  For a 32-bit register that
        ;; clears the upper half.
        (call $rm_write (local.get $size) (local.get $dst))
        (if (global.get $fault) (then (return)))
        (call $setregN (i32.const 0) (local.get $size) (local.get $dst)))))

  ;; ---- 0F C0/C1: XADD -----------------------------------------------------
  (func $h0f_xadd (param $op i32)
    (local $size i32) (local $a i64) (local $b i64) (local $r i64)
    (local.set $size (if (result i32) (i32.and (local.get $op) (i32.const 1))
                       (then (global.get $opsize)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $a (call $rm_read (local.get $size)))
    (local.set $b (call $reg_read (local.get $size)))
    (if (global.get $fault) (then (return)))
    (local.set $r (call $do_add (local.get $a) (local.get $b) (local.get $size)))
    (call $rm_write (local.get $size) (local.get $r))
    (if (global.get $fault) (then (return)))
    (call $reg_write (local.get $size) (local.get $a)))

  ;; ---- 0F C7: CMPXCHG8B / CMPXCHG16B --------------------------------------
  (func $h0f_grp9 (param $op i32)
    (local $size i32) (local $lo i64) (local $hi i64) (local $a i64) (local $la i64)
    (call $decode_modrm)
    (if (i32.ne (global.get $mrm_ext) (i32.const 1)) (then (call $raise_ud) (return)))
    (local.set $size (if (result i32) (i32.eq (global.get $opsize) (i32.const 8))
                       (then (i32.const 8)) (else (i32.const 4))))
    (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off)
                                  (i32.shl (local.get $size) (i32.const 1))))
    (if (global.get $fault) (then (return)))
    (local.set $lo (call $lin_read (local.get $la) (local.get $size)))
    (local.set $hi (call $lin_read (i64.add (local.get $la) (i64.extend_i32_u (local.get $size)))
                                   (local.get $size)))
    (if (global.get $fault) (then (return)))
    (if (i32.and (i64.eq (local.get $lo) (call $regN (i32.const 0) (local.get $size)))
                 (i64.eq (local.get $hi) (call $regN (i32.const 2) (local.get $size))))
      (then
        (call $set_flag (i32.const 6) (i32.const 1))
        (call $lin_write (local.get $la) (local.get $size)
              (call $regN (i32.const 3) (local.get $size)))
        (call $lin_write (i64.add (local.get $la) (i64.extend_i32_u (local.get $size)))
              (local.get $size) (call $regN (i32.const 1) (local.get $size))))
      (else
        (call $set_flag (i32.const 6) (i32.const 0))
        (call $setregN (i32.const 0) (local.get $size) (local.get $lo))
        (call $setregN (i32.const 2) (local.get $size) (local.get $hi)))))

  ;; ---- 0F B6/B7 MOVZX, 0F BE/BF MOVSX -------------------------------------
  (func $h0f_movzx (param $op i32)
    (local $src i32) (local $v i64)
    (local.set $src (if (result i32) (i32.and (local.get $op) (i32.const 1))
                      (then (i32.const 2)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $v (call $rm_read (local.get $src)))
    (if (global.get $fault) (then (return)))
    (call $reg_write (global.get $opsize) (local.get $v)))

  (func $h0f_movsx (param $op i32)
    (local $src i32) (local $v i64)
    (local.set $src (if (result i32) (i32.and (local.get $op) (i32.const 1))
                      (then (i32.const 2)) (else (i32.const 1))))
    (call $decode_modrm)
    (local.set $v (call $rm_read (local.get $src)))
    (if (global.get $fault) (then (return)))
    (call $reg_write (global.get $opsize) (call $sext (local.get $v) (local.get $src))))

  ;; ---- 0F BC/BD: BSF / BSR (and TZCNT/LZCNT under F3) ---------------------
  (func $h0f_bsf (param $op i32)
    (local $v i64) (local $size i32) (local $r i64)
    (local.set $size (global.get $opsize))
    (call $decode_modrm)
    (local.set $v (call $trunc (call $rm_read (local.get $size)) (local.get $size)))
    (if (global.get $fault) (then (return)))
    (if (i64.eqz (local.get $v))
      (then
        (call $set_flag (i32.const 6) (i32.const 1))
        (if (i32.eq (global.get $rep) (i32.const 3))
          (then (call $reg_write (local.get $size)
                  (i64.extend_i32_u (i32.shl (local.get $size) (i32.const 3))))
                (call $set_flag (i32.const 0) (i32.const 1))))
        (return)))
    (call $set_flag (i32.const 6) (i32.const 0))
    (if (i32.eq (local.get $op) (i32.const 0xBC))
      (then (local.set $r (i64.ctz (local.get $v))))
      (else
        (if (i32.eq (global.get $rep) (i32.const 3))
          (then (local.set $r (i64.sub (i64.clz (local.get $v))     ;; LZCNT
                                       (i64.extend_i32_u (i32.sub (i32.const 64)
                                         (i32.shl (local.get $size) (i32.const 3)))))))
          (else (local.set $r (i64.sub (i64.const 63) (i64.clz (local.get $v))))))))
    (call $reg_write (local.get $size) (local.get $r)))

  (func $h0f_popcnt (param $op i32)
    (local $v i64)
    (call $decode_modrm)
    (local.set $v (call $trunc (call $rm_read (global.get $opsize)) (global.get $opsize)))
    (if (global.get $fault) (then (return)))
    (call $reg_write (global.get $opsize) (i64.popcnt (local.get $v)))
    (call $set_flags (i64.const 2))
    (call $set_flag (i32.const 6) (i64.eqz (local.get $v))))

  ;; ---- 0F C8-CF: BSWAP ----------------------------------------------------
  (func $h0f_bswap (param $op i32)
    (local $r i32) (local $v i64)
    (local.set $r (i32.or (i32.and (local.get $op) (i32.const 7))
                          (i32.shl (i32.and (global.get $rex) (i32.const 1)) (i32.const 3))))
    (if (i32.eq (global.get $opsize) (i32.const 8))
      (then
        (local.set $v (call $reg64 (local.get $r)))
        (call $setreg64 (local.get $r)
          (i64.or
            (i64.or (i64.shl (i64.and (local.get $v) (i64.const 0xFF)) (i64.const 56))
                    (i64.shl (i64.and (local.get $v) (i64.const 0xFF00)) (i64.const 40)))
            (i64.or
              (i64.or (i64.shl (i64.and (local.get $v) (i64.const 0xFF0000)) (i64.const 24))
                      (i64.shl (i64.and (local.get $v) (i64.const 0xFF000000)) (i64.const 8)))
              (i64.or
                (i64.or (i64.and (i64.shr_u (local.get $v) (i64.const 8)) (i64.const 0xFF000000))
                        (i64.and (i64.shr_u (local.get $v) (i64.const 24)) (i64.const 0xFF0000)))
                (i64.or (i64.and (i64.shr_u (local.get $v) (i64.const 40)) (i64.const 0xFF00))
                        (i64.shr_u (local.get $v) (i64.const 56))))))))
      (else
        (local.set $v (i64.extend_i32_u (call $reg32 (local.get $r))))
        (call $setreg32 (local.get $r) (i32.wrap_i64
          (i64.or
            (i64.or (i64.shl (i64.and (local.get $v) (i64.const 0xFF)) (i64.const 24))
                    (i64.shl (i64.and (local.get $v) (i64.const 0xFF00)) (i64.const 8)))
            (i64.or (i64.and (i64.shr_u (local.get $v) (i64.const 8)) (i64.const 0xFF00))
                    (i64.and (i64.shr_u (local.get $v) (i64.const 24)) (i64.const 0xFF)))))))))

  ;; ---- 0F AE: fences, CLFLUSH, FXSAVE (treated as no-ops) -----------------
  ;; ---- 0F AE: FXSAVE, FXRSTOR, LDMXCSR, STMXCSR, and the fences ----------
  ;;  FXSAVE and FXRSTOR are how a kernel gives every process its own x87 and
  ;;  SSE registers across a context switch, and how a signal handler's state
  ;;  reaches the user stack.  They did nothing, so every process shared one
  ;;  set of XMM registers: a switch in the middle of glibc's SSE2 string code
  ;;  handed it another process's values, systemd's paths came out mangled,
  ;;  and udev aborted -- differently from boot to boot, as switches landed.
  (func $h0f_grp15 (param $op i32)
    (local $sub i32) (local $v i64)
    (call $decode_modrm)
    (local.set $sub (global.get $mrm_ext))
    ;; Register forms are LFENCE, MFENCE and SFENCE, with nothing to order
    ;; here.  With F3 they are the FS/GS base instructions, not advertised.
    (if (i32.eqz (global.get $mrm_mem))
      (then (if (i32.eq (global.get $rep) (i32.const 3)) (then (call $raise_ud)))
            (return)))
    (block $d
      (if (i32.eqz (local.get $sub)) (then (call $fxsave) (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 1)) (then (call $fxrstor) (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 2))                 ;; LDMXCSR
        (then
          (local.set $v (call $rm_read (i32.const 4)))
          (if (global.get $fault) (then (return)))
          (if (i64.ne (i64.and (local.get $v) (i64.const 0xFFFF0000)) (i64.const 0))
            (then (call $raise_gp (i64.const 0)) (return)))
          (i32.store (i32.const 0x500) (i32.wrap_i64 (local.get $v)))
          (br $d)))
      (if (i32.eq (local.get $sub) (i32.const 3))                 ;; STMXCSR
        (then (call $rm_write (i32.const 4) (i64.extend_i32_u (i32.load (i32.const 0x500))))
              (br $d)))
      ;; XSAVE and XRSTOR, which CPUID does not offer
      (if (i32.or (i32.eq (local.get $sub) (i32.const 4)) (i32.eq (local.get $sub) (i32.const 5)))
        (then (call $raise_ud) (br $d)))))
      ;; /6 and /7 with memory: CLWB, CLFLUSH -- no cache to write back

  ;; How many XMM registers FXSAVE covers: all sixteen only in 64-bit mode.
  (func $fx_xmm_count (result i32)
    (select (i32.const 16) (i32.const 8) (i32.eq (global.get $mode) (i32.const 3))))

  ;; The 512-byte FXSAVE area: control, status and abridged tag words at 0,
  ;; MXCSR and its mask at 24, ST(0)..ST(7) as 80-bit values in 16-byte slots
  ;; from 32, the XMM registers from 160.  The instruction pointers the x87
  ;; would record are not tracked and are stored as zero.
  (func $fxsave
    (local $la i64) (local $i i32) (local $tw i32) (local $abridged i32) (local $v f64)
    (local $p i32)
    (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off) (i32.const 512)))
    (if (global.get $fault) (then (return)))
    ;; abridged tag: one bit per physical register, set unless it is empty
    (local.set $tw (i32.load (i32.const 0x594)))
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 8)))
      (if (i32.ne (i32.and (i32.shr_u (local.get $tw) (i32.shl (local.get $i) (i32.const 1)))
                           (i32.const 3))
                  (i32.const 3))
        (then (local.set $abridged (i32.or (local.get $abridged)
                                           (i32.shl (i32.const 1) (local.get $i))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (call $lin_write (local.get $la) (i32.const 8)
      (i64.or (i64.extend_i32_u (i32.and (i32.load (i32.const 0x508)) (i32.const 0xFFFF)))
        (i64.or (i64.shl (i64.extend_i32_u (i32.and (call $status_word) (i32.const 0xFFFF)))
                         (i64.const 16))
                (i64.shl (i64.extend_i32_u (local.get $abridged)) (i64.const 32)))))
    (call $lin_write (i64.add (local.get $la) (i64.const 8)) (i32.const 8) (i64.const 0))
    (call $lin_write (i64.add (local.get $la) (i64.const 16)) (i32.const 8) (i64.const 0))
    (call $lin_write (i64.add (local.get $la) (i64.const 24)) (i32.const 8)
      (i64.or (i64.extend_i32_u (i32.load (i32.const 0x500))) (i64.const 0xFFBF00000000)))
    ;; a register holding an MMX value goes out as its 80-bit form, exactly
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 8)))
      (local.set $p (i32.and (i32.add (call $ftop) (local.get $i)) (i32.const 7)))
      (local.set $v (call $st (local.get $i)))
      (call $lin_write (i64.add (local.get $la) (i64.extend_i32_u
                         (i32.add (i32.const 32) (i32.shl (local.get $i) (i32.const 4)))))
            (i32.const 8)
            (if (result i64) (call $raw_held (local.get $p))
              (then (call $raw_mant (local.get $p)))
              (else (call $f64_ext_mant (local.get $v)))))
      (call $lin_write (i64.add (local.get $la) (i64.extend_i32_u
                         (i32.add (i32.const 40) (i32.shl (local.get $i) (i32.const 4)))))
            (i32.const 8)
            (i64.extend_i32_u (if (result i32) (call $raw_held (local.get $p))
                                (then (call $raw_se (local.get $p)))
                                (else (call $f64_ext_se (local.get $v))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (call $fx_xmm_count)))
      (call $lin_write (i64.add (local.get $la) (i64.extend_i32_u
                         (i32.add (i32.const 160) (i32.shl (local.get $i) (i32.const 4)))))
            (i32.const 8) (i64.load (call $xmm_off (local.get $i))))
      (call $lin_write (i64.add (local.get $la) (i64.extend_i32_u
                         (i32.add (i32.const 168) (i32.shl (local.get $i) (i32.const 4)))))
            (i32.const 8) (i64.load (i32.add (call $xmm_off (local.get $i)) (i32.const 8))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))

  (func $fxrstor
    (local $la i64) (local $i i32) (local $w0 i64) (local $fsw i32) (local $abridged i32)
    (local $tw i32) (local $off i64) (local $mant i64) (local $se i32)
    (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off) (i32.const 512)))
    (if (global.get $fault) (then (return)))
    ;; Touch both ends first, so a fault leaves every register as it was
    ;; rather than half restored.
    (drop (call $lin_read (i64.add (local.get $la) (i64.const 504)) (i32.const 8)))
    (local.set $w0 (call $lin_read (local.get $la) (i32.const 8)))
    (if (global.get $fault) (then (return)))
    (i32.store (i32.const 0x508) (i32.wrap_i64 (i64.and (local.get $w0) (i64.const 0xFFFF))))
    (local.set $fsw (i32.wrap_i64 (i64.and (i64.shr_u (local.get $w0) (i64.const 16))
                                           (i64.const 0xFFFF))))
    (i32.store (i32.const 0x504) (local.get $fsw))
    (call $ftop_set (i32.shr_u (local.get $fsw) (i32.const 11)))
    (local.set $abridged (i32.wrap_i64 (i64.and (i64.shr_u (local.get $w0) (i64.const 32))
                                                (i64.const 0xFF))))
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 8)))
      (if (i32.eqz (i32.and (local.get $abridged) (i32.shl (i32.const 1) (local.get $i))))
        (then (local.set $tw (i32.or (local.get $tw)
                (i32.shl (i32.const 3) (i32.shl (local.get $i) (i32.const 1)))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (i32.store (i32.const 0x594) (local.get $tw))
    (i32.store (i32.const 0x500)
      (i32.wrap_i64 (call $lin_read (i64.add (local.get $la) (i64.const 24)) (i32.const 4))))
    ;; registers in stack order, under the TOP just restored
    ;; A NaN or infinity -- which is what an MMX value looks like -- is kept in
    ;; its 80-bit form, so an MMX value saved and restored comes back exact.
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 8)))
      (local.set $off (i64.add (local.get $la) (i64.extend_i32_u
                        (i32.add (i32.const 32) (i32.shl (local.get $i) (i32.const 4))))))
      (local.set $mant (call $lin_read (local.get $off) (i32.const 8)))
      (local.set $se (i32.wrap_i64 (call $lin_read (i64.add (local.get $off) (i64.const 8))
                                                   (i32.const 2))))
      (if (i32.eq (i32.and (local.get $se) (i32.const 0x7FFF)) (i32.const 0x7FFF))
        (then (call $raw_put (i32.and (i32.add (call $ftop) (local.get $i)) (i32.const 7))
                             (local.get $mant) (local.get $se)))
        (else (call $st_set (local.get $i) (call $ext_f64 (local.get $mant) (local.get $se)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (call $fx_xmm_count)))
      (local.set $off (i64.add (local.get $la) (i64.extend_i32_u
                        (i32.add (i32.const 160) (i32.shl (local.get $i) (i32.const 4))))))
      (i64.store (call $xmm_off (local.get $i)) (call $lin_read (local.get $off) (i32.const 8)))
      (i64.store (i32.add (call $xmm_off (local.get $i)) (i32.const 8))
                 (call $lin_read (i64.add (local.get $off) (i64.const 8)) (i32.const 8)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))

  ;; An f64 in the 80-bit extended format, as significand (with its explicit
  ;; integer bit) and sign-and-exponent.  Exact: every f64 has an extended
  ;; twin.  The x87 code's own conversion goes through log2 and exp2, which is
  ;; close but would let values drift on every context switch.
  (func $f64_ext_mant (param $v f64) (result i64)
    (local $b i64) (local $e i32) (local $f i64)
    (local.set $b (i64.reinterpret_f64 (local.get $v)))
    (local.set $e (i32.wrap_i64 (i64.and (i64.shr_u (local.get $b) (i64.const 52)) (i64.const 0x7FF))))
    (local.set $f (i64.and (local.get $b) (i64.const 0xFFFFFFFFFFFFF)))
    (if (i32.eqz (local.get $e))                        ;; zero, or denormal: normalise
      (then (return (i64.shl (local.get $f) (i64.clz (local.get $f))))))
    (i64.or (i64.const 0x8000000000000000) (i64.shl (local.get $f) (i64.const 11))))

  (func $f64_ext_se (param $v f64) (result i32)
    (local $b i64) (local $e i32) (local $f i64) (local $s i32)
    (local.set $b (i64.reinterpret_f64 (local.get $v)))
    (local.set $s (i32.shl (i32.wrap_i64 (i64.shr_u (local.get $b) (i64.const 63))) (i32.const 15)))
    (local.set $e (i32.wrap_i64 (i64.and (i64.shr_u (local.get $b) (i64.const 52)) (i64.const 0x7FF))))
    (local.set $f (i64.and (local.get $b) (i64.const 0xFFFFFFFFFFFFF)))
    (if (i32.eq (local.get $e) (i32.const 0x7FF))
      (then (return (i32.or (local.get $s) (i32.const 0x7FFF)))))
    (if (i32.eqz (local.get $e))
      (then
        (if (i64.eqz (local.get $f)) (then (return (local.get $s))))
        ;; a denormal's leading bit p sits at 2^(p - 1074)
        (return (i32.or (local.get $s)
          (i32.sub (i32.const 15372) (i32.wrap_i64 (i64.clz (local.get $f))))))))
    (i32.or (local.get $s) (i32.add (local.get $e) (i32.const 15360))))

  ;; And back, rounding to nearest even.  Below the f64 normal range the value
  ;; is shifted into a denormal, truncating.
  (func $ext_f64 (param $m i64) (param $se i32) (result f64)
    (local $s i64) (local $e i32) (local $lz i32) (local $x i32) (local $frac i64)
    (local $round i64) (local $sh i32)
    (local.set $s (i64.shl (i64.extend_i32_u (i32.and (local.get $se) (i32.const 0x8000)))
                           (i64.const 48)))
    (local.set $e (i32.and (local.get $se) (i32.const 0x7FFF)))
    (if (i32.eq (local.get $e) (i32.const 0x7FFF))
      (then
        (local.set $frac (i64.and (i64.shr_u (local.get $m) (i64.const 11))
                                  (i64.const 0xFFFFFFFFFFFFF)))
        (if (i64.eqz (i64.shl (local.get $m) (i64.const 1)))       ;; infinity
          (then (return (f64.reinterpret_i64 (i64.or (local.get $s) (i64.const 0x7FF0000000000000))))))
        (if (i64.eqz (local.get $frac)) (then (local.set $frac (i64.const 0x8000000000000))))
        (return (f64.reinterpret_i64 (i64.or (local.get $s)
                  (i64.or (i64.const 0x7FF0000000000000) (local.get $frac)))))))
    (if (i64.eqz (local.get $m)) (then (return (f64.reinterpret_i64 (local.get $s)))))
    (local.set $lz (i32.wrap_i64 (i64.clz (local.get $m))))
    (local.set $m (i64.shl (local.get $m) (i64.extend_i32_u (local.get $lz))))
    (local.set $x (i32.sub (i32.sub (select (i32.const 1) (local.get $e) (i32.eqz (local.get $e)))
                                    (i32.const 16383))
                           (local.get $lz)))
    (if (i32.gt_s (local.get $x) (i32.const 1023))
      (then (return (f64.reinterpret_i64 (i64.or (local.get $s) (i64.const 0x7FF0000000000000))))))
    (if (i32.ge_s (local.get $x) (i32.const -1022))
      (then
        (local.set $frac (i64.and (i64.shr_u (local.get $m) (i64.const 11)) (i64.const 0xFFFFFFFFFFFFF)))
        (local.set $round (i64.and (local.get $m) (i64.const 0x7FF)))
        (if (i32.or (i64.gt_u (local.get $round) (i64.const 0x400))
                    (i32.and (i64.eq (local.get $round) (i64.const 0x400))
                             (i32.wrap_i64 (i64.and (local.get $frac) (i64.const 1)))))
          (then
            (local.set $frac (i64.add (local.get $frac) (i64.const 1)))
            (if (i64.eq (local.get $frac) (i64.const 0x10000000000000))
              (then (local.set $frac (i64.const 0))
                    (local.set $x (i32.add (local.get $x) (i32.const 1)))))))
        (if (i32.gt_s (local.get $x) (i32.const 1023))
          (then (return (f64.reinterpret_i64 (i64.or (local.get $s) (i64.const 0x7FF0000000000000))))))
        (return (f64.reinterpret_i64 (i64.or (local.get $s)
                  (i64.or (i64.shl (i64.extend_i32_u (i32.add (local.get $x) (i32.const 1023)))
                                   (i64.const 52))
                          (local.get $frac)))))))
    (local.set $sh (i32.sub (i32.const -1022) (local.get $x)))
    (if (i32.gt_s (local.get $sh) (i32.const 52)) (then (return (f64.reinterpret_i64 (local.get $s)))))
    (f64.reinterpret_i64 (i64.or (local.get $s)
      (i64.shr_u (local.get $m) (i64.extend_i32_u (i32.add (local.get $sh) (i32.const 11)))))))

  ;; =========================================================================
  ;;  minimal SSE: enough for the moves the kernel emits
  ;; =========================================================================
  (func $xmm_off (param $r i32) (result i32)
    (i32.add (i32.const 0x400) (i32.shl (local.get $r) (i32.const 4))))

  (func $sse_check (result i32)
    ;; CR0.EM or missing CR4.OSFXSR make SSE unavailable
    (if (i32.wrap_i64 (i64.and (i64.shr_u (call $cr0) (i64.const 2)) (i64.const 1)))
      (then (call $raise_ud) (return (i32.const 0))))
    (if (call $fpu_ts)
      (then (call $raise (i32.const 7) (i64.const 0) (i32.const 0)) (return (i32.const 0))))
    (i32.const 1))

  ;; 0F 10/11 MOVUPS/MOVSS/MOVUPD, 0F 28/29 MOVAPS, 0F 6F/7F MOVDQA/MOVDQU
  (func $h0f_movxmm (param $op i32)
    (local $to_rm i32) (local $lo i64) (local $hi i64) (local $la i64) (local $reg i32)
    (local $w i32)
    (if (call $is_mmx (local.get $op)) (then (call $h_mmx (local.get $op)) (return)))
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)
    (local.set $reg (global.get $mrm_reg))
    (local.set $to_rm (i32.or (i32.eq (local.get $op) (i32.const 0x11))
                       (i32.or (i32.eq (local.get $op) (i32.const 0x29))
                               (i32.eq (local.get $op) (i32.const 0x7F)))))
    ;; 0F 10 and 0F 11 carry their width in the repeat prefix: F3 makes it
    ;; MOVSS and moves four bytes, F2 makes it MOVSD and moves eight.  Moving
    ;; sixteen regardless both over-reads the source and, on a store, writes
    ;; over the eight bytes that follow the destination.
    (local.set $w (i32.const 16))
    (if (i32.or (i32.eq (local.get $op) (i32.const 0x10))
                (i32.eq (local.get $op) (i32.const 0x11)))
      (then
        (if (i32.eq (global.get $rep) (i32.const 3)) (then (local.set $w (i32.const 4))))
        (if (i32.eq (global.get $rep) (i32.const 2)) (then (local.set $w (i32.const 8))))))
    (if (global.get $mrm_mem)
      (then
        (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off) (local.get $w)))
        (if (global.get $fault) (then (return)))
        (if (local.get $to_rm)
          (then
            (if (i32.eq (local.get $w) (i32.const 16))
              (then
                (call $lin_write (local.get $la) (i32.const 8)
                      (i64.load (call $xmm_off (local.get $reg))))
                (call $lin_write (i64.add (local.get $la) (i64.const 8)) (i32.const 8)
                      (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)))))
              (else
                (call $lin_write (local.get $la) (local.get $w)
                      (i64.load (call $xmm_off (local.get $reg)))))))
          (else
            ;; a scalar load from memory clears everything above what it read
            (if (i32.eq (local.get $w) (i32.const 16))
              (then
                (local.set $lo (call $lin_read (local.get $la) (i32.const 8)))
                (local.set $hi (call $lin_read (i64.add (local.get $la) (i64.const 8))
                                               (i32.const 8))))
              (else
                (local.set $lo (call $lin_read (local.get $la) (local.get $w)))
                (local.set $hi (i64.const 0))))
            (if (global.get $fault) (then (return)))
            (i64.store (call $xmm_off (local.get $reg)) (local.get $lo))
            (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))
                       (local.get $hi)))))
      (else
        ;; register to register: a scalar move leaves the upper bits as they were
        (if (local.get $to_rm)
          (then
            (i64.store (call $xmm_off (global.get $mrm_rm))
              (if (result i64) (i32.eq (local.get $w) (i32.const 4))
                (then (i64.or
                        (i64.and (i64.load (call $xmm_off (global.get $mrm_rm)))
                                 (i64.const 0xFFFFFFFF00000000))
                        (i64.and (i64.load (call $xmm_off (local.get $reg)))
                                 (i64.const 0xFFFFFFFF))))
                (else (i64.load (call $xmm_off (local.get $reg))))))
            (if (i32.eq (local.get $w) (i32.const 16))
              (then (i64.store (i32.add (call $xmm_off (global.get $mrm_rm)) (i32.const 8))
                      (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)))))))
          (else
            (i64.store (call $xmm_off (local.get $reg))
              (if (result i64) (i32.eq (local.get $w) (i32.const 4))
                (then (i64.or
                        (i64.and (i64.load (call $xmm_off (local.get $reg)))
                                 (i64.const 0xFFFFFFFF00000000))
                        (i64.and (i64.load (call $xmm_off (global.get $mrm_rm)))
                                 (i64.const 0xFFFFFFFF))))
                (else (i64.load (call $xmm_off (global.get $mrm_rm))))))
            (if (i32.eq (local.get $w) (i32.const 16))
              (then (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))
                      (i64.load (i32.add (call $xmm_off (global.get $mrm_rm))
                                         (i32.const 8)))))))))))

  ;; 0F 6E MOVD/MOVQ to xmm, 0F 7E MOVD/MOVQ from xmm
  (func $h0f_movd (param $op i32)
    (local $size i32) (local $v i64) (local $reg i32)
    (if (call $is_mmx (local.get $op)) (then (call $h_mmx (local.get $op)) (return)))
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)
    (local.set $reg (global.get $mrm_reg))
    (local.set $size (if (result i32) (i32.eq (global.get $opsize) (i32.const 8))
                       (then (i32.const 8)) (else (i32.const 4))))
    (if (i32.eq (local.get $op) (i32.const 0x6E))
      (then
        (local.set $v (call $rm_read (local.get $size)))
        (if (global.get $fault) (then (return)))
        (i64.store (call $xmm_off (local.get $reg)) (local.get $v))
        (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)) (i64.const 0)))
      (else
        ;; F3 0F 7E is MOVQ xmm, xmm/m64
        (if (i32.eq (global.get $rep) (i32.const 3))
          (then
            (if (global.get $mrm_mem)
              (then (local.set $v (call $seg_read (global.get $mrm_seg) (call $mrm_off) (i32.const 8))))
              (else (local.set $v (i64.load (call $xmm_off (global.get $mrm_rm))))))
            (if (global.get $fault) (then (return)))
            (i64.store (call $xmm_off (local.get $reg)) (local.get $v))
            (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)) (i64.const 0)))
          (else
            (call $rm_write (local.get $size) (i64.load (call $xmm_off (local.get $reg)))))))))

  ;; 0F 12-0F 17: the half-register moves and unpacks.  These are pure data
  ;; movement with no arithmetic, so they can be modelled exactly.  Windows'
  ;; loader reaches MOVLHPS inside its inline memset.
  (func $h0f_movlh (param $op i32)
    (local $reg i32) (local $la i64)
    (local $dlo i64) (local $dhi i64) (local $slo i64) (local $shi i64)
    (local $wide i32)
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)
    (local.set $reg (global.get $mrm_reg))
    (local.set $dlo (i64.load (call $xmm_off (local.get $reg))))
    (local.set $dhi (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))))

    ;; the stores take the register as their source and memory as destination
    (if (i32.or (i32.eq (local.get $op) (i32.const 0x13))
                (i32.eq (local.get $op) (i32.const 0x17)))
      (then
        (if (i32.eqz (global.get $mrm_mem)) (then (call $raise_ud) (return)))
        (call $seg_write (global.get $mrm_seg) (call $mrm_off) (i32.const 8)
              (if (result i64) (i32.eq (local.get $op) (i32.const 0x13))
                (then (local.get $dlo)) (else (local.get $dhi))))
        (return)))

    ;; UNPCK reads a full 128 bits; everything else reads 64
    (local.set $wide (i32.or (i32.eq (local.get $op) (i32.const 0x14))
                             (i32.eq (local.get $op) (i32.const 0x15))))
    (if (global.get $mrm_mem)
      (then
        (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off)
                             (if (result i32) (local.get $wide)
                               (then (i32.const 16)) (else (i32.const 8)))))
        (if (global.get $fault) (then (return)))
        (local.set $slo (call $lin_read (local.get $la) (i32.const 8)))
        (if (local.get $wide)
          (then (local.set $shi (call $lin_read (i64.add (local.get $la) (i64.const 8))
                                      (i32.const 8)))))
        (if (global.get $fault) (then (return))))
      (else
        (local.set $slo (i64.load (call $xmm_off (global.get $mrm_rm))))
        (local.set $shi (i64.load (i32.add (call $xmm_off (global.get $mrm_rm))
                                           (i32.const 8))))))

    (block $done
      (if (i32.eq (local.get $op) (i32.const 0x12))
        (then
          (if (i32.eq (global.get $rep) (i32.const 2))          ;; F2: MOVDDUP
            (then (local.set $dlo (local.get $slo))
                  (local.set $dhi (local.get $slo))
                  (br $done)))
          (if (i32.eq (global.get $rep) (i32.const 3))          ;; F3: MOVSLDUP
            (then
              (local.set $dlo (i64.or (i64.and (local.get $slo) (i64.const 0xFFFFFFFF))
                                      (i64.shl (local.get $slo) (i64.const 32))))
              (local.set $dhi (i64.or (i64.and (local.get $shi) (i64.const 0xFFFFFFFF))
                                      (i64.shl (local.get $shi) (i64.const 32))))
              (br $done)))
          ;; MOVLPS from memory, MOVHLPS from a register
          (if (global.get $mrm_mem)
            (then (local.set $dlo (local.get $slo)))
            (else (local.set $dlo (local.get $shi))))
          (br $done)))

      (if (i32.eq (local.get $op) (i32.const 0x16))
        (then
          (if (i32.eq (global.get $rep) (i32.const 3))          ;; F3: MOVSHDUP
            (then
              (local.set $dlo (i64.or (i64.shr_u (local.get $slo) (i64.const 32))
                                      (i64.and (local.get $slo) (i64.const -4294967296))))
              (local.set $dhi (i64.or (i64.shr_u (local.get $shi) (i64.const 32))
                                      (i64.and (local.get $shi) (i64.const -4294967296))))
              (br $done)))
          ;; MOVHPS from memory, MOVLHPS from a register: both fill the high half
          (local.set $dhi (local.get $slo))
          (br $done)))

      (if (i32.eq (local.get $op) (i32.const 0x14))             ;; UNPCKL
        (then
          (if (global.get $op66)
            (then (local.set $dhi (local.get $slo)))            ;; UNPCKLPD
            (else
              (local.set $dhi (i64.or (i64.shr_u (local.get $dlo) (i64.const 32))
                                      (i64.and (local.get $slo) (i64.const -4294967296))))
              (local.set $dlo (i64.or (i64.and (local.get $dlo) (i64.const 0xFFFFFFFF))
                                      (i64.shl (local.get $slo) (i64.const 32))))))
          (br $done)))

      ;; 0F 15 UNPCKH
      (if (global.get $op66)
        (then (local.set $dlo (local.get $dhi))
              (local.set $dhi (local.get $shi)))
        (else
          (local.set $dlo (i64.or (i64.and (local.get $dhi) (i64.const 0xFFFFFFFF))
                                  (i64.shl (local.get $shi) (i64.const 32))))
          (local.set $dhi (i64.or (i64.shr_u (local.get $dhi) (i64.const 32))
                                  (i64.and (local.get $shi) (i64.const -4294967296)))))))

    (i64.store (call $xmm_off (local.get $reg)) (local.get $dlo))
    (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)) (local.get $dhi)))

  ;; ---- packed integer operations ------------------------------------------
  ;;  Compares, unpacks, shuffles and packed add/subtract.  These carry no
  ;;  rounding behaviour, so they are exact.  Operands are staged in scratch at
  ;;  0x6400 (destination) and 0x6420 (source) and worked on element by element,
  ;;  which keeps the code small; they are not on any hot path.
  (func $h0f_psimd (param $op i32)
    (local $reg i32) (local $la i64) (local $i i32) (local $n i32)
    (local $imm i32) (local $mask i32) (local $eq i32)
    (if (call $is_mmx (local.get $op)) (then (call $h_mmx (local.get $op)) (return)))
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)
    (local.set $reg (global.get $mrm_reg))

    ;; 0F 2B / 0F E7 / 0F D6 are stores
    (if (i32.or (i32.eq (local.get $op) (i32.const 0x2B))
                (i32.eq (local.get $op) (i32.const 0xE7)))
      (then
        (if (i32.eqz (global.get $mrm_mem)) (then (call $raise_ud) (return)))
        (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off) (i32.const 16)))
        (if (global.get $fault) (then (return)))
        (call $lin_write (local.get $la) (i32.const 8)
              (i64.load (call $xmm_off (local.get $reg))))
        (call $lin_write (i64.add (local.get $la) (i64.const 8)) (i32.const 8)
              (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))))
        (return)))
    (if (i32.eq (local.get $op) (i32.const 0xD6))            ;; MOVQ xmm/m64, xmm
      (then
        (if (global.get $mrm_mem)
          (then (call $seg_write (global.get $mrm_seg) (call $mrm_off) (i32.const 8)
                      (i64.load (call $xmm_off (local.get $reg)))))
          (else
            (i64.store (call $xmm_off (global.get $mrm_rm))
                       (i64.load (call $xmm_off (local.get $reg))))
            (i64.store (i32.add (call $xmm_off (global.get $mrm_rm)) (i32.const 8))
                       (i64.const 0))))
        (return)))

    ;; PSHUFD / PSHUFLW / PSHUFHW: the selector is fetched before the operand
    ;; is read.  A RIP-relative address is resolved against RIP as it stands,
    ;; so reading first took the sixteen bytes one byte early -- and gcc puts
    ;; shuffled constants in exactly that form.
    (if (i32.eq (local.get $op) (i32.const 0x70))
      (then (local.set $imm (call $fetch8))
            (if (global.get $fault) (then (return)))))

    ;; stage destination and source
    (i64.store (i32.const 0x6400) (i64.load (call $xmm_off (local.get $reg))))
    (i64.store (i32.const 0x6408) (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))))
    (if (global.get $mrm_mem)
      (then
        (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off) (i32.const 16)))
        (if (global.get $fault) (then (return)))
        (i64.store (i32.const 0x6420) (call $lin_read (local.get $la) (i32.const 8)))
        (i64.store (i32.const 0x6428)
                   (call $lin_read (i64.add (local.get $la) (i64.const 8)) (i32.const 8)))
        (if (global.get $fault) (then (return))))
      (else
        (i64.store (i32.const 0x6420) (i64.load (call $xmm_off (global.get $mrm_rm))))
        (i64.store (i32.const 0x6428)
                   (i64.load (i32.add (call $xmm_off (global.get $mrm_rm)) (i32.const 8))))))

    ;; PSHUFD / PSHUFLW / PSHUFHW take an immediate selector
    (if (i32.eq (local.get $op) (i32.const 0x70))
      (then
        (local.set $i (i32.const 0))
        (block $pe (loop $pl
          (br_if $pe (i32.ge_u (local.get $i) (i32.const 4)))
          (if (global.get $op66)                              ;; PSHUFD
            (then (i32.store (i32.add (i32.const 0x6400) (i32.shl (local.get $i) (i32.const 2)))
                    (i32.load (i32.add (i32.const 0x6420)
                      (i32.shl (i32.and (i32.shr_u (local.get $imm)
                                                   (i32.shl (local.get $i) (i32.const 1)))
                                        (i32.const 3)) (i32.const 2))))))
            (else
              ;; PSHUFLW (F2) shuffles the low four words, PSHUFHW (F3) the high
              (if (i32.eq (global.get $rep) (i32.const 3))
                (then
                  (i64.store (i32.const 0x6400) (i64.load (i32.const 0x6420)))
                  (i32.store16 (i32.add (i32.const 0x6408) (i32.shl (local.get $i) (i32.const 1)))
                    (i32.load16_u (i32.add (i32.const 0x6428)
                      (i32.shl (i32.and (i32.shr_u (local.get $imm)
                                                   (i32.shl (local.get $i) (i32.const 1)))
                                        (i32.const 3)) (i32.const 1))))))
                (else
                  (i64.store (i32.const 0x6408) (i64.load (i32.const 0x6428)))
                  (i32.store16 (i32.add (i32.const 0x6400) (i32.shl (local.get $i) (i32.const 1)))
                    (i32.load16_u (i32.add (i32.const 0x6420)
                      (i32.shl (i32.and (i32.shr_u (local.get $imm)
                                                   (i32.shl (local.get $i) (i32.const 1)))
                                        (i32.const 3)) (i32.const 1)))))))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $pl)))
        (call $psimd_writeback (local.get $reg))
        (return)))

    ;; PMOVMSKB gathers the top bit of each byte into a general register
    (if (i32.eq (local.get $op) (i32.const 0xD7))
      (then
        (local.set $mask (i32.const 0))
        (local.set $i (i32.const 0))
        (block $me (loop $ml
          (br_if $me (i32.ge_u (local.get $i) (i32.const 16)))
          (local.set $mask (i32.or (local.get $mask)
            (i32.shl (i32.shr_u (i32.load8_u (i32.add (i32.const 0x6420) (local.get $i)))
                                (i32.const 7))
                     (local.get $i))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $ml)))
        (call $setregN (local.get $reg) (i32.const 4) (i64.extend_i32_u (local.get $mask)))
        (return)))

    ;; bitwise operations act on the whole 128 bits
    (if (i32.eq (local.get $op) (i32.const 0xDB))
      (then (call $psimd_bits (i32.const 0)) (call $psimd_writeback (local.get $reg)) (return)))
    (if (i32.eq (local.get $op) (i32.const 0xDF))
      (then (call $psimd_bits (i32.const 1)) (call $psimd_writeback (local.get $reg)) (return)))
    (if (i32.eq (local.get $op) (i32.const 0xEB))
      (then (call $psimd_bits (i32.const 2)) (call $psimd_writeback (local.get $reg)) (return)))
    (if (i32.eq (local.get $op) (i32.const 0xEF))
      (then (call $psimd_bits (i32.const 3)) (call $psimd_writeback (local.get $reg)) (return)))

    (call $psimd_elem (local.get $op))
    (call $psimd_writeback (local.get $reg)))

  (func $psimd_writeback (param $reg i32)
    (i64.store (call $xmm_off (local.get $reg)) (i64.load (i32.const 0x6400)))
    (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))
               (i64.load (i32.const 0x6408))))

  ;; 0 AND, 1 ANDN, 2 OR, 3 XOR
  ;; The destination is staged at 0x6400 and the source at 0x6420.  Both halves
  ;; are computed outright, so there is nothing to clear first -- and clearing
  ;; 0x6400 would throw the destination away before it is read.
  (func $psimd_bits (param $how i32)
    (i64.store (i32.const 0x6400) (call $psimd_bitop (local.get $how)
      (i64.load (i32.const 0x6400)) (i64.load (i32.const 0x6420))))
    (i64.store (i32.const 0x6408) (call $psimd_bitop (local.get $how)
      (i64.load (i32.const 0x6408)) (i64.load (i32.const 0x6428)))))

  (func $psimd_bitop (param $how i32) (param $d i64) (param $s i64) (result i64)
    (block $x (block $o (block $n (block $a
      (br_table $a $n $o $x (local.get $how)))
      (return (i64.and (local.get $d) (local.get $s))))
      (return (i64.and (i64.xor (local.get $d) (i64.const -1)) (local.get $s))))
      (return (i64.or (local.get $d) (local.get $s))))
    (i64.xor (local.get $d) (local.get $s)))

  ;; element-wise compares, unpacks and packed add/subtract
  (func $psimd_elem (param $op i32)
    (local $i i32) (local $w i32) (local $lane i32)
    ;; PADDQ (0F D4) and PSUBQ (0F FB) work on 64-bit lanes.  The byte, word and
    ;; dword helpers below load and store i32, so they cannot express those: a
    ;; carry or borrow would never cross the halfway point, turning PSUBQ into
    ;; two independent 32-bit subtracts.
    (if (i32.or (i32.eq (local.get $op) (i32.const 0xD4))
                (i32.eq (local.get $op) (i32.const 0xFB)))
      (then
        (if (i32.eq (local.get $op) (i32.const 0xD4))
          (then
            (i64.store (i32.const 0x6400)
              (i64.add (i64.load (i32.const 0x6400)) (i64.load (i32.const 0x6420))))
            (i64.store (i32.const 0x6408)
              (i64.add (i64.load (i32.const 0x6408)) (i64.load (i32.const 0x6428)))))
          (else
            (i64.store (i32.const 0x6400)
              (i64.sub (i64.load (i32.const 0x6400)) (i64.load (i32.const 0x6420))))
            (i64.store (i32.const 0x6408)
              (i64.sub (i64.load (i32.const 0x6408)) (i64.load (i32.const 0x6428))))))
        (return)))
    ;; PCMPEQB / PCMPEQW / PCMPEQD
    (if (i32.and (i32.ge_u (local.get $op) (i32.const 0x74))
                 (i32.le_u (local.get $op) (i32.const 0x76)))
      (then
        (local.set $w (i32.shl (i32.const 1) (i32.sub (local.get $op) (i32.const 0x74))))
        (local.set $i (i32.const 0))
        (block $e (loop $l
          (br_if $e (i32.ge_u (local.get $i) (i32.const 16)))
          (call $psimd_put (local.get $i) (local.get $w)
            (if (result i32) (i32.eq (call $psimd_get (i32.const 0x6400) (local.get $i) (local.get $w))
                                     (call $psimd_get (i32.const 0x6420) (local.get $i) (local.get $w)))
              (then (i32.const -1)) (else (i32.const 0))))
          (local.set $i (i32.add (local.get $i) (local.get $w)))
          (br $l)))
        (return)))
    ;; PCMPGTB / PCMPGTW / PCMPGTD, signed
    (if (i32.and (i32.ge_u (local.get $op) (i32.const 0x64))
                 (i32.le_u (local.get $op) (i32.const 0x66)))
      (then
        (local.set $w (i32.shl (i32.const 1) (i32.sub (local.get $op) (i32.const 0x64))))
        (local.set $i (i32.const 0))
        (block $eg (loop $lg
          (br_if $eg (i32.ge_u (local.get $i) (i32.const 16)))
          (call $psimd_put (local.get $i) (local.get $w)
            (if (result i32) (i64.gt_s
                  (call $lane_sext (i64.extend_i32_u
                    (call $psimd_get (i32.const 0x6400) (local.get $i) (local.get $w)))
                    (local.get $w))
                  (call $lane_sext (i64.extend_i32_u
                    (call $psimd_get (i32.const 0x6420) (local.get $i) (local.get $w)))
                    (local.get $w)))
              (then (i32.const -1)) (else (i32.const 0))))
          (local.set $i (i32.add (local.get $i) (local.get $w)))
          (br $lg)))
        (return)))
    ;; PADD / PSUB on bytes, words and dwords
    (if (i32.and (i32.ge_u (local.get $op) (i32.const 0xF8))
                 (i32.le_u (local.get $op) (i32.const 0xFE)))
      (then
        (local.set $w (i32.shl (i32.const 1)
          (i32.and (i32.sub (local.get $op) (i32.const 0xF8)) (i32.const 3))))
        (if (i32.gt_u (local.get $w) (i32.const 4)) (then (local.set $w (i32.const 4))))
        (local.set $i (i32.const 0))
        (block $e2 (loop $l2
          (br_if $e2 (i32.ge_u (local.get $i) (i32.const 16)))
          (call $psimd_put (local.get $i) (local.get $w)
            (if (result i32) (i32.lt_u (local.get $op) (i32.const 0xFC))
              (then (i32.sub (call $psimd_get (i32.const 0x6400) (local.get $i) (local.get $w))
                             (call $psimd_get (i32.const 0x6420) (local.get $i) (local.get $w))))
              (else (i32.add (call $psimd_get (i32.const 0x6400) (local.get $i) (local.get $w))
                             (call $psimd_get (i32.const 0x6420) (local.get $i) (local.get $w))))))
          (local.set $i (i32.add (local.get $i) (local.get $w)))
          (br $l2)))
        (return)))
    (if (call $psimd_more (local.get $op)) (then (return)))
    ;; PUNPCK: low half for 0x60-0x62 and 0x6C, high half for 0x68-0x6A and 0x6D
    (call $psimd_unpack (local.get $op)))

  ;; ---- the rest of the SSE2 integer set ------------------------------------
  ;;  Saturating add and subtract, min and max, average, the multiplies, the
  ;;  packs, PMADDWD and PSADBW.  glibc's SSE2 string functions are built from
  ;;  these -- its strlen is PMINUB and PCMPEQB -- so without them a guest dies
  ;;  of SIGILL in its first process, and Debian's init took the kernel with it.
  ;;  Returns 1 when the opcode was one of these.  The MMX forms arrive staged
  ;;  by $h_mmx, which sets $mmx_lanes; any other unprefixed form is #UD.
  (func $psimd_more (param $op i32) (result i32)
    (local $w i32) (local $i i32) (local $h i32) (local $sum i32) (local $v i32)
    (local.set $w (call $psimd_lane_width (local.get $op)))
    (if (i32.eqz (i32.or (i32.ne (local.get $w) (i32.const 0))
                         (call $psimd_is_more (local.get $op))))
      (then (return (i32.const 0))))
    (if (i32.eqz (i32.or (global.get $op66) (global.get $mmx_lanes)))
      (then (call $raise_ud) (return (i32.const 1))))

    ;; lane by lane, bytes or words
    (if (local.get $w)
      (then
        (local.set $i (i32.const 0))
        (block $e (loop $l
          (br_if $e (i32.ge_u (local.get $i) (i32.const 16)))
          (call $psimd_put (local.get $i) (local.get $w)
            (call $psimd_lane (local.get $op) (local.get $w)
              (call $psimd_get (i32.const 0x6400) (local.get $i) (local.get $w))
              (call $psimd_get (i32.const 0x6420) (local.get $i) (local.get $w))))
          (local.set $i (i32.add (local.get $i) (local.get $w)))
          (br $l)))
        (return (i32.const 1))))

    ;; PACKSSWB / PACKUSWB / PACKSSDW: the destination's elements narrow into
    ;; the low half of the result and the source's into the high half
    (if (i32.eq (local.get $op) (i32.const 0x6B))
      (then
        (local.set $i (i32.const 0))
        (block $e (loop $l
          (br_if $e (i32.ge_u (local.get $i) (i32.const 4)))
          (i32.store16 (i32.add (i32.const 0x6440) (i32.shl (local.get $i) (i32.const 1)))
            (call $clamp (i32.load (i32.add (i32.const 0x6400) (i32.shl (local.get $i) (i32.const 2))))
                         (i32.const -0x8000) (i32.const 0x7FFF)))
          (i32.store16 (i32.add (i32.const 0x6448) (i32.shl (local.get $i) (i32.const 1)))
            (call $clamp (i32.load (i32.add (i32.const 0x6420) (i32.shl (local.get $i) (i32.const 2))))
                         (i32.const -0x8000) (i32.const 0x7FFF)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (call $psimd_from_6440)
        (return (i32.const 1))))
    (if (i32.or (i32.eq (local.get $op) (i32.const 0x63)) (i32.eq (local.get $op) (i32.const 0x67)))
      (then
        (local.set $i (i32.const 0))
        (block $e (loop $l
          (br_if $e (i32.ge_u (local.get $i) (i32.const 8)))
          (i32.store8 (i32.add (i32.const 0x6440) (local.get $i))
            (call $psimd_narrow (local.get $op)
              (i32.load16_s (i32.add (i32.const 0x6400) (i32.shl (local.get $i) (i32.const 1))))))
          (i32.store8 (i32.add (i32.const 0x6448) (local.get $i))
            (call $psimd_narrow (local.get $op)
              (i32.load16_s (i32.add (i32.const 0x6420) (i32.shl (local.get $i) (i32.const 1))))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (call $psimd_from_6440)
        (return (i32.const 1))))

    ;; PMULUDQ: the even dwords, multiplied out to full quadwords
    (if (i32.eq (local.get $op) (i32.const 0xF4))
      (then
        (i64.store (i32.const 0x6400)
          (i64.mul (i64.load32_u (i32.const 0x6400)) (i64.load32_u (i32.const 0x6420))))
        (i64.store (i32.const 0x6408)
          (i64.mul (i64.load32_u (i32.const 0x6408)) (i64.load32_u (i32.const 0x6428))))
        (return (i32.const 1))))

    ;; PMADDWD: signed word products, adjacent pairs summed into dwords.  Each
    ;; result reads only its own two words, so it can be written in place.
    (if (i32.eq (local.get $op) (i32.const 0xF5))
      (then
        (local.set $i (i32.const 0))
        (block $e (loop $l
          (br_if $e (i32.ge_u (local.get $i) (i32.const 16)))
          (i32.store (i32.add (i32.const 0x6400) (local.get $i))
            (i32.add
              (i32.mul (i32.load16_s (i32.add (i32.const 0x6400) (local.get $i)))
                       (i32.load16_s (i32.add (i32.const 0x6420) (local.get $i))))
              (i32.mul (i32.load16_s (i32.add (i32.const 0x6402) (local.get $i)))
                       (i32.load16_s (i32.add (i32.const 0x6422) (local.get $i))))))
          (local.set $i (i32.add (local.get $i) (i32.const 4)))
          (br $l)))
        (return (i32.const 1))))

    ;; PSADBW: per eight-byte half, the sum of absolute byte differences, in
    ;; the low word of that half's quadword
    (local.set $h (i32.const 0))
    (block $he (loop $hl
      (br_if $he (i32.ge_u (local.get $h) (i32.const 16)))
      (local.set $sum (i32.const 0))
      (local.set $i (i32.const 0))
      (block $e (loop $l
        (br_if $e (i32.ge_u (local.get $i) (i32.const 8)))
        (local.set $v (i32.sub
          (i32.load8_u (i32.add (i32.add (i32.const 0x6400) (local.get $h)) (local.get $i)))
          (i32.load8_u (i32.add (i32.add (i32.const 0x6420) (local.get $h)) (local.get $i)))))
        (local.set $sum (i32.add (local.get $sum)
          (select (local.get $v) (i32.sub (i32.const 0) (local.get $v))
                  (i32.ge_s (local.get $v) (i32.const 0)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (i64.store (i32.add (i32.const 0x6400) (local.get $h)) (i64.extend_i32_u (local.get $sum)))
      (local.set $h (i32.add (local.get $h) (i32.const 8)))
      (br $hl)))
    (i32.const 1))

  ;; Lane width of the lane-wise operations: 1 for bytes, 2 for words, else 0.
  (func $psimd_lane_width (param $op i32) (result i32)
    (block $b (block $w
      (br_if $b (i32.eq (local.get $op) (i32.const 0xD8)))    ;; PSUBUSB
      (br_if $b (i32.eq (local.get $op) (i32.const 0xDA)))    ;; PMINUB
      (br_if $b (i32.eq (local.get $op) (i32.const 0xDC)))    ;; PADDUSB
      (br_if $b (i32.eq (local.get $op) (i32.const 0xDE)))    ;; PMAXUB
      (br_if $b (i32.eq (local.get $op) (i32.const 0xE0)))    ;; PAVGB
      (br_if $b (i32.eq (local.get $op) (i32.const 0xE8)))    ;; PSUBSB
      (br_if $b (i32.eq (local.get $op) (i32.const 0xEC)))    ;; PADDSB
      (br_if $w (i32.eq (local.get $op) (i32.const 0xD5)))    ;; PMULLW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xD9)))    ;; PSUBUSW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xDD)))    ;; PADDUSW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xE3)))    ;; PAVGW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xE4)))    ;; PMULHUW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xE5)))    ;; PMULHW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xE9)))    ;; PSUBSW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xEA)))    ;; PMINSW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xED)))    ;; PADDSW
      (br_if $w (i32.eq (local.get $op) (i32.const 0xEE)))    ;; PMAXSW
      (return (i32.const 0)))
      (return (i32.const 2)))
    (i32.const 1))

  ;; the other operations $psimd_more handles
  (func $psimd_is_more (param $op i32) (result i32)
    (i32.or (i32.or (i32.eq (local.get $op) (i32.const 0x63))
                    (i32.eq (local.get $op) (i32.const 0x67)))
      (i32.or (i32.or (i32.eq (local.get $op) (i32.const 0x6B))
                      (i32.eq (local.get $op) (i32.const 0xF4)))
              (i32.or (i32.eq (local.get $op) (i32.const 0xF5))
                      (i32.eq (local.get $op) (i32.const 0xF6))))))

  ;; One lane of a lane-wise operation.  a and b arrive zero-extended; the
  ;; signed operations sign-extend them here.
  (func $psimd_lane (param $op i32) (param $w i32) (param $a i32) (param $b i32) (result i32)
    (local $max i32) (local $sa i32) (local $sb i32) (local $smax i32)
    (local.set $max (select (i32.const 0xFF) (i32.const 0xFFFF) (i32.eq (local.get $w) (i32.const 1))))
    (local.set $smax (i32.shr_u (local.get $max) (i32.const 1)))
    (local.set $sa (select (i32.extend8_s (local.get $a)) (i32.extend16_s (local.get $a))
                           (i32.eq (local.get $w) (i32.const 1))))
    (local.set $sb (select (i32.extend8_s (local.get $b)) (i32.extend16_s (local.get $b))
                           (i32.eq (local.get $w) (i32.const 1))))
    (block $r (result i32)
      (if (i32.eq (local.get $op) (i32.const 0xD5))                       ;; PMULLW
        (then (br $r (i32.mul (local.get $a) (local.get $b)))))
      (if (i32.eq (local.get $op) (i32.const 0xE4))                       ;; PMULHUW
        (then (br $r (i32.shr_u (i32.mul (local.get $a) (local.get $b)) (i32.const 16)))))
      (if (i32.eq (local.get $op) (i32.const 0xE5))                       ;; PMULHW
        (then (br $r (i32.shr_s (i32.mul (local.get $sa) (local.get $sb)) (i32.const 16)))))
      (if (i32.or (i32.eq (local.get $op) (i32.const 0xD8)) (i32.eq (local.get $op) (i32.const 0xD9)))
        (then (br $r (select (i32.sub (local.get $a) (local.get $b)) (i32.const 0)   ;; PSUBUS
                             (i32.ge_u (local.get $a) (local.get $b))))))
      (if (i32.or (i32.eq (local.get $op) (i32.const 0xDC)) (i32.eq (local.get $op) (i32.const 0xDD)))
        (then (br $r (call $clamp (i32.add (local.get $a) (local.get $b))         ;; PADDUS
                                  (i32.const 0) (local.get $max)))))
      (if (i32.or (i32.eq (local.get $op) (i32.const 0xE8)) (i32.eq (local.get $op) (i32.const 0xE9)))
        (then (br $r (call $clamp (i32.sub (local.get $sa) (local.get $sb))       ;; PSUBS
                                  (i32.sub (i32.const -1) (local.get $smax)) (local.get $smax)))))
      (if (i32.or (i32.eq (local.get $op) (i32.const 0xEC)) (i32.eq (local.get $op) (i32.const 0xED)))
        (then (br $r (call $clamp (i32.add (local.get $sa) (local.get $sb))       ;; PADDS
                                  (i32.sub (i32.const -1) (local.get $smax)) (local.get $smax)))))
      (if (i32.eq (local.get $op) (i32.const 0xDA))                       ;; PMINUB
        (then (br $r (select (local.get $a) (local.get $b) (i32.lt_u (local.get $a) (local.get $b))))))
      (if (i32.eq (local.get $op) (i32.const 0xDE))                       ;; PMAXUB
        (then (br $r (select (local.get $a) (local.get $b) (i32.gt_u (local.get $a) (local.get $b))))))
      (if (i32.eq (local.get $op) (i32.const 0xEA))                       ;; PMINSW
        (then (br $r (select (local.get $a) (local.get $b) (i32.lt_s (local.get $sa) (local.get $sb))))))
      (if (i32.eq (local.get $op) (i32.const 0xEE))                       ;; PMAXSW
        (then (br $r (select (local.get $a) (local.get $b) (i32.gt_s (local.get $sa) (local.get $sb))))))
      ;; PAVGB / PAVGW, rounding up
      (i32.shr_u (i32.add (i32.add (local.get $a) (local.get $b)) (i32.const 1)) (i32.const 1))))

  (func $clamp (param $v i32) (param $lo i32) (param $hi i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $v) (local.get $lo))
      (then (local.get $lo))
      (else (if (result i32) (i32.gt_s (local.get $v) (local.get $hi))
              (then (local.get $hi)) (else (local.get $v))))))

  ;; a signed word narrowed to a byte: signed for PACKSSWB, unsigned for PACKUSWB
  (func $psimd_narrow (param $op i32) (param $v i32) (result i32)
    (if (result i32) (i32.eq (local.get $op) (i32.const 0x63))
      (then (call $clamp (local.get $v) (i32.const -128) (i32.const 127)))
      (else (call $clamp (local.get $v) (i32.const 0) (i32.const 255)))))

  (func $psimd_from_6440
    (i64.store (i32.const 0x6400) (i64.load (i32.const 0x6440)))
    (i64.store (i32.const 0x6408) (i64.load (i32.const 0x6448))))

  ;; ---- PINSRW, PEXTRW, MASKMOVDQU, EMMS, RSQRT, RCP, and the 0F E6 converts --
  ;;  The SSE2 instructions whose operands are not simply two XMM registers.
  (func $h0f_sse2x (param $op i32)
    (local $reg i32) (local $d i32) (local $s i32) (local $imm i32) (local $v i64)
    (local $i i32) (local $t i32) (local $base i64) (local $seg i32) (local $x f32)
    (local $a f64) (local $b f64)
    (if (call $is_mmx (local.get $op)) (then (call $h_mmx (local.get $op)) (return)))
    ;; EMMS ends MMX use by marking every x87 register empty
    (if (i32.eq (local.get $op) (i32.const 0x77))
      (then (if (call $mmx_check)
              (then (i32.store16 (i32.const 0x594) (i32.const 0xFFFF))))
            (return)))
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)
    (local.set $reg (global.get $mrm_reg))
    (local.set $d (call $xmm_off (local.get $reg)))
    (local.set $s (call $xmm_off (global.get $mrm_rm)))
    (block $done
      ;; PINSRW xmm, r32/m16, imm8.  The immediate is fetched before the
      ;; operand, which keeps a RIP-relative address right.
      (if (i32.eq (local.get $op) (i32.const 0xC4))
        (then
          (if (i32.eqz (global.get $op66)) (then (call $raise_ud) (return)))
          (local.set $imm (i32.and (call $fetch8) (i32.const 7)))
          (if (global.get $fault) (then (return)))
          (local.set $v (if (result i64) (global.get $mrm_mem)
            (then (call $seg_read (global.get $mrm_seg) (call $mrm_off) (i32.const 2)))
            (else (call $regN (global.get $mrm_rm) (i32.const 2)))))
          (if (global.get $fault) (then (return)))
          (i32.store16 (i32.add (local.get $d) (i32.shl (local.get $imm) (i32.const 1)))
                       (i32.wrap_i64 (local.get $v)))
          (br $done)))
      ;; PEXTRW r32, xmm, imm8
      (if (i32.eq (local.get $op) (i32.const 0xC5))
        (then
          (if (i32.or (i32.eqz (global.get $op66)) (global.get $mrm_mem))
            (then (call $raise_ud) (return)))
          (local.set $imm (i32.and (call $fetch8) (i32.const 7)))
          (if (global.get $fault) (then (return)))
          (call $setregN (local.get $reg) (i32.const 4) (i64.extend_i32_u
            (i32.load16_u (i32.add (local.get $s) (i32.shl (local.get $imm) (i32.const 1))))))
          (br $done)))
      ;; MASKMOVDQU xmm1, xmm2: the bytes of xmm1 whose byte in xmm2 has its
      ;; top bit set are stored at DS:rDI
      (if (i32.eq (local.get $op) (i32.const 0xF7))
        (then
          (if (i32.or (i32.eqz (global.get $op66)) (global.get $mrm_mem))
            (then (call $raise_ud) (return)))
          (local.set $seg (if (result i32) (i32.eq (global.get $segovr) (i32.const -1))
                            (then (i32.const 3)) (else (global.get $segovr))))
          (local.set $base (call $regN (i32.const 7) (global.get $addrsize)))
          (local.set $i (i32.const 0))
          (block $e (loop $l
            (br_if $e (i32.ge_u (local.get $i) (i32.const 16)))
            (if (i32.and (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 0x80))
              (then
                (call $seg_write (local.get $seg)
                  (call $trunc (i64.add (local.get $base) (i64.extend_i32_u (local.get $i)))
                               (global.get $addrsize))
                  (i32.const 1)
                  (i64.extend_i32_u (i32.load8_u (i32.add (local.get $d) (local.get $i)))))
                (if (global.get $fault) (then (return)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $l)))
          (br $done)))
      ;; RSQRTPS/SS and RCPPS/SS.  Hardware gives a 12-bit approximation; the
      ;; exact value is within every bound the manual allows.
      (if (i32.or (i32.eq (local.get $op) (i32.const 0x52)) (i32.eq (local.get $op) (i32.const 0x53)))
        (then
          (local.set $t (call $ssef_type))
          (if (i32.and (i32.ne (local.get $t) (i32.const 0)) (i32.ne (local.get $t) (i32.const 2)))
            (then (call $raise_ud) (return)))
          (call $ssef_src (call $ssef_width (local.get $t)))
          (if (global.get $fault) (then (return)))
          (local.set $i (i32.const 0))
          (block $e (loop $l
            (br_if $e (i32.ge_u (local.get $i)
                                (select (i32.const 4) (i32.const 16) (i32.eq (local.get $t) (i32.const 2)))))
            (local.set $x (f32.load (i32.add (i32.const 0x6420) (local.get $i))))
            (f32.store (i32.add (local.get $d) (local.get $i))
              (f32.div (f32.const 1)
                (if (result f32) (i32.eq (local.get $op) (i32.const 0x52))
                  (then (f32.sqrt (local.get $x))) (else (local.get $x)))))
            (local.set $i (i32.add (local.get $i) (i32.const 4)))
            (br $l)))
          (br $done)))
      ;; 0F E6: CVTDQ2PD (F3), CVTTPD2DQ (66), CVTPD2DQ (F2)
      (if (i32.eq (local.get $op) (i32.const 0xE6))
        (then
          (local.set $t (call $ssef_type))
          (if (i32.eq (local.get $t) (i32.const 2))                  ;; CVTDQ2PD
            (then
              (call $ssef_src (i32.const 8))
              (if (global.get $fault) (then (return)))
              (f64.store (local.get $d) (f64.convert_i32_s (i32.load (i32.const 0x6420))))
              (f64.store (i32.add (local.get $d) (i32.const 8))
                         (f64.convert_i32_s (i32.load (i32.const 0x6424))))
              (br $done)))
          (if (i32.eqz (i32.or (i32.eq (local.get $t) (i32.const 1)) (i32.eq (local.get $t) (i32.const 3))))
            (then (call $raise_ud) (return)))
          (call $ssef_src (i32.const 16))
          (if (global.get $fault) (then (return)))
          (local.set $a (f64.load (i32.const 0x6420)))
          (local.set $b (f64.load (i32.const 0x6428)))
          (if (i32.eq (local.get $t) (i32.const 3))                  ;; CVTPD2DQ rounds
            (then (local.set $a (f64.nearest (local.get $a)))
                  (local.set $b (f64.nearest (local.get $b)))))
          (i32.store (local.get $d) (call $sse_f64_i32 (local.get $a)))
          (i32.store (i32.add (local.get $d) (i32.const 4)) (call $sse_f64_i32 (local.get $b)))
          (i64.store (i32.add (local.get $d) (i32.const 8)) (i64.const 0))
          (br $done)))
      (call $raise_ud)))

  (func $psimd_get (param $base i32) (param $off i32) (param $w i32) (result i32)
    (block $d (result i32)
      (if (i32.eq (local.get $w) (i32.const 1))
        (then (br $d (i32.load8_u (i32.add (local.get $base) (local.get $off))))))
      (if (i32.eq (local.get $w) (i32.const 2))
        (then (br $d (i32.load16_u (i32.add (local.get $base) (local.get $off))))))
      (i32.load (i32.add (local.get $base) (local.get $off)))))

  (func $psimd_put (param $off i32) (param $w i32) (param $v i32)
    (block $d
      (if (i32.eq (local.get $w) (i32.const 1))
        (then (i32.store8 (i32.add (i32.const 0x6400) (local.get $off)) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $w) (i32.const 2))
        (then (i32.store16 (i32.add (i32.const 0x6400) (local.get $off)) (local.get $v)) (br $d)))
      (i32.store (i32.add (i32.const 0x6400) (local.get $off)) (local.get $v))))

  (func $psimd_unpack (param $op i32)
    (local $w i32) (local $high i32) (local $i i32) (local $src i32) (local $out i32)
    (local.set $high (i32.or (i32.and (i32.ge_u (local.get $op) (i32.const 0x68))
                                      (i32.le_u (local.get $op) (i32.const 0x6A)))
                             (i32.eq (local.get $op) (i32.const 0x6D))))
    (block $wd
      (if (i32.or (i32.eq (local.get $op) (i32.const 0x6C))
                  (i32.eq (local.get $op) (i32.const 0x6D)))
        (then (local.set $w (i32.const 8)) (br $wd)))
      (local.set $w (i32.shl (i32.const 1)
        (i32.and (i32.sub (local.get $op) (i32.const 0x60)) (i32.const 7))))
      (if (i32.gt_u (local.get $w) (i32.const 4)) (then (local.set $w (i32.const 4)))))
    ;; interleave from the chosen half into a staging area, then copy back
    (local.set $src (if (result i32) (local.get $high) (then (i32.const 8)) (else (i32.const 0))))
    (local.set $i (i32.const 0))
    (local.set $out (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $out) (i32.const 16)))
      (call $psimd_copy (i32.add (i32.const 0x6440) (local.get $out))
            (i32.add (i32.add (i32.const 0x6400) (local.get $src)) (local.get $i))
            (local.get $w))
      (call $psimd_copy (i32.add (i32.add (i32.const 0x6440) (local.get $out)) (local.get $w))
            (i32.add (i32.add (i32.const 0x6420) (local.get $src)) (local.get $i))
            (local.get $w))
      (local.set $out (i32.add (local.get $out) (i32.shl (local.get $w) (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (local.get $w)))
      (br $l)))
    (i64.store (i32.const 0x6400) (i64.load (i32.const 0x6440)))
    (i64.store (i32.const 0x6408) (i64.load (i32.const 0x6448))))

  (func $psimd_copy (param $dst i32) (param $src i32) (param $n i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (local.get $n)))
      (i32.store8 (i32.add (local.get $dst) (local.get $i))
                  (i32.load8_u (i32.add (local.get $src) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))

  ;; ---- packed shifts -------------------------------------------------------
  ;;  0F 71/72/73 shift by an immediate, with the ModRM reg field selecting the
  ;;  operation and rm naming the register; 0F D1..F3 take the count from a
  ;;  second register.  PSRLDQ and PSLLDQ shift the whole 128 bits by whole
  ;;  bytes rather than per lane.
  (func $h0f_pshift (param $op i32)
    (local $sub i32) (local $cnt i32) (local $reg i32) (local $w i32) (local $dir i32)
    (local $lo i64) (local $hi i64) (local $i i32) (local $la i64)
    (if (call $is_mmx (local.get $op)) (then (call $h_mmx (local.get $op)) (return)))
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)

    (if (i32.le_u (local.get $op) (i32.const 0x73))
      (then
        ;; immediate form: destination is the rm register
        (local.set $sub (global.get $mrm_ext))
        (local.set $reg (global.get $mrm_rm))
        (local.set $cnt (call $fetch8))
        (if (global.get $fault) (then (return)))
        (local.set $w (i32.shl (i32.const 1) (i32.sub (local.get $op) (i32.const 0x70))))
        (block $d
          (if (i32.eq (local.get $sub) (i32.const 2)) (then (local.set $dir (i32.const 0)) (br $d)))
          (if (i32.eq (local.get $sub) (i32.const 4)) (then (local.set $dir (i32.const 1)) (br $d)))
          (if (i32.eq (local.get $sub) (i32.const 6)) (then (local.set $dir (i32.const 2)) (br $d)))
          (if (i32.eq (local.get $sub) (i32.const 3)) (then (local.set $dir (i32.const 3)) (br $d)))
          (if (i32.eq (local.get $sub) (i32.const 7)) (then (local.set $dir (i32.const 4)) (br $d)))
          (call $raise_ud)
          (return)))
      (else
        ;; register form: destination is reg, count comes from the operand
        (local.set $reg (global.get $mrm_reg))
        (if (global.get $mrm_mem)
          (then
            (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off) (i32.const 16)))
            (if (global.get $fault) (then (return)))
            (local.set $lo (call $lin_read (local.get $la) (i32.const 8)))
            (if (global.get $fault) (then (return))))
          (else (local.set $lo (i64.load (call $xmm_off (global.get $mrm_rm))))))
        (local.set $cnt (if (result i32) (i64.gt_u (local.get $lo) (i64.const 255))
                          (then (i32.const 255)) (else (i32.wrap_i64 (local.get $lo)))))
        (block $d2
          (if (i32.and (i32.ge_u (local.get $op) (i32.const 0xD1))
                       (i32.le_u (local.get $op) (i32.const 0xD3)))
            (then (local.set $dir (i32.const 0))
                  (local.set $w (i32.shl (i32.const 2) (i32.sub (local.get $op) (i32.const 0xD1))))
                  (br $d2)))
          (if (i32.or (i32.eq (local.get $op) (i32.const 0xE1))
                      (i32.eq (local.get $op) (i32.const 0xE2)))
            (then (local.set $dir (i32.const 1))
                  (local.set $w (i32.shl (i32.const 2) (i32.sub (local.get $op) (i32.const 0xE1))))
                  (br $d2)))
          (local.set $dir (i32.const 2))
          (local.set $w (i32.shl (i32.const 2) (i32.sub (local.get $op) (i32.const 0xF1)))))))

    (local.set $lo (i64.load (call $xmm_off (local.get $reg))))
    (local.set $hi (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))))

    ;; whole-register byte shifts
    (if (i32.ge_u (local.get $dir) (i32.const 3))
      (then
        (if (i32.ge_u (local.get $cnt) (i32.const 16))
          (then (local.set $lo (i64.const 0)) (local.set $hi (i64.const 0)))
          (else
            (i64.store (i32.const 0x6400) (local.get $lo))
            (i64.store (i32.const 0x6408) (local.get $hi))
            (i64.store (i32.const 0x6440) (i64.const 0))
            (i64.store (i32.const 0x6448) (i64.const 0))
            (local.set $i (i32.const 0))
            (block $be (loop $bl
              (br_if $be (i32.ge_u (local.get $i) (i32.const 16)))
              (if (i32.eq (local.get $dir) (i32.const 3))     ;; PSRLDQ
                (then (if (i32.lt_u (i32.add (local.get $i) (local.get $cnt)) (i32.const 16))
                        (then (i32.store8 (i32.add (i32.const 0x6440) (local.get $i))
                                (i32.load8_u (i32.add (i32.add (i32.const 0x6400) (local.get $i))
                                                      (local.get $cnt)))))))
                (else                                         ;; PSLLDQ
                  (if (i32.ge_u (local.get $i) (local.get $cnt))
                    (then (i32.store8 (i32.add (i32.const 0x6440) (local.get $i))
                            (i32.load8_u (i32.sub (i32.add (i32.const 0x6400) (local.get $i))
                                                  (local.get $cnt))))))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $bl)))
            (local.set $lo (i64.load (i32.const 0x6440)))
            (local.set $hi (i64.load (i32.const 0x6448)))))
        (i64.store (call $xmm_off (local.get $reg)) (local.get $lo))
        (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)) (local.get $hi))
        (return)))

    ;; per-lane shifts
    (i64.store (i32.const 0x6400) (local.get $lo))
    (i64.store (i32.const 0x6408) (local.get $hi))
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 16)))
      (call $lane_shift (local.get $i) (local.get $w) (local.get $cnt) (local.get $dir))
      (local.set $i (i32.add (local.get $i) (local.get $w)))
      (br $l)))
    (i64.store (call $xmm_off (local.get $reg)) (i64.load (i32.const 0x6400)))
    (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))
               (i64.load (i32.const 0x6408))))

  ;; Shift one lane in the staging area.  A count at or past the lane width
  ;; produces zero, or all sign bits for an arithmetic right shift.
  (func $lane_shift (param $off i32) (param $w i32) (param $cnt i32) (param $dir i32)
    (local $bits i32) (local $v i64) (local $r i64)
    (local.set $bits (i32.shl (local.get $w) (i32.const 3)))
    (local.set $v (call $lane_get (local.get $off) (local.get $w)))
    (if (i32.ge_u (local.get $cnt) (local.get $bits))
      (then
        (if (i32.eq (local.get $dir) (i32.const 1))
          (then (local.set $r (i64.shr_s (call $lane_sext (local.get $v) (local.get $w))
                                         (i64.const 63))))
          (else (local.set $r (i64.const 0)))))
      (else
        (block $d
          (if (i32.eq (local.get $dir) (i32.const 0))
            (then (local.set $r (i64.shr_u (local.get $v) (i64.extend_i32_u (local.get $cnt))))
                  (br $d)))
          (if (i32.eq (local.get $dir) (i32.const 1))
            (then (local.set $r (i64.shr_s (call $lane_sext (local.get $v) (local.get $w))
                                           (i64.extend_i32_u (local.get $cnt))))
                  (br $d)))
          (local.set $r (i64.shl (local.get $v) (i64.extend_i32_u (local.get $cnt)))))))
    (call $lane_put (local.get $off) (local.get $w) (local.get $r)))

  (func $lane_sext (param $v i64) (param $w i32) (result i64)
    (local $sh i64)
    (local.set $sh (i64.extend_i32_u (i32.sub (i32.const 64)
                                      (i32.shl (local.get $w) (i32.const 3)))))
    (i64.shr_s (i64.shl (local.get $v) (local.get $sh)) (local.get $sh)))

  (func $lane_get (param $off i32) (param $w i32) (result i64)
    (block $d (result i64)
      (if (i32.eq (local.get $w) (i32.const 2))
        (then (br $d (i64.extend_i32_u (i32.load16_u (i32.add (i32.const 0x6400) (local.get $off)))))))
      (if (i32.eq (local.get $w) (i32.const 4))
        (then (br $d (i64.extend_i32_u (i32.load (i32.add (i32.const 0x6400) (local.get $off)))))))
      (i64.load (i32.add (i32.const 0x6400) (local.get $off)))))

  (func $lane_put (param $off i32) (param $w i32) (param $v i64)
    (block $d
      (if (i32.eq (local.get $w) (i32.const 2))
        (then (i32.store16 (i32.add (i32.const 0x6400) (local.get $off))
                           (i32.wrap_i64 (local.get $v))) (br $d)))
      (if (i32.eq (local.get $w) (i32.const 4))
        (then (i32.store (i32.add (i32.const 0x6400) (local.get $off))
                         (i32.wrap_i64 (local.get $v))) (br $d)))
      (i64.store (i32.add (i32.const 0x6400) (local.get $off)) (local.get $v))))

  ;; 0F 57 XORPS, 0F 54 ANDPS, 0F 56 ORPS, 0F EF PXOR
  (func $h0f_sse_arith (param $op i32)
    (local $lo i64) (local $hi i64) (local $reg i32) (local $la i64)
    (if (call $is_mmx (local.get $op)) (then (call $h_mmx (local.get $op)) (return)))
    (if (i32.eqz (call $sse_check)) (then (return)))
    (call $decode_modrm)
    (local.set $reg (global.get $mrm_reg))
    (if (global.get $mrm_mem)
      (then
        (local.set $la (call $seg_lin (global.get $mrm_seg) (call $mrm_off) (i32.const 16)))
        (local.set $lo (call $lin_read (local.get $la) (i32.const 8)))
        (local.set $hi (call $lin_read (i64.add (local.get $la) (i64.const 8)) (i32.const 8)))
        (if (global.get $fault) (then (return))))
      (else
        (local.set $lo (i64.load (call $xmm_off (global.get $mrm_rm))))
        (local.set $hi (i64.load (i32.add (call $xmm_off (global.get $mrm_rm)) (i32.const 8))))))
    (block $d
      (if (i32.eq (local.get $op) (i32.const 0x54))
        (then
          (i64.store (call $xmm_off (local.get $reg))
                     (i64.and (i64.load (call $xmm_off (local.get $reg))) (local.get $lo)))
          (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))
                     (i64.and (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)))
                              (local.get $hi)))
          (br $d)))
      (if (i32.eq (local.get $op) (i32.const 0x56))
        (then
          (i64.store (call $xmm_off (local.get $reg))
                     (i64.or (i64.load (call $xmm_off (local.get $reg))) (local.get $lo)))
          (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))
                     (i64.or (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)))
                             (local.get $hi)))
          (br $d)))
      ;; XORPS / XORPD / PXOR
      (i64.store (call $xmm_off (local.get $reg))
                 (i64.xor (i64.load (call $xmm_off (local.get $reg))) (local.get $lo)))
      (i64.store (i32.add (call $xmm_off (local.get $reg)) (i32.const 8))
                 (i64.xor (i64.load (i32.add (call $xmm_off (local.get $reg)) (i32.const 8)))
                          (local.get $hi)))))

  ;; =========================================================================
  ;;  MMX: the integer forms without a 66 prefix, on the eight 64-bit registers
  ;;  that alias the x87 stack.  CPUID offers MMX, so Windows XP uses it -- its
  ;;  win32k blends alpha with PMULLW -- and a missing form there is a bug
  ;;  check.  Worse, the moves without a prefix used to run as XMM moves, so
  ;;  MMX code silently computed on the wrong registers.
  ;;
  ;;  The arithmetic is the SSE2 lane code's: both operands are staged in its
  ;;  scratch area, eight bytes each with the rest zero, and the low eight
  ;;  bytes of the result are the MMX answer.  Packs and the high unpacks pick
  ;;  their elements from different places, which the staging arranges.
  ;; =========================================================================

  ;; The integer opcodes that, with no 66, F2 or F3 prefix, name MMX registers.
  (func $is_mmx (param $op i32) (result i32)
    (if (i32.or (global.get $op66) (global.get $rep)) (then (return (i32.const 0))))
    (block $yes
      (br_if $yes (i32.and (i32.ge_u (local.get $op) (i32.const 0x60))
                           (i32.le_u (local.get $op) (i32.const 0x6B))))
      (br_if $yes (i32.and (i32.ge_u (local.get $op) (i32.const 0x6E))
                           (i32.le_u (local.get $op) (i32.const 0x76))))
      (br_if $yes (i32.or (i32.eq (local.get $op) (i32.const 0x7E))
                          (i32.eq (local.get $op) (i32.const 0x7F))))
      (br_if $yes (i32.or (i32.eq (local.get $op) (i32.const 0xC4))
                          (i32.eq (local.get $op) (i32.const 0xC5))))
      (br_if $yes (i32.and (i32.ge_u (local.get $op) (i32.const 0xD1))
                           (i32.le_u (local.get $op) (i32.const 0xFE))))
      (return (i32.const 0)))
    ;; within D1-FE, D6 and E6 have no MMX form, and F0 is LDDQU
    (i32.eqz (i32.or (i32.eq (local.get $op) (i32.const 0xD6))
                     (i32.or (i32.eq (local.get $op) (i32.const 0xE6))
                             (i32.eq (local.get $op) (i32.const 0xF0))))))

  ;; #UD under CR0.EM, #NM under CR0.TS.  1 when MMX may run.
  (func $mmx_check (result i32)
    (if (i32.wrap_i64 (i64.and (i64.shr_u (call $cr0) (i64.const 2)) (i64.const 1)))
      (then (call $raise_ud) (return (i32.const 0))))
    (if (call $fpu_ts)
      (then (call $raise (i32.const 7) (i64.const 0) (i32.const 0)) (return (i32.const 0))))
    (i32.const 1))

  ;; An operand read as m64 or an MMX register.
  (func $mmx_src (result i64)
    (if (result i64) (global.get $mrm_mem)
      (then (call $seg_read (global.get $mrm_seg) (call $mrm_off) (i32.const 8)))
      (else (call $mm_get (global.get $mrm_rm)))))

  (func $h_mmx (param $op i32)
    (local $reg i32) (local $imm i32) (local $d i64) (local $s i64) (local $v i64)
    (local $i i32) (local $mask i32) (local $w i32) (local $dir i32) (local $cnt i32)
    (local $size i32) (local $seg i32) (local $base i64)
    (if (i32.eqz (call $mmx_check)) (then (return)))
    (call $decode_modrm)
    (local.set $reg (i32.and (global.get $mrm_reg) (i32.const 7)))
    (block $done
      ;; MOVD, or MOVQ with REX.W, to and from a general register or memory
      (if (i32.or (i32.eq (local.get $op) (i32.const 0x6E)) (i32.eq (local.get $op) (i32.const 0x7E)))
        (then
          (local.set $size (select (i32.const 8) (i32.const 4)
                                   (i32.eq (global.get $opsize) (i32.const 8))))
          (if (i32.eq (local.get $op) (i32.const 0x6E))
            (then (local.set $v (call $rm_read (local.get $size)))
                  (if (global.get $fault) (then (return)))
                  (call $mm_set (local.get $reg) (local.get $v)))
            (else (call $rm_write (local.get $size) (call $mm_get (local.get $reg)))
                  (if (global.get $fault) (then (return)))))
          (br $done)))
      ;; MOVQ mm, mm/m64
      (if (i32.eq (local.get $op) (i32.const 0x6F))
        (then (local.set $v (call $mmx_src))
              (if (global.get $fault) (then (return)))
              (call $mm_set (local.get $reg) (local.get $v))
              (br $done)))
      ;; MOVQ mm/m64, mm and MOVNTQ m64, mm
      (if (i32.or (i32.eq (local.get $op) (i32.const 0x7F)) (i32.eq (local.get $op) (i32.const 0xE7)))
        (then
          (if (global.get $mrm_mem)
            (then (call $seg_write (global.get $mrm_seg) (call $mrm_off) (i32.const 8)
                        (call $mm_get (local.get $reg)))
                  (if (global.get $fault) (then (return))))
            (else
              (if (i32.eq (local.get $op) (i32.const 0xE7)) (then (call $raise_ud) (return)))
              (call $mm_set (global.get $mrm_rm) (call $mm_get (local.get $reg)))))
          (br $done)))
      ;; PEXTRW r32, mm, imm8 and PMOVMSKB r32, mm take a register operand only
      (if (i32.or (i32.eq (local.get $op) (i32.const 0xC5)) (i32.eq (local.get $op) (i32.const 0xD7)))
        (then
          (if (global.get $mrm_mem) (then (call $raise_ud) (return)))
          (local.set $s (call $mm_get (global.get $mrm_rm)))
          (if (i32.eq (local.get $op) (i32.const 0xC5))
            (then
              (local.set $imm (call $fetch8))
              (if (global.get $fault) (then (return)))
              (local.set $v (i64.and (i64.shr_u (local.get $s) (i64.extend_i32_u
                              (i32.shl (i32.and (local.get $imm) (i32.const 3)) (i32.const 4))))
                                     (i64.const 0xFFFF))))
            (else
              (local.set $i (i32.const 0))
              (block $me (loop $ml
                (br_if $me (i32.ge_u (local.get $i) (i32.const 8)))
                (local.set $mask (i32.or (local.get $mask)
                  (i32.shl (i32.wrap_i64 (i64.and (i64.shr_u (local.get $s) (i64.extend_i32_u
                                           (i32.add (i32.shl (local.get $i) (i32.const 3)) (i32.const 7))))
                                                  (i64.const 1)))
                           (local.get $i))))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $ml)))
              (local.set $v (i64.extend_i32_u (local.get $mask)))))
          (call $setregN (global.get $mrm_reg) (i32.const 4) (local.get $v))
          (br $done)))
      ;; PINSRW mm, r32/m16, imm8: the immediate comes first, as for PSHUFD,
      ;; so that a RIP-relative operand resolves against the instruction's end
      (if (i32.eq (local.get $op) (i32.const 0xC4))
        (then
          (local.set $imm (i32.shl (i32.and (call $fetch8) (i32.const 3)) (i32.const 4)))
          (if (global.get $fault) (then (return)))
          (local.set $v (if (result i64) (global.get $mrm_mem)
                          (then (call $seg_read (global.get $mrm_seg) (call $mrm_off) (i32.const 2)))
                          (else (i64.extend_i32_u (call $reg16 (global.get $mrm_rm))))))
          (if (global.get $fault) (then (return)))
          (call $mm_set (local.get $reg)
            (i64.or (i64.and (call $mm_get (local.get $reg))
                             (i64.xor (i64.shl (i64.const 0xFFFF) (i64.extend_i32_u (local.get $imm)))
                                      (i64.const -1)))
                    (i64.shl (i64.and (local.get $v) (i64.const 0xFFFF))
                             (i64.extend_i32_u (local.get $imm)))))
          (br $done)))
      ;; MASKMOVQ: the bytes of reg whose byte in rm has its top bit set, to DS:(E)DI
      (if (i32.eq (local.get $op) (i32.const 0xF7))
        (then
          (if (global.get $mrm_mem) (then (call $raise_ud) (return)))
          (local.set $d (call $mm_get (local.get $reg)))
          (local.set $s (call $mm_get (global.get $mrm_rm)))
          (local.set $seg (select (i32.const 3) (global.get $segovr)
                                  (i32.eq (global.get $segovr) (i32.const -1))))
          (local.set $base (call $regN (i32.const 7) (global.get $addrsize)))
          (local.set $i (i32.const 0))
          (block $ke (loop $kl
            (br_if $ke (i32.ge_u (local.get $i) (i32.const 8)))
            (if (i64.ne (i64.and (local.get $s) (i64.shl (i64.const 0x80) (i64.extend_i32_u
                                   (i32.shl (local.get $i) (i32.const 3)))))
                        (i64.const 0))
              (then
                (call $seg_write (local.get $seg)
                      (call $trunc (i64.add (local.get $base) (i64.extend_i32_u (local.get $i)))
                                   (global.get $addrsize))
                      (i32.const 1)
                      (i64.shr_u (local.get $d) (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 3)))))
                (if (global.get $fault) (then (return)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $kl)))
          (br $done)))
      ;; shifts by an immediate: 0F 71-73, /2 right, /4 arithmetic right, /6
      ;; left, on the register in rm.  There are no MMX byte shifts.
      (if (i32.and (i32.ge_u (local.get $op) (i32.const 0x71)) (i32.le_u (local.get $op) (i32.const 0x73)))
        (then
          (if (global.get $mrm_mem) (then (call $raise_ud) (return)))
          (local.set $cnt (call $fetch8))
          (if (global.get $fault) (then (return)))
          (local.set $w (i32.shl (i32.const 1) (i32.sub (local.get $op) (i32.const 0x70))))
          (block $sd
            (if (i32.eq (global.get $mrm_ext) (i32.const 2)) (then (local.set $dir (i32.const 0)) (br $sd)))
            (if (i32.and (i32.eq (global.get $mrm_ext) (i32.const 4))
                         (i32.ne (local.get $op) (i32.const 0x73)))
              (then (local.set $dir (i32.const 1)) (br $sd)))
            (if (i32.eq (global.get $mrm_ext) (i32.const 6)) (then (local.set $dir (i32.const 2)) (br $sd)))
            (call $raise_ud)
            (return))
          (call $mm_set (global.get $mrm_rm)
            (call $mmx_shift (call $mm_get (global.get $mrm_rm)) (local.get $w) (local.get $cnt)
                             (local.get $dir)))
          (br $done)))

      ;; everything else reads reg and an MMX register or m64
      (if (i32.eq (local.get $op) (i32.const 0x70))
        (then (local.set $imm (call $fetch8))
              (if (global.get $fault) (then (return)))))
      (local.set $s (call $mmx_src))
      (if (global.get $fault) (then (return)))
      (local.set $d (call $mm_get (local.get $reg)))

      ;; PSHUFW: each word of the result picked from the source by two bits
      (if (i32.eq (local.get $op) (i32.const 0x70))
        (then
          (local.set $v (i64.const 0))
          (local.set $i (i32.const 0))
          (block $pe (loop $pl
            (br_if $pe (i32.ge_u (local.get $i) (i32.const 4)))
            (local.set $v (i64.or (local.get $v)
              (i64.shl (i64.and (i64.shr_u (local.get $s) (i64.extend_i32_u (i32.shl
                         (i32.and (i32.shr_u (local.get $imm) (i32.shl (local.get $i) (i32.const 1)))
                                  (i32.const 3))
                         (i32.const 4))))
                                (i64.const 0xFFFF))
                       (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 4))))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $pl)))
          (call $mm_set (local.get $reg) (local.get $v))
          (br $done)))

      ;; shifts by a count in the source
      (local.set $dir (i32.const -1))
      (if (i32.and (i32.ge_u (local.get $op) (i32.const 0xD1)) (i32.le_u (local.get $op) (i32.const 0xD3)))
        (then (local.set $dir (i32.const 0))
              (local.set $w (i32.shl (i32.const 2) (i32.sub (local.get $op) (i32.const 0xD1))))))
      (if (i32.or (i32.eq (local.get $op) (i32.const 0xE1)) (i32.eq (local.get $op) (i32.const 0xE2)))
        (then (local.set $dir (i32.const 1))
              (local.set $w (i32.shl (i32.const 2) (i32.sub (local.get $op) (i32.const 0xE1))))))
      (if (i32.and (i32.ge_u (local.get $op) (i32.const 0xF1)) (i32.le_u (local.get $op) (i32.const 0xF3)))
        (then (local.set $dir (i32.const 2))
              (local.set $w (i32.shl (i32.const 2) (i32.sub (local.get $op) (i32.const 0xF1))))))
      (if (i32.ge_s (local.get $dir) (i32.const 0))
        (then
          (call $mm_set (local.get $reg)
            (call $mmx_shift (local.get $d) (local.get $w)
                  (select (i32.const 255) (i32.wrap_i64 (local.get $s))
                          (i64.gt_u (local.get $s) (i64.const 255)))
                  (local.get $dir)))
          (br $done)))

      ;; the bitwise operations
      (if (i32.eq (local.get $op) (i32.const 0xDB))
        (then (call $mm_set (local.get $reg) (i64.and (local.get $d) (local.get $s))) (br $done)))
      (if (i32.eq (local.get $op) (i32.const 0xDF))
        (then (call $mm_set (local.get $reg)
                (i64.and (i64.xor (local.get $d) (i64.const -1)) (local.get $s))) (br $done)))
      (if (i32.eq (local.get $op) (i32.const 0xEB))
        (then (call $mm_set (local.get $reg) (i64.or (local.get $d) (local.get $s))) (br $done)))
      (if (i32.eq (local.get $op) (i32.const 0xEF))
        (then (call $mm_set (local.get $reg) (i64.xor (local.get $d) (local.get $s))) (br $done)))

      ;; the rest through the SSE2 lane code
      (i64.store (i32.const 0x6400) (local.get $d))
      (i64.store (i32.const 0x6408) (i64.const 0))
      (i64.store (i32.const 0x6420) (local.get $s))
      (i64.store (i32.const 0x6428) (i64.const 0))
      ;; the packs narrow the destination's elements, then the source's, into
      ;; one register: with both in the destination the low eight bytes are it
      (if (i32.or (i32.or (i32.eq (local.get $op) (i32.const 0x63)) (i32.eq (local.get $op) (i32.const 0x67)))
                  (i32.eq (local.get $op) (i32.const 0x6B)))
        (then (i64.store (i32.const 0x6408) (local.get $s))))
      ;; the high unpacks interleave the upper halves, which the 128-bit code
      ;; finds at bytes 8-15
      (if (i32.and (i32.ge_u (local.get $op) (i32.const 0x68)) (i32.le_u (local.get $op) (i32.const 0x6A)))
        (then
          (i64.store (i32.const 0x6400) (i64.const 0))
          (i64.store (i32.const 0x6404) (local.get $d))
          (i64.store (i32.const 0x6420) (i64.const 0))
          (i64.store (i32.const 0x6424) (local.get $s))))
      (global.set $mmx_lanes (i32.const 1))
      (call $psimd_elem (local.get $op))
      (global.set $mmx_lanes (i32.const 0))
      (if (global.get $fault) (then (return)))
      (call $mm_set (local.get $reg) (i64.load (i32.const 0x6400))))
    (call $mmx_enter))

  ;; Shift each lane of a 64-bit value: dir 0 logical right, 1 arithmetic
  ;; right, 2 left, through the same lane code as the XMM shifts.
  (func $mmx_shift (param $v i64) (param $w i32) (param $cnt i32) (param $dir i32) (result i64)
    (local $i i32)
    (i64.store (i32.const 0x6400) (local.get $v))
    (local.set $i (i32.const 0))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 8)))
      (call $lane_shift (local.get $i) (local.get $w) (local.get $cnt) (local.get $dir))
      (local.set $i (i32.add (local.get $i) (local.get $w)))
      (br $l)))
    (i64.load (i32.const 0x6400)))

