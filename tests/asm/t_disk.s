// Exercises the writable RAM hard drive through INT 13h.
//   - writes a pattern to a high LBA on drive 0x80 (extended write, AH=43)
//   - reads it back (extended read, AH=42) and compares
//   - reads a never-written LBA and checks it comes back as zeros
//   - writes and reads through the CHS entry points (AH=03 / AH=02)
// Reports 0 on the debug port for success, otherwise a check number.

        .set    DAP,     0x0600           // disk address packet
        .set    SRCBUF,  0x9000           // pattern written from here
        .set    DSTBUF,  0xA000           // read back to here
        .set    ZEROBUF, 0xB000

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

// ---- build a 512-byte pattern: byte i = i ^ 0x5A ----
        mov     $SRCBUF, %di
        xor     %cx, %cx
1:      mov     %cl, %al
        xor     $0x5A, %al
        mov     %al, (%di)
        inc     %di
        inc     %cx
        cmp     $512, %cx
        jb      1b

// ---- extended write of one sector to LBA 0x12345 ----
        call    make_dap_src
        mov     $0x4300, %ax
        mov     $0x80, %dl
        mov     $DAP, %si
        int     $0x13
        mov     $1, %bl
        jc      fail

// ---- extended read it back to a different buffer ----
        call    make_dap_dst
        mov     $0x4200, %ax
        mov     $0x80, %dl
        mov     $DAP, %si
        int     $0x13
        mov     $2, %bl
        jc      fail

        mov     $SRCBUF, %si
        mov     $DSTBUF, %di
        mov     $512, %cx
        call    compare
        mov     $3, %bl
        jnz     fail

// ---- a sector that was never written must read back as zeros ----
        call    make_dap_zero
        mov     $0x4200, %ax
        mov     $0x80, %dl
        mov     $DAP, %si
        int     $0x13
        mov     $4, %bl
        jc      fail

        mov     $ZEROBUF, %di
        mov     $512, %cx
2:      cmpb    $0, (%di)
        mov     $5, %bl
        jne     fail
        inc     %di
        loop    2b

// ---- CHS write then CHS read, cylinder 2 head 3 sector 4 ----
        mov     $SRCBUF, %bx
        mov     $0x0301, %ax             // write one sector
        mov     $0x0204, %cx             // cylinder 2, sector 4
        mov     $0x0380, %dx             // head 3, drive 0x80
        int     $0x13
        mov     $6, %bl
        jc      fail

        mov     $DSTBUF, %bx
        mov     $512, %cx
        mov     $DSTBUF, %di
        xor     %al, %al
3:      mov     %al, (%di)               // scrub the destination first
        inc     %di
        loop    3b

        mov     $DSTBUF, %bx
        mov     $0x0201, %ax             // read one sector
        mov     $0x0204, %cx
        mov     $0x0380, %dx
        int     $0x13
        mov     $7, %bl
        jc      fail

        mov     $SRCBUF, %si
        mov     $DSTBUF, %di
        mov     $512, %cx
        call    compare
        mov     $8, %bl
        jnz     fail

// ---- the drive should report itself through AH=48 ----
        mov     $DAP, %si
        movw    $0x1e, (%si)
        mov     $0x4800, %ax
        mov     $0x80, %dl
        int     $0x13
        mov     $9, %bl
        jc      fail

        xor     %al, %al
        out     %al, $0xE9
        hlt
        jmp     .

fail:
        mov     %bl, %al
        out     %al, $0xE9
        hlt
        jmp     .

// ---- helpers ----
// Compare %cx bytes at ds:si and es:di; ZF set when equal.
compare:
        repe    cmpsb
        ret

// Disk address packet: size, reserved, count, offset, segment, LBA (qword)
make_dap_src:
        mov     $DAP, %di
        movw    $0x0010, (%di)
        movw    $1, 2(%di)
        movw    $SRCBUF, 4(%di)
        movw    $0, 6(%di)
        movl    $0x12345, 8(%di)
        movl    $0, 12(%di)
        ret

make_dap_dst:
        call    make_dap_src
        movw    $DSTBUF, 4(%di)
        ret

make_dap_zero:
        call    make_dap_src
        movw    $ZEROBUF, 4(%di)
        movl    $0x77777, 8(%di)         // never written
        ret

        .org    510
        .word   0xaa55
