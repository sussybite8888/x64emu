// A boot sector that exercises the BIOS and the VGA graphics path:
//   - prints a line through INT 10h teletype
//   - switches to mode 13h (320x200, 256 colours) through INT 10h
//   - paints a known pattern into the framebuffer at A000:0000
//   - reports success on the debug port and halts
// The host checks both the pattern and the RGBA the renderer produces.

        .code16
        .text
        .globl  _start
_start:
        cli
        xor     %ax, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     $0x7c00, %sp
        sti

// ---- teletype a banner so INT 10h AH=0Eh is covered ----
        mov     $msg, %si
        call    print

// ---- set mode 13h ----
        mov     $0x0013, %ax
        int     $0x10

// ---- confirm the BIOS recorded the new mode ----
        mov     $0x0f00, %ax
        int     $0x10
        cmp     $0x13, %al
        jne     fail

// ---- paint: pixel (x, y) gets colour (x ^ y) ----
        mov     $0xa000, %ax
        mov     %ax, %es
        xor     %di, %di
        xor     %dx, %dx                 // dx = y
row:
        xor     %cx, %cx                 // cx = x
col:
        mov     %cl, %al
        xor     %dl, %al
        stosb
        inc     %cx
        cmp     $320, %cx
        jb      col
        inc     %dx
        cmp     $200, %dx
        jb      row

        xor     %al, %al
        out     %al, $0xE9
        hlt
        jmp     .

fail:
        mov     $1, %al
        out     %al, $0xE9
        hlt
        jmp     .

// print a NUL-terminated string at %si with INT 10h AH=0Eh
print:
        lodsb
        test    %al, %al
        jz      1f
        mov     $0x0e, %ah
        mov     $0x0007, %bx
        int     $0x10
        jmp     print
1:      ret

msg:    .asciz  "x64emu vga test\r\n"

        .org    510
        .word   0xaa55
