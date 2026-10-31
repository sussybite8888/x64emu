  ;; =========================================================================
  ;;  Part 30: descriptors, segment loading, control transfers, interrupts
  ;; =========================================================================

  ;; ---- descriptor field extraction ---------------------------------------
  (func $desc_base (param $d i64) (result i64)
    (i64.or (i64.and (i64.shr_u (local.get $d) (i64.const 16)) (i64.const 0x00FFFFFF))
            (i64.and (i64.shr_u (local.get $d) (i64.const 32)) (i64.const 0xFF000000))))

  (func $desc_limit (param $d i64) (result i32)
    (local $lim i32)
    (local.set $lim (i32.or
      (i32.wrap_i64 (i64.and (local.get $d) (i64.const 0xFFFF)))
      (i32.wrap_i64 (i64.and (i64.shr_u (local.get $d) (i64.const 32)) (i64.const 0x000F0000)))))
    ;; granularity bit scales by 4 KiB
    (if (i32.wrap_i64 (i64.and (i64.shr_u (local.get $d) (i64.const 55)) (i64.const 1)))
      (then (local.set $lim (i32.or (i32.shl (local.get $lim) (i32.const 12)) (i32.const 0xFFF)))))
    (local.get $lim))

  ;; pack the access/flag bits into the compact form kept in the segment cache
  (func $desc_attr (param $d i64) (result i32)
    (local $acc i32) (local $fl i32) (local $a i32)
    (local.set $acc (i32.wrap_i64 (i64.and (i64.shr_u (local.get $d) (i64.const 40)) (i64.const 0xFF))))
    (local.set $fl  (i32.wrap_i64 (i64.and (i64.shr_u (local.get $d) (i64.const 52)) (i64.const 0xF))))
    (local.set $a (i32.and (i32.shr_u (local.get $acc) (i32.const 7)) (i32.const 1)))       ;; present
    (local.set $a (i32.or (local.get $a)
      (i32.shl (i32.and (i32.shr_u (local.get $acc) (i32.const 1)) (i32.const 1)) (i32.const 1))))
    (local.set $a (i32.or (local.get $a)
      (i32.shl (i32.and (i32.shr_u (local.get $acc) (i32.const 3)) (i32.const 1)) (i32.const 2))))
    (local.set $a (i32.or (local.get $a)
      (i32.shl (i32.and (i32.shr_u (local.get $acc) (i32.const 2)) (i32.const 1)) (i32.const 3))))
    (local.set $a (i32.or (local.get $a)
      (i32.shl (i32.and (i32.shr_u (local.get $fl) (i32.const 1)) (i32.const 1)) (i32.const 4))))  ;; L
    (local.set $a (i32.or (local.get $a)
      (i32.shl (i32.and (i32.shr_u (local.get $fl) (i32.const 2)) (i32.const 1)) (i32.const 5))))  ;; D/B
    (local.set $a (i32.or (local.get $a)
      (i32.shl (i32.and (i32.shr_u (local.get $acc) (i32.const 5)) (i32.const 3)) (i32.const 8))))  ;; DPL
    (local.set $a (i32.or (local.get $a)
      (i32.shl (i32.and (i32.shr_u (local.get $acc) (i32.const 4)) (i32.const 1)) (i32.const 12)))) ;; S bit
    (local.get $a))

  (func $desc_type (param $d i64) (result i32)
    (i32.wrap_i64 (i64.and (i64.shr_u (local.get $d) (i64.const 40)) (i64.const 0x1F))))

  ;; read the 8-byte descriptor named by a selector (GDT or LDT)
  (func $read_desc (param $sel i32) (result i64)
    (local $base i64) (local $limit i32) (local $off i32)
    (local.set $off (i32.and (local.get $sel) (i32.const 0xFFF8)))
    (if (i32.and (local.get $sel) (i32.const 4))
      (then (local.set $base (i64.load (i32.const 0x228)))     ;; LDT cached base
            (local.set $limit (i32.load (i32.const 0x230))))
      (else (local.set $base (call $gdt_base))
            (local.set $limit (call $gdt_limit))))
    (if (i32.gt_u (i32.add (local.get $off) (i32.const 7)) (local.get $limit))
      (then (call $raise_gp (i64.extend_i32_u (i32.and (local.get $sel) (i32.const 0xFFFC))))
            (return (i64.const 0))))
    (call $sys_read (i64.add (local.get $base) (i64.extend_i32_u (local.get $off))) (i32.const 8)))

  ;; upper half of a 16-byte system descriptor (long mode)
  (func $read_desc_hi (param $sel i32) (result i64)
    (local $base i64)
    (if (i32.and (local.get $sel) (i32.const 4))
      (then (local.set $base (i64.load (i32.const 0x228))))
      (else (local.set $base (call $gdt_base))))
    (call $sys_read (i64.add (local.get $base)
                             (i64.extend_i32_u (i32.add (i32.and (local.get $sel) (i32.const 0xFFF8))
                                                        (i32.const 8))))
          (i32.const 8)))

  ;; ---- load a segment register -------------------------------------------
  (func $load_seg (param $s i32) (param $sel i32)
    (local $d i64) (local $attr i32) (local $base i64) (local $hi i64)

    ;; Real mode: the base is simply selector * 16, and the cached descriptor
    ;; has D/B clear.  That matters because software enters protected mode
    ;; without reloading CS and expects 16-bit code until it far-jumps.
    ;; Virtual-8086 mode loads segments the same way, at DPL 3.
    (if (i32.or (i32.eqz (call $pe_on)) (global.get $vm))
      (then
        (call $seg_store (local.get $s) (i32.and (local.get $sel) (i32.const 0xFFFF))
              (i64.shl (i64.extend_i32_u (i32.and (local.get $sel) (i32.const 0xFFFF))) (i64.const 4))
              (i32.const 0xFFFF)
              (i32.or (select (i32.const 0x300) (i32.const 0) (global.get $vm))
                (if (result i32) (i32.eq (local.get $s) (i32.const 1))
                  (then (i32.const 0x1007))     ;; code, readable, 16-bit
                  (else (i32.const 0x1003)))))  ;; data, writable, 16-bit
        (if (i32.eq (local.get $s) (i32.const 1)) (then (call $recompute_mode)))
        (return)))

    ;; null selector: allowed for DS/ES/FS/GS (and SS outside CPL 3 in long mode)
    (if (i32.eqz (i32.and (local.get $sel) (i32.const 0xFFFC)))
      (then
        (if (i32.eq (local.get $s) (i32.const 2))
          (then
            (if (i32.ne (global.get $mode) (i32.const 3))
              (then (call $raise_gp (i64.const 0)) (return)))))
        (call $seg_store (local.get $s) (local.get $sel) (i64.const 0) (i32.const 0) (i32.const 0))
        (return)))

    (local.set $d (call $seg_check (local.get $s) (local.get $sel)))
    (if (global.get $fault) (then (return)))
    (local.set $attr (call $desc_attr (local.get $d)))
    (local.set $base (call $desc_base (local.get $d)))
    ;; FS/GS bases are 64-bit in long mode but come from MSRs, not descriptors
    (call $seg_store (local.get $s) (local.get $sel) (local.get $base)
          (call $desc_limit (local.get $d)) (local.get $attr))
    (if (i32.eq (local.get $s) (i32.const 1))
      (then (call $recompute_mode))))

  ;; The checks a protected-mode segment load makes, loading nothing: the
  ;; descriptor, or 0 with a fault raised.  IRET runs them on CS and SS before
  ;; it changes privilege, so that a fault finds the CPU as it was.  The type
  ;; is checked before presence, as on hardware: a not-present segment of the
  ;; right kind is #NP (#SS for a stack), which is what demand-loading relies on.
  (func $seg_check (param $s i32) (param $sel i32) (result i64)
    (local $d i64) (local $attr i32) (local $err i64)
    (local.set $err (i64.extend_i32_u (i32.and (local.get $sel) (i32.const 0xFFFC))))
    (local.set $d (call $read_desc (local.get $sel)))
    (if (global.get $fault) (then (return (i64.const 0))))
    (local.set $attr (call $desc_attr (local.get $d)))
    (block $bad
      ;; a code or data descriptor
      (br_if $bad (i32.eqz (i32.and (local.get $attr) (i32.const 0x1000))))
      ;; CS must be code; SS must be writable data
      (if (i32.eq (local.get $s) (i32.const 1))
        (then (br_if $bad (i32.eqz (i32.and (local.get $attr) (i32.const 4))))))
      (if (i32.eq (local.get $s) (i32.const 2))
        (then (br_if $bad (i32.ne (i32.and (local.get $attr) (i32.const 6)) (i32.const 2)))))
      (if (i32.eqz (i32.and (local.get $attr) (i32.const 1)))
        (then
          (if (i32.eq (local.get $s) (i32.const 2))
            (then (call $raise_ss (local.get $err)))
            (else (call $raise_np (local.get $err))))
          (return (i64.const 0))))
      (return (local.get $d)))
    (call $raise_gp (local.get $err))
    (i64.const 0))

  ;; The privilege rules a return must also meet: CS's RPL is at least the CPL
  ;; returned from; a non-conforming CS has DPL equal to that RPL, a conforming
  ;; one at most it; and going outward, SS's RPL and DPL both equal it.  Windows
  ;; XP ends a BIOS call made from its kernel with an IRET built to break these
  ;; -- to its ring-0 code selector with RPL 3 -- and its #GP handler knows the
  ;; frame and finishes the call.  Taking that IRET ran kernel code at ring 3,
  ;; the page fault that followed killed the thread, and with it the display
  ;; driver's mutex.  1 when the return may go ahead; 0 with #GP raised.
  (func $ret_priv_ok (param $cs i32) (param $ss i32) (param $outer i32)
                     (param $old_cpl i32) (result i32)
    (local $rpl i32) (local $attr i32) (local $dpl i32)
    (local.set $rpl (i32.and (local.get $cs) (i32.const 3)))
    (local.set $attr (call $desc_attr (call $read_desc (local.get $cs))))
    (if (global.get $fault) (then (return (i32.const 0))))
    (local.set $dpl (i32.and (i32.shr_u (local.get $attr) (i32.const 8)) (i32.const 3)))
    (if (i32.or (i32.lt_u (local.get $rpl) (local.get $old_cpl))
                (if (result i32) (i32.and (local.get $attr) (i32.const 8))   ;; conforming
                  (then (i32.gt_u (local.get $dpl) (local.get $rpl)))
                  (else (i32.ne (local.get $dpl) (local.get $rpl)))))
      (then (call $raise_gp (i64.extend_i32_u (i32.and (local.get $cs) (i32.const 0xFFFC))))
            (return (i32.const 0))))
    (if (i32.and (local.get $outer) (i32.ne (i32.and (local.get $ss) (i32.const 0xFFFC)) (i32.const 0)))
      (then
        (local.set $attr (call $desc_attr (call $read_desc (local.get $ss))))
        (if (global.get $fault) (then (return (i32.const 0))))
        (if (i32.or (i32.ne (i32.and (local.get $ss) (i32.const 3)) (local.get $rpl))
                    (i32.ne (i32.and (i32.shr_u (local.get $attr) (i32.const 8)) (i32.const 3))
                            (local.get $rpl)))
          (then (call $raise_gp (i64.extend_i32_u (i32.and (local.get $ss) (i32.const 0xFFFC))))
                (return (i32.const 0))))))
    (i32.const 1))

  ;; ---- far transfers ------------------------------------------------------
  (func $far_jump (param $sel i32) (param $off i64)
    (local $d i64) (local $attr i32)
    (if (i32.or (i32.eqz (call $pe_on)) (global.get $vm))
      (then
        (call $load_seg (i32.const 1) (local.get $sel))
        (call $set_rip (i64.and (local.get $off) (i64.const 0xFFFF)))
        (return)))
    (local.set $d (call $read_desc (local.get $sel)))
    (if (global.get $fault) (then (return)))
    (local.set $attr (call $desc_attr (local.get $d)))
    (if (i32.eqz (i32.and (local.get $attr) (i32.const 1)))
      (then (call $raise_np (i64.extend_i32_u (i32.and (local.get $sel) (i32.const 0xFFFC)))) (return)))
    (call $seg_store (i32.const 1)
          (i32.or (i32.and (local.get $sel) (i32.const 0xFFFC)) (call $cpl))
          (call $desc_base (local.get $d))
          (call $desc_limit (local.get $d)) (local.get $attr))
    (call $recompute_mode)
    (call $set_rip (local.get $off)))

  ;; ---- IDT-driven interrupt / exception delivery -------------------------
  ;;  soft = 1 for INT n / INT3 / INTO (which use the DPL check)
  (func $do_interrupt (param $vec i32) (param $err i64) (param $has_err i32)
                      (param $soft i32) (param $ret_rip i64)
    (local $g i64) (local $ghi i64) (local $off i64) (local $sel i32)
    (local $type i32) (local $dpl i32) (local $ist i32)
    (local $old_cpl i32) (local $new_cpl i32) (local $d i64)
    (local $old_ss i32) (local $old_sp i64) (local $newsp i64)
    (local $tss i64) (local $fl i64) (local $attr i32) (local $from_vm i32)
    (local $gsz i32)

    ;; ---------------- real mode: 4-byte IVT entries ----------------
    (if (i32.eqz (call $pe_on))
      (then
        (call $push (call $flags) (i32.const 2))
        (call $push (i64.extend_i32_u (call $seg_sel (i32.const 1))) (i32.const 2))
        (call $push (local.get $ret_rip) (i32.const 2))
        (if (global.get $fault) (then (return)))
        (local.set $off (call $lin_read
                          (i64.extend_i32_u (i32.shl (local.get $vec) (i32.const 2))) (i32.const 2)))
        (local.set $sel (i32.wrap_i64 (call $lin_read
                          (i64.extend_i32_u (i32.add (i32.shl (local.get $vec) (i32.const 2))
                                                     (i32.const 2))) (i32.const 2))))
        (call $set_flag (i32.const 9) (i32.const 0))    ;; IF
        (call $set_flag (i32.const 8) (i32.const 0))    ;; TF
        (call $load_seg (i32.const 1) (local.get $sel))
        (call $set_rip (local.get $off))
        (return)))

    ;; ---------------- protected / long mode ----------------
    (local.set $old_cpl (call $cpl))
    (if (i32.eq (global.get $mode) (i32.const 3))
      (then
        ;; 16-byte gate
        (if (i32.gt_u (i32.add (i32.shl (local.get $vec) (i32.const 4)) (i32.const 15))
                      (call $idt_limit))
          (then (call $raise_gp (i64.extend_i32_u (i32.or (i32.shl (local.get $vec) (i32.const 3))
                                                          (i32.const 2)))) (return)))
        (local.set $g (call $sys_read
          (i64.add (call $idt_base) (i64.extend_i32_u (i32.shl (local.get $vec) (i32.const 4))))
          (i32.const 8)))
        (local.set $ghi (call $sys_read
          (i64.add (call $idt_base)
                   (i64.extend_i32_u (i32.add (i32.shl (local.get $vec) (i32.const 4)) (i32.const 8))))
          (i32.const 8)))
        (if (global.get $fault) (then (return)))
        (local.set $off (i64.or
          (i64.and (local.get $g) (i64.const 0xFFFF))
          (i64.or (i64.and (i64.shr_u (local.get $g) (i64.const 32)) (i64.const 0xFFFF0000))
                  (i64.shl (i64.and (local.get $ghi) (i64.const 0xFFFFFFFF)) (i64.const 32)))))
        (local.set $sel (i32.wrap_i64 (i64.and (i64.shr_u (local.get $g) (i64.const 16))
                                               (i64.const 0xFFFF))))
        (local.set $type (i32.wrap_i64 (i64.and (i64.shr_u (local.get $g) (i64.const 40))
                                                (i64.const 0x1F))))
        (local.set $dpl (i32.wrap_i64 (i64.and (i64.shr_u (local.get $g) (i64.const 45))
                                               (i64.const 3))))
        (local.set $ist (i32.wrap_i64 (i64.and (i64.shr_u (local.get $g) (i64.const 32))
                                               (i64.const 7))))
        (if (i64.eqz (i64.and (i64.shr_u (local.get $g) (i64.const 47)) (i64.const 1)))
          (then (call $raise_np (i64.extend_i32_u (i32.or (i32.shl (local.get $vec) (i32.const 3))
                                                          (i32.const 2)))) (return)))
        (if (i32.and (local.get $soft) (i32.lt_u (local.get $dpl) (local.get $old_cpl)))
          (then (call $raise_gp (i64.extend_i32_u (i32.or (i32.shl (local.get $vec) (i32.const 3))
                                                          (i32.const 2)))) (return)))

        ;; target privilege comes from the target code segment's DPL
        (local.set $d (call $read_desc (local.get $sel)))
        (if (global.get $fault) (then (return)))
        (local.set $attr (call $desc_attr (local.get $d)))
        (local.set $new_cpl (i32.and (i32.shr_u (local.get $attr) (i32.const 8)) (i32.const 3)))

        (local.set $old_ss (call $seg_sel (i32.const 2)))
        (local.set $old_sp (call $reg64 (i32.const 4)))
        (local.set $fl (call $flags))

        ;; stack switch: IST always switches, otherwise only on a CPL change
        (local.set $tss (i64.load (i32.const 0x248)))     ;; TR cached base
        (if (i32.ne (local.get $ist) (i32.const 0))
          (then
            (local.set $newsp (call $sys_read
              (i64.add (local.get $tss)
                       (i64.extend_i32_u (i32.add (i32.const 36)
                                                  (i32.shl (i32.sub (local.get $ist) (i32.const 1))
                                                           (i32.const 3)))))
              (i32.const 8)))
            (call $setreg64 (i32.const 4) (local.get $newsp))
            (call $seg_store (i32.const 2) (i32.const 0) (i64.const 0) (i32.const 0) (i32.const 0)))
          (else
            (if (i32.lt_u (local.get $new_cpl) (local.get $old_cpl))
              (then
                (local.set $newsp (call $sys_read
                  (i64.add (local.get $tss)
                           (i64.extend_i32_u (i32.add (i32.const 4)
                                                      (i32.shl (local.get $new_cpl) (i32.const 3)))))
                  (i32.const 8)))
                (call $setreg64 (i32.const 4) (local.get $newsp))
                (call $seg_store (i32.const 2) (i32.const 0) (i64.const 0) (i32.const 0) (i32.const 0))))))

        ;; 16-byte aligned stack frame
        (call $setreg64 (i32.const 4) (i64.and (call $reg64 (i32.const 4)) (i64.const -16)))
        (call $set_cpl (local.get $new_cpl))
        (global.set $mode (i32.const 3))

        (call $push (i64.extend_i32_u (local.get $old_ss)) (i32.const 8))
        (call $push (local.get $old_sp) (i32.const 8))
        (call $push (local.get $fl) (i32.const 8))
        (call $push (i64.extend_i32_u (call $seg_sel (i32.const 1))) (i32.const 8))
        (call $push (local.get $ret_rip) (i32.const 8))
        (if (local.get $has_err) (then (call $push (local.get $err) (i32.const 8))))

        (call $seg_store (i32.const 1) (local.get $sel) (i64.const 0)
              (i32.const -1) (local.get $attr))
        (call $recompute_mode)
        (call $set_rip (local.get $off))
        ;; interrupt gate (type 14) clears IF; trap gate (15) leaves it
        (if (i32.eq (i32.and (local.get $type) (i32.const 0xF)) (i32.const 14))
          (then (call $set_flag (i32.const 9) (i32.const 0))))
        (call $set_flag (i32.const 8) (i32.const 0))
        (call $set_flag (i32.const 14) (i32.const 0))
        (return)))

    ;; ---------------- 32-bit protected mode ----------------
    (if (i32.gt_u (i32.add (i32.shl (local.get $vec) (i32.const 3)) (i32.const 7))
                  (call $idt_limit))
      (then (call $raise_gp (i64.extend_i32_u (i32.or (i32.shl (local.get $vec) (i32.const 3))
                                                      (i32.const 2)))) (return)))
    (local.set $g (call $sys_read
      (i64.add (call $idt_base) (i64.extend_i32_u (i32.shl (local.get $vec) (i32.const 3))))
      (i32.const 8)))
    (if (global.get $fault) (then (return)))
    (local.set $off (i64.or (i64.and (local.get $g) (i64.const 0xFFFF))
                            (i64.and (i64.shr_u (local.get $g) (i64.const 32))
                                     (i64.const 0xFFFF0000))))
    (local.set $sel (i32.wrap_i64 (i64.and (i64.shr_u (local.get $g) (i64.const 16)) (i64.const 0xFFFF))))
    (local.set $type (i32.wrap_i64 (i64.and (i64.shr_u (local.get $g) (i64.const 40)) (i64.const 0x1F))))
    ;; A 16-bit gate (types 6 and 7) pushes a 16-bit frame and enters at a
    ;; 16-bit offset.  Windows routes its 16-bit clients' interrupts through
    ;; such gates and reads the frame back as words.
    (local.set $gsz (select (i32.const 4) (i32.const 2) (i32.and (local.get $type) (i32.const 8))))
    (if (i32.eq (local.get $gsz) (i32.const 2))
      (then (local.set $off (i64.and (local.get $off) (i64.const 0xFFFF)))))
    (local.set $dpl (i32.wrap_i64 (i64.and (i64.shr_u (local.get $g) (i64.const 45)) (i64.const 3))))
    (if (i64.eqz (i64.and (i64.shr_u (local.get $g) (i64.const 47)) (i64.const 1)))
      (then (call $raise_np (i64.extend_i32_u (i32.or (i32.shl (local.get $vec) (i32.const 3))
                                                      (i32.const 2)))) (return)))
    (if (i32.and (local.get $soft) (i32.lt_u (local.get $dpl) (local.get $old_cpl)))
      (then (call $raise_gp (i64.extend_i32_u (i32.or (i32.shl (local.get $vec) (i32.const 3))
                                                      (i32.const 2)))) (return)))

    (local.set $d (call $read_desc (local.get $sel)))
    (if (global.get $fault) (then (return)))
    (local.set $attr (call $desc_attr (local.get $d)))
    (local.set $new_cpl (i32.and (i32.shr_u (local.get $attr) (i32.const 8)) (i32.const 3)))
    (local.set $old_ss (call $seg_sel (i32.const 2)))
    (local.set $old_sp (call $reg64 (i32.const 4)))
    (local.set $fl (call $flags))

    ;; Out of virtual-8086 mode the handler must be at ring 0.  VM is cleared
    ;; before the ring-0 stack is loaded, so that SS0 is read as a protected
    ;; mode selector; the flags image pushed below still has it set, which is
    ;; what tells the handler where it came from.
    (local.set $from_vm (global.get $vm))
    (if (local.get $from_vm)
      (then
        (if (local.get $new_cpl)
          (then (call $raise_gp (i64.extend_i32_u (i32.and (local.get $sel) (i32.const 0xFFFC))))
                (return)))
        (call $set_flag (i32.const 17) (i32.const 0))
        (global.set $vm (i32.const 0))))

    (if (i32.lt_u (local.get $new_cpl) (local.get $old_cpl))
      (then
        (local.set $tss (i64.load (i32.const 0x248)))
        (local.set $newsp (call $sys_read
          (i64.add (local.get $tss)
                   (i64.extend_i32_u (i32.add (i32.const 4) (i32.shl (local.get $new_cpl) (i32.const 3)))))
          (i32.const 4)))
        (call $load_seg (i32.const 2) (i32.wrap_i64 (call $sys_read
          (i64.add (local.get $tss)
                   (i64.extend_i32_u (i32.add (i32.const 8) (i32.shl (local.get $new_cpl) (i32.const 3)))))
          (i32.const 4))))
        (call $setreg32 (i32.const 4) (i32.wrap_i64 (local.get $newsp)))
        (call $set_cpl (local.get $new_cpl))
        ;; a virtual-8086 frame also carries the four data segments, which
        ;; then read as null: their real-mode values mean nothing here
        (if (local.get $from_vm)
          (then
            (call $push (i64.extend_i32_u (call $seg_sel (i32.const 5))) (local.get $gsz))
            (call $push (i64.extend_i32_u (call $seg_sel (i32.const 4))) (local.get $gsz))
            (call $push (i64.extend_i32_u (call $seg_sel (i32.const 3))) (local.get $gsz))
            (call $push (i64.extend_i32_u (call $seg_sel (i32.const 0))) (local.get $gsz))
            (call $seg_store (i32.const 0) (i32.const 0) (i64.const 0) (i32.const 0) (i32.const 0))
            (call $seg_store (i32.const 3) (i32.const 0) (i64.const 0) (i32.const 0) (i32.const 0))
            (call $seg_store (i32.const 4) (i32.const 0) (i64.const 0) (i32.const 0) (i32.const 0))
            (call $seg_store (i32.const 5) (i32.const 0) (i64.const 0) (i32.const 0) (i32.const 0))))
        (call $push (i64.extend_i32_u (local.get $old_ss)) (local.get $gsz))
        (call $push (local.get $old_sp) (local.get $gsz)))
      (else (call $set_cpl (local.get $new_cpl))))

    (call $push (local.get $fl) (local.get $gsz))
    (call $push (i64.extend_i32_u (call $seg_sel (i32.const 1))) (local.get $gsz))
    (call $push (local.get $ret_rip) (local.get $gsz))
    (if (local.get $has_err) (then (call $push (local.get $err) (local.get $gsz))))

    (call $seg_store (i32.const 1) (local.get $sel) (call $desc_base (local.get $d))
          (call $desc_limit (local.get $d)) (local.get $attr))
    (call $recompute_mode)
    (call $set_rip (local.get $off))
    ;; an interrupt gate (6 or 14) clears IF; a trap gate (7 or 15) leaves it
    (if (i32.eq (i32.and (local.get $type) (i32.const 7)) (i32.const 6))
      (then (call $set_flag (i32.const 9) (i32.const 0))))
    (call $set_flag (i32.const 8) (i32.const 0))
    (call $set_flag (i32.const 14) (i32.const 0))
    (call $set_flag (i32.const 16) (i32.const 0)))

  ;; ---- IRET ---------------------------------------------------------------
  (func $do_iret (param $size i32)
    (local $rip i64) (local $cs i32) (local $fl i64) (local $sp i64) (local $ss i32)
    (local $new_cpl i32) (local $old_cpl i32) (local $mask i64)

    ;; real mode
    (if (i32.eqz (call $pe_on))
      (then
        (local.set $rip (call $pop (i32.const 2)))
        (local.set $cs (i32.wrap_i64 (call $pop (i32.const 2))))
        (local.set $fl (call $pop (i32.const 2)))
        (if (global.get $fault) (then (return)))
        (call $load_seg (i32.const 1) (local.get $cs))
        (call $set_rip (local.get $rip))
        (call $set_flags (i64.or (i64.and (call $flags) (i64.const 0xFFFF0000)) (local.get $fl)))
        (return)))

    ;; virtual-8086 mode: a real-mode IRET, but IOPL-sensitive, and unable to
    ;; change IOPL or leave the mode
    (if (global.get $vm)
      (then
        (if (i32.lt_u (call $iopl) (i32.const 3))
          (then (call $raise_gp (i64.const 0)) (return)))
        (local.set $rip (call $pop (local.get $size)))
        (local.set $cs (i32.wrap_i64 (call $pop (local.get $size))))
        (local.set $fl (call $pop (local.get $size)))
        (if (global.get $fault) (then (return)))
        (call $load_seg (i32.const 1) (local.get $cs))
        (call $set_rip (local.get $rip))
        (call $flags_merge
          (if (result i64) (i32.eq (local.get $size) (i32.const 2))
            (then (i64.const 0x4FD5)) (else (i64.const 0x254FD5)))
          (local.get $fl))
        (return)))

    (local.set $old_cpl (call $cpl))
    (local.set $rip (call $pop (local.get $size)))
    (local.set $cs (i32.wrap_i64 (call $pop (local.get $size))))
    (local.set $fl (call $pop (local.get $size)))
    (if (global.get $fault) (then (return)))

    ;; VM in a 32-bit frame popped at ring 0 enters virtual-8086 mode
    (if (i32.and (i32.and (i32.eqz (local.get $old_cpl))
                          (i32.eq (local.get $size) (i32.const 4)))
                 (i32.and (i32.eqz (call $lma))
                          (i32.wrap_i64 (i64.and (i64.shr_u (local.get $fl) (i64.const 17))
                                                 (i64.const 1)))))
      (then (call $iret_to_v86 (local.get $rip) (local.get $cs) (local.get $fl))
            (return)))

    (local.set $new_cpl (i32.and (local.get $cs) (i32.const 3)))

    ;; returning to a less privileged level pops SS:SP too.  In long mode the
    ;; stack frame always contains SS:RSP.
    (if (i32.or (i32.gt_u (local.get $new_cpl) (local.get $old_cpl))
                (i32.eq (global.get $mode) (i32.const 3)))
      (then
        (local.set $sp (call $pop (local.get $size)))
        (local.set $ss (i32.wrap_i64 (call $pop (local.get $size))))
        (if (global.get $fault) (then (return)))
        ;; Both segments are checked before privilege changes.  A fault has to
        ;; be taken at the old CPL, on the old stack, with the frame intact.
        (drop (call $seg_check (i32.const 1) (local.get $cs)))
        (if (i32.and (local.get $ss) (i32.const 0xFFFC))
          (then (drop (call $seg_check (i32.const 2) (local.get $ss)))))
        (if (global.get $fault) (then (return)))
        (if (i32.eqz (call $ret_priv_ok (local.get $cs) (local.get $ss)
                       (i32.gt_u (local.get $new_cpl) (local.get $old_cpl)) (local.get $old_cpl)))
          (then (return)))
        (call $set_cpl (local.get $new_cpl))
        (call $load_seg (i32.const 1) (local.get $cs))
        (call $load_seg (i32.const 2) (local.get $ss))
        (call $setreg64 (i32.const 4) (local.get $sp)))
      (else
        (drop (call $seg_check (i32.const 1) (local.get $cs)))
        (if (global.get $fault) (then (return)))
        (if (i32.eqz (call $ret_priv_ok (local.get $cs) (i32.const 0) (i32.const 0)
                                        (local.get $old_cpl)))
          (then (return)))
        (call $set_cpl (local.get $new_cpl))
        (call $load_seg (i32.const 1) (local.get $cs))))

    ;; What the popped image may change depends on the privilege IRET ran at:
    ;; IOPL and VIF/VIP only from ring 0, IF only at or above IOPL.  VM never
    ;; changes here; entering virtual-8086 mode is the path above.
    (local.set $mask (i64.const 0x257FD5))
    (if (local.get $old_cpl)
      (then (local.set $mask (i64.and (local.get $mask) (i64.const -0x3001))))
      (else (local.set $mask (i64.or (local.get $mask) (i64.const 0x180000)))))
    (if (i32.gt_u (local.get $old_cpl) (call $iopl))
      (then (local.set $mask (i64.and (local.get $mask) (i64.const -0x201)))))
    (if (i32.eq (local.get $size) (i32.const 2))
      (then (local.set $mask (i64.and (local.get $mask) (i64.const 0xFFFF)))))
    (call $set_rip (local.get $rip))
    (call $flags_merge (local.get $mask) (local.get $fl))
    (call $recompute_mode))

  ;; IRET from ring 0 into virtual-8086 mode.  The 32-bit frame goes on past
  ;; EIP, CS and EFLAGS with ESP, SS, ES, DS, FS and GS, and every segment is
  ;; then loaded the real-mode way.
  (func $iret_to_v86 (param $rip i64) (param $cs i32) (param $fl i64)
    (local $sp i64) (local $ss i32) (local $es i32) (local $ds i32)
    (local $fs i32) (local $gs i32)
    (local.set $sp (call $pop (i32.const 4)))
    (local.set $ss (i32.wrap_i64 (call $pop (i32.const 4))))
    (local.set $es (i32.wrap_i64 (call $pop (i32.const 4))))
    (local.set $ds (i32.wrap_i64 (call $pop (i32.const 4))))
    (local.set $fs (i32.wrap_i64 (call $pop (i32.const 4))))
    (local.set $gs (i32.wrap_i64 (call $pop (i32.const 4))))
    (if (global.get $fault) (then (return)))
    (call $set_flags (local.get $fl))
    (call $recompute_mode)                         ;; VM is set: CPL 3
    (call $load_seg (i32.const 1) (local.get $cs))
    (call $load_seg (i32.const 2) (local.get $ss))
    (call $load_seg (i32.const 0) (local.get $es))
    (call $load_seg (i32.const 3) (local.get $ds))
    (call $load_seg (i32.const 4) (local.get $fs))
    (call $load_seg (i32.const 5) (local.get $gs))
    (call $setreg32 (i32.const 4) (i32.wrap_i64 (local.get $sp)))
    (call $set_rip (i64.and (local.get $rip) (i64.const 0xFFFF))))

  ;; ---- SYSCALL / SYSRET ---------------------------------------------------
  (func $do_syscall
    (local $star i64) (local $cs i32)
    (call $setreg64 (i32.const 1) (call $rip))                       ;; RCX = return RIP
    (call $setreg64 (i32.const 11) (call $flags))                    ;; R11 = RFLAGS
    (local.set $star (i64.load (i32.const 0x268)))
    (local.set $cs (i32.and (i32.wrap_i64 (i64.shr_u (local.get $star) (i64.const 32)))
                            (i32.const 0xFFFC)))
    ;; SYSCALL synthesises flat 64-bit CS/SS rather than reading the GDT
    (call $seg_store (i32.const 1) (local.get $cs) (i64.const 0) (i32.const -1)
          (i32.const 0x1017))       ;; present, readable, code, L=1, DPL 0
    (call $seg_store (i32.const 2) (i32.add (local.get $cs) (i32.const 8))
          (i64.const 0) (i32.const -1) (i32.const 0x1023))
    (call $set_cpl (i32.const 0))
    (global.set $mode (i32.const 3))
    (call $set_flags (i64.and (call $flags)
                              (i64.xor (i64.load (i32.const 0x280)) (i64.const -1))))
    (call $set_rip (i64.load (i32.const 0x270))))                    ;; LSTAR

  (func $do_sysret (param $size i32)
    (local $star i64) (local $cs i32)
    (local.set $star (i64.load (i32.const 0x268)))
    (local.set $cs (i32.and (i32.wrap_i64 (i64.shr_u (local.get $star) (i64.const 48)))
                            (i32.const 0xFFFC)))
    (if (i32.eq (local.get $size) (i32.const 8))
      (then
        ;; SYSRET to 64-bit code lands on STAR[63:48] + 16, a long-mode segment
        (call $seg_store (i32.const 1) (i32.or (i32.add (local.get $cs) (i32.const 16)) (i32.const 3))
              (i64.const 0) (i32.const -1) (i32.const 0x1317))
        (call $seg_store (i32.const 2) (i32.or (i32.add (local.get $cs) (i32.const 8)) (i32.const 3))
              (i64.const 0) (i32.const -1) (i32.const 0x1323)))
      (else
        ;; the compatibility-mode form returns to a 32-bit code segment
        (call $seg_store (i32.const 1) (i32.or (local.get $cs) (i32.const 3))
              (i64.const 0) (i32.const -1) (i32.const 0x1327))
        (call $seg_store (i32.const 2) (i32.or (i32.add (local.get $cs) (i32.const 8)) (i32.const 3))
              (i64.const 0) (i32.const -1) (i32.const 0x1323))))
    (call $set_cpl (i32.const 3))
    (call $set_flags (i64.or (call $reg64 (i32.const 11)) (i64.const 2)))
    (call $set_rip (call $reg64 (i32.const 1)))
    (call $recompute_mode))

  ;; ---- SYSENTER / SYSEXIT (the fast path 32-bit Linux uses) --------------
  ;;  MSR storage: 0x300 SYSENTER_CS, 0x308 SYSENTER_ESP, 0x310 SYSENTER_EIP
  (func $do_sysenter
    (local $cs i32)
    (local.set $cs (i32.and (i32.wrap_i64 (i64.load (i32.const 0x300))) (i32.const 0xFFFC)))
    (if (i32.eqz (local.get $cs)) (then (call $raise_gp (i64.const 0)) (return)))
    ;; CS and SS are synthesised flat, exactly as the architecture specifies
    (call $seg_store (i32.const 1) (local.get $cs) (i64.const 0) (i32.const -1)
          (i32.const 0x1027))                    ;; code, D=1, DPL 0
    (call $seg_store (i32.const 2) (i32.add (local.get $cs) (i32.const 8))
          (i64.const 0) (i32.const -1) (i32.const 0x1023))
    (call $set_cpl (i32.const 0))
    (call $set_flag (i32.const 9) (i32.const 0))    ;; IF
    (call $set_flag (i32.const 17) (i32.const 0))   ;; VM
    (call $setreg64 (i32.const 4) (i64.load (i32.const 0x308)))
    (call $set_rip (i64.load (i32.const 0x310)))
    (call $recompute_mode))

  (func $do_sysexit
    (local $cs i32)
    (if (i32.ne (call $cpl) (i32.const 0)) (then (call $raise_gp (i64.const 0)) (return)))
    (local.set $cs (i32.and (i32.wrap_i64 (i64.load (i32.const 0x300))) (i32.const 0xFFFC)))
    (if (i32.eqz (local.get $cs)) (then (call $raise_gp (i64.const 0)) (return)))
    (call $seg_store (i32.const 1) (i32.or (i32.add (local.get $cs) (i32.const 16)) (i32.const 3))
          (i64.const 0) (i32.const -1) (i32.const 0x1327))
    (call $seg_store (i32.const 2) (i32.or (i32.add (local.get $cs) (i32.const 24)) (i32.const 3))
          (i64.const 0) (i32.const -1) (i32.const 0x1323))
    (call $set_cpl (i32.const 3))
    (call $setreg64 (i32.const 4) (call $reg64 (i32.const 1)))   ;; ESP <- ECX
    (call $set_rip (call $reg64 (i32.const 2)))                  ;; EIP <- EDX
    (call $recompute_mode))
