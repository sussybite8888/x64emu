// The PS/2 mouse through the BIOS, the way Windows 95's driver uses it.
//   - INT 11h reports a pointing device
//   - INT 15h C205h / C207h / C200h initialise, install a handler, enable
//   - the host then moves the mouse, and the ROM's INT 74h handler must
//     far-call ours with the packet's status, X and Y words on the stack
// Writes 0xFE to the debug port once ready for the host to move the mouse,
// then 0 for success or a check number.

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

        int     $0x11                       // equipment: bit 2 is the mouse
        test    $4, %al
        mov     $1, %bl
        jz      fail

        mov     $0xc205, %ax                // initialise, 3-byte packets
        mov     $3, %bh
        int     $0x15
        mov     $2, %bl
        jc      fail
        mov     $0xc207, %ax                // our handler, at ES:BX
        mov     $handler, %bx
        int     $0x15
        mov     $3, %bl
        jc      fail
        mov     $0xc200, %ax                // enable
        mov     $1, %bh
        int     $0x15
        mov     $4, %bl
        jc      fail

        mov     $0xfe, %al                  // ready: move the mouse
        out     %al, $0xe9
        sti
1:      hlt
        cmpb    $0, got
        je      1b
        cli

        cmpw    $0x09, status               // left button, bit 3, no signs
        mov     $5, %bl
        jne     fail
        cmpw    $5, xdelta
        mov     $6, %bl
        jne     fail
        cmpw    $3, ydelta                  // up is positive
        mov     $7, %bl
        jne     fail

        xor     %al, %al
        out     %al, $0xe9
        hlt
fail:
        mov     %bl, %al
        out     %al, $0xe9
        cli
        hlt

// Far-called by the BIOS: [bp+12] status, [bp+10] X, [bp+8] Y, [bp+6] Z.
// DS is the BIOS's own here, so our variables are reached through CS.
handler:
        push    %bp
        mov     %sp, %bp
        push    %ax
        mov     12(%bp), %ax
        mov     %ax, %cs:status
        mov     10(%bp), %ax
        mov     %ax, %cs:xdelta
        mov     8(%bp), %ax
        mov     %ax, %cs:ydelta
        movb    $1, %cs:got
        pop     %ax
        pop     %bp
        lret

status: .word   0
xdelta: .word   0
ydelta: .word   0
got:    .byte   0
