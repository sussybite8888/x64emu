// FXSAVE and FXRSTOR: the 512-byte area and a full round trip.
//
// A kernel switches processes by saving one's x87 and SSE registers and
// restoring the next one's.  When these did nothing every process shared one
// set of XMM registers, and a switch in the middle of glibc's SSE2 string code
// handed it another process's values.  This checks the area's layout against
// the manual and that everything saved comes back bit for bit.
        .code64
        .text
        .globl  _start

.macro  want64  addr, value, code
        movabs  $\value, %r14
        cmp     %r14, \addr
        mov     $\code, %r13b
        jne     fail
.endm

_start:
        mov     $0x8000, %rsp

// ---- distinct values everywhere --------------------------------------
        lea     pattern(%rip), %rsi
        movdqu  0(%rsi), %xmm0
        movdqu  16(%rsi), %xmm1
        movdqu  32(%rsi), %xmm2
        movdqu  48(%rsi), %xmm3
        movdqu  64(%rsi), %xmm4
        movdqu  80(%rsi), %xmm5
        movdqu  96(%rsi), %xmm6
        movdqu  112(%rsi), %xmm7
        movdqu  128(%rsi), %xmm8
        movdqu  144(%rsi), %xmm9
        movdqu  160(%rsi), %xmm10
        movdqu  176(%rsi), %xmm11
        movdqu  192(%rsi), %xmm12
        movdqu  208(%rsi), %xmm13
        movdqu  224(%rsi), %xmm14
        movdqu  240(%rsi), %xmm15
        fninit
        fldcw   cw(%rip)                        // round toward zero, 0x0F7F
        fldl    denorm(%rip)                    // becomes ST(2)
        fldl    minus25(%rip)                   // ST(1) = -2.5
        fld1                                    // ST(0) = 1.0, TOP = 5
        ldmxcsr mx(%rip)

        fxsave64 area(%rip)

// ---- the layout ---------------------------------------------------------
        movzwl  area+0(%rip), %eax              // control word
        cmp     $0x0f7f, %eax
        mov     $1, %r13b
        jne     fail
        movzwl  area+2(%rip), %eax              // status word: TOP = 5
        shr     $11, %eax
        and     $7, %eax
        cmp     $5, %eax
        mov     $2, %r13b
        jne     fail
        movzbl  area+4(%rip), %eax              // abridged tag: physical 5, 6, 7
        cmp     $0xe0, %eax
        mov     $3, %r13b
        jne     fail
        mov     area+24(%rip), %eax             // MXCSR
        cmp     $0x7f80, %eax
        mov     $4, %r13b
        jne     fail
        mov     area+32(%rip), %rax             // ST(0) = 1.0
        want64  %rax, 0x8000000000000000, 5
        movzwl  area+40(%rip), %eax
        cmp     $0x3fff, %eax
        mov     $6, %r13b
        jne     fail
        mov     area+48(%rip), %rax             // ST(1) = -2.5
        want64  %rax, 0xa000000000000000, 7
        movzwl  area+56(%rip), %eax
        cmp     $0xc000, %eax
        mov     $8, %r13b
        jne     fail
        mov     area+64(%rip), %rax             // ST(2): the denormal, normalised
        want64  %rax, 0x8000000000000000, 9
        movzwl  area+72(%rip), %eax             // 2^-1074 is exponent 16383-1074
        cmp     $0x3bcd, %eax
        mov     $10, %r13b
        jne     fail
        mov     area+160+5*16(%rip), %rax       // XMM5's slot
        cmp     80(%rsi), %rax
        mov     $11, %r13b
        jne     fail
        mov     area+160+15*16+8(%rip), %rax    // XMM15's top half
        cmp     248(%rsi), %rax
        mov     $12, %r13b
        jne     fail

// ---- wipe everything, then restore ------------------------------------
        pxor    %xmm0, %xmm0
        pxor    %xmm5, %xmm5
        pxor    %xmm15, %xmm15
        fninit
        movl    $0x1f80, scratch(%rip)
        ldmxcsr scratch(%rip)

        fxrstor64 area(%rip)

        movdqu  %xmm0, out(%rip)
        mov     out(%rip), %rax
        cmp     0(%rsi), %rax
        mov     $13, %r13b
        jne     fail
        movdqu  %xmm5, out(%rip)
        mov     out+8(%rip), %rax
        cmp     88(%rsi), %rax
        mov     $14, %r13b
        jne     fail
        movdqu  %xmm15, out(%rip)
        mov     out(%rip), %rax
        cmp     240(%rsi), %rax
        mov     $15, %r13b
        jne     fail
        stmxcsr scratch(%rip)
        cmpl    $0x7f80, scratch(%rip)
        mov     $16, %r13b
        jne     fail
        fnstcw  scratch(%rip)
        cmpw    $0x0f7f, scratch(%rip)
        mov     $17, %r13b
        jne     fail
        fstpl   out(%rip)                       // 1.0
        mov     out(%rip), %rax
        want64  %rax, 0x3ff0000000000000, 18
        fstpl   out(%rip)                       // -2.5
        mov     out(%rip), %rax
        want64  %rax, 0xc004000000000000, 19
        fstpl   out(%rip)                       // the denormal, exactly
        mov     out(%rip), %rax
        want64  %rax, 0x0000000000000001, 20
        fnstsw  %ax                             // and the stack is empty again
        shr     $11, %eax
        and     $7, %eax
        mov     $21, %r13b
        jne     fail

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
area:   .space  512
out:    .quad   0, 0
scratch: .quad  0
cw:     .word   0x0f7f
        .align  4
mx:     .long   0x7f80
        .align  8
minus25: .double -2.5
denorm: .quad   0x0000000000000001
        .align  16
pattern:
        .quad   0x0101010101010101, 0x1111111111111111
        .quad   0x0202020202020202, 0x2222222222222222
        .quad   0x0303030303030303, 0x3333333333333333
        .quad   0x0404040404040404, 0x4444444444444444
        .quad   0x0505050505050505, 0x5555555555555555
        .quad   0x0606060606060606, 0x6666666666666666
        .quad   0x0707070707070707, 0x7777777777777777
        .quad   0x0808080808080808, 0x8888888888888888
        .quad   0x0909090909090909, 0x9999999999999999
        .quad   0x0a0a0a0a0a0a0a0a, 0xaaaaaaaaaaaaaaaa
        .quad   0x0b0b0b0b0b0b0b0b, 0xbbbbbbbbbbbbbbbb
        .quad   0x0c0c0c0c0c0c0c0c, 0xcccccccccccccccc
        .quad   0x0d0d0d0d0d0d0d0d, 0xdddddddddddddddd
        .quad   0x0e0e0e0e0e0e0e0e, 0xeeeeeeeeeeeeeeee
        .quad   0x0f0f0f0f0f0f0f0f, 0xffffffffffffffff
        .quad   0x1010101010101010, 0x0000000000000001
