// The same two loops assembled for 16-, 32- and 64-bit modes, so the cost of a
// mode can be compared against the others rather than against nothing.  The
// host enters at the label matching the mode it set up.
        .text
        .globl  _start

// ---- 64-bit -------------------------------------------------------------
        .code64
        .globl  m64_alu
m64_alu:
        mov     $2000000, %ecx
1:      .rept   16
        add     %eax, %ebx
        .endr
        dec     %ecx
        jnz     1b
        hlt

        .globl  m64_mem
m64_mem:
        mov     $2000000, %ecx
        mov     $0x100000, %edi
1:      .rept   8
        mov     (%rdi), %eax
        mov     %eax, 4(%rdi)
        .endr
        dec     %ecx
        jnz     1b
        hlt

// ---- 32-bit protected ---------------------------------------------------
        .code32
        .globl  m32_alu
m32_alu:
        mov     $2000000, %ecx
1:      .rept   16
        add     %eax, %ebx
        .endr
        dec     %ecx
        jnz     1b
        hlt

        .globl  m32_mem
m32_mem:
        mov     $2000000, %ecx
        mov     $0x100000, %edi
1:      .rept   8
        mov     (%edi), %eax
        mov     %eax, 4(%edi)
        .endr
        dec     %ecx
        jnz     1b
        hlt

// ---- 16-bit real --------------------------------------------------------
        .code16
        .globl  m16_alu
m16_alu:
        mov     $2000000, %ecx
1:      .rept   16
        add     %ax, %bx
        .endr
        dec     %ecx
        jnz     1b
        hlt

        .globl  m16_mem
m16_mem:
        mov     $2000000, %ecx
        mov     $0x2000, %di
1:      .rept   8
        mov     (%di), %ax
        mov     %ax, 4(%di)
        .endr
        dec     %ecx
        jnz     1b
        hlt
