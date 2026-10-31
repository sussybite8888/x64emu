// Partial-register writes and 32-bit zero extension.
//
// A table-driven AES pulls bytes out of words constantly -- movzx from %ah,
// shifts, scaled-index loads -- and a 32-bit destination must clear the whole
// upper half of the 64-bit register while an 8- or 16-bit one must not.
        .code64
        .text
        .globl  _start

.macro  want    reg, value, code
        movabs  $\value, %r14
        cmp     %r14, \reg
        mov     $\code, %bl
        jne     fail
.endm

_start:
        mov     $0x8000, %rsp

// a 32-bit destination zero-extends
        movabs  $0x1122334455667788, %rax
        mov     $0x99AABBCC, %eax
        want    %rax, 0x0000000099AABBCC, 1

// 8- and 16-bit destinations leave the rest alone
        movabs  $0x1122334455667788, %rax
        mov     $0xFF, %al
        want    %rax, 0x11223344556677FF, 2
        mov     $0xEE, %ah
        want    %rax, 0x112233445566EEFF, 3
        mov     $0x1234, %ax
        want    %rax, 0x1122334455661234, 4

// reading the high byte register
        movzbl  %ah, %ebx
        want    %rbx, 0x12, 5

// 32-bit arithmetic zero-extends too, even when it carries
        movabs  $0x1122334455667788, %rax
        add     $1, %eax
        want    %rax, 0x0000000055667789, 6

        movabs  $0x11223344FFFFFFFF, %rax
        add     $1, %eax
        want    %rax, 0x0000000000000000, 7

        movabs  $0x1122334455667788, %rax
        shr     $8, %eax
        want    %rax, 0x0000000000556677, 8

// zero and sign extension from a byte
        mov     $-1, %rax
        movzbq  %al, %rbx
        want    %rbx, 0xFF, 9
        movsbq  %al, %rbx
        want    %rbx, 0xFFFFFFFFFFFFFFFF, 10

// the scaled-index byte load an AES T-table uses
        lea     table(%rip), %rsi
        movabs  $0x1122334455667703, %rax
        movzbl  %al, %ecx
        movzbl  (%rsi,%rcx,1), %edx
        want    %rdx, 0x33, 11

        mov     $0x0102, %ax
        movzbl  %ah, %ecx
        movzbl  (%rsi,%rcx,4), %edx
        want    %rdx, 0xBB, 12

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %bl, %al
        out     %al, $0xE9
        hlt

        .align  16
table:  .byte   0xAA, 0x11, 0x22, 0x33, 0xBB, 0x44, 0x55, 0x66
        .byte   0xCC, 0x77, 0x88, 0x99, 0xDD, 0xEE, 0xFF, 0x00
