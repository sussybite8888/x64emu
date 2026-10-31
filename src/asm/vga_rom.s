// ROM code the BIOS runs for INT 10h called from a virtual-8086 machine, so
// that the VGA is programmed with port writes a virtual display driver can
// trap (see VGA_SET_MODE in src/js/bios.js, which holds these bytes).
// Rebuild with:
//   clang -target x86_64-unknown-none -c src/asm/vga_rom.s -o vga_rom.o
//   python3 tests/elf2bin.py vga_rom.o 0x2000 > vga_rom.bin
        .intel_syntax noprefix
        .code16
        .text
// Program the VGA from a parameter block, with port I/O a virtual display
// driver can trap.  AX = offset of the block in this segment; bit 15 set
// means leave video memory as it is (mode number with bit 7 set).
//   block: misc, seq[1..4], crtc[0..24], attr[0..19], gc[0..8],
//          dac byte count (word), dac table offset (word),
//          clear segment (word), clear word count (word), clear value (word)
set_mode:
        push    ds
        push    es
        push    si
        push    di
        push    dx
        push    cx
        push    bx
        push    ax
        and     ah, 0x7f
        mov     si, ax
        push    cs
        pop     ds
        cld
        mov     dx, 0x3c4
        mov     ax, 0x0100              // sequencer: synchronous reset
        out     dx, ax
        mov     dx, 0x3c2
        lodsb                           // miscellaneous output
        out     dx, al
        mov     dx, 0x3c4
        mov     bl, 1
1:      mov     al, bl
        out     dx, al
        inc     dx
        lodsb
        out     dx, al
        dec     dx
        inc     bl
        cmp     bl, 5
        jb      1b
        mov     ax, 0x0300              // end the reset
        out     dx, ax
        mov     dx, 0x3d4
        mov     ax, 0x0011              // unlock CRTC 0-7
        out     dx, ax
        xor     bl, bl
2:      mov     al, bl
        out     dx, al
        inc     dx
        lodsb
        out     dx, al
        dec     dx
        inc     bl
        cmp     bl, 25
        jb      2b
        mov     dx, 0x3da
        in      al, dx                // attribute flip-flop to index
        mov     dx, 0x3c0
        xor     bl, bl
3:      mov     al, bl
        out     dx, al
        lodsb
        out     dx, al
        inc     bl
        cmp     bl, 20
        jb      3b
        mov     al, 0x20                // palette done: display on
        out     dx, al
        mov     dx, 0x3ce
        xor     bl, bl
4:      mov     al, bl
        out     dx, al
        inc     dx
        lodsb
        out     dx, al
        dec     dx
        inc     bl
        cmp     bl, 9
        jb      4b
        lodsw                           // the DAC
        mov     cx, ax
        lodsw
        push    si
        mov     si, ax
        mov     dx, 0x3c8
        xor     al, al
        out     dx, al
        inc     dx
        rep     outsb
        pop     si
        lodsw                           // video memory
        mov     es, ax
        lodsw
        mov     cx, ax
        lodsw
        pop     bx                      // the caller's AX: bit 15 keeps memory
        test    bh, 0x80
        jnz     5f
        xor     di, di
        rep     stosw
5:      pop     bx
        pop     cx
        pop     dx
        pop     di
        pop     si
        pop     es
        pop     ds
        iret

// The hardware cursor's position, from the BIOS data area: the active page's
// cursor at 40:50 + 2 * page, the page's start at 40:4E.
set_cursor:
        push    ds
        push    ax
        push    bx
        push    cx
        push    dx
        mov     ax, 0x40
        mov     ds, ax
        mov     dx, word ptr [0x63]              // CRTC port
        mov     bl, byte ptr [0x62]              // active page
        xor     bh, bh
        shl     bx, 1
        mov     al, byte ptr [bx + 0x51]         // row
        mul     byte ptr [0x4a]         // * columns
        xor     ch, ch
        mov     cl, byte ptr [bx + 0x50]         // + column
        add     ax, cx
        mov     cx, word ptr [0x4e]              // + the page's start, in characters
        shr     cx, 1
        add     cx, ax
        mov     al, 0x0e
        mov     ah, ch
        out     dx, ax
        mov     al, 0x0f
        mov     ah, cl
        out     dx, ax
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        pop     ds
        iret
