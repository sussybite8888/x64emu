// LAR, LSL, VERR and VERW.
//
// The Windows 95 VMM validates selectors with these before it trusts them, so
// a missing one is an invalid-opcode fault inside the kernel, and a VERR that
// leaves ZF alone sends it down whichever path ZF happened to pick.  None of
// them may fault on a bad selector: the answer goes in ZF and the destination
// is left untouched.  This runs in long mode, which also drops the 16-bit
// system types.
        .code64
        .text
        .globl  _start

.macro  want    reg, value, code
        movabs  $\value, %r14
        cmp     %r14, \reg
        mov     $\code, %r13b
        jne     fail
.endm

// ZF must be set by the instruction under test, so start from the opposite
.macro  zf0
        xor     %r8d, %r8d
        inc     %r8d
.endm
.macro  zf1
        xor     %r8d, %r8d
.endm

_start:
        mov     $0x8000, %rsp
        lea     gdt(%rip), %rax
        mov     %rax, gdtr+2(%rip)
        lgdt    gdtr(%rip)

// ---- LAR: access rights, masked to 00FFFF00 --------------------------
        mov     $0x10, %ecx
        mov     $0xdeadbeef, %eax
        zf0
        lar     %cx, %eax
        mov     $1, %r13b
        jnz     fail
        want    %rax, 0x00CF9200, 2

        mov     $0x18, %ecx
        zf0
        lar     %cx, %eax
        mov     $3, %r13b
        jnz     fail
        want    %rax, 0x00409000, 4

// a 16-bit destination gets only the access byte, and keeps its upper half
        mov     $0x10, %ecx
        mov     $0x12345678, %eax
        zf0
        lar     %cx, %ax
        mov     $5, %r13b
        jnz     fail
        want    %rax, 0x12349200, 6

// the selector can come from memory
        movw    $0x18, sel(%rip)
        zf0
        lar     sel(%rip), %eax
        mov     $7, %r13b
        jnz     fail
        want    %rax, 0x00409000, 8

// ---- LSL: the limit, scaled by granularity ----------------------------
        mov     $0x10, %ecx
        zf0
        lsl     %cx, %eax
        mov     $9, %r13b
        jnz     fail
        want    %rax, 0xFFFFFFFF, 10

        mov     $0x18, %ecx
        zf0
        lsl     %cx, %eax
        mov     $11, %r13b
        jnz     fail
        want    %rax, 0x1234, 12

// ---- selectors that are not visible: ZF clear, destination untouched --
        xor     %ecx, %ecx                      // null
        mov     $0x55555555, %eax
        zf1
        lar     %cx, %eax
        mov     $13, %r13b
        jz      fail
        want    %rax, 0x55555555, 14

        mov     $0x58, %ecx                     // past the end of the GDT
        zf1
        lar     %cx, %eax
        mov     $15, %r13b
        jz      fail
        zf1
        lsl     %cx, %eax
        mov     $16, %r13b
        jz      fail
        want    %rax, 0x55555555, 17

        mov     $0x13, %ecx                     // RPL 3 against DPL 0
        zf1
        lar     %cx, %eax
        mov     $18, %r13b
        jz      fail

        mov     $0x2b, %ecx                     // DPL 3 is visible from ring 0
        zf0
        lar     %cx, %eax
        mov     $19, %r13b
        jnz     fail
        want    %rax, 0x00CFF200, 20

        mov     $0x4b, %ecx                     // conforming code ignores RPL
        zf0
        lar     %cx, %eax
        mov     $21, %r13b
        jnz     fail

// ---- system descriptors ------------------------------------------------
        mov     $0x30, %ecx                     // 16-bit TSS: not in long mode
        zf1
        lar     %cx, %eax
        mov     $22, %r13b
        jz      fail

        mov     $0x38, %ecx                     // 64-bit TSS
        zf0
        lar     %cx, %eax
        mov     $23, %r13b
        jnz     fail
        want    %rax, 0x00008900, 24
        zf0
        lsl     %cx, %eax
        mov     $25, %r13b
        jnz     fail
        want    %rax, 0x67, 26

// ---- VERR / VERW -------------------------------------------------------
        mov     $0x10, %ecx                     // writable data
        zf0
        verr    %cx
        mov     $27, %r13b
        jnz     fail
        zf0
        verw    %cx
        mov     $28, %r13b
        jnz     fail

        mov     $0x18, %ecx                     // read-only data
        zf0
        verr    %cx
        mov     $29, %r13b
        jnz     fail
        zf1
        verw    %cx
        mov     $30, %r13b
        jz      fail

        mov     $0x20, %ecx                     // execute-only code
        zf1
        verr    %cx
        mov     $31, %r13b
        jz      fail
        zf1
        verw    %cx
        mov     $32, %r13b
        jz      fail

        mov     $0x08, %ecx                     // readable code
        zf0
        verr    %cx
        mov     $33, %r13b
        jnz     fail

        mov     $0x13, %ecx                     // RPL 3 against DPL 0
        zf1
        verr    %cx
        mov     $34, %r13b
        jz      fail

        mov     $0x38, %ecx                     // a TSS is not a segment
        zf1
        verr    %cx
        mov     $35, %r13b
        jz      fail

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
gdt:
        .quad   0                               // 0x00 null
        .quad   0x00AF9A000000FFFF              // 0x08 code64, readable
        .quad   0x00CF92000000FFFF              // 0x10 data, writable, 4 GiB
        .quad   0x0040900000001234              // 0x18 data, read-only, byte limit
        .quad   0x00CF98000000FFFF              // 0x20 code, execute-only
        .quad   0x00CFF2000000FFFF              // 0x28 data, DPL 3
        .quad   0x0000810000000067              // 0x30 16-bit TSS
        .quad   0x0000890000000067              // 0x38 64-bit TSS (low half)
        .quad   0                               // 0x40 64-bit TSS (high half)
        .quad   0x00CF9E000000FFFF              // 0x48 conforming code
gdt_end:
gdtr:   .word   gdt_end - gdt - 1
        .quad   0
sel:    .word   0
