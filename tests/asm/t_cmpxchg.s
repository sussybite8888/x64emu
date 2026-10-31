// CMPXCHG8B and CMPXCHG16B.
//
// Windows advertises and uses the 128-bit form for interlocked list heads, so a
// wrong compare or a half-written store corrupts kernel structures rather than
// faulting anywhere near the mistake.  Both the success and failure paths
// matter: on failure the memory operand must be left alone and loaded back into
// RDX:RAX, which is what makes a retry loop terminate.
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

// ---- CMPXCHG16B, comparison succeeds -----------------------------------
        movabs  $0x1111111111111111, %rax
        mov     %rax, m128(%rip)
        movabs  $0x2222222222222222, %rax
        mov     %rax, m128+8(%rip)

        movabs  $0x1111111111111111, %rax        // expected low
        movabs  $0x2222222222222222, %rdx        // expected high
        movabs  $0xAAAAAAAAAAAAAAAA, %rbx        // replacement low
        movabs  $0xBBBBBBBBBBBBBBBB, %rcx        // replacement high
        cmpxchg16b m128(%rip)
        mov     $1, %r13b
        jne     fail                             // ZF set on success
        mov     m128(%rip), %rsi
        want    %rsi, 0xAAAAAAAAAAAAAAAA, 2
        mov     m128+8(%rip), %rsi
        want    %rsi, 0xBBBBBBBBBBBBBBBB, 3
// RDX:RAX must be left as it was
        want    %rax, 0x1111111111111111, 4
        want    %rdx, 0x2222222222222222, 5

// ---- CMPXCHG16B, comparison fails --------------------------------------
        movabs  $0x1111111111111111, %rax
        mov     %rax, m128(%rip)
        movabs  $0x2222222222222222, %rax
        mov     %rax, m128+8(%rip)

        movabs  $0x9999999999999999, %rax        // wrong low half
        movabs  $0x2222222222222222, %rdx
        movabs  $0xAAAAAAAAAAAAAAAA, %rbx
        movabs  $0xBBBBBBBBBBBBBBBB, %rcx
        cmpxchg16b m128(%rip)
        mov     $6, %r13b
        je      fail                             // ZF clear on failure
// memory untouched
        mov     m128(%rip), %rsi
        want    %rsi, 0x1111111111111111, 7
        mov     m128+8(%rip), %rsi
        want    %rsi, 0x2222222222222222, 8
// and the current value loaded back for the retry
        want    %rax, 0x1111111111111111, 9
        want    %rdx, 0x2222222222222222, 10

// a mismatch in the high half only must also fail
        movabs  $0x1111111111111111, %rax
        movabs  $0x7777777777777777, %rdx
        cmpxchg16b m128(%rip)
        mov     $11, %r13b
        je      fail
        want    %rdx, 0x2222222222222222, 12

// ---- CMPXCHG8B, comparison succeeds ------------------------------------
        movabs  $0x2222222211111111, %rax
        mov     %rax, m64(%rip)

        mov     $0x11111111, %eax                // expected low
        mov     $0x22222222, %edx                // expected high
        mov     $0xAAAAAAAA, %ebx
        mov     $0xBBBBBBBB, %ecx
        cmpxchg8b m64(%rip)
        mov     $13, %r13b
        jne     fail
        mov     m64(%rip), %rsi
        want    %rsi, 0xBBBBBBBBAAAAAAAA, 14

// ---- CMPXCHG8B, comparison fails ---------------------------------------
        movabs  $0x2222222211111111, %rax
        mov     %rax, m64(%rip)

        mov     $0x99999999, %eax
        mov     $0x22222222, %edx
        mov     $0xAAAAAAAA, %ebx
        mov     $0xBBBBBBBB, %ecx
        cmpxchg8b m64(%rip)
        mov     $15, %r13b
        je      fail
        mov     m64(%rip), %rsi
        want    %rsi, 0x2222222211111111, 16      // memory untouched
        want    %rax, 0x11111111, 17             // reloaded for the retry
        want    %rdx, 0x22222222, 18

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
m128:   .quad   0, 0
m64:    .quad   0
