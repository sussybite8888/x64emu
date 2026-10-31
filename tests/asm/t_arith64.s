// 64-bit arithmetic, flags, shifts, multiply/divide, string ops, stack.
// Result is reported by writing a byte to port 0xE9; 0 means success and any
// other value is the index of the check that failed.
        .code64
        .text
        .globl  _start
_start:
        mov     $1, %r15d                 // check counter

// ---- add / sub / carry / overflow ----
        mov     $0xFFFFFFFFFFFFFFFF, %rax
        add     $1, %rax
        jnz     fail                      // result must be zero
        jnc     fail                      // carry out of the top
        inc     %r15d

        mov     $0x7FFFFFFFFFFFFFFF, %rax
        add     $1, %rax
        jno     fail                      // signed overflow
        inc     %r15d

        mov     $5, %rax
        sub     $7, %rax
        jnc     fail                      // borrow out of the subtraction
        cmp     $-2, %rax
        jne     fail
        inc     %r15d

// ---- 32-bit operations zero the upper half ----
        mov     $0xFFFFFFFFFFFFFFFF, %rax
        mov     $1, %eax
        cmp     $1, %rax
        jne     fail
        inc     %r15d

// ---- 16-bit and 8-bit writes preserve the rest ----
        mov     $0x1122334455667788, %rax
        mov     $0xBEEF, %ax
        movabs  $0x112233445566BEEF, %rcx
        cmp     %rcx, %rax
        jne     fail
        inc     %r15d

        mov     $0xAB, %al
        movabs  $0x112233445566BEAB, %rcx
        cmp     %rcx, %rax
        jne     fail
        inc     %r15d

// ---- shifts ----
        mov     $0x8000000000000000, %rax
        shl     $1, %rax
        jnz     fail
        jnc     fail
        inc     %r15d

        mov     $-16, %rax
        sar     $2, %rax
        cmp     $-4, %rax
        jne     fail
        inc     %r15d

        mov     $0x12345678, %eax
        rol     $8, %eax
        cmp     $0x34567812, %eax
        jne     fail
        inc     %r15d

// ---- multiply, 128-bit result ----
        movabs  $0x123456789ABCDEF0, %rax
        movabs  $0x1000000000000000, %rcx
        mul     %rcx                      // rdx:rax = rax * rcx
        movabs  $0x0123456789ABCDEF, %rbx
        cmp     %rbx, %rdx
        jne     fail
        test    %rax, %rax
        jnz     fail
        inc     %r15d

// ---- 128/64 division ----
        movabs  $0x0123456789ABCDEF, %rdx
        xor     %rax, %rax
        movabs  $0x1000000000000000, %rcx
        div     %rcx                      // quotient in rax, remainder in rdx
        movabs  $0x123456789ABCDEF0, %rbx
        cmp     %rbx, %rax
        jne     fail
        test    %rdx, %rdx
        jnz     fail
        inc     %r15d

// ---- signed division ----
        mov     $-100, %rax
        cqto
        mov     $7, %rcx
        idiv    %rcx
        cmp     $-14, %rax
        jne     fail
        cmp     $-2, %rdx
        jne     fail
        inc     %r15d

// ---- stack, call, ret ----
        mov     $0x8000, %rsp
        mov     $0xCAFEBABE, %rax
        push    %rax
        pop     %rbx
        cmp     %rax, %rbx
        jne     fail
        inc     %r15d

        call    subroutine
        cmp     $0x42, %rax
        jne     fail
        inc     %r15d

// ---- rep movsb ----
        lea     source(%rip), %rsi
        mov     $0x9000, %rdi
        mov     $8, %rcx
        cld
        rep     movsb
        mov     0x9000, %rax
        movabs  $0x0807060504030201, %rcx
        cmp     %rcx, %rax
        jne     fail
        inc     %r15d

// ---- rep stosq then scas ----
        mov     $0xA000, %rdi
        mov     $0x1111111111111111, %rax
        mov     $4, %rcx
        rep     stosq
        mov     $0xA000, %rdi
        mov     $4, %rcx
        mov     $0x1111111111111111, %rax
        repe    scasq
        jnz     fail
        inc     %r15d

// ---- bit operations ----
        mov     $0x100, %rax
        bsf     %rax, %rcx
        cmp     $8, %rcx
        jne     fail
        bsr     %rax, %rcx
        cmp     $8, %rcx
        jne     fail
        inc     %r15d

        mov     $0, %rax
        bts     $40, %rax
        movabs  $0x10000000000, %rcx
        cmp     %rcx, %rax
        jne     fail
        btr     $40, %rax
        jnc     fail
        test    %rax, %rax
        jnz     fail
        inc     %r15d

// ---- setcc / cmov ----
        xor     %rax, %rax
        cmp     $1, %rax
        setl    %bl
        cmp     $1, %bl
        jne     fail
        mov     $7, %rcx
        mov     $9, %rdx
        cmp     %rdx, %rcx
        cmovl   %rdx, %rcx
        cmp     $9, %rcx
        jne     fail
        inc     %r15d

// ---- byte swap and sign extension ----
        mov     $0x11223344, %eax
        bswap   %eax
        cmp     $0x44332211, %eax
        jne     fail
        movsbq  %al, %rax
        cmp     $0x11, %rax
        jne     fail
        inc     %r15d

        mov     $0xFF, %al
        movsbq  %al, %rax
        cmp     $-1, %rax
        jne     fail
        inc     %r15d

// ---- xadd / cmpxchg ----
        mov     $10, %rax
        mov     $5, %rbx
        xadd    %rbx, %rax                // rax = 15, rbx = 10
        cmp     $15, %rax
        jne     fail
        cmp     $10, %rbx
        jne     fail
        inc     %r15d

        mov     $0x9800, %rdi
        movq    $100, (%rdi)
        mov     $100, %rax
        mov     $200, %rbx
        cmpxchg %rbx, (%rdi)
        jnz     fail
        cmpq    $200, (%rdi)
        jne     fail
        inc     %r15d

// ---- success ----
        xor     %eax, %eax
        out     %al, $0xE9
        hlt

fail:
        mov     %r15d, %eax
        out     %al, $0xE9
        hlt

subroutine:
        mov     $0x42, %rax
        ret

        .align 8
source:
        .byte 1, 2, 3, 4, 5, 6, 7, 8
