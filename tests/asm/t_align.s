// Coverage for the eight-byte instruction read-ahead buffer.
//
// The buffer is refilled at each instruction boundary, so padding between
// instructions proves nothing — what matters is where a field sits *within* an
// instruction.  A displacement that overruns the buffer has to be read from
// memory, and anything still buffered is then stale: an immediate following it
// must not be taken from the buffer.  Ignored segment prefixes pad the front of
// the instruction so the displacement crosses the buffer edge at every offset.
        .code64
        .text
        .globl  _start
_start:
        mov     $0x8000, %rsp
        mov     $0x200000, %rdi

// disp32 followed by imm8, with 0..7 null prefixes ahead of it
        .set    K, 0
        .rept   8
        .rept   K
        .byte   0x2e                    // CS prefix, ignored in 64-bit mode
        .endr
        movb    $0x5A, (0x1000 + K * 8)(%rdi)
        .set    K, K + 1
        .endr

// the same walk for disp32 followed by imm32
        .set    J, 0
        .rept   8
        .rept   J
        .byte   0x2e
        .endr
        movl    $0xAABBCCDD, (0x2000 + J * 8)(%rdi)
        .set    J, J + 1
        .endr

// and with a SIB byte in the mix, which shifts the displacement one further
        .set    M, 0
        .rept   8
        .rept   M
        .byte   0x2e
        .endr
        xor     %rax, %rax
        movb    $0x5A, (0x3000 + M * 8)(%rdi,%rax,1)
        .set    M, M + 1
        .endr

        mov     $0x1000, %rsi
        mov     $1, %bl
        call    check_bytes
        mov     $0x3000, %rsi
        mov     $3, %bl
        call    check_bytes

        xor     %rcx, %rcx
2:      mov     %rcx, %rax
        shl     $3, %rax
        cmpl    $0xAABBCCDD, 0x2000(%rdi,%rax)
        mov     $2, %bl
        jne     fail
        inc     %rcx
        cmp     $8, %rcx
        jb      2b

        xor     %eax, %eax
        out     %al, $0xE9
        hlt

// eight bytes of 0x5A at %rsi(%rdi), stride 8
check_bytes:
        xor     %rcx, %rcx
1:      mov     %rcx, %rax
        shl     $3, %rax
        add     %rsi, %rax
        cmpb    $0x5A, (%rdi,%rax)
        jne     fail
        inc     %rcx
        cmp     $8, %rcx
        jb      1b
        ret
fail:
        mov     %bl, %al
        out     %al, $0xE9
        hlt
