  ;; =========================================================================
  ;;  Part 20: exceptions, physical memory, TLB, page walk, linear access
  ;; =========================================================================

  ;; ---- exception raising -------------------------------------------------
  ;;  Sets the fault global; every caller in the memory path bails out and the
  ;;  main loop delivers the exception through the IDT.
  (func $raise (param $vec i32) (param $err i64) (param $has_err i32)
    (if (global.get $fault) (then (return)))   ;; first fault wins
    (global.set $fault (i32.const 1))
    (i32.store (i32.const 0xC8) (local.get $vec))
    (i32.store (i32.const 0xCC) (local.get $has_err))
    (i64.store (i32.const 0xD0) (local.get $err)))

  (func $raise_gp (param $err i64) (call $raise (i32.const 13) (local.get $err) (i32.const 1)))
  (func $raise_ud  (call $raise (i32.const 6) (i64.const 0) (i32.const 0)))
  (func $raise_ss (param $err i64) (call $raise (i32.const 12) (local.get $err) (i32.const 1)))
  (func $raise_np (param $err i64) (call $raise (i32.const 11) (local.get $err) (i32.const 1)))
  (func $raise_de  (call $raise (i32.const 0) (i64.const 0) (i32.const 0)))

  (func $raise_pf (param $addr i64) (param $err i64)
    (call $set_cr2 (local.get $addr))
    (call $raise (i32.const 14) (local.get $err) (i32.const 1)))

  ;; ---- physical memory ---------------------------------------------------
  (func $in_ram (param $pa i64) (param $size i32) (result i32)
    (if (global.get $vga_mmio)
      (then
        ;; the planar window belongs to the adapter, not to memory
        (if (i32.and (i64.lt_u (local.get $pa) (i64.const 0xB0000))
                     (i64.ge_u (i64.add (local.get $pa) (i64.extend_i32_u (local.get $size)))
                               (i64.const 0xA0000)))
          (then (return (i32.const 0))))))
    (i64.le_u (i64.add (local.get $pa) (i64.extend_i32_u (local.get $size)))
              (global.get $ram_size)))

  ;; Guest RAM lives in memory 1, indexed by the physical address itself.
  (func $phys_r8 (param $pa i64) (result i64)
    (if (result i64) (call $in_ram (local.get $pa) (i32.const 1))
      (then (i64.load8_u $ram (local.get $pa)))
      (else (call $mmio_read (local.get $pa) (i32.const 1)))))

  (func $phys_r16 (param $pa i64) (result i64)
    (if (result i64) (call $in_ram (local.get $pa) (i32.const 2))
      (then (i64.load16_u $ram align=1 (local.get $pa)))
      (else (call $mmio_read (local.get $pa) (i32.const 2)))))

  (func $phys_r32 (param $pa i64) (result i64)
    (if (result i64) (call $in_ram (local.get $pa) (i32.const 4))
      (then (i64.load32_u $ram align=1 (local.get $pa)))
      (else (call $mmio_read (local.get $pa) (i32.const 4)))))

  (func $phys_r64 (param $pa i64) (result i64)
    (if (result i64) (call $in_ram (local.get $pa) (i32.const 8))
      (then (i64.load $ram align=1 (local.get $pa)))
      (else (call $mmio_read (local.get $pa) (i32.const 8)))))

  (func $phys_w8 (param $pa i64) (param $v i64)
    (if (call $in_ram (local.get $pa) (i32.const 1))
      (then (i64.store8 $ram (local.get $pa) (local.get $v)))
      (else (call $mmio_write (local.get $pa) (i32.const 1) (local.get $v)))))

  (func $phys_w16 (param $pa i64) (param $v i64)
    (if (call $in_ram (local.get $pa) (i32.const 2))
      (then (i64.store16 $ram align=1 (local.get $pa) (local.get $v)))
      (else (call $mmio_write (local.get $pa) (i32.const 2) (local.get $v)))))

  (func $phys_w32 (param $pa i64) (param $v i64)
    (if (call $in_ram (local.get $pa) (i32.const 4))
      (then (i64.store32 $ram align=1 (local.get $pa) (local.get $v)))
      (else (call $mmio_write (local.get $pa) (i32.const 4) (local.get $v)))))

  (func $phys_w64 (param $pa i64) (param $v i64)
    (if (call $in_ram (local.get $pa) (i32.const 8))
      (then (i64.store $ram align=1 (local.get $pa) (local.get $v)))
      (else (call $mmio_write (local.get $pa) (i32.const 8) (local.get $v)))))

  (func $phys_rN (param $pa i64) (param $size i32) (result i64)
    (block $d (result i64)
      (if (i32.eq (local.get $size) (i32.const 1)) (then (br $d (call $phys_r8  (local.get $pa)))))
      (if (i32.eq (local.get $size) (i32.const 2)) (then (br $d (call $phys_r16 (local.get $pa)))))
      (if (i32.eq (local.get $size) (i32.const 4)) (then (br $d (call $phys_r32 (local.get $pa)))))
      (call $phys_r64 (local.get $pa))))

  (func $phys_wN (param $pa i64) (param $size i32) (param $v i64)
    (block $d
      (if (i32.eq (local.get $size) (i32.const 1)) (then (call $phys_w8  (local.get $pa) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $size) (i32.const 2)) (then (call $phys_w16 (local.get $pa) (local.get $v)) (br $d)))
      (if (i32.eq (local.get $size) (i32.const 4)) (then (call $phys_w32 (local.get $pa) (local.get $v)) (br $d)))
      (call $phys_w64 (local.get $pa) (local.get $v))))

  ;; ---- TLB ---------------------------------------------------------------
  ;;  1024 direct-mapped entries at 0x1000.  Entry: tag(u64), data(u64)
  (func $tlb_slot (param $va i64) (result i32)
    (i32.add (i32.const 0x1000)
      (i32.shl (i32.and (i32.wrap_i64 (i64.shr_u (local.get $va) (i64.const 12)))
                        (i32.const 1023))
               (i32.const 4))))

  ;; Everything that can change a translation drops the address caches.
  (func $flush_addr_caches
    (global.set $fetch_page (i64.const -1))
    (global.set $dr_page (i64.const -1))
    (global.set $dw_page (i64.const -1)))

  (func $tlb_flush
    (local $i i32)
    (call $flush_addr_caches)
    ;; Blocks are keyed on linear addresses, so anything that changes what a
    ;; linear address maps to invalidates every one of them.
    (if (global.get $jit_on) (then (call $jit_flush)))
    (local.set $i (i32.const 0))
    (block $end (loop $l
      (br_if $end (i32.ge_u (local.get $i) (i32.const 1024)))
      (i64.store (i32.add (i32.const 0x1000) (i32.shl (local.get $i) (i32.const 4)))
                 (i64.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))

  (func $tlb_flush_page (param $va i64)
    (call $flush_addr_caches)
    (i64.store (call $tlb_slot (local.get $va)) (i64.const 0)))

  ;; ---- page walk ---------------------------------------------------------
  ;;  access: 0 = read, 1 = write, 2 = instruction fetch
  ;;  user:   current privilege is user (CPL == 3)
  ;;  Returns physical address, or 0 with $fault set.
  (func $walk (param $va i64) (param $access i32) (param $user i32) (result i64)
    (local $pte i64) (local $tbl i64) (local $idx i64)
    (local $wr i32) (local $us i32) (local $nx i32) (local $err i64)
    (local $lvl i32) (local $shift i64) (local $levels i32)
    (local $wp i32) (local $nxe i32)

    (local.set $wr (i32.const 1))       ;; accumulated writable
    (local.set $us (i32.const 1))       ;; accumulated user-accessible
    (local.set $nx (i32.const 0))       ;; accumulated no-execute

    ;; ---- long mode: 4 levels, 9 bits each starting at bit 39 ----
    (if (call $lma)
      (then
        (local.set $tbl (i64.and (call $cr3) (i64.const 0x000FFFFFFFFFF000)))
        (local.set $lvl (i32.const 0))
        (local.set $shift (i64.const 39))
        (block $walk_done
          (loop $lp
            (local.set $idx (i64.and (i64.shr_u (local.get $va) (local.get $shift))
                                     (i64.const 511)))
            (local.set $pte (call $phys_r64
                              (i64.add (local.get $tbl) (i64.shl (local.get $idx) (i64.const 3)))))
            ;; present?
            (if (i64.eqz (i64.and (local.get $pte) (i64.const 1)))
              (then
                (call $raise_pf (local.get $va)
                  (i64.or (i64.extend_i32_u (i32.shl (local.get $access) (i32.const 1)))
                          (i64.extend_i32_u (i32.shl (local.get $user) (i32.const 2)))))
                (return (i64.const 0))))
            (local.set $wr (i32.and (local.get $wr)
                             (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 1)) (i64.const 1)))))
            (local.set $us (i32.and (local.get $us)
                             (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 2)) (i64.const 1)))))
            (local.set $nx (i32.or (local.get $nx)
                             (i32.wrap_i64 (i64.shr_u (local.get $pte) (i64.const 63)))))
            ;; large page (PS bit 7) at levels 1 (1 GiB) and 2 (2 MiB)
            (if (i32.and (i32.ne (local.get $lvl) (i32.const 0))
                         (i32.and (i32.ne (local.get $lvl) (i32.const 3))
                           (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 7)) (i64.const 1)))))
              (then
                ;; mark accessed / dirty
                (call $mark_ad (local.get $tbl) (local.get $idx) (local.get $pte) (local.get $access))
                (br $walk_done)))
            (if (i32.eq (local.get $lvl) (i32.const 3))
              (then
                (call $mark_ad (local.get $tbl) (local.get $idx) (local.get $pte) (local.get $access))
                (br $walk_done)))
            (local.set $tbl (i64.and (local.get $pte) (i64.const 0x000FFFFFFFFFF000)))
            (local.set $lvl (i32.add (local.get $lvl) (i32.const 1)))
            (local.set $shift (i64.sub (local.get $shift) (i64.const 9)))
            (br $lp)))
        (return (call $finish_walk (local.get $va) (local.get $pte) (local.get $shift)
                      (local.get $access) (local.get $user)
                      (local.get $wr) (local.get $us) (local.get $nx)))))

    ;; ---- PAE (non-long): 3 levels, starting at bit 30 ----
    (if (call $pae_on)
      (then
        (local.set $tbl (i64.and (call $cr3) (i64.const 0xFFFFFFE0)))
        (local.set $idx (i64.and (i64.shr_u (local.get $va) (i64.const 30)) (i64.const 3)))
        (local.set $pte (call $phys_r64
                          (i64.add (local.get $tbl) (i64.shl (local.get $idx) (i64.const 3)))))
        (if (i64.eqz (i64.and (local.get $pte) (i64.const 1)))
          (then (call $raise_pf (local.get $va)
                  (i64.or (i64.extend_i32_u (i32.shl (local.get $access) (i32.const 1)))
                          (i64.extend_i32_u (i32.shl (local.get $user) (i32.const 2)))))
                (return (i64.const 0))))
        (local.set $tbl (i64.and (local.get $pte) (i64.const 0x000FFFFFFFFFF000)))
        (local.set $lvl (i32.const 2))
        (local.set $shift (i64.const 21))
        (block $pae_done
          (loop $lp2
            (local.set $idx (i64.and (i64.shr_u (local.get $va) (local.get $shift))
                                     (i64.const 511)))
            (local.set $pte (call $phys_r64
                              (i64.add (local.get $tbl) (i64.shl (local.get $idx) (i64.const 3)))))
            (if (i64.eqz (i64.and (local.get $pte) (i64.const 1)))
              (then (call $raise_pf (local.get $va)
                      (i64.or (i64.extend_i32_u (i32.shl (local.get $access) (i32.const 1)))
                              (i64.extend_i32_u (i32.shl (local.get $user) (i32.const 2)))))
                    (return (i64.const 0))))
            (local.set $wr (i32.and (local.get $wr)
                             (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 1)) (i64.const 1)))))
            (local.set $us (i32.and (local.get $us)
                             (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 2)) (i64.const 1)))))
            (local.set $nx (i32.or (local.get $nx)
                             (i32.wrap_i64 (i64.shr_u (local.get $pte) (i64.const 63)))))
            (if (i32.or (i32.eq (local.get $lvl) (i32.const 3))
                        (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 7)) (i64.const 1))))
              (then (call $mark_ad (local.get $tbl) (local.get $idx) (local.get $pte) (local.get $access))
                    (br $pae_done)))
            (local.set $tbl (i64.and (local.get $pte) (i64.const 0x000FFFFFFFFFF000)))
            (local.set $lvl (i32.add (local.get $lvl) (i32.const 1)))
            (local.set $shift (i64.sub (local.get $shift) (i64.const 9)))
            (br $lp2)))
        (return (call $finish_walk (local.get $va) (local.get $pte) (local.get $shift)
                      (local.get $access) (local.get $user)
                      (local.get $wr) (local.get $us) (local.get $nx)))))

    ;; ---- legacy 32-bit: 2 levels, 10 bits each ----
    (local.set $tbl (i64.and (call $cr3) (i64.const 0xFFFFF000)))
    (local.set $idx (i64.and (i64.shr_u (local.get $va) (i64.const 22)) (i64.const 1023)))
    (local.set $pte (call $phys_r32
                      (i64.add (local.get $tbl) (i64.shl (local.get $idx) (i64.const 2)))))
    (if (i64.eqz (i64.and (local.get $pte) (i64.const 1)))
      (then (call $raise_pf (local.get $va)
              (i64.or (i64.extend_i32_u (i32.shl (local.get $access) (i32.const 1)))
                      (i64.extend_i32_u (i32.shl (local.get $user) (i32.const 2)))))
            (return (i64.const 0))))
    (local.set $wr (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 1)) (i64.const 1))))
    (local.set $us (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 2)) (i64.const 1))))
    ;; 4 MiB page?  PSE bit 7 with CR4.PSE
    (if (i32.and (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 7)) (i64.const 1)))
                 (i32.wrap_i64 (i64.and (i64.shr_u (call $cr4) (i64.const 4)) (i64.const 1))))
      (then
        (return (call $finish_walk (local.get $va)
                  (i64.and (local.get $pte) (i64.const 0xFFC00000))
                  (i64.const 22) (local.get $access) (local.get $user)
                  (local.get $wr) (local.get $us) (i32.const 0)))))
    (local.set $tbl (i64.and (local.get $pte) (i64.const 0xFFFFF000)))
    (local.set $idx (i64.and (i64.shr_u (local.get $va) (i64.const 12)) (i64.const 1023)))
    (local.set $pte (call $phys_r32
                      (i64.add (local.get $tbl) (i64.shl (local.get $idx) (i64.const 2)))))
    (if (i64.eqz (i64.and (local.get $pte) (i64.const 1)))
      (then (call $raise_pf (local.get $va)
              (i64.or (i64.extend_i32_u (i32.shl (local.get $access) (i32.const 1)))
                      (i64.extend_i32_u (i32.shl (local.get $user) (i32.const 2)))))
            (return (i64.const 0))))
    (local.set $wr (i32.and (local.get $wr)
                     (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 1)) (i64.const 1)))))
    (local.set $us (i32.and (local.get $us)
                     (i32.wrap_i64 (i64.and (i64.shr_u (local.get $pte) (i64.const 2)) (i64.const 1)))))
    (call $mark_ad_32 (local.get $tbl) (local.get $idx) (local.get $pte) (local.get $access))
    (call $finish_walk (local.get $va) (local.get $pte) (i64.const 12)
          (local.get $access) (local.get $user)
          (local.get $wr) (local.get $us) (i32.const 0)))

  ;; set Accessed (and Dirty on write) in a 64-bit PTE
  (func $mark_ad (param $tbl i64) (param $idx i64) (param $pte i64) (param $access i32)
    (local $new i64)
    (local.set $new (i64.or (local.get $pte) (i64.const 0x20)))     ;; A
    (if (i32.eq (local.get $access) (i32.const 1))
      (then (local.set $new (i64.or (local.get $new) (i64.const 0x40)))))  ;; D
    (if (i64.ne (local.get $new) (local.get $pte))
      (then (call $phys_w64 (i64.add (local.get $tbl) (i64.shl (local.get $idx) (i64.const 3)))
                            (local.get $new)))))

  (func $mark_ad_32 (param $tbl i64) (param $idx i64) (param $pte i64) (param $access i32)
    (local $new i64)
    (local.set $new (i64.or (local.get $pte) (i64.const 0x20)))
    (if (i32.eq (local.get $access) (i32.const 1))
      (then (local.set $new (i64.or (local.get $new) (i64.const 0x40)))))
    (if (i64.ne (local.get $new) (local.get $pte))
      (then (call $phys_w32 (i64.add (local.get $tbl) (i64.shl (local.get $idx) (i64.const 2)))
                            (local.get $new)))))

  ;; permission check + address assembly + TLB fill
  (func $finish_walk (param $va i64) (param $pte i64) (param $shift i64)
                     (param $access i32) (param $user i32)
                     (param $wr i32) (param $us i32) (param $nx i32) (result i64)
    (local $pa i64) (local $mask i64) (local $err i64) (local $wp i32)

    ;; user access to a supervisor page
    (if (i32.and (local.get $user) (i32.eqz (local.get $us)))
      (then (local.set $err (i64.const 1))))
    ;; write to a read-only page.  Supervisor writes are allowed unless CR0.WP.
    (local.set $wp (i32.wrap_i64 (i64.and (i64.shr_u (call $cr0) (i64.const 16)) (i64.const 1))))
    (if (i32.and (i32.eq (local.get $access) (i32.const 1)) (i32.eqz (local.get $wr)))
      (then (if (i32.or (local.get $user) (local.get $wp))
              (then (local.set $err (i64.const 1))))))
    ;; instruction fetch from an NX page
    (if (i32.and (i32.eq (local.get $access) (i32.const 2)) (local.get $nx))
      (then (if (i32.wrap_i64 (i64.and (i64.shr_u (call $efer) (i64.const 11)) (i64.const 1)))
              (then (local.set $err (i64.const 1))))))

    (if (i64.ne (local.get $err) (i64.const 0))
      (then
        (call $raise_pf (local.get $va)
          (i64.or (i64.const 1)   ;; present, so it is a protection violation
            (i64.or (i64.extend_i32_u (i32.shl (local.get $access) (i32.const 1)))
                    (i64.extend_i32_u (i32.shl (local.get $user) (i32.const 2))))))
        (return (i64.const 0))))

    ;; physical = (pte & frame_mask) | (va & offset_mask)
    (local.set $mask (i64.sub (i64.shl (i64.const 1) (local.get $shift)) (i64.const 1)))
    (local.set $pa (i64.or
                     (i64.and (local.get $pte)
                              (i64.and (i64.const 0x000FFFFFFFFFF000)
                                       (i64.xor (local.get $mask) (i64.const -1))))
                     (i64.and (local.get $va) (local.get $mask))))

    ;; fill the TLB with the 4 KiB page containing this translation
    (i64.store (call $tlb_slot (local.get $va))
               (i64.or (i64.and (local.get $va) (i64.const -4096)) (i64.const 1)))
    (i64.store (i32.add (call $tlb_slot (local.get $va)) (i32.const 8))
               (i64.or (i64.and (local.get $pa) (i64.const -4096))
                 (i64.or (i64.extend_i32_u (local.get $us))
                   (i64.or (i64.shl (i64.extend_i32_u (local.get $wr)) (i64.const 1))
                           (i64.shl (i64.extend_i32_u (local.get $nx)) (i64.const 2))))))
    (local.get $pa))

  ;; ---- virtual -> physical with TLB lookup -------------------------------
  ;;  When $sysacc is set the access is one the CPU itself performs while
  ;;  loading a descriptor, an IDT gate or the TSS.  Those are supervisor
  ;;  accesses no matter what CPL the interrupted code was running at.
  (func $translate (param $va i64) (param $access i32) (result i64)
    (local $slot i32) (local $tag i64) (local $data i64) (local $user i32)
    (local $req i32)

    (if (i32.eqz (call $paging_on))
      (then (return (i64.and (i64.and (local.get $va) (i64.const 0xFFFFFFFFFF))
                             (global.get $a20_mask)))))

    (local.set $user (i32.and (i32.eq (global.get $cpl_g) (i32.const 3))
                              (i32.eqz (global.get $sysacc))))
    (local.set $slot (i32.add (i32.const 0x1000)
      (i32.shl (i32.and (i32.wrap_i64 (i64.shr_u (local.get $va) (i64.const 12)))
                        (i32.const 1023))
               (i32.const 4))))
    (local.set $tag (i64.load (local.get $slot)))
    (if (i64.eq (local.get $tag)
                (i64.or (i64.and (local.get $va) (i64.const -4096)) (i64.const 1)))
      (then
        (local.set $data (i64.load (i32.add (local.get $slot) (i32.const 8))))
        ;; Permissions collapse to "these bits must be set in the entry":
        ;;   bit0 user-accessible, bit1 writable.  Execute additionally needs
        ;;   the NX bit clear, which is checked separately.
        (local.set $req
          (i32.or (local.get $user)
                  (i32.shl (i32.and (i32.eq (local.get $access) (i32.const 1))
                                    (i32.or (local.get $user) (global.get $cr0_wp)))
                           (i32.const 1))))
        (if (i32.and
              (i32.eq (i32.and (i32.wrap_i64 (local.get $data)) (local.get $req))
                      (local.get $req))
              (i32.eqz (i32.and (i32.eq (local.get $access) (i32.const 2))
                                (i32.wrap_i64 (i64.and (i64.shr_u (local.get $data)
                                                                  (i64.const 2))
                                                       (i64.const 1))))))
          (then
            (return (i64.and (i64.or (i64.and (local.get $data) (i64.const -4096))
                                     (i64.and (local.get $va) (i64.const 4095)))
                             (global.get $a20_mask)))))))
    (i64.and (call $walk (local.get $va) (local.get $access) (local.get $user))
             (global.get $a20_mask)))

  ;; ---- linear memory access (page-split aware) ---------------------------
  (func $lin_read (param $la i64) (param $size i32) (result i64)
    (local $pa i64) (local $i i32) (local $v i64) (local $off i32)
    (if (global.get $fault) (then (return (i64.const 0))))
    (local.set $off (i32.wrap_i64 (i64.and (local.get $la) (i64.const 4095))))
    ;; Same page as the previous load, and the access fits inside it.  The
    ;; cache is bypassed entirely while $sysacc is set, because those reads skip
    ;; the user/supervisor check and must not leave a translation behind that
    ;; ordinary code could then hit.
    (if (i32.and (i32.eqz (global.get $sysacc)) (i32.and
          (i64.eq (i64.and (local.get $la) (i64.const -4096)) (global.get $dr_page))
          (i32.le_u (i32.add (local.get $off) (local.get $size)) (i32.const 4096))))
      (then (return (call $ram_load
              (i64.add (global.get $dr_phys) (i64.extend_i32_u (local.get $off)))
              (local.get $size)))))
    ;; fast path: access does not cross a page boundary
    (if (i32.le_u (i32.add (local.get $off) (local.get $size)) (i32.const 4096))
      (then
        (local.set $pa (call $translate (local.get $la) (i32.const 0)))
        (if (global.get $fault) (then (return (i64.const 0))))
        (if (call $in_ram (i64.and (local.get $pa) (i64.const -4096)) (i32.const 4096))
          (then
            (if (i32.eqz (global.get $sysacc))
              (then
                (global.set $dr_page (i64.and (local.get $la) (i64.const -4096)))
                (global.set $dr_phys (i64.and (local.get $pa) (i64.const -4096)))))
            (return (call $ram_load (local.get $pa) (local.get $size)))))
        (return (call $phys_rN (local.get $pa) (local.get $size)))))
    ;; slow path: assemble byte by byte
    (local.set $i (i32.const 0))
    (local.set $v (i64.const 0))
    (block $end (loop $l
      (br_if $end (i32.ge_u (local.get $i) (local.get $size)))
      (local.set $pa (call $translate
                       (i64.add (local.get $la) (i64.extend_i32_u (local.get $i)))
                       (i32.const 0)))
      (if (global.get $fault) (then (return (i64.const 0))))
      (local.set $v (i64.or (local.get $v)
                      (i64.shl (call $phys_r8 (local.get $pa))
                               (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 3))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.get $v))

  (func $lin_write (param $la i64) (param $size i32) (param $v i64)
    (local $pa i64) (local $i i32) (local $off i32)
    ;; i32.and is bitwise, so the length has to be reduced to 0/1 first or a
    ;; length like 0x10 ands away the comparison result entirely
    (if (i32.and (i32.ne (global.get $watch_len) (i32.const 0))
                 (i32.and
                   (i64.lt_u (local.get $la)
                             (i64.add (global.get $watch_lo)
                                      (i64.extend_i32_u (global.get $watch_len))))
                   (i64.gt_u (i64.add (local.get $la) (i64.extend_i32_u (local.get $size)))
                             (global.get $watch_lo))))
      (then (call $watch_record (local.get $la) (local.get $size) (local.get $v))))
    ;; A write into a page some compiled block was built from invalidates it.
    ;; The test costs one predictable branch while the JIT is off.
    (if (global.get $jit_on) (then (call $jit_check_write (local.get $la))))
    (if (global.get $fault) (then (return)))
    (local.set $off (i32.wrap_i64 (i64.and (local.get $la) (i64.const 4095))))
    ;; same page as the previous store; the cache is only filled once the page
    ;; has been shown to be writable at the current privilege level
    (if (i32.and (i32.eqz (global.get $sysacc)) (i32.and
          (i64.eq (i64.and (local.get $la) (i64.const -4096)) (global.get $dw_page))
          (i32.le_u (i32.add (local.get $off) (local.get $size)) (i32.const 4096))))
      (then (call $ram_store
              (i64.add (global.get $dw_phys) (i64.extend_i32_u (local.get $off)))
              (local.get $size) (local.get $v))
            (return)))
    (if (i32.le_u (i32.add (local.get $off) (local.get $size)) (i32.const 4096))
      (then
        (local.set $pa (call $translate (local.get $la) (i32.const 1)))
        (if (global.get $fault) (then (return)))
        (if (call $in_ram (i64.and (local.get $pa) (i64.const -4096)) (i32.const 4096))
          (then
            (if (i32.eqz (global.get $sysacc))
              (then
                (global.set $dw_page (i64.and (local.get $la) (i64.const -4096)))
                (global.set $dw_phys (i64.and (local.get $pa) (i64.const -4096)))))
            (call $ram_store (local.get $pa) (local.get $size) (local.get $v))
            (return)))
        (call $phys_wN (local.get $pa) (local.get $size) (local.get $v))
        (return)))
    ;; A split write must fault before any byte lands, so probe both pages first.
    (call $translate (local.get $la) (i32.const 1))
    (drop)
    (call $translate (i64.add (local.get $la) (i64.extend_i32_u (i32.sub (local.get $size) (i32.const 1))))
                     (i32.const 1))
    (drop)
    (if (global.get $fault) (then (return)))
    (local.set $i (i32.const 0))
    (block $end (loop $l
      (br_if $end (i32.ge_u (local.get $i) (local.get $size)))
      (local.set $pa (call $translate
                       (i64.add (local.get $la) (i64.extend_i32_u (local.get $i)))
                       (i32.const 1)))
      (if (global.get $fault) (then (return)))
      (call $phys_w8 (local.get $pa)
            (i64.and (i64.shr_u (local.get $v)
                                (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 3))))
                     (i64.const 255)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))

  ;; Read performed by the CPU on its own behalf (descriptor tables, gates,
  ;; the TSS), which is never subject to the user/supervisor check.
  (func $sys_read (param $la i64) (param $size i32) (result i64)
    (local $prev i32) (local $v i64)
    (local.set $prev (global.get $sysacc))
    (global.set $sysacc (i32.const 1))
    (local.set $v (call $lin_read (local.get $la) (local.get $size)))
    (global.set $sysacc (local.get $prev))
    (local.get $v))

  ;; ---- segmented access --------------------------------------------------
  (func $canonical_ok (param $la i64) (result i32)
    (i64.eq (i64.shr_s (i64.shl (local.get $la) (i64.const 16)) (i64.const 16))
            (local.get $la)))

  ;; Translate a segment-relative offset into a linear address, with limit and
  ;; canonical checks appropriate to the current mode.
  (func $seg_lin (param $seg i32) (param $off i64) (param $size i32) (result i64)
    (local $la i64) (local $lim i64) (local $o i64) (local $end i64) (local $attr i32)
    (if (i32.eq (global.get $mode) (i32.const 3))
      (then
        ;; 64-bit: only FS and GS carry a base; everything else is flat
        (if (i32.or (i32.eq (local.get $seg) (i32.const 4))
                    (i32.eq (local.get $seg) (i32.const 5)))
          (then (local.set $la (i64.add (call $seg_base (local.get $seg)) (local.get $off))))
          (else (local.set $la (local.get $off))))
        (if (i32.eqz (call $canonical_ok (local.get $la)))
          (then
            (if (i32.eq (local.get $seg) (i32.const 2))
              (then (call $raise_ss (i64.const 0)))
              (else (call $raise_gp (i64.const 0))))
            (return (i64.const 0))))
        (return (local.get $la))))
    ;; real / protected mode
    (local.set $la (i64.add (call $seg_base (local.get $seg))
                            (i64.and (local.get $off) (i64.const 0xFFFFFFFF))))
    (if (i32.ne (global.get $mode) (i32.const 0))
      (then
        (local.set $lim (i64.extend_i32_u (call $seg_limit (local.get $seg))))
        (local.set $o (i64.and (local.get $off) (i64.const 0xFFFFFFFF)))
        (local.set $end (i64.add (local.get $o)
                                 (i64.extend_i32_u (i32.sub (local.get $size) (i32.const 1)))))
        (local.set $attr (call $seg_attr (local.get $seg)))
        (if (if (result i32) (i32.eq (i32.and (local.get $attr) (i32.const 0xC)) (i32.const 8))
              ;; Expand-down data: the limit is the lower bound, and the top
              ;; is 4 GiB or 64 KiB by the B bit.  Windows 95's 16-bit kernel
              ;; keeps a flat selector like this, with the bottom 64 KiB cut
              ;; out so that a null pointer faults.
              (then (i32.or (i64.le_u (local.get $o) (local.get $lim))
                            (i64.gt_u (local.get $end)
                                      (select (i64.const 0xFFFFFFFF) (i64.const 0xFFFF)
                                              (i32.and (local.get $attr) (i32.const 0x20))))))
              (else (i64.gt_u (local.get $end) (local.get $lim))))
          (then
            (if (i32.eq (local.get $seg) (i32.const 2))
              (then (call $raise_ss (i64.const 0)))
              (else (call $raise_gp (i64.const 0))))
            (return (i64.const 0))))))
    (i64.and (local.get $la) (i64.const 0xFFFFFFFF)))

  (func $seg_read (param $seg i32) (param $off i64) (param $size i32) (result i64)
    (local $la i64)
    (local.set $la (call $seg_lin (local.get $seg) (local.get $off) (local.get $size)))
    (if (global.get $fault) (then (return (i64.const 0))))
    (call $lin_read (local.get $la) (local.get $size)))

  (func $seg_write (param $seg i32) (param $off i64) (param $size i32) (param $v i64)
    (local $la i64)
    (local.set $la (call $seg_lin (local.get $seg) (local.get $off) (local.get $size)))
    (if (global.get $fault) (then (return)))
    (call $lin_write (local.get $la) (local.get $size) (local.get $v)))

  ;; Load from RAM with no bounds check.  Only used once the caller has already
  ;; established that the whole access lies inside guest RAM.
  (func $ram_load (param $pa i64) (param $size i32) (result i64)
    (block $b8 (block $b4 (block $b2 (block $b1
      (br_table $b1 $b1 $b2 $b1 $b4 $b1 $b1 $b1 $b8 (local.get $size)))
      (return (i64.load8_u $ram (local.get $pa))))
      (return (i64.load16_u $ram align=1 (local.get $pa))))
      (return (i64.load32_u $ram align=1 (local.get $pa))))
    (i64.load $ram align=1 (local.get $pa)))

  (func $ram_store (param $pa i64) (param $size i32) (param $v i64)
    (block $b8 (block $b4 (block $b2 (block $b1
      (br_table $b1 $b1 $b2 $b1 $b4 $b1 $b1 $b1 $b8 (local.get $size)))
      (i64.store8 $ram (local.get $pa) (local.get $v)) (return))
      (i64.store16 $ram align=1 (local.get $pa) (local.get $v)) (return))
      (i64.store32 $ram align=1 (local.get $pa) (local.get $v)) (return))
    (i64.store $ram align=1 (local.get $pa) (local.get $v)))

  ;; ---- instruction fetch -------------------------------------------------
  (func $fetch (param $size i32) (result i64)
    (local $la i64) (local $pa i64) (local $v i64) (local $i i32) (local $off i32)
    (local $rip i64)
    ;; multi-byte immediates and displacements come from the window too
    (if (i32.ge_u (global.get $iw_left) (local.get $size))
      (then
        (local.set $v (i64.and (global.get $iw)
          (i64.load (i32.add (i32.const 0x6200) (i32.shl (local.get $size) (i32.const 3))))))
        (global.set $iw (i64.shr_u (global.get $iw)
          (i64.extend_i32_u (i32.shl (local.get $size) (i32.const 3)))))
        (global.set $iw_left (i32.sub (global.get $iw_left) (local.get $size)))
        (global.set $rip_g (i64.and (i64.add (global.get $rip_g)
                                             (i64.extend_i32_u (local.get $size)))
                                    (global.get $rip_mask)))
        (return (local.get $v))))
    ;; Falling through here advances RIP without consuming from the window, so
    ;; whatever is still buffered no longer lines up with RIP and must go.
    (global.set $iw_left (i32.const 0))
    ;; RIP is read and written exactly once
    (local.set $rip (global.get $rip_g))
    (local.set $la (i64.add (global.get $cs_base) (local.get $rip)))
    (local.set $rip (i64.add (local.get $rip) (i64.extend_i32_u (local.get $size))))
    (if (i32.ne (global.get $mode) (i32.const 3))
      (then (local.set $la (i64.and (local.get $la) (i64.const 0xFFFFFFFF)))
            (local.set $rip (i64.and (local.get $rip) (i64.const 0xFFFFFFFF)))))
    (global.set $rip_g (local.get $rip))

    ;; fast path: same code page as last time, and the access fits inside it
    (local.set $off (i32.wrap_i64 (i64.and (local.get $la) (i64.const 4095))))
    (if (i32.and
          (i64.eq (i64.and (local.get $la) (i64.const -4096)) (global.get $fetch_page))
          (i32.le_u (i32.add (local.get $off) (local.get $size)) (i32.const 4096)))
      (then
        (return (call $ram_load
                  (i64.add (global.get $fetch_phys) (i64.extend_i32_u (local.get $off)))
                  (local.get $size)))))

    (if (i32.le_u (i32.add (local.get $off) (local.get $size)) (i32.const 4096))
      (then
        (local.set $pa (call $translate (local.get $la) (i32.const 2)))
        (if (global.get $fault) (then (return (i64.const 0))))
        ;; remember the page when it is ordinary RAM, so the next byte is cheap
        (if (call $in_ram (i64.and (local.get $pa) (i64.const -4096)) (i32.const 4096))
          (then
            (global.set $fetch_page (i64.and (local.get $la) (i64.const -4096)))
            (global.set $fetch_phys (i64.and (local.get $pa) (i64.const -4096)))))
        (return (call $phys_rN (local.get $pa) (local.get $size)))))
    (local.set $i (i32.const 0))
    (local.set $v (i64.const 0))
    (block $end (loop $l
      (br_if $end (i32.ge_u (local.get $i) (local.get $size)))
      (local.set $pa (call $translate
                       (i64.add (local.get $la) (i64.extend_i32_u (local.get $i)))
                       (i32.const 2)))
      (if (global.get $fault) (then (return (i64.const 0))))
      (local.set $v (i64.or (local.get $v)
                      (i64.shl (call $phys_r8 (local.get $pa))
                               (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 3))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.get $v))

  ;; Pull the next eight instruction bytes into a register.  Only valid when
  ;; the whole window sits inside the cached code page; otherwise the decoder
  ;; falls back to fetching a byte at a time.
  (func $fill_window
    (local $la i64) (local $off i32)
    (local.set $la (i64.and (i64.add (global.get $cs_base) (global.get $rip_g))
                            (global.get $rip_mask)))
    (if (i32.and
          (i64.eq (i64.and (local.get $la) (i64.const -4096)) (global.get $fetch_page))
          (i32.le_u (i32.wrap_i64 (i64.and (local.get $la) (i64.const 4095)))
                    (i32.const 4088)))
      (then
        (global.set $iw (i64.load $ram align=1
          (i64.add (global.get $fetch_phys) (i64.and (local.get $la) (i64.const 4095)))))
        (global.set $iw_left (i32.const 8)))
      (else (global.set $iw_left (i32.const 0)))))

  ;; Single-byte fetch, specialised: opcodes, ModRM, SIB and 8-bit immediates
  ;; all come through here, and a one-byte read can never cross a page.
  (func $fetch8 (result i32)
    (local $rip i64) (local $la i64) (local $b i32)
    ;; the common case: take a byte straight out of the window
    (if (global.get $iw_left)
      (then
        (local.set $b (i32.wrap_i64 (i64.and (global.get $iw) (i64.const 255))))
        (global.set $iw (i64.shr_u (global.get $iw) (i64.const 8)))
        (global.set $iw_left (i32.sub (global.get $iw_left) (i32.const 1)))
        (global.set $rip_g (i64.and (i64.add (global.get $rip_g) (i64.const 1))
                                    (global.get $rip_mask)))
        (return (local.get $b))))
    (local.set $rip (global.get $rip_g))
    (local.set $la (i64.add (global.get $cs_base) (local.get $rip)))
    (if (i32.ne (global.get $mode) (i32.const 3))
      (then (local.set $la (i64.and (local.get $la) (i64.const 0xFFFFFFFF)))))
    (if (i64.eq (i64.and (local.get $la) (i64.const -4096)) (global.get $fetch_page))
      (then
        ;; advance RIP with a single write and read straight from the page
        (global.set $rip_g
          (if (result i64) (i32.eq (global.get $mode) (i32.const 3))
            (then (i64.add (local.get $rip) (i64.const 1)))
            (else (i64.and (i64.add (local.get $rip) (i64.const 1))
                           (i64.const 0xFFFFFFFF)))))
        (return (i32.wrap_i64 (i64.load8_u $ram
          (i64.add (global.get $fetch_phys)
                   (i64.and (local.get $la) (i64.const 4095))))))))
    (i32.wrap_i64 (call $fetch (i32.const 1))))
  (func $fetch16 (result i32) (i32.wrap_i64 (call $fetch (i32.const 2))))
  (func $fetch32 (result i32) (i32.wrap_i64 (call $fetch (i32.const 4))))
  (func $fetch64 (result i64) (call $fetch (i32.const 8)))

  ;; sign-extended immediate fetch of the given width
  (func $fetch_imm (param $size i32) (result i64)
    (block $d (result i64)
      (if (i32.eq (local.get $size) (i32.const 1))
        (then (br $d (i64.extend_i32_s (i32.extend8_s (call $fetch8))))))
      (if (i32.eq (local.get $size) (i32.const 2))
        (then (br $d (i64.extend_i32_s (i32.extend16_s (call $fetch16))))))
      (if (i32.eq (local.get $size) (i32.const 4))
        (then (br $d (i64.extend_i32_s (call $fetch32)))))
      (call $fetch64)))
