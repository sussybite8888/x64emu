// Instructions a software AES-GCM leans on.
//
// Windows 10's boot library self-tests AES-GCM before it will run, and halts
// forever on the four-character code 'gcm1' if the answer is wrong, so a single
// bad shift or multiply is enough to stop the machine with no message.
// Expected values are computed independently rather than read off this CPU.
        .code64
        .text
        .globl  _start

.macro  want    reg, value, code
        mov     $\value, %r14
        cmp     %r14, \reg
        mov     $\code, %bl
        jne     fail
.endm

_start:
        mov     $0x8000, %rsp

// SHLD / SHRD move bits across word boundaries in GHASH
        movabs  $0x0123456789ABCDEF, %rax
        movabs  $0xFEDCBA9876543210, %rdx
        shld    $12, %rdx, %rax
        want    %rax, 0x3456789abcdeffed, 1

        movabs  $0x0123456789ABCDEF, %rax
        movabs  $0xFEDCBA9876543210, %rdx
        shrd    $12, %rdx, %rax
        want    %rax, 0x2100123456789abc, 2

        movabs  $0x0123456789ABCDEF, %rax
        bswap   %rax
        want    %rax, 0xefcdab8967452301, 3

        movabs  $0x0123456789ABCDEF, %rax
        rol     $8, %rax
        want    %rax, 0x23456789abcdef01, 4

        movabs  $0x0123456789ABCDEF, %rax
        ror     $8, %rax
        want    %rax, 0xef0123456789abcd, 5

// a shift count is masked to 6 bits, so 64 shifts by nothing at all
        movabs  $0x0123456789ABCDEF, %rax
        mov     $64, %cl
        shl     %cl, %rax
        want    %rax, 0x0123456789abcdef, 6

// 64x64 -> 128 multiply, both halves
        movabs  $0x0123456789ABCDEF, %rax
        movabs  $0xFEDCBA9876543210, %rbx
        mul     %rbx
        want    %rax, 0x2236d88fe5618cf0, 7
        want    %rdx, 0x0121fa00ad77d742, 8

        movabs  $0x0123456789ABCDEF, %rax
        movabs  $0xFEDCBA9876543210, %rbx
        imul    %rbx
        want    %rax, 0x2236d88fe5618cf0, 9
        want    %rdx, 0xfffeb49923cc0953, 10

// the SSE2 integer ops an AES table implementation uses
        movabs  $0x0123456789ABCDEF, %rax
        mov     %rax, v1(%rip)
        movabs  $0xFEDCBA9876543210, %rax
        mov     %rax, v1+8(%rip)
        movdqu  v1(%rip), %xmm0
        movdqu  v1(%rip), %xmm1
        pxor    %xmm1, %xmm0                    // x ^ x == 0
        movdqu  %xmm0, v2(%rip)
        mov     v2(%rip), %rax
        or      v2+8(%rip), %rax
        want    %rax, 0, 11

        movdqu  v1(%rip), %xmm0
        psllq   $4, %xmm0
        movdqu  %xmm0, v2(%rip)
        movabs  $0x123456789ABCDEF0, %r15
        cmp     %r15, v2(%rip)
        mov     $12, %bl
        jne     fail

        movdqu  v1(%rip), %xmm0
        psrlq   $4, %xmm0
        movdqu  %xmm0, v2(%rip)
        movabs  $0x00123456789ABCDE, %r15
        cmp     %r15, v2(%rip)
        mov     $13, %bl
        jne     fail

// unaligned loads must work: AES key schedules are rarely 16-byte aligned
        movdqu  v1+1(%rip), %xmm0
        movdqu  %xmm0, v2(%rip)
        movabs  $0x100123456789ABCD, %r15
        cmp     %r15, v2(%rip)
        mov     $14, %bl
        jne     fail

// BTS with an immediate offset past the operand wraps within it.  Only a
// register offset reaches the memory beyond.
        movq    $0, v1(%rip)
        btsl    $33, v1(%rip)                   // bit 1 of the same dword
        cmpq    $2, v1(%rip)
        mov     $15, %bl
        jne     fail
        mov     $33, %eax
        btsl    %eax, v1(%rip)                  // bit 1 of the next dword
        movabs  $0x0000000200000002, %r15
        cmp     %r15, v1(%rip)
        mov     $16, %bl
        jne     fail

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %bl, %al
        out     %al, $0xE9
        hlt

        .align  16
v1:     .quad   0, 0
v2:     .quad   0, 0
