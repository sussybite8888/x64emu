  ;; =========================================================================
  ;;  Part 85: block cache and runtime support for the JIT
  ;; =========================================================================
  ;;
  ;;  Compiled blocks live in modules the host builds while the guest runs and
  ;;  publishes into the imported $jit table.  The core reaches them with one
  ;;  call_indirect, so a block costs no JavaScript transition at all.
  ;;
  ;;  A block is keyed on the linear address of its first instruction together
  ;;  with the CPU mode: the same bytes decode differently at 16, 32 and 64
  ;;  bits, so mode has to be part of the key rather than a reason to flush.
  ;;
  ;;  What a compiled block promises:
  ;;    - it leaves RIP pointing at the next instruction to execute
  ;;    - it sets $rip0 to the instruction it is about to run, so a fault
  ;;      reports the address the interpreter would have reported, and $rsp0
  ;;      to RSP there, so the fault finds the stack as it was
  ;;    - it returns the number of instructions it actually retired, which may
  ;;      be fewer than it contains if one of them faulted
  ;;
  ;;  BLOCK CACHE (0xC000, 256 entries x 16 bytes, direct mapped)
  ;;    +0  linear address of the block head (u64)
  ;;    +8  table slot + 1 (u32); zero means the entry is empty
  ;;    +12 mode (u32)
  ;;  HOTNESS (0xD000, 2048 x u32)  tag in the high 24 bits, count in the low 8
  ;;  CODE PAGES (0xF000, 1024 bytes)  hashed set of pages holding compiled code
  ;;  HOT RING (0xF400 index, 0xF408, 64 x u64)  addresses awaiting compilation

  (type $jitblk (func (result i32)))

  (global $jit_on (mut i32) (i32.const 0))

  ;; Set whenever control transfers somewhere rather than falling through, so
  ;; the cache is consulted at branch targets and nowhere else.  This does two
  ;; jobs at once: it keeps the miss path off the straight-line interpreter,
  ;; and it means the addresses that become blocks are the ones something
  ;; actually jumps to, instead of every byte offset inside a loop body.
  (global $jit_head (mut i32) (i32.const 1))

  ;; Treat every address as a branch target.  This exists for the differential
  ;; test: block selection is a performance policy, but what a block *emits* is
  ;; a correctness question, and gating on real branch targets would leave
  ;; straight-line test programs compiling almost nothing to compare.
  (global $jit_all_heads (mut i32) (i32.const 0))

  ;; Flushes are counted because their frequency decides whether compiling is
  ;; worth anything at all: a cache thrown away faster than it fills is pure
  ;; cost, and that is invisible without a number.
  (global $jit_flushes (mut i32) (i32.const 0))
  (global $jit_lookups (mut i32) (i32.const 0))
  (global $jit_notes   (mut i32) (i32.const 0))

  (global $JIT_CACHE i32 (i32.const 0xC000))
  (global $JIT_HOT   i32 (i32.const 0xD000))
  (global $JIT_PAGES i32 (i32.const 0xF000))
  (global $JIT_RING  i32 (i32.const 0xF408))

  ;; How many times an address must be reached before it is worth compiling.
  ;; Low enough that a loop entered once and run for a while still pays off,
  ;; high enough that straight-line setup code is never compiled at all.
  ;; Mutable so a test can drop it to 1 and compile everything it touches:
  ;; at the production value most short programs never compile a single block,
  ;; and a differential test that compiles nothing proves nothing.
  (global $JIT_THRESHOLD (mut i32) (i32.const 40))

  ;; Linear address of the instruction RIP currently names.
  (func $jit_la (result i64)
    (i64.and (i64.add (global.get $cs_base) (global.get $rip_g))
             (global.get $rip_mask)))

  ;; Mixing in a shifted copy spreads addresses that differ only in their high
  ;; bits, which is exactly what a page full of code looks like.
  (func $jit_mix (param $la i64) (result i32)
    (i32.xor (i32.wrap_i64 (local.get $la))
             (i32.wrap_i64 (i64.shr_u (local.get $la) (i64.const 13)))))

  (func $jit_slot_addr (param $la i64) (result i32)
    (i32.add (global.get $JIT_CACHE)
             (i32.shl (i32.and (call $jit_mix (local.get $la)) (i32.const 255))
                      (i32.const 4))))

  ;; ---- hotness -----------------------------------------------------------
  ;; Each entry belongs to one address, identified by a tag.  Sharing a bare
  ;; counter between every address that hashes alike was tried twice and failed
  ;; both ways: marking a bucket "already offered" let one address poison it for
  ;; every other, and resetting it instead turned publishing into a firehose --
  ;; 3.6 million offers in a boot, of which a 64-entry ring could carry almost
  ;; none.  With a tag, a colliding address simply takes the entry over and
  ;; starts counting again, so a genuinely hot address wins it and keeps it.
  (func $jit_hot_entry (param $la i64) (result i32)
    (i32.add (global.get $JIT_HOT)
             (i32.shl (i32.and (call $jit_mix (local.get $la)) (i32.const 2047))
                      (i32.const 2))))

  (func $jit_hot_tag (param $la i64) (result i32)
    (i32.and (i32.wrap_i64 (i64.shr_u (local.get $la) (i64.const 4)))
             (i32.const 0xFFFFFF)))

  (func $jit_note (param $la i64)
    (local $e i32) (local $v i32) (local $tag i32) (local $c i32) (local $ri i32)
    (global.set $jit_notes (i32.add (global.get $jit_notes) (i32.const 1)))
    (local.set $e (call $jit_hot_entry (local.get $la)))
    (local.set $tag (call $jit_hot_tag (local.get $la)))
    (local.set $v (i32.load (local.get $e)))
    ;; A colliding address does not evict the incumbent outright, it ages it by
    ;; one.  Straight eviction was tried and left the table thrashing: with more
    ;; hot addresses than entries, two that collide reset each other every time
    ;; and neither ever reaches the threshold -- 174 million misses produced
    ;; twelve offers.  Ageing means a genuinely hot address gains faster than
    ;; passers-by can drain it, and only a spent entry is taken over.
    (local.set $c (i32.and (local.get $v) (i32.const 255)))
    (if (i32.ne (i32.shr_u (local.get $v) (i32.const 8)) (local.get $tag))
      (then
        ;; 255 means the incumbent has already been offered and is finished
        ;; with the entry, so it is free for the taking.
        (if (i32.and (i32.ne (local.get $c) (i32.const 255))
                     (i32.gt_u (local.get $c) (i32.const 0)))
          (then
            (i32.store (local.get $e)
                       (i32.or (i32.and (local.get $v) (i32.const 0xFFFFFF00))
                               (i32.sub (local.get $c) (i32.const 1))))
            (return)))
        (local.set $c (i32.const 0))))
    ;; 255 means this address has already been handed to the host, whether it
    ;; compiled it or not.  A block that compiled becomes a cache hit and stops
    ;; arriving here at all; one that did not is not worth offering again.
    (if (i32.eq (local.get $c) (i32.const 255)) (then (return)))
    (local.set $c (i32.add (local.get $c) (i32.const 1)))
    (if (i32.lt_u (local.get $c) (global.get $JIT_THRESHOLD))
      (then
        (i32.store (local.get $e)
                   (i32.or (i32.shl (local.get $tag) (i32.const 8)) (local.get $c)))
        (return)))
    (i32.store (local.get $e)
               (i32.or (i32.shl (local.get $tag) (i32.const 8)) (i32.const 255)))
    (local.set $ri (i32.load (i32.const 0xF400)))
    (i64.store (i32.add (global.get $JIT_RING)
                        (i32.shl (i32.and (local.get $ri) (i32.const 63)) (i32.const 3)))
               (local.get $la))
    (i32.store (i32.const 0xF400) (i32.add (local.get $ri) (i32.const 1))))

  ;; ---- lookup ------------------------------------------------------------
  ;; Returns the table slot plus one, or zero on a miss.  The bias is what lets
  ;; slot 0 be a real block while zero still means "not found".
  (func $jit_lookup (result i32)
    (local $la i64) (local $e i32) (local $s i32)
    (global.set $jit_lookups (i32.add (global.get $jit_lookups) (i32.const 1)))
    (local.set $la (call $jit_la))
    (local.set $e (call $jit_slot_addr (local.get $la)))
    (local.set $s (i32.load (i32.add (local.get $e) (i32.const 8))))
    (if (i32.and (i32.ne (local.get $s) (i32.const 0))
                 (i32.and (i64.eq (i64.load (local.get $e)) (local.get $la))
                          (i32.eq (i32.load (i32.add (local.get $e) (i32.const 12)))
                                  (global.get $mode))))
      (then (return (local.get $s))))
    (call $jit_note (local.get $la))
    (i32.const 0))

  ;; ---- invalidation ------------------------------------------------------
  ;; Compiled code is only valid while the bytes it was built from are
  ;; unchanged and while linear addresses still mean what they meant, so the
  ;; whole cache is dropped whenever either could have moved.  Flushing
  ;; everything is coarse, but it happens rarely and a stale block is not a
  ;; slow program, it is a wrong one.
  (func $jit_flush (export "jit_flush")
    (local $i i32)
    (global.set $jit_flushes (i32.add (global.get $jit_flushes) (i32.const 1)))
    (block $e (loop $l
      (br_if $e (i32.ge_u (local.get $i) (i32.const 4096)))
      (i64.store (i32.add (global.get $JIT_CACHE) (local.get $i)) (i64.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 8)))
      (br $l)))
    (local.set $i (i32.const 0))
    (block $e2 (loop $l2
      (br_if $e2 (i32.ge_u (local.get $i) (i32.const 8192)))
      (i64.store (i32.add (global.get $JIT_HOT) (local.get $i)) (i64.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 8)))
      (br $l2)))
    (local.set $i (i32.const 0))
    (block $e3 (loop $l3
      (br_if $e3 (i32.ge_u (local.get $i) (i32.const 1024)))
      (i64.store (i32.add (global.get $JIT_PAGES) (local.get $i)) (i64.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 8)))
      (br $l3)))
    (i32.store (i32.const 0xF400) (i32.const 0)))

  ;; A hashed set of pages, so a write only has to consult one bit.  Collisions
  ;; cost an unnecessary flush and nothing else, which is why a hash is
  ;; acceptable where a precise map would need far more memory than the state
  ;; block has.
  (func $jit_page_bit (param $la i64) (result i32)
    (i32.and (call $jit_mix (i64.shr_u (local.get $la) (i64.const 12)))
             (i32.const 8191)))

  (func $jit_mark_code (param $la i64)
    (local $b i32)
    (local.set $b (call $jit_page_bit (local.get $la)))
    (i32.store8
      (i32.add (global.get $JIT_PAGES) (i32.shr_u (local.get $b) (i32.const 3)))
      (i32.or (i32.load8_u (i32.add (global.get $JIT_PAGES)
                                    (i32.shr_u (local.get $b) (i32.const 3))))
              (i32.shl (i32.const 1) (i32.and (local.get $b) (i32.const 7))))))

  ;; Called for every guest write while the JIT is on.
  (func $jit_check_write (param $la i64)
    (local $b i32)
    (local.set $b (call $jit_page_bit (local.get $la)))
    (if (i32.and (i32.load8_u (i32.add (global.get $JIT_PAGES)
                                       (i32.shr_u (local.get $b) (i32.const 3))))
                 (i32.shl (i32.const 1) (i32.and (local.get $b) (i32.const 7))))
      (then (call $jit_flush))))

  ;; =========================================================================
  ;;  Host interface
  ;; =========================================================================
  (func (export "jit_enable") (param $on i32)
    (global.set $jit_on (local.get $on))
    (call $jit_flush))

  (func (export "jit_enabled") (result i32) (global.get $jit_on))
  (func (export "jit_flush_count") (result i32) (global.get $jit_flushes))
  (func (export "jit_lookup_count") (result i32) (global.get $jit_lookups))
  (func (export "jit_note_count") (result i32) (global.get $jit_notes))

  (func (export "jit_all_heads") (param $on i32)
    (global.set $jit_all_heads (local.get $on))
    (call $jit_flush))

  (func (export "jit_set_threshold") (param $n i32)
    (global.set $JIT_THRESHOLD (local.get $n))
    (call $jit_flush))

  ;; Drain the queue of addresses that got hot: the host compiles these.
  (func (export "jit_hot_count") (result i32) (i32.load (i32.const 0xF400)))
  (func (export "jit_hot_at") (param $i i32) (result i64)
    (i64.load (i32.add (global.get $JIT_RING)
                       (i32.shl (i32.and (local.get $i) (i32.const 63)) (i32.const 3)))))

  ;; Publish a compiled block.  The host has already placed the function in the
  ;; table; this is what makes the core start using it.
  (func (export "jit_install") (param $la i64) (param $slot i32) (param $mode i32)
    (local $e i32)
    (local.set $e (call $jit_slot_addr (local.get $la)))
    (i64.store (local.get $e) (local.get $la))
    (i32.store (i32.add (local.get $e) (i32.const 8)) (i32.add (local.get $slot) (i32.const 1)))
    (i32.store (i32.add (local.get $e) (i32.const 12)) (local.get $mode))
    (call $jit_mark_code (local.get $la)))

  ;; Mark an address as spoken for, so an instruction in the middle of a block
  ;; the host already compiled never becomes a block head of its own.
  (func (export "jit_suppress") (param $la i64)
    (i32.store (call $jit_hot_entry (local.get $la))
               (i32.or (i32.shl (call $jit_hot_tag (local.get $la)) (i32.const 8))
                       (i32.const 255))))

  ;; ---- helpers compiled blocks call --------------------------------------
  ;; These are the interpreter's own primitives, reached with operands the
  ;; compiler already worked out.  Keeping the semantics here rather than
  ;; re-deriving them in the generated code is what makes a compiled block and
  ;; an interpreted one agree by construction.
  (func (export "j_alu") (param $op i32) (param $a i64) (param $b i64) (param $size i32)
        (result i64)
    (call $alu (local.get $op) (local.get $a) (local.get $b) (local.get $size)))

  (func (export "j_rd") (param $seg i32) (param $off i64) (param $size i32) (result i64)
    (call $seg_read (local.get $seg) (local.get $off) (local.get $size)))

  (func (export "j_wr") (param $seg i32) (param $off i64) (param $size i32) (param $v i64)
    (call $seg_write (local.get $seg) (local.get $off) (local.get $size) (local.get $v)))

  (func (export "j_push") (param $v i64) (param $size i32)
    (call $push (local.get $v) (local.get $size)))

  (func (export "j_pop") (param $size i32) (result i64) (call $pop (local.get $size)))

  (func (export "j_setregn") (param $r i32) (param $size i32) (param $v i64)
    (call $setregN (local.get $r) (local.get $size) (local.get $v)))

  (func (export "j_regn") (param $r i32) (param $size i32) (result i64)
    (call $regN (local.get $r) (local.get $size)))

  ;; Flag state, for the conditions a compiled branch has to evaluate.
  (func (export "j_cond") (param $cc i32) (result i32) (call $cond (local.get $cc)))

  ;; RIP, the instruction-start address and the fault flag are touched at every
  ;; instruction boundary, so compiled code reaches them as imported mutable
  ;; globals: one instruction each, where a helper call would be a function
  ;; call per boundary.
  (export "g_rip"   (global $rip_g))
  (export "g_rip0"  (global $rip0))
  (export "g_rsp0"  (global $rsp0))
  (export "g_fault" (global $fault))
