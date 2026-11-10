// String operations.
//
// These move most of the bytes a boot loader ever copies, and they have several
// edge cases that are easy to get wrong: the direction flag runs them
// backwards, a REP prefix with a zero count must do nothing at all and leave
// the pointers alone, and the search forms have to leave RCX and RDI pointing
// just past the element that matched.
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
        cld

// ---- REP MOVSB ---------------------------------------------------------
        lea     src(%rip), %rsi
        lea     dst(%rip), %rdi
        mov     $16, %rcx
        rep     movsb
        want    %rcx, 0, 1
        mov     dst(%rip), %rax
        want    %rax, 0xA7A6A5A4A3A2A1A0, 2
        mov     dst+8(%rip), %rax
        want    %rax, 0xAFAEADACABAAA9A8, 3
// the pointers must end just past the region copied
        lea     src(%rip), %rax
        add     $16, %rax
        cmp     %rax, %rsi
        mov     $4, %r13b
        jne     fail
        lea     dst(%rip), %rax
        add     $16, %rax
        cmp     %rax, %rdi
        mov     $5, %r13b
        jne     fail

// ---- REP MOVSQ ---------------------------------------------------------
        lea     src(%rip), %rsi
        lea     dst2(%rip), %rdi
        mov     $2, %rcx
        rep     movsq
        want    %rcx, 0, 6
        mov     dst2(%rip), %rax
        want    %rax, 0xA7A6A5A4A3A2A1A0, 7
        mov     dst2+8(%rip), %rax
        want    %rax, 0xAFAEADACABAAA9A8, 8

// ---- a REP with a zero count must not move anything --------------------
        lea     src(%rip), %rsi
        lea     dst3(%rip), %rdi
        xor     %rcx, %rcx
        rep     movsb
        lea     src(%rip), %rax
        cmp     %rax, %rsi
        mov     $9, %r13b
        jne     fail                            // RSI must not have moved
        lea     dst3(%rip), %rax
        cmp     %rax, %rdi
        mov     $10, %r13b
        jne     fail
        mov     dst3(%rip), %rax
        want    %rax, 0, 11                     // and nothing was written

// ---- the direction flag runs the copy backwards ------------------------
        lea     src+3(%rip), %rsi
        lea     dst3+3(%rip), %rdi
        mov     $4, %rcx
        std
        rep     movsb
        cld
        want    %rcx, 0, 12
        mov     dst3(%rip), %eax
        want    %rax, 0xA3A2A1A0, 13            // same order, both ran down
        lea     src(%rip), %rax
        dec     %rax
        cmp     %rax, %rsi
        mov     $14, %r13b
        jne     fail                            // RSI ends one before the start

// ---- REP STOSB / REP STOSQ --------------------------------------------
        lea     dst4(%rip), %rdi
        mov     $0xAB, %al
        mov     $8, %rcx
        rep     stosb
        mov     dst4(%rip), %rax
        want    %rax, 0xABABABABABABABAB, 15

        lea     dst4(%rip), %rdi
        movabs  $0x1122334455667788, %rax
        mov     $2, %rcx
        rep     stosq
        mov     dst4(%rip), %rax
        want    %rax, 0x1122334455667788, 16
        mov     dst4+8(%rip), %rax
        want    %rax, 0x1122334455667788, 17

// ---- LODS --------------------------------------------------------------
        lea     src(%rip), %rsi
        xor     %rax, %rax
        lodsb
        want    %rax, 0xA0, 18
        lea     src(%rip), %rax
        inc     %rax
        cmp     %rax, %rsi
        mov     $19, %r13b
        jne     fail

        lea     src(%rip), %rsi
        lodsq
        want    %rax, 0xA7A6A5A4A3A2A1A0, 20

// ---- REPNE SCASB finds the byte and stops just past it -----------------
        lea     src(%rip), %rdi
        mov     $16, %rcx
        mov     $0xA5, %al
        repne   scasb
        mov     $21, %r13b
        jne     fail                            // ZF set: it was found
        want    %rcx, 10, 22                    // six elements consumed
        lea     src(%rip), %rax
        add     $6, %rax
        cmp     %rax, %rdi
        mov     $23, %r13b
        jne     fail

// a byte that is not there runs the count out and leaves ZF clear
        lea     src(%rip), %rdi
        mov     $16, %rcx
        mov     $0x5C, %al
        repne   scasb
        mov     $24, %r13b
        je      fail
        want    %rcx, 0, 25

// ---- REPE CMPSB over identical regions ---------------------------------
        lea     src(%rip), %rsi
        lea     dst(%rip), %rdi
        mov     $16, %rcx
        repe    cmpsb
        mov     $26, %r13b
        jne     fail
        want    %rcx, 0, 27

// and over regions that differ at a known offset
        lea     src(%rip), %rsi
        lea     diff(%rip), %rdi
        mov     $16, %rcx
        repe    cmpsb
        mov     $28, %r13b
        je      fail
        want    %rcx, 12, 29                    // stopped after the fourth byte

// ---- an overlapping forward copy repeats a pattern ---------------------
// x86 copies one element at a time, front to back, so a destination one byte
// above its source re-reads what it has just written.  A bulk copy with
// memmove semantics would shift the bytes instead.
        lea     pat(%rip), %rsi
        lea     pat+1(%rip), %rdi
        mov     $15, %rcx
        rep     movsb
        mov     pat(%rip), %rax
        want    %rax, 0x5A5A5A5A5A5A5A5A, 30
        mov     pat+8(%rip), %rax
        want    %rax, 0x5A5A5A5A5A5A5A5A, 31

// ---- a copy across several pages ---------------------------------------
// Fill 12000 bytes with a pattern, copy them as dwords to a destination that
// sits at a different offset within its pages, and compare.  Large copies are
// done a page at a time, so this crosses every boundary case.
        mov     $0x400001, %rdi
        xor     %ecx, %ecx
1:      mov     %ecx, %eax
        shr     $8, %eax
        xor     %ecx, %eax
        mov     %al, (%rdi,%rcx)
        inc     %ecx
        cmp     $12000, %ecx
        jne     1b
        mov     $0x400001, %rsi
        mov     $0x410ffd, %rdi
        mov     $3000, %rcx
        rep     movsl
        want    %rcx, 0, 32
        mov     $0x410ffd + 12000, %rax
        cmp     %rax, %rdi
        mov     $33, %r13b
        jne     fail
        mov     $0x400001, %rsi
        mov     $0x410ffd, %rdi
        mov     $12000, %rcx
        repe    cmpsb
        mov     $34, %r13b
        jne     fail
        want    %rcx, 0, 35
// and REP STOSW over the same span
        mov     $0x410ffd, %rdi
        mov     $0xBEEF, %ax
        mov     $6000, %rcx
        rep     stosw
        movzwl  0x410ffd, %eax
        want    %rax, 0xBEEF, 36
        movzwl  0x410ffd + 11998, %eax
        want    %rax, 0xBEEF, 37
        movzbl  0x410ffd + 12000, %eax
        want    %rax, 0, 38                     // and not one byte past

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
src:    .byte   0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7
        .byte   0xA8,0xA9,0xAA,0xAB,0xAC,0xAD,0xAE,0xAF
// identical to src apart from the fourth byte
diff:   .byte   0xA0,0xA1,0xA2,0x00,0xA4,0xA5,0xA6,0xA7
        .byte   0xA8,0xA9,0xAA,0xAB,0xAC,0xAD,0xAE,0xAF
dst:    .quad   0, 0
dst2:   .quad   0, 0
dst3:   .quad   0, 0
dst4:   .quad   0, 0
pat:    .byte   0x5A
        .fill   15, 1, 0
