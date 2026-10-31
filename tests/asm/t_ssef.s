// SSE/SSE2 floating point: the instructions a normal x86-64 toolchain emits
// for every `float` and `double`.
//
// Expected values are written out independently rather than read back from the
// emulator, so a wrong lane, a dropped prefix or a clobbered upper half fails a
// check instead of agreeing with itself.  The two properties most easily got
// wrong are checked deliberately: a scalar operation must leave the rest of the
// destination register alone, and MIN/MAX/compare are specified as comparisons,
// so they return the *source* whenever the comparison is not true -- which is
// what makes them differ from an ordinary minimum for NaN and for signed zero.
        .code64
        .text
        .globl  _start

.macro  want    reg, value, code
        movabs  $\value, %r14
        cmp     %r14, \reg
        mov     $\code, %r13b
        jne     fail
.endm

// low half of xmm0 against a 64-bit pattern
.macro  wantlo  value, code
        movq    %xmm0, %rax
        want    %rax, \value, \code
.endm

_start:
        mov     $0x8000, %rsp

// ---- scalar double arithmetic -----------------------------------------
        movsd   v3(%rip), %xmm0
        addsd   v4(%rip), %xmm0
        wantlo  0x401C000000000000, 1            // 7.0

        movsd   v3(%rip), %xmm0
        subsd   v4(%rip), %xmm0
        wantlo  0xBFF0000000000000, 2            // -1.0

        movsd   v3(%rip), %xmm0
        mulsd   v4(%rip), %xmm0
        wantlo  0x4028000000000000, 3            // 12.0

        movsd   v3(%rip), %xmm0
        divsd   v4(%rip), %xmm0
        wantlo  0x3FE8000000000000, 4            // 0.75

        movsd   v16(%rip), %xmm0
        sqrtsd  %xmm0, %xmm0
        wantlo  0x4010000000000000, 5            // 4.0

// a scalar operation must not disturb the upper half of the register
        movupd  pair(%rip), %xmm0                // [3.0, 5.0]
        addsd   v4(%rip), %xmm0
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x401C000000000000, 6      // low became 7.0
        mov     out+8(%rip), %rax
        want    %rax, 0x4014000000000000, 7      // high still 5.0

// ---- scalar single ------------------------------------------------------
        movss   f3(%rip), %xmm0
        addss   f4(%rip), %xmm0
        movd    %xmm0, %eax
        want    %rax, 0x40E00000, 8              // 7.0f

// ADDSS writes four bytes; the other twelve are untouched
        movupd  quad(%rip), %xmm0                // four distinct floats
        addss   f4(%rip), %xmm0
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x4080000040E00000, 9      // lane0 7.0f, lane1 4.0f kept
        mov     out+8(%rip), %rax
        want    %rax, 0x4100000040A00000, 10     // lanes 2,3 kept

// ---- packed -------------------------------------------------------------
        movupd  pair(%rip), %xmm0                // [3.0, 5.0]
        addpd   pair2(%rip), %xmm0               // + [4.0, 2.0]
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x401C000000000000, 11     // 7.0
        mov     out+8(%rip), %rax
        want    %rax, 0x401C000000000000, 12     // 7.0

        movupd  quad(%rip), %xmm0                // [3,4,5,8] as floats
        addps   quad(%rip), %xmm0
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x4100000040C00000, 13     // 6.0f, 8.0f
        mov     out+8(%rip), %rax
        want    %rax, 0x4180000041200000, 14     // 10.0f, 16.0f

// ---- MIN and MAX return the source when the comparison is not true -----
        movsd   v3(%rip), %xmm0
        minsd   v4(%rip), %xmm0
        wantlo  0x4008000000000000, 15           // 3.0

        movsd   v3(%rip), %xmm0
        maxsd   v4(%rip), %xmm0
        wantlo  0x4010000000000000, 16           // 4.0

// with a NaN source the result is the source, and with a NaN destination it
// is also the source: MINSD is "dst < src ? dst : src", nothing more
        movsd   v3(%rip), %xmm0
        minsd   vnan(%rip), %xmm0
        wantlo  0x7FF8000000000000, 17           // the NaN

        movsd   vnan(%rip), %xmm0
        minsd   v3(%rip), %xmm0
        wantlo  0x4008000000000000, 18           // 3.0

// ---- conversions --------------------------------------------------------
        mov     $7, %eax
        cvtsi2sd %eax, %xmm0
        wantlo  0x401C000000000000, 19           // 7.0

        movabs  $1234567890123, %rax
        cvtsi2sd %rax, %xmm0                     // REX.W selects the 64-bit form
        wantlo  0x4271F71FB04CB000, 20

        mov     $7, %eax
        cvtsi2ss %eax, %xmm0
        movd    %xmm0, %eax
        want    %rax, 0x40E00000, 21             // 7.0f

// CVTTSD2SI truncates, CVTSD2SI rounds to nearest
        movsd   v2_7(%rip), %xmm0
        cvttsd2si %xmm0, %eax
        want    %rax, 2, 22
        cvtsd2si %xmm0, %eax
        want    %rax, 3, 23

        movsd   vneg2_7(%rip), %xmm0
        cvttsd2si %xmm0, %eax
        want    %rax, 0xFFFFFFFE, 24             // a 32-bit destination zero-extends
        cvttsd2si %xmm0, %rax                    // 64-bit destination
        want    %rax, -2, 25

// single <-> double
        movss   f3(%rip), %xmm0
        cvtss2sd %xmm0, %xmm0
        wantlo  0x4008000000000000, 26           // 3.0

        movsd   v3(%rip), %xmm0
        cvtsd2ss %xmm0, %xmm0
        movd    %xmm0, %eax
        want    %rax, 0x40400000, 27             // 3.0f

// ---- UCOMISD reports into EFLAGS ---------------------------------------
        movsd   v3(%rip), %xmm0
        ucomisd v4(%rip), %xmm0                  // 3.0 < 4.0 -> CF=1 ZF=0
        mov     $28, %r13b
        jnc     fail
        jz      fail

        movsd   v4(%rip), %xmm0
        ucomisd v3(%rip), %xmm0                  // 4.0 > 3.0 -> CF=0 ZF=0
        mov     $29, %r13b
        jc      fail
        jz      fail

        movsd   v3(%rip), %xmm0
        ucomisd v3(%rip), %xmm0                  // equal -> ZF=1 CF=0 PF=0
        mov     $30, %r13b
        jnz     fail
        jc      fail
        jp      fail

        movsd   v3(%rip), %xmm0
        ucomisd vnan(%rip), %xmm0                // unordered -> ZF=PF=CF=1
        mov     $31, %r13b
        jnp     fail
        jnz     fail
        jnc     fail

// COMISD sets the same flags for ordered operands
        movsd   v3(%rip), %xmm0
        comisd  v4(%rip), %xmm0
        mov     $32, %r13b
        jnc     fail

// the single-precision forms use no prefix at all
        movss   f3(%rip), %xmm0
        ucomiss f4(%rip), %xmm0
        mov     $33, %r13b
        jnc     fail

// ---- CMPSD produces a mask ---------------------------------------------
        movsd   v3(%rip), %xmm0
        cmpsd   $1, v4(%rip), %xmm0              // 3.0 < 4.0 -> all ones
        wantlo  0xFFFFFFFFFFFFFFFF, 34

        movsd   v4(%rip), %xmm0
        cmpsd   $1, v3(%rip), %xmm0              // 4.0 < 3.0 -> zero
        wantlo  0, 35

        movsd   v3(%rip), %xmm0
        cmpsd   $0, v3(%rip), %xmm0              // equal
        wantlo  0xFFFFFFFFFFFFFFFF, 36

        movsd   v3(%rip), %xmm0
        cmpsd   $3, vnan(%rip), %xmm0            // unordered
        wantlo  0xFFFFFFFFFFFFFFFF, 37

// ---- ANDNPD complements the destination, not the source ----------------
        movupd  mask_a(%rip), %xmm0
        andnpd  mask_b(%rip), %xmm0              // ~a & b
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x00FF00FF00FF00FF, 38
        mov     out+8(%rip), %rax
        want    %rax, 0x0000FFFF0000FFFF, 39

// ---- MOVQ store form ----------------------------------------------------
        movupd  pair(%rip), %xmm0
        movq    %xmm0, out(%rip)                 // 66 0F D6
        mov     out(%rip), %rax
        want    %rax, 0x4008000000000000, 40

// register destination clears the upper half
        movupd  pair(%rip), %xmm1
        movq    %xmm1, %xmm0
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x4008000000000000, 41
        mov     out+8(%rip), %rax
        want    %rax, 0, 42

// ---- packed conversions -------------------------------------------------
// These are the least-exercised paths: the widening ones read only half a
// register and the narrowing ones must clear the half they do not write.
        cvtps2pd quad(%rip), %xmm0               // low two floats [3,4] -> doubles
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x4008000000000000, 43     // 3.0
        mov     out+8(%rip), %rax
        want    %rax, 0x4010000000000000, 44     // 4.0

        cvtpd2ps pair(%rip), %xmm0               // [3.0, 5.0] -> two floats
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x40A0000040400000, 45     // 3.0f, 5.0f
        mov     out+8(%rip), %rax
        want    %rax, 0, 46                      // upper half cleared

        cvtdq2ps ints(%rip), %xmm0               // [1,2,3,4] -> floats
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x400000003F800000, 47     // 1.0f, 2.0f
        mov     out+8(%rip), %rax
        want    %rax, 0x4080000040400000, 48     // 3.0f, 4.0f

        cvttps2dq fracs(%rip), %xmm0             // truncate toward zero
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0xFFFFFFFD00000003, 49     // 3.7 -> 3, -3.7 -> -3
        cvtps2dq fracs(%rip), %xmm0              // round to nearest
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0xFFFFFFFC00000004, 50     // 3.7 -> 4, -3.7 -> -4

// packed arithmetic on doubles, and a packed square root
        movupd  sixteen(%rip), %xmm0
        sqrtpd  %xmm0, %xmm0
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x4010000000000000, 51     // 4.0
        mov     out+8(%rip), %rax
        want    %rax, 0x4018000000000000, 52     // 6.0

        movupd  quad(%rip), %xmm0                // [3,4,5,8]
        divps   quad(%rip), %xmm0
        movupd  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x3F8000003F800000, 53     // 1.0f in every lane
        mov     out+8(%rip), %rax
        want    %rax, 0x3F8000003F800000, 54

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
v3:      .double 3.0
v4:      .double 4.0
v16:     .double 16.0
v2_7:    .double 2.7
vneg2_7: .double -2.7
vnan:    .quad   0x7FF8000000000000
f3:      .float  3.0
f4:      .float  4.0
        .align  16
pair:    .double 3.0, 5.0
pair2:   .double 4.0, 2.0
quad:    .float  3.0, 4.0, 5.0, 8.0
mask_a:  .quad   0xFF00FF00FF00FF00, 0xFFFF0000FFFF0000
mask_b:  .quad   0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF
ints:    .long   1, 2, 3, 4
fracs:   .float  3.7, -3.7, 3.7, -3.7
sixteen: .double 16.0, 36.0
out:     .quad   0, 0
