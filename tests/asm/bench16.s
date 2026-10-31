// Two 16-bit loops driven through the real BIOS, so the cost of an INT round
// trip can be separated from the cost of interpreting 16-bit code.  %bx picks:
//   0 = pure ALU, no BIOS at all      1 = INT 1Ah on every iteration
        .code16
        .text
        .globl  _start
_start:
        cli
        xor     %ax, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     $0x7000, %sp
        mov     0x7c00 + boot_sel - _start, %bl
        cmp     $1, %bl
        je      int_loop

// ---- interpretation only ----
alu_loop:
        mov     $0x4000, %cx
1:      .rept   16
        add     %ax, %dx
        .endr
        loop    1b
        mov     $0, %al
        outb    %al, $0xE9
        hlt

// ---- one BIOS call per iteration ----
int_loop:
        mov     $0x4000, %cx
1:      push    %cx
        xor     %ah, %ah
        int     $0x1a
        pop     %cx
        loop    1b
        mov     $0, %al
        outb    %al, $0xE9
        hlt

boot_sel:
        .byte   0
