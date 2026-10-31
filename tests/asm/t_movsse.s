// SSE load and store forms, and RIP-relative addressing for each of them.
//
// Compilers copy small constant blobs with MOVAPS/MOVUPS/MOVSD against
// RIP-relative operands, so a displacement computed from the wrong end of the
// instruction silently copies a neighbouring constant instead of the intended
// one.  The table below is deliberately packed with distinct adjacent values so
// an offset that is wrong by even eight bytes fails rather than reading
// something plausible.
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

// ---- MOVAPS / MOVUPS, 16 bytes ----------------------------------------
        movaps  v1(%rip), %xmm0
        movups  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x1111111111111111, 1
        mov     out+8(%rip), %rax
        want    %rax, 0x2222222222222222, 2

// the second 16 bytes, to prove the displacement is not simply landing at v1
        movaps  v2(%rip), %xmm0
        movups  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x3333333333333333, 3
        mov     out+8(%rip), %rax
        want    %rax, 0x4444444444444444, 4

// MOVUPS against an unaligned source
        movups  v1+4(%rip), %xmm0
        movups  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x2222222211111111, 5

// ---- MOVSD: 8 bytes, and the upper half of the register is cleared ----
        movaps  v2(%rip), %xmm1                 // dirty the whole register
        movsd   v1(%rip), %xmm1
        movups  %xmm1, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x1111111111111111, 6
        mov     out+8(%rip), %rax
        want    %rax, 0, 7                      // loading from memory zeroes it

// each adjacent quadword must be reachable at its own displacement
        movsd   v1+8(%rip), %xmm0
        movsd   %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x2222222222222222, 8

        movsd   v2(%rip), %xmm0
        movsd   %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x3333333333333333, 9

        movsd   v2+8(%rip), %xmm0
        movsd   %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x4444444444444444, 10

// storing MOVSD must leave the neighbouring quadword alone
        movabs  $0x7777777777777777, %rax
        mov     %rax, out+8(%rip)
        movsd   v1(%rip), %xmm0
        movsd   %xmm0, out(%rip)
        mov     out+8(%rip), %rax
        want    %rax, 0x7777777777777777, 11

// ---- MOVSS: 4 bytes, clearing the rest -------------------------------
        movaps  v2(%rip), %xmm1
        movss   v1(%rip), %xmm1
        movups  %xmm1, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x11111111, 12
        mov     out+8(%rip), %rax
        want    %rax, 0, 13

// ---- MOVQ between memory, register and GPR ---------------------------
        movq    v2(%rip), %xmm0
        movq    %xmm0, %rax
        want    %rax, 0x3333333333333333, 14

        movabs  $0x0123456789ABCDEF, %rax
        movq    %rax, %xmm0
        movq    %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x0123456789ABCDEF, 15

// MOVD moves 32 bits and clears the rest
        mov     $0xCAFEBABE, %eax
        movd    %eax, %xmm0
        movups  %xmm0, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0xCAFEBABE, 16
        mov     out+8(%rip), %rax
        want    %rax, 0, 17

// ---- MOVAPS register to register -------------------------------------
        movaps  v1(%rip), %xmm0
        movaps  v2(%rip), %xmm1
        movaps  %xmm0, %xmm1
        movups  %xmm1, out(%rip)
        mov     out(%rip), %rax
        want    %rax, 0x1111111111111111, 18
        mov     out+8(%rip), %rax
        want    %rax, 0x2222222222222222, 19

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
v1:     .quad   0x1111111111111111, 0x2222222222222222
v2:     .quad   0x3333333333333333, 0x4444444444444444
out:    .quad   0, 0
