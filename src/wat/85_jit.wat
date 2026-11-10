  ;; =========================================================================
  ;;  Part 85: block cache, translation cache and runtime support for the JIT
  ;; =========================================================================
  ;;
  ;;  Compiled blocks live in modules the host builds while the guest runs and
  ;;  publishes into the imported $jit table.  The core reaches them with one
  ;;  call_indirect, so a block costs no JavaScript transition at all.
  ;;
  ;;  A block is keyed on the PHYSICAL address of its first instruction, plus
  ;;  what decides how its bytes decode and behave: the CPU mode, virtual-8086,
  ;;  and the stack width.  Keying on linear addresses, as this first did, threw
  ;;  every block away at each CR3 load -- every task switch -- which on Windows
  ;;  meant thousands of flushes in a boot and a cache that never filled.
  ;;  Compiled code works RIP out relative to wherever it was entered, so the
  ;;  same physical code reached through another CS base or mapping still runs
  ;;  correctly.
  ;;
  ;;  What a compiled block promises:
  ;;    - it leaves RIP pointing at the next instruction to execute
  ;;    - when an instruction faults, it sets $rip0 and $rsp0 to that
  ;;      instruction's start, and the flags to what they were there, exactly
  ;;      as the interpreter would have left them
  ;;    - it returns the number of instructions it retired, and has already
  ;;      added them to the timestamp counter
  ;;
  ;;  Code is invalidated a page at a time.  A bitmap marks every physical page
  ;;  holding compiled code; no store to such a page can take a cached fast
  ;;  path, and one that reaches it bumps the page's generation, which every
  ;;  block built from the page was stamped with.  Stale blocks then simply
  ;;  stop matching.
  ;;
  ;;  LAYOUT (state memory)
  ;;    0x010000  JIT TLB, reads:  4096 x {tag u64, delta u64}
  ;;    0x020000  JIT TLB, writes: the same
  ;;    0x030000  code page bitmap, one bit per 4 KiB page (2^20 bits)
  ;;    0x050000  page generations, 65536 x u32, by page number modulo 65536
  ;;    0x090000  block cache, 32768 x {pa u64, slot+1 u32, key|gen<<8 u32}
  ;;    0x110000  hotness, 65536 x u32: tag in the high 24 bits, count in the low 8
  ;;    0x150000  hot ring index (u32); entries from 0x150010, 4096 x {pa u64, kg u32}
  ;;    0x1A0010  the last 256 invalidations, {pa u64, linear RIP u64}, for diagnosis
  ;;    0x200000  code regions, 65536 x 40 bytes, by page number modulo 65536:
  ;;              {page+1 u32 (0 free, -1 shared), pad, 256-bit mask}, one bit
  ;;              per 16 bytes of the page that some block's instructions occupy

  (type $jitblk (func (result i32)))

  (global $jit_on (mut i32) (i32.const 0))

  ;; Set whenever control transfers somewhere rather than falling through, so
  ;; the cache is consulted at branch targets and nowhere else.
  (global $jit_head (mut i32) (i32.const 1))

  ;; Treat every address as a branch target.  This exists for the differential
  ;; test: block selection is a performance policy, but what a block *emits* is
  ;; a correctness question, and gating on real branch targets would leave
  ;; straight-line test programs compiling almost nothing to compare.
  (global $jit_all_heads (mut i32) (i32.const 0))

  (global $jit_lookups (mut i32) (i32.const 0))
  (global $jit_hits    (mut i32) (i32.const 0))
  (global $jit_notes   (mut i32) (i32.const 0))
  (global $jit_invals  (mut i32) (i32.const 0))
  (global $jit_blocks_run (mut i64) (i64.const 0))
  (global $jit_instrs_run (mut i64) (i64.const 0))
  ;; A new code page was marked since the host last committed a batch, so
  ;; write translations that may point into it have to go.
  (global $jit_wdirty  (mut i32) (i32.const 0))

  (global $JTLB_R    i32 (i32.const 0x10000))
  (global $JTLB_W    i32 (i32.const 0x20000))
  (global $JIT_CODE  i32 (i32.const 0x30000))
  (global $JIT_GEN   i32 (i32.const 0x50000))
  (global $JIT_CACHE i32 (i32.const 0x90000))
  (global $JIT_HOT   i32 (i32.const 0x110000))
  (global $JIT_RINGI i32 (i32.const 0x150000))
  (global $JIT_RING  i32 (i32.const 0x150010))
  (global $JIT_REGION i32 (i32.const 0x200000))

  ;; How many times an address must be reached before it is worth compiling.
  ;; Mutable so a test can drop it to 1 and compile everything it touches.
  (global $JIT_THRESHOLD (mut i32) (i32.const 50))

  ;; ---- the JIT TLB ---------------------------------------------------------
  (func $jtlb_slot (param $la i64) (result i32)
    (i32.shl (i32.and (i32.wrap_i64 (i64.shr_u (local.get $la) (i64.const 12)))
                      (i32.const 4095))
             (i32.const 4)))

  (func $jtlb_flush_all
    (memory.fill (global.get $JTLB_R) (i32.const 0) (i32.const 0x20000)))

  ;; ---- code pages ----------------------------------------------------------
  (func $jit_page_index (param $pa i64) (result i32)
    (i32.and (i32.wrap_i64 (i64.shr_u (local.get $pa) (i64.const 12))) (i32.const 0xFFFFF)))

  (func $jit_is_code (param $pa i64) (result i32)
    (local $i i32)
    (local.set $i (call $jit_page_index (local.get $pa)))
    (i32.and (i32.load8_u (i32.add (global.get $JIT_CODE) (i32.shr_u (local.get $i) (i32.const 3))))
             (i32.shl (i32.const 1) (i32.and (local.get $i) (i32.const 7)))))

  (func $jit_gen_addr (param $pa i64) (result i32)
    (i32.add (global.get $JIT_GEN)
             (i32.shl (i32.and (i32.wrap_i64 (i64.shr_u (local.get $pa) (i64.const 12)))
                               (i32.const 0xFFFF))
                      (i32.const 2))))

  ;; Which 16-byte regions of a page compiled code occupies.  Code and data
  ;; share pages all the time -- a driver's variables beside its functions, a
  ;; thunk allocated next to a stack -- and only a store into the code itself
  ;; should cost the page its blocks.
  ;;
  ;; The table has an entry per page number modulo 65536, tagged with the page
  ;; it describes.  Two pages with live code that land on one entry make it
  ;; "shared", which stands for every region of both: needlessly cautious, but
  ;; never wrong.  An entry's own page losing its code clears the entry.
  (func $jit_region_addr (param $pa i64) (result i32)
    (i32.add (global.get $JIT_REGION)
             (i32.mul (i32.and (i32.wrap_i64 (i64.shr_u (local.get $pa) (i64.const 12)))
                               (i32.const 0xFFFF))
                      (i32.const 40))))

  (func $jit_page_tag (param $pa i64) (result i32)
    (i32.add (i32.wrap_i64 (i64.shr_u (local.get $pa) (i64.const 12))) (i32.const 1)))

  ;; Does a store of `len` bytes at `pa` touch code?  Only asked of pages whose
  ;; code bit is set.
  (func $jit_region_hit (param $pa i64) (param $len i32) (result i32)
    (local $e i32) (local $tag i32) (local $r i32) (local $last i32) (local $off i32)
    (local.set $e (call $jit_region_addr (local.get $pa)))
    (local.set $tag (i32.load (local.get $e)))
    (if (i32.ne (local.get $tag) (call $jit_page_tag (local.get $pa)))
      (then (return (i32.const 1))))           ;; shared, or not ours: assume so
    (local.set $off (i32.and (i32.wrap_i64 (local.get $pa)) (i32.const 4095)))
    (local.set $r (i32.shr_u (local.get $off) (i32.const 4)))
    (local.set $last (i32.shr_u (i32.add (local.get $off) (i32.sub (local.get $len) (i32.const 1)))
                                (i32.const 4)))
    (if (i32.gt_u (local.get $last) (i32.const 255)) (then (local.set $last (i32.const 255))))
    (block $no (loop $l
      (br_if $no (i32.gt_u (local.get $r) (local.get $last)))
      (if (i32.and (i32.load8_u offset=8 (i32.add (local.get $e) (i32.shr_u (local.get $r) (i32.const 3))))
                   (i32.shl (i32.const 1) (i32.and (local.get $r) (i32.const 7))))
        (then (return (i32.const 1))))
      (local.set $r (i32.add (local.get $r) (i32.const 1)))
      (br $l)))
    (i32.const 0))

  ;; A store reached a page with compiled code on it.
  ;; A thunk VMM builds inside one of its own structures shares sixteen bytes
  ;; with a field written on every interrupt, so the region test alone is not
  ;; enough; the host settles it to the byte.
  (func $jit_code_store (param $pa i64) (param $len i32)
    (if (call $jit_region_hit (local.get $pa) (local.get $len))
      (then
        (if (call $jit_precise (local.get $pa) (local.get $len))
          (then (call $jit_code_written (local.get $pa)))))))

  ;; Every block built from the page goes stale at once; the page stops being
  ;; code until something is compiled from it again, so further stores to it
  ;; run at full speed.
  (func $jit_code_written (param $pa i64)
    (local $i i32) (local $a i32) (local $g i32)
    ;; the page's regions go with its blocks, unless the entry is shared
    (local.set $g (call $jit_region_addr (local.get $pa)))
    (if (i32.eq (i32.load (local.get $g)) (call $jit_page_tag (local.get $pa)))
      (then (memory.fill (i32.add (local.get $g) (i32.const 8)) (i32.const 0) (i32.const 32))))
    (local.set $i (call $jit_page_index (local.get $pa)))
    (local.set $a (i32.add (global.get $JIT_CODE) (i32.shr_u (local.get $i) (i32.const 3))))
    (i32.store8 (local.get $a)
      (i32.and (i32.load8_u (local.get $a))
               (i32.xor (i32.shl (i32.const 1) (i32.and (local.get $i) (i32.const 7)))
                        (i32.const -1))))
    (local.set $g (call $jit_gen_addr (local.get $pa)))
    (i32.store (local.get $g) (i32.add (i32.load (local.get $g)) (i32.const 1)))
    ;; Recorded, because a page invalidated over and over is the first thing
    ;; to look at when compiled code is not paying off: {pa, linear RIP} x 256.
    (local.set $g (i32.add (i32.const 0x1A0010)
                           (i32.shl (i32.and (global.get $jit_invals) (i32.const 255)) (i32.const 4))))
    (i64.store (local.get $g) (local.get $pa))
    (i64.store offset=8 (local.get $g) (i64.add (global.get $cs_base) (global.get $rip0)))
    (global.set $jit_invals (i32.add (global.get $jit_invals) (i32.const 1)))
    (global.set $jit_exit (i32.const 1)))

  ;; ---- keys ----------------------------------------------------------------
  ;;  bits 0-1 mode, bit 2 virtual-8086, bit 3 32-bit stack.  The generation
  ;;  of the block's page sits above them in the cache entry.
  (func $jit_key (result i32)
    (i32.or (i32.or (global.get $mode) (i32.shl (global.get $vm) (i32.const 2)))
            (i32.shl (i32.and (i32.ne (global.get $mode) (i32.const 3))
                              (i32.and (i32.shr_u (i32.load (i32.const 0x154)) (i32.const 5))
                                       (i32.const 1)))
                     (i32.const 3))))

  (func $jit_kg (param $pa i64) (result i32)
    (i32.or (call $jit_key)
            (i32.shl (i32.load (call $jit_gen_addr (local.get $pa))) (i32.const 8))))

  (func $jit_mix (param $pa i64) (result i32)
    (i32.xor (i32.xor (i32.wrap_i64 (local.get $pa))
                      (i32.wrap_i64 (i64.shr_u (local.get $pa) (i64.const 15))))
             (i32.wrap_i64 (i64.shr_u (local.get $pa) (i64.const 29)))))

  (func $jit_slot_addr (param $pa i64) (result i32)
    (i32.add (global.get $JIT_CACHE)
             (i32.shl (i32.and (call $jit_mix (local.get $pa)) (i32.const 32767))
                      (i32.const 4))))

  ;; ---- hotness -------------------------------------------------------------
  ;;  Each entry belongs to one (address, key, generation), identified by a
  ;;  tag.  A colliding address ages the incumbent by one rather than evicting
  ;;  it, so a genuinely hot address gains faster than passers-by drain it.
  ;;  255 means "offered to the host"; folding the generation into the tag is
  ;;  what lets code rewritten in place become hot -- and compiled -- again.
  (func $jit_hot_entry (param $pa i64) (result i32)
    (i32.add (global.get $JIT_HOT)
             (i32.shl (i32.and (i32.xor (call $jit_mix (local.get $pa))
                                        (i32.shr_u (call $jit_mix (local.get $pa)) (i32.const 16)))
                               (i32.const 0xFFFF))
                      (i32.const 2))))

  (func $jit_hot_tag (param $pa i64) (param $kg i32) (result i32)
    (i32.and (i32.xor (i32.wrap_i64 (local.get $pa))
                      (i32.mul (local.get $kg) (i32.const 0x9E3779B1)))
             (i32.const 0xFFFFFF)))

  (func $jit_note (param $pa i64) (param $kg i32)
    (local $e i32) (local $v i32) (local $tag i32) (local $c i32) (local $ri i32)
    (local $slot i32)
    (global.set $jit_notes (i32.add (global.get $jit_notes) (i32.const 1)))
    (local.set $e (call $jit_hot_entry (local.get $pa)))
    (local.set $tag (call $jit_hot_tag (local.get $pa) (local.get $kg)))
    (local.set $v (i32.load (local.get $e)))
    (local.set $c (i32.and (local.get $v) (i32.const 255)))
    (if (i32.ne (i32.shr_u (local.get $v) (i32.const 8)) (local.get $tag))
      (then
        (if (i32.and (i32.ne (local.get $c) (i32.const 255))
                     (i32.gt_u (local.get $c) (i32.const 0)))
          (then
            (i32.store (local.get $e) (i32.sub (local.get $v) (i32.const 1)))
            (return)))
        (local.set $c (i32.const 0))))
    (if (i32.eq (local.get $c) (i32.const 255)) (then (return)))
    (local.set $c (i32.add (local.get $c) (i32.const 1)))
    (if (i32.lt_u (local.get $c) (global.get $JIT_THRESHOLD))
      (then
        (i32.store (local.get $e)
                   (i32.or (i32.shl (local.get $tag) (i32.const 8)) (local.get $c)))
        (return)))
    (i32.store (local.get $e)
               (i32.or (i32.shl (local.get $tag) (i32.const 8)) (i32.const 255)))
    (local.set $ri (i32.load (global.get $JIT_RINGI)))
    (local.set $slot (i32.add (global.get $JIT_RING)
                              (i32.shl (i32.and (local.get $ri) (i32.const 4095)) (i32.const 4))))
    (i64.store (local.get $slot) (local.get $pa))
    (i32.store offset=8 (local.get $slot) (local.get $kg))
    (i32.store (global.get $JIT_RINGI) (i32.add (local.get $ri) (i32.const 1))))

  ;; ---- lookup --------------------------------------------------------------
  ;;  The code page cache usually holds RIP's page already.  When it does not,
  ;;  the TLB is consulted without walking: a lookup must never fault, and a
  ;;  page the TLB does not know is one the interpreter is about to walk anyway.
  (func $jit_probe_fetch (param $la i64) (result i32)
    (local $slot i32) (local $data i64) (local $pa i64) (local $user i32)
    (if (i32.eqz (call $paging_on))
      (then
        (local.set $pa (i64.and (i64.and (local.get $la) (i64.const 0xFFFFFFFFFF))
                                (global.get $a20_mask))))
      (else
        (local.set $slot (call $tlb_slot (local.get $la)))
        (if (i64.ne (i64.load (local.get $slot))
                    (i64.or (i64.and (local.get $la) (i64.const -4096)) (i64.const 1)))
          (then (return (i32.const 0))))
        (local.set $data (i64.load offset=8 (local.get $slot)))
        (local.set $user (i32.eq (global.get $cpl_g) (i32.const 3)))
        ;; user pages only for user code, and never a no-execute page
        (if (i32.or (i32.and (local.get $user)
                             (i32.eqz (i32.wrap_i64 (i64.and (local.get $data) (i64.const 1)))))
                    (i32.wrap_i64 (i64.and (i64.shr_u (local.get $data) (i64.const 2)) (i64.const 1))))
          (then (return (i32.const 0))))
        (local.set $pa (i64.and (i64.or (i64.and (local.get $data) (i64.const -4096))
                                        (i64.and (local.get $la) (i64.const 4095)))
                                (global.get $a20_mask)))))
    (if (i32.eqz (call $in_ram (i64.and (local.get $pa) (i64.const -4096)) (i32.const 4096)))
      (then (return (i32.const 0))))
    (global.set $fetch_page (i64.and (local.get $la) (i64.const -4096)))
    (global.set $fetch_phys (i64.and (local.get $pa) (i64.const -4096)))
    (i32.const 1))

  ;; Returns the table slot plus one, or zero on a miss.
  (func $jit_lookup (result i32)
    (local $la i64) (local $pa i64) (local $e i32) (local $kg i32)
    (global.set $jit_lookups (i32.add (global.get $jit_lookups) (i32.const 1)))
    (local.set $la (i64.and (i64.add (global.get $cs_base) (global.get $rip_g))
                            (global.get $rip_mask)))
    (if (i64.ne (i64.and (local.get $la) (i64.const -4096)) (global.get $fetch_page))
      (then
        (if (i32.eqz (call $jit_probe_fetch (local.get $la)))
          (then
            ;; Try again at the next instruction, which will have walked it.
            (global.set $jit_head (i32.const 1))
            (return (i32.const 0))))))
    (local.set $pa (i64.add (global.get $fetch_phys) (i64.and (local.get $la) (i64.const 4095))))
    (local.set $kg (call $jit_kg (local.get $pa)))
    (local.set $e (call $jit_slot_addr (local.get $pa)))
    (if (i32.and (i64.eq (i64.load (local.get $e)) (local.get $pa))
                 (i32.eq (i32.load offset=12 (local.get $e)) (local.get $kg)))
      (then
        (global.set $jit_hits (i32.add (global.get $jit_hits) (i32.const 1)))
        (return (i32.load offset=8 (local.get $e)))))
    (call $jit_note (local.get $pa) (local.get $kg))
    (i32.const 0))

  ;; =========================================================================
  ;;  Host interface
  ;; =========================================================================
  (func $jit_reset (export "jit_reset")
    (memory.fill (global.get $JIT_CACHE) (i32.const 0) (i32.const 0x80000))
    (memory.fill (global.get $JIT_HOT) (i32.const 0) (i32.const 0x40000))
    (memory.fill (global.get $JIT_CODE) (i32.const 0) (i32.const 0x20000))
    (memory.fill (global.get $JIT_REGION) (i32.const 0) (i32.const 0x280000))
    (i32.store (global.get $JIT_RINGI) (i32.const 0)))

  ;; Kept for the host and the tests, which still call it by its old name.
  (func (export "jit_flush") (call $jit_reset))

  (func (export "jit_enable") (param $on i32)
    (global.set $jit_on (local.get $on))
    (call $jit_reset))

  (func (export "jit_enabled") (result i32) (global.get $jit_on))
  (func (export "jit_lookup_count") (result i32) (global.get $jit_lookups))
  (func (export "jit_hit_count") (result i32) (global.get $jit_hits))
  (func (export "jit_note_count") (result i32) (global.get $jit_notes))
  (func (export "jit_inval_count") (result i32) (global.get $jit_invals))
  (func (export "jit_inval_pa") (param $i i32) (result i64)
    (i64.load (i32.add (i32.const 0x1A0010) (i32.shl (i32.and (local.get $i) (i32.const 255)) (i32.const 4)))))
  (func (export "jit_inval_rip") (param $i i32) (result i64)
    (i64.load offset=8 (i32.add (i32.const 0x1A0010) (i32.shl (i32.and (local.get $i) (i32.const 255)) (i32.const 4)))))
  (func (export "jit_flush_count") (result i32) (global.get $jit_invals))
  (func (export "jit_blocks_run") (result i64) (global.get $jit_blocks_run))
  (func (export "jit_instrs_run") (result i64) (global.get $jit_instrs_run))

  (func (export "jit_all_heads") (param $on i32)
    (global.set $jit_all_heads (local.get $on))
    (call $jit_reset))

  (func (export "jit_set_threshold") (param $n i32)
    (global.set $JIT_THRESHOLD (local.get $n))
    (call $jit_reset))

  ;; Drain the queue of addresses that got hot: the host compiles these.
  (func (export "jit_hot_count") (result i32) (i32.load (global.get $JIT_RINGI)))
  (func (export "jit_hot_pa") (param $i i32) (result i64)
    (i64.load (i32.add (global.get $JIT_RING)
                       (i32.shl (i32.and (local.get $i) (i32.const 4095)) (i32.const 4)))))
  (func (export "jit_hot_kg") (param $i i32) (result i32)
    (i32.load offset=8 (i32.add (global.get $JIT_RING)
                                (i32.shl (i32.and (local.get $i) (i32.const 4095)) (i32.const 4)))))

  ;; The key a block compiled right now would need, for the host to compile
  ;; one ahead of time.
  (func (export "jit_current_key") (result i32) (call $jit_key))

  ;; The current generation of a physical page.
  (func (export "jit_page_gen") (param $pa i64) (result i32)
    (i32.load (call $jit_gen_addr (local.get $pa))))

  ;; Publish a compiled block.  The host has already placed the function in the
  ;; table; this is what makes the core start using it.  $kg carries the key
  ;; and the generation the block was built against; if the page has moved on
  ;; since, the block is already stale and is not installed.
  (func (export "jit_install") (param $pa i64) (param $kg i32) (param $slot i32)
        (param $m0 i64) (param $m1 i64) (param $m2 i64) (param $m3 i64) (result i32)
    (local $e i32) (local $old i64) (local $i i32) (local $a i32) (local $bit i32) (local $r i32)
    (local $tag i32) (local $mine i32) (local $other i64)
    (if (i32.ne (i32.shr_u (local.get $kg) (i32.const 8))
                (i32.load (call $jit_gen_addr (local.get $pa))))
      (then (return (i32.const 0))))
    (local.set $e (call $jit_slot_addr (local.get $pa)))
    ;; Whatever this displaces may get hot again and be offered anew, rather
    ;; than staying "already offered" while nothing can run it.
    (local.set $old (i64.load (local.get $e)))
    (if (i32.and (i32.ne (i32.load offset=8 (local.get $e)) (i32.const 0))
                 (i64.ne (local.get $old) (local.get $pa)))
      (then (i32.store (call $jit_hot_entry (local.get $old)) (i32.const 0))))
    (i64.store (local.get $e) (local.get $pa))
    (i32.store offset=8 (local.get $e) (i32.add (local.get $slot) (i32.const 1)))
    (i32.store offset=12 (local.get $e) (local.get $kg))
    (local.set $i (call $jit_page_index (local.get $pa)))
    (local.set $a (i32.add (global.get $JIT_CODE) (i32.shr_u (local.get $i) (i32.const 3))))
    (local.set $bit (i32.shl (i32.const 1) (i32.and (local.get $i) (i32.const 7))))
    (if (i32.eqz (i32.and (i32.load8_u (local.get $a)) (local.get $bit)))
      (then
        (i32.store8 (local.get $a) (i32.or (i32.load8_u (local.get $a)) (local.get $bit)))
        (global.set $jit_wdirty (i32.const 1))))
    ;; $m0..$m3 are the 16-byte regions the block's instructions occupy.
    (local.set $r (call $jit_region_addr (local.get $pa)))
    (local.set $tag (i32.load (local.get $r)))
    (local.set $mine (call $jit_page_tag (local.get $pa)))
    (if (i32.ne (local.get $tag) (local.get $mine))
      (then
        (if (i32.ne (local.get $tag) (i32.const -1))
          (then
            ;; Free, or held by a page with no code left: take it.  Otherwise
            ;; two pages with live code share it, and it stands for both.
            (local.set $other (i64.shl (i64.extend_i32_u (i32.sub (local.get $tag) (i32.const 1)))
                                       (i64.const 12)))
            (if (i32.or (i32.eqz (local.get $tag))
                        (i32.eqz (call $jit_is_code (local.get $other))))
              (then
                (i32.store (local.get $r) (local.get $mine))
                (memory.fill (i32.add (local.get $r) (i32.const 8)) (i32.const 0) (i32.const 32)))
              (else
                (i32.store (local.get $r) (i32.const -1))
                (memory.fill (i32.add (local.get $r) (i32.const 8)) (i32.const -1) (i32.const 32))))))))
    (if (i32.eq (i32.load (local.get $r)) (local.get $mine))
      (then
        (i64.store offset=8 (local.get $r) (i64.or (i64.load offset=8 (local.get $r)) (local.get $m0)))
        (i64.store offset=16 (local.get $r) (i64.or (i64.load offset=16 (local.get $r)) (local.get $m1)))
        (i64.store offset=24 (local.get $r) (i64.or (i64.load offset=24 (local.get $r)) (local.get $m2)))
        (i64.store offset=32 (local.get $r) (i64.or (i64.load offset=32 (local.get $r)) (local.get $m3)))))
    (i32.const 1))

  ;; Mark an address as not worth offering again (it would not compile).
  (func (export "jit_reject") (param $pa i64) (param $kg i32)
    (i32.store (call $jit_hot_entry (local.get $pa))
               (i32.or (i32.shl (call $jit_hot_tag (local.get $pa) (local.get $kg)) (i32.const 8))
                       (i32.const 255))))

  ;; After a batch of installs: no write translation may still point into a
  ;; page that has just become code.
  (func (export "jit_commit")
    (if (global.get $jit_wdirty)
      (then
        (memory.fill (global.get $JTLB_W) (i32.const 0) (i32.const 0x10000))
        (global.set $jit_wdirty (i32.const 0)))))

  ;; The host wrote guest RAM directly (a BIOS disk read, a mode set).  The
  ;; whole range is treated as touching every region of each page it reaches,
  ;; which is conservative and only costs a recompile.
  (func (export "jit_host_write") (param $pa i64) (param $len i32)
    (local $p i64) (local $end i64)
    (local.set $p (i64.and (local.get $pa) (i64.const -4096)))
    (local.set $end (i64.add (local.get $pa) (i64.extend_i32_u (local.get $len))))
    (block $e (loop $l
      (br_if $e (i64.ge_u (local.get $p) (local.get $end)))
      (if (call $jit_is_code (local.get $p)) (then (call $jit_code_written (local.get $p))))
      (local.set $p (i64.add (local.get $p) (i64.const 4096)))
      (br $l))))

  ;; ---- helpers compiled blocks call --------------------------------------
  ;; These are the interpreter's own primitives, reached with operands the
  ;; compiler already worked out.  Keeping the semantics here rather than
  ;; re-deriving them in the generated code is what makes a compiled block and
  ;; an interpreted one agree by construction.

  ;; One instruction, interpreted, at RIP.  Non-zero means the block must stop:
  ;; it faulted, halted, asked to leave the run loop, or changed something the
  ;; block was compiled against.
  (func (export "j_step") (result i32)
    (call $step)
    (i32.or (i32.or (global.get $fault) (global.get $exit_req))
            (i32.or (global.get $halted) (global.get $jit_exit))))

  (func (export "j_alu") (param $op i32) (param $a i64) (param $b i64) (param $size i32)
        (result i64)
    (call $alu (local.get $op) (local.get $a) (local.get $b) (local.get $size)))

  (func (export "j_shift") (param $op i32) (param $v i64) (param $cnt i32) (param $size i32)
        (result i64)
    (call $do_shift (local.get $op) (local.get $v) (local.get $cnt) (local.get $size)))

  ;; Slow paths for memory.  Reads report a fault through $fault; writes also
  ;; say whether the store landed on compiled code, which ends the block.
  (func (export "j_rd") (param $seg i32) (param $off i64) (param $size i32) (result i64)
    (call $seg_read (local.get $seg) (local.get $off) (local.get $size)))

  (func (export "j_wr") (param $seg i32) (param $off i64) (param $size i32) (param $v i64)
        (result i32)
    (call $seg_write (local.get $seg) (local.get $off) (local.get $size) (local.get $v))
    (i32.or (global.get $fault) (global.get $jit_exit)))

  ;; Long mode stack accesses skip segmentation, as $push and $pop do.
  (func (export "j_lrd") (param $la i64) (param $size i32) (result i64)
    (call $lin_read (local.get $la) (local.get $size)))

  (func (export "j_lwr") (param $la i64) (param $size i32) (param $v i64) (result i32)
    (call $lin_write (local.get $la) (local.get $size) (local.get $v))
    (i32.or (global.get $fault) (global.get $jit_exit)))

  ;; Produce the flags a deferred operation would have set.
  ;;   kind 1 add, 2 sub, 3 logic (b unused), 4 inc, 5 dec (b unused)
  (func (export "j_flags") (param $kind i32) (param $a i64) (param $b i64) (param $size i32)
    (block $dec (block $inc (block $logic (block $sub (block $add (block $none
      (br_table $none $add $sub $logic $inc $dec $none (local.get $kind)))
      (return))
      (drop (call $do_add (local.get $a) (local.get $b) (local.get $size))) (return))
      (drop (call $do_sub (local.get $a) (local.get $b) (local.get $size))) (return))
      (drop (call $do_logic (local.get $a) (local.get $size))) (return))
      (drop (call $do_inc (local.get $a) (local.get $size))) (return))
    (drop (call $do_dec (local.get $a) (local.get $size))))

  ;; Flag state, for the conditions a compiled branch cannot work out itself.
  (func (export "j_cond") (param $cc i32) (result i32) (call $cond (local.get $cc)))

  ;; RIP, the fault bookkeeping, the flags and the timestamp counter are
  ;; touched constantly, so compiled code reaches them as imported globals.
  (export "g_rip"    (global $rip_g))
  (export "g_rip0"   (global $rip0))
  (export "g_rsp0"   (global $rsp0))
  (export "g_fault"  (global $fault))
  (export "g_flags"  (global $flags_g))
  (export "g_tsc"    (global $tsc_g))
  (export "g_exit"   (global $jit_exit))
  (export "g_budget" (global $jit_budget))
  (export "g_tlbbits" (global $jtlb_bits))
