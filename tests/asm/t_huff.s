// The instruction forms a Huffman/LZ bit-tree decoder is built from.
//
// Windows' boot loader decompresses the kernel with one, and it walks a table
// of signed 16-bit nodes with a scaled index, consumes bits with a variable
// shift whose count is deliberately negative, and tracks the bit position in a
// memory operand.  Any one of those going wrong leaves the decoder looping
// forever on input it can no longer make progress through, which is a hang with
// no fault and no I/O to point at it.
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
        lea     tbl(%rip), %rdx

// ---- MOVSX from a scaled-index memory operand --------------------------
// The nodes are signed: a negative entry is a leaf, so a zero-extending or
// mis-scaled load turns leaves into branches and the walk never ends.
        mov     $1, %eax
        movswl  0x18(%rdx,%rax,2), %ebx          // tbl+0x18+2
        want    %rbx, 0xFFFFFFFE, 1             // -2 in a 32-bit dest, which zero-extends

        mov     $2, %eax
        movswl  0x18(%rdx,%rax,2), %ebx          // tbl+0x18+4
        want    %rbx, 0x7FFE, 2                  // positive stays positive

        mov     $1, %ebx
        movswl  0x20(%rdx,%rbx,4), %ecx          // scale 4
        want    %rcx, 0xFFFFFF81, 3             // -127

// two registers, no scale, like [ebx+edx+disp]
        lea     tbl(%rip), %rdx
        mov     $4, %rbx
        movzbl  0x18(%rbx,%rdx), %ecx
        want    %rcx, 0xFE, 4

// ---- a variable shift by a negative count ------------------------------
// The decoder computes the count as -n and leans on the count being masked to
// five bits.  Masking to six, as a 64-bit shift would, shifts by the wrong
// amount and the bit stream desynchronises.
        mov     $0x12345678, %edi
        mov     $8, %al
        movsbl  %al, %ecx
        neg     %ecx                             // ecx = -8 = 0xFFFFFFF8
        shl     %cl, %edi                        // masked to 24
        want    %rdi, 0x78000000, 5

        mov     $0x12345678, %edi
        mov     $0xFF, %cl                       // 255 & 31 == 31
        shl     %cl, %edi
        want    %rdi, 0x0, 6                     // low bit was 0

        mov     $0x00000001, %edi
        mov     $0xFF, %cl
        shl     %cl, %edi
        want    %rdi, 0x80000000, 7

        mov     $0x80000000, %edi
        mov     $0xE0, %cl                       // 224 & 31 == 0: no shift at all
        shl     %cl, %edi
        want    %rdi, 0x80000000, 8

// a 64-bit shift masks to six bits instead, and must still do so
        movabs  $0x1, %r15
        mov     $0x40, %cl                       // 64 & 63 == 0
        shl     %cl, %r15
        want    %r15, 1, 9
        mov     $0x3F, %cl
        shl     %cl, %r15
        want    %r15, 0x8000000000000000, 10

// ---- shifting a memory operand by CL ------------------------------------
        movl    $0x000000FF, pos(%rip)
        mov     $4, %cl
        shll    %cl, pos(%rip)
        mov     pos(%rip), %eax
        want    %rax, 0xFF0, 11

        movl    $0x80000000, pos(%rip)
        mov     $33, %cl                         // 33 & 31 == 1
        shrl    %cl, pos(%rip)
        mov     pos(%rip), %eax
        want    %rax, 0x40000000, 12

// ---- the byte bookkeeping around it -------------------------------------
        mov     $0x1234FF07, %eax
        mov     $0x09, %cl
        sub     %cl, %al                         // partial register arithmetic
        want    %rax, 0x1234FFFE, 13

        mov     $0x00000005, %ecx
        neg     %ecx
        want    %rcx, 0xFFFFFFFB, 14             // 32-bit neg zero-extends

        mov     $0xFFC00000, %edi
        shr     $22, %edi
        want    %rdi, 0x3FF, 15

// ---- OR into a memory accumulator, as the bit reader does ---------------
        movl    $0x0000000F, pos(%rip)
        mov     $0xF0, %eax
        or      %eax, pos(%rip)
        mov     pos(%rip), %eax
        want    %rax, 0xFF, 16

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
// 0x18 bytes of padding, then the signed node table
tbl:    .quad   0, 0, 0
        .word   0x0100, 0xFFFE, 0x7FFE, 0x00FE   // +0x18
        .word   0x0000, 0x0000, 0xFF81, 0x0000   // +0x20, negative node at +0x24
pos:    .quad   0
