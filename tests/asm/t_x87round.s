// The x87 rounding control, which the control word selects and which FRNDINT
// and the integer stores are obliged to obey.
//
// Ignoring it is not a small error.  A guest that wants the integer part of a
// value sets the mode and then rounds; if the mode is ignored the integer comes
// out one too large whenever the fraction is at least a half.  When that
// integer is a binary exponent -- as it is when a printf builds a power of ten
// -- being out by one scales the answer by a factor of two, which is how
// TempleOS came to report its version as 2.51 instead of 5.03.
//
// FISTTP is the deliberate exception: it truncates whatever the mode says.
        .code64
        .text
        .globl  _start

.macro  want    reg, value, code
        movabs  $\value, %r14
        cmp     %r14, \reg
        mov     $\code, %r13b
        jne     fail
.endm

// round ST(0) to an integer under control word \cw and check the result
.macro  rnd     cw, src, value, code
        movl    $\cw, cw(%rip)
        fldcw   cw(%rip)
        fldl    \src(%rip)
        frndint
        fistpll out(%rip)                       // FISTTP would defeat the point
        mov     out(%rip), %rax
        want    %rax, \value, \code
.endm

// store ST(0) as an integer under control word \cw, letting the store round
.macro  ist     cw, src, value, code
        movl    $\cw, cw(%rip)
        fldcw   cw(%rip)
        fldl    \src(%rip)
        fistpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, \value, \code
.endm

.set    NEAREST, 0x027f
.set    DOWN,    0x067f
.set    UP,      0x0a7f
.set    CHOP,    0x0e7f

_start:
        mov     $0x8000, %rsp
        mov     %cr0, %rax
        and     $-13, %rax                      // clear EM and TS
        or      $2, %rax                        // MP
        mov     %rax, %cr0
        fninit

// ---- FRNDINT under each mode -------------------------------------------
        rnd     NEAREST, v2_7,    3,  1
        rnd     NEAREST, vneg2_7, -3, 2
        rnd     DOWN,    v2_7,    2,  3
        rnd     DOWN,    vneg2_7, -3, 4
        rnd     UP,      v2_7,    3,  5
        rnd     UP,      vneg2_7, -2, 6
        rnd     CHOP,    v2_7,    2,  7
        rnd     CHOP,    vneg2_7, -2, 8

// a halfway value goes to even under round-to-nearest, which is what makes it
// "nearest even" rather than "nearest away from zero"
        rnd     NEAREST, v2_5,    2,  9
        rnd     NEAREST, v3_5,    4,  10
        rnd     NEAREST, vneg2_5, -2, 11

// ---- FIST/FISTP round the same way -------------------------------------
        ist     NEAREST, v2_7,    3,  12
        ist     DOWN,    v2_7,    2,  13
        ist     UP,      v2_7,    3,  14
        ist     CHOP,    v2_7,    2,  15
        ist     CHOP,    vneg2_7, -2, 16
        ist     DOWN,    vneg2_7, -3, 17
        ist     NEAREST, v2_5,    2,  18       // nearest even again

// ---- FISTTP ignores the mode entirely ----------------------------------
        movl    $UP, cw(%rip)
        fldcw   cw(%rip)
        fldl    v2_7(%rip)
        fisttpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, 2, 19                     // truncated, not rounded up

        movl    $DOWN, cw(%rip)
        fldcw   cw(%rip)
        fldl    vneg2_7(%rip)
        fisttpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, -2, 20                    // truncated, not rounded down

// ---- the control word survives a round trip ----------------------------
        movl    $CHOP, cw(%rip)
        fldcw   cw(%rip)
        movl    $0, cw2(%rip)
        fnstcw  cw2(%rip)
        movzwl  cw2(%rip), %eax
        and     $0x0c00, %eax                   // just the rounding field
        want    %rax, 0x0c00, 21

// ---- the mode reaches a scaled power of two ----------------------------
// This is the shape that broke TempleOS: split a value into an integer
// exponent and a fraction, then scale.  With the mode ignored the integer is
// out by one and the result is out by a factor of two.
        movl    $CHOP, cw(%rip)
        fldcw   cw(%rip)
        fldl    v6_6(%rip)                      // 6.6
        frndint                                 // -> 6 with truncation
        fldl    v1_0(%rip)                      // ST0=1.0, ST1=6
        fscale                                  // 1.0 * 2^6
        fistpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, 64, 22
        fstp    %st(0)                          // drop the leftover exponent

        movl    $NEAREST, cw(%rip)
        fldcw   cw(%rip)
        fldl    v6_6(%rip)
        frndint                                 // -> 7 to nearest
        fldl    v1_0(%rip)
        fscale                                  // 1.0 * 2^7
        fistpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, 128, 23
        fstp    %st(0)

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
v2_7:    .double 2.7
vneg2_7: .double -2.7
v2_5:    .double 2.5
v3_5:    .double 3.5
vneg2_5: .double -2.5
v6_6:    .double 6.6
v1_0:    .double 1.0
out:     .quad   0
cw:      .long   0
cw2:     .long   0
