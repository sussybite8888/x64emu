// Boot sector that exercises planar VGA (mode 12h, 640x480 in 16 colours).
//   - sets the mode through INT 10h
//   - draws with graphics-controller write mode 0, one plane at a time
//   - draws a second block using the bit mask, so partial bytes are covered
// Reports 0 on the debug port when done.

        .code16
        .text
        .globl  _start
_start:
        cli
        xor     %ax, %ax
        mov     %ax, %ds
        mov     %ax, %ss
        mov     $0x7c00, %sp
        sti

// ---- mode 12h: 640x480, four planes ----
        mov     $0x0012, %ax
        int     $0x10

        mov     $0xa000, %ax
        mov     %ax, %es

// ---- write mode 0, full bit mask ----
        mov     $0x3ce, %dx
        mov     $0x0005, %ax             // GC index 5 = mode, value 0
        out     %ax, %dx
        mov     $0xff08, %ax             // GC index 8 = bit mask, all bits
        out     %ax, %dx
        mov     $0x0001, %ax             // GC index 1 = enable set/reset, none
        out     %ax, %dx

// ---- plane 0 only: colour 1 across the first row of bytes ----
        mov     $0x3c4, %dx
        mov     $0x0102, %ax             // sequencer map mask = plane 0
        out     %ax, %dx
        xor     %di, %di
        mov     $80, %cx
        mov     $0xff, %al
        rep     stosb                    // es:di = a000:0000

// ---- planes 0 and 1: colour 3 on the second row ----
        mov     $0x3c4, %dx
        mov     $0x0302, %ax             // map mask = planes 0 and 1
        out     %ax, %dx
        mov     $80, %di
        mov     $80, %cx
        mov     $0xff, %al
        rep     stosb

// ---- bit mask: only the top bit of each byte on the third row ----
        mov     $0x3ce, %dx
        mov     $0x8008, %ax             // bit mask = 0x80
        out     %ax, %dx
        mov     $0x3c4, %dx
        mov     $0x0f02, %ax             // all four planes
        out     %ax, %dx
        mov     $160, %di
        movb    %es:(%di), %al           // load the latches
        mov     $0xff, %al
        movb    %al, %es:(%di)

        xor     %al, %al
        out     %al, $0xE9
        hlt
        jmp     .

        .org    510
        .word   0xaa55
