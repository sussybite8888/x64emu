// FISTTP, the float-to-integer store a compiler emits for a cast.
//
// It has two properties that are easy to get wrong together, and both were:
// it stores an *integer*, and it truncates toward zero no matter what the
// rounding mode says.  The 64-bit form shares its escape opcode with FST and
// FSTP m64real -- DD /1 against DD /2 and DD /3 -- so treating the three alike
// stores the raw IEEE bit pattern where the guest expects a small integer.
// TempleOS converts every F64 that way, which left its version number reading
// 0.000 and its compiler unable to run at all.
        .code64
        .text
        .globl  _start

.macro  want    reg, value, code
        movabs  $\value, %r14
        cmp     %r14, \reg
        mov     $\code, %r13b
        jne     fail
.endm

_start:
        mov     $0x8000, %rsp
        mov     %cr0, %rax
        and     $-13, %rax                      // clear EM and TS
        or      $2, %rax                        // MP
        mov     %rax, %cr0
        fninit

// ---- FISTTP m64int truncates toward zero ------------------------------
        fldl    v2_7(%rip)
        fisttpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, 2, 1                      // 2.7 -> 2, not 3

        fldl    vneg2_7(%rip)
        fisttpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, -2, 2                     // -2.7 -> -2, not -3

// a value whose bit pattern is nothing like its integer value: 5.03 stores as
// 5, where storing the real would put 0x4014_1EB8_51EB_851F here
        fldl    v5_03(%rip)
        fisttpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, 5, 3

// ---- and it pops -------------------------------------------------------
// After three loads and three FISTTPs the stack is empty again, so a fourth
// load lands in ST(0) rather than overflowing.
        fldl    v42(%rip)
        fisttpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, 42, 4
        fnstsw  %ax
        and     $0x3800, %eax                   // top-of-stack field
        want    %rax, 0, 5                      // back to zero: every load popped

// ---- the narrower widths -----------------------------------------------
        movq    $0, out(%rip)
        fldl    v2_7(%rip)
        fisttpl out(%rip)                       // m32int
        mov     out(%rip), %eax
        want    %rax, 2, 6

        movq    $0, out(%rip)
        fldl    vneg2_7(%rip)
        fisttps out(%rip)                       // m16int
        movzwl  out(%rip), %eax
        want    %rax, 0xfffe, 7                 // -2 as a 16-bit value

// ---- FST/FSTP m64real must still store the real -------------------------
// These share DD with FISTTP; splitting them wrongly the other way would turn
// a perfectly good double into a small integer.
        fldl    v5_03(%rip)
        fstpl   out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x40141EB851EB851F, 8     // the bits of 5.03

// FST (DD /2) stores without popping, so the value is still there to store
// a second time
        fldl    v42(%rip)
        fstl    out(%rip)
        movq    $0, out2(%rip)
        fstpl   out2(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x4045000000000000, 9     // 42.0
        mov     out2(%rip), %rax
        want    %rax, 0x4045000000000000, 10    // still on the stack for FSTP

// ---- truncation beats the rounding mode --------------------------------
// Set rounding to nearest explicitly; FISTTP must ignore it and still chop.
        mov     $0x037f, %eax                   // round to nearest
        mov     %eax, cw(%rip)
        fldcw   cw(%rip)
        fldl    v2_7(%rip)
        fisttpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, 2, 11

// FISTP, by contrast, does honour it: 2.7 to nearest is 3
        fldl    v2_7(%rip)
        fistpll out(%rip)
        mov     out(%rip), %rax
        want    %rax, 3, 12

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
v5_03:   .double 5.03
v42:     .double 42.0
out:     .quad   0
out2:    .quad   0
cw:      .long   0
