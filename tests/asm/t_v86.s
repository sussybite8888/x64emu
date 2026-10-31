// Virtual-8086 mode.
//
// Starts in real mode at physical 0 and builds the smallest monitor that can
// host a V86 task: a GDT, an IDT, and a TSS whose I/O permission bitmap lets
// through only ports 0x80 and 0xE9.  It then IRETs into V86 mode and checks
// what Windows 95's VMM relies on: real-mode addressing at privilege 3, the
// IOPL-sensitive instructions trapping at IOPL 0 and running at IOPL 3, port
// access decided by the bitmap whatever IOPL is, ARPL as an invalid opcode,
// INT n through the IDT, and the shape of the frame a trap leaves on the
// ring-0 stack.  First, though, it checks that an IRET which faults leaves
// the CPU as it found it, since the monitor's own returns depend on that.
//
// The ring-0 handlers skip a trapping instruction by the length the V86 code
// leaves in BL, and record the vector and error code for it to check.
// Reports 0 on the debug port for success.

        .set    TSS,   0x20000
        .set    ESP0,  0x9000
        .set    V86SS, 0x0700
        .set    V86SP, 0x0FFE

        .code16
        .text
        .globl  _start
_start:
        cli
        cld
        xor     %ax, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     $0x7000, %sp
        lgdt    gdtr
        mov     %cr0, %eax
        or      $1, %eax
        mov     %eax, %cr0
        ljmp    $0x08, $pm_entry

// ---------------------------------------------------------------------------
//  the monitor, at ring 0
// ---------------------------------------------------------------------------
        .code32
pm_entry:
        mov     $0x10, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %fs
        mov     %ax, %gs
        mov     %ax, %ss
        mov     $ESP0, %esp

// TSS: the ring-0 stack, and a bitmap for ports 0-0x3FF denying all but two
        mov     $TSS, %edi
        xor     %eax, %eax
        mov     $(0x68 / 4), %ecx
        rep     stosl
        movl    $ESP0, TSS + 4
        movl    $0x10, TSS + 8
        movw    $0x68, TSS + 0x66
        mov     $(TSS + 0x68), %edi
        mov     $0xFFFFFFFF, %eax
        mov     $(0x84 / 4), %ecx
        rep     stosl
        andb    $0xFE, TSS + 0x68 + (0x80 / 8)      // port 0x80
        andb    $0xFD, TSS + 0x68 + (0xE9 / 8)      // port 0xE9
        mov     $0x18, %ax
        ltr     %ax

// IDT: everything unexpected except the vectors under test
        xor     %ecx, %ecx
1:      mov     $unexpected, %ebx
        mov     $0x8E, %edx
        call    set_gate
        inc     %ecx
        cmp     $0x32, %ecx
        jb      1b
        mov     $6, %ecx
        mov     $ud_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate
        mov     $13, %ecx
        mov     $gp_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate
        mov     $0x30, %ecx                         // reachable from ring 3
        mov     $int30_handler, %ebx
        mov     $0xEE, %edx
        call    set_gate
        mov     $0x31, %ecx                         // not reachable from ring 3
        mov     $int30_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate
        mov     $11, %ecx
        mov     $np_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate
        mov     $0x2F, %ecx                         // a 16-bit interrupt gate
        mov     $gate16_handler, %ebx
        mov     $0x86, %edx
        call    set_gate
        lidt    idtr

// ---- a 16-bit gate pushes a 16-bit frame ----
// IP, CS and FLAGS as words, six bytes in all, and IF cleared.  Windows routes
// its 16-bit clients' interrupts through gates like this.
        mov     %esp, %esi
        sti
        int     $0x2F
gate16_ret:
        cli
        cmp     %esp, %esi                          // a 16-bit IRET took them back
        mov     $0x55, %cl
        jne     pm_fail

// ---- an expand-down segment: the limit is the lower bound ----
// With B set the segment runs from limit+1 to 4 GiB.  Windows 95's 16-bit
// kernel keeps a flat selector like this to make its low 64 KiB fault.
        mov     $13, %ecx
        mov     $xd_gp_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate
        mov     $0x30, %ax
        mov     %ax, %fs
        movl    $0x12345678, %fs:0x30000            // above the limit: allowed
        cmpl    $0x12345678, 0x30000
        mov     $0x5B, %cl
        jne     pm_fail
        movb    $0, xd_faulted
        mov     %fs:0x100, %eax                     // below it: #GP
        cmpb    $1, xd_faulted
        mov     $0x5C, %cl
        jne     pm_fail
        mov     $0x10, %ax
        mov     %ax, %fs
        mov     $13, %ecx
        mov     $gp_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate

// ---- an IRET that faults is restartable ----
// Returning to a not-present ring-3 code segment is #NP naming it, taken at
// ring 0 on the ring-0 stack with the IRET frame still in place.  Windows 95
// demand-loads 16-bit code this way, through its own returns to ring 3.
        pushl   $0x23                               // SS
        pushl   $0x1000                             // ESP
        pushl   $0x00000002                         // EFLAGS
        pushl   $0x2B                               // CS, not present
        pushl   $0x1234                             // EIP
        mov     %esp, iret_esp
iret_np:
        iret
        mov     $0x50, %cl
        jmp     pm_fail
np_resume:
        mov     $ESP0, %esp

// ---- an IRET to ring-0 code with RPL 3 is #GP ----
// A non-conforming code segment's DPL has to equal the RPL returned to.
// Windows XP ends the BIOS calls its kernel makes with exactly this IRET, and
// finishes them in its #GP handler; taking it ran kernel code at ring 3.
        mov     $13, %ecx
        mov     $priv_gp_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate
        pushl   $0x23                               // SS
        pushl   $0x1000                             // ESP
        pushl   $0x00000002                         // EFLAGS
        pushl   $0x0B                               // CS: ring-0 code, RPL 3
        pushl   $0x1234                             // EIP
iret_priv:
        iret
        mov     $0x5E, %cl
        jmp     pm_fail
priv_resume:
        mov     $ESP0, %esp
        mov     $13, %ecx
        mov     $gp_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate

// ---- with CR0.TS set, the first x87, MMX or SSE instruction is #NM ----
// Windows switches that state lazily and swaps it in from this fault; without
// it every thread ran on the registers of the last.  The handler clears TS and
// the instruction runs again, as it would under a kernel.
        mov     $7, %ecx
        mov     $nm_handler, %ebx
        mov     $0x8E, %edx
        call    set_gate
        mov     %cr0, %eax
        or      $8, %eax
        mov     %eax, %cr0
        fninit
        cmpb    $1, nm_count
        mov     $0x62, %cl
        jne     pm_fail
        mov     %cr0, %eax
        or      $8, %eax
        mov     %eax, %cr0
        movq    %mm0, %mm1
        cmpb    $2, nm_count
        mov     $0x63, %cl
        jne     pm_fail
        mov     %cr0, %eax
        or      $8, %eax
        mov     %eax, %cr0
        pxor    %xmm0, %xmm0
        cmpb    $3, nm_count
        mov     $0x64, %cl
        jne     pm_fail
        fninit                                      // and none once TS is clear
        movq    %mm0, %mm1
        cmpb    $3, nm_count
        mov     $0x65, %cl
        jne     pm_fail

        movw    $0xFFFF, last_vec

// into virtual-8086 mode: VM set, IOPL 0, interrupts off
        pushl   $0                                  // GS
        pushl   $0                                  // FS
        pushl   $0                                  // DS
        pushl   $0                                  // ES
        pushl   $V86SS
        pushl   $V86SP
        pushl   $0x00020002
        pushl   $0                                  // CS
        pushl   $v86_start
        iret

// ecx = vector, ebx = handler, edx = gate type byte
set_gate:
        lea     idt(,%ecx,8), %edi
        mov     %ebx, %eax
        and     $0xFFFF, %eax
        or      $0x00080000, %eax
        mov     %eax, (%edi)
        mov     %ebx, %eax
        and     $0xFFFF0000, %eax
        shl     $8, %edx
        or      %edx, %eax
        mov     %eax, 4(%edi)
        ret

// After pusha the saved V86 registers sit at 0..31 (BL at 16, AX at 28), and
// the frame the CPU built follows: EIP, CS, EFLAGS, ESP, SS, ES, DS, FS, GS,
// after the error code when there is one.
.macro  enter_trap
        pusha
        // arriving from V86 mode, the data segments read as null
        mov     %ds, %ax
        mov     %es, %dx
        or      %dx, %ax
        mov     %fs, %dx
        or      %dx, %ax
        mov     %gs, %dx
        or      %dx, %ax
        mov     $0x41, %cl
        jnz     pm_fail
        mov     $0x10, %ax
        mov     %ax, %ds
.endm

// f = offset of the saved EIP
.macro  check_frame f
        testl   $0x20000, \f+8(%esp)                // EFLAGS image has VM
        mov     $0x42, %cl
        jz      pm_fail
        cmpl    $0, \f+4(%esp)                      // CS
        mov     $0x43, %cl
        jne     pm_fail
        cmpl    $V86SS, \f+16(%esp)                 // SS
        mov     $0x44, %cl
        jne     pm_fail
        cmpl    $0x1000, \f+20(%esp)                // ES
        mov     $0x45, %cl
        jne     pm_fail
        cmpl    $0, \f+24(%esp)                     // DS
        jne     pm_fail
        cmpl    $0x1001, \f+32(%esp)                // GS
        mov     $0x46, %cl
        jne     pm_fail
.endm

gp_handler:
        enter_trap
        check_frame 36
        movw    $13, last_vec
        mov     32(%esp), %eax
        mov     %ax, last_err
        movzbl  16(%esp), %eax
        add     %eax, 36(%esp)                      // past the trapping instruction
        popa
        add     $4, %esp                            // the error code
        iret

ud_handler:
        enter_trap
        check_frame 32
        cmpw    $1, exiting
        je      finished
        cmpw    $0x1234, 28(%esp)                   // the V86 code asks for IOPL 3
        jne     1f
        orl     $0x3000, 40(%esp)
1:      movw    $6, last_vec
        movw    $0, last_err
        movzbl  16(%esp), %eax
        add     %eax, 32(%esp)
        popa
        iret
finished:
        hlt

int30_handler:
        enter_trap
        check_frame 32
        pushf                                       // an interrupt gate clears IF
        popl    %eax
        test    $0x200, %eax
        mov     $0x47, %cl
        jnz     pm_fail
        testl   $0x200, 40(%esp)                    // the V86 code had it set
        mov     $0x48, %cl
        jz      pm_fail
        movw    $0x30, last_vec
        movw    $0, last_err
        popa
        iret

xd_gp_handler:
        cmpl    $0, (%esp)
        mov     $0x5D, %cl
        jne     pm_fail
        movb    $1, xd_faulted
        addl    $6, 4(%esp)                         // past mov %fs:0x100, %eax
        add     $4, %esp
        iret

gate16_handler:
        lea     6(%esp), %eax
        cmp     %esi, %eax
        mov     $0x56, %cl
        jne     pm_fail
        cmpw    $gate16_ret, (%esp)                 // IP
        mov     $0x57, %cl
        jne     pm_fail
        cmpw    $0x08, 2(%esp)                      // CS
        mov     $0x58, %cl
        jne     pm_fail
        testw   $0x200, 4(%esp)                     // FLAGS had IF set
        mov     $0x59, %cl
        jz      pm_fail
        pushf                                       // and the gate cleared it
        popl    %eax
        test    $0x200, %eax
        mov     $0x5A, %cl
        jnz     pm_fail
        iretw

np_handler:
        cmpl    $0x28, (%esp)                       // error code: the selector
        mov     $0x51, %cl
        jne     pm_fail
        cmpl    $iret_np, 4(%esp)                   // EIP: the IRET itself
        mov     $0x52, %cl
        jne     pm_fail
        cmpl    $0x08, 8(%esp)                      // taken at ring 0
        mov     $0x53, %cl
        jne     pm_fail
        lea     16(%esp), %eax                      // and the frame is where it was
        cmp     iret_esp, %eax
        mov     $0x54, %cl
        jne     pm_fail
        jmp     np_resume

nm_handler:
        incb    nm_count
        clts
        iret

priv_gp_handler:
        cmpl    $0x08, (%esp)                       // error code: the CS selector
        mov     $0x5F, %cl
        jne     pm_fail
        cmpl    $iret_priv, 4(%esp)                 // EIP: the IRET itself
        mov     $0x60, %cl
        jne     pm_fail
        cmpl    $0x08, 8(%esp)                      // taken at ring 0
        mov     $0x61, %cl
        jne     pm_fail
        jmp     priv_resume

unexpected:
        mov     $0x4F, %cl
pm_fail:
        mov     %cl, %al
        out     %al, $0xE9
        hlt

// ---------------------------------------------------------------------------
//  the V86 task
// ---------------------------------------------------------------------------
        .code16

.macro  expect  vec, err, code
        cmpw    $\vec, last_vec
        mov     $\code, %al
        jne     v86_fail
        cmpw    $\err, last_err
        jne     v86_fail
        movw    $0xFFFF, last_vec
.endm

.macro  notrap  code
        cmpw    $0xFFFF, last_vec
        mov     $\code, %al
        jne     v86_fail
.endm

v86_start:
// ---- real-mode addressing: two segments aimed at one linear address ----
        mov     $0x1000, %ax
        mov     %ax, %es
        movw    $0xBEEF, %es:0x10
        mov     $0x1001, %ax
        mov     %ax, %gs
        mov     %gs:0, %ax
        cmp     $0xBEEF, %ax
        mov     $1, %al
        jne     v86_fail

// ---- a 16-bit stack ----
        mov     %sp, %dx
        push    $0x5678
        pop     %cx
        cmp     $0x5678, %cx
        mov     $2, %al
        jne     v86_fail
        cmp     %sp, %dx
        jne     v86_fail

// ---- a port the bitmap allows goes straight through ----
        mov     $0x5a, %al
        out     %al, $0x80
        in      $0x80, %al
        notrap  3

// ---- ports it denies raise #GP(0) ----
        mov     $2, %bl
        in      $0x70, %al
        expect  13, 0, 4
        mov     $2, %bl
        out     %ax, $0x80                          // 0x80 is allowed, 0x81 is not
        expect  13, 0, 5
        mov     $0x3f8, %dx
        mov     $1, %bl
        in      (%dx), %al
        expect  13, 0, 6

// ---- at IOPL 0 the IOPL-sensitive instructions trap ----
        mov     $1, %bl
        cli
        expect  13, 0, 7
        mov     $1, %bl
        pushf
        expect  13, 0, 8
        mov     $1, %bl
        popf
        expect  13, 0, 9
        mov     $2, %bl
        int     $0x30
        expect  13, 0, 10
        mov     $1, %bl
        iret
        expect  13, 0, 11
        mov     $1, %bl
        hlt
        expect  13, 0, 12

// ---- ARPL does not exist here: it is the V86 breakpoint ----
        mov     $2, %bl
        arpl    %ax, %ax
        expect  6, 0, 13

// ---- ask the monitor for IOPL 3 ----
        mov     $0x1234, %ax
        mov     $2, %bl
        arpl    %ax, %ax
        expect  6, 0, 14

// ---- at IOPL 3, CLI, STI, PUSHF and POPF run directly ----
        cli
        pushf
        pop     %cx
        test    $0x200, %cx
        mov     $15, %al
        jnz     v86_fail
        sti
        pushfl
        popl    %ecx
        test    $0x200, %ecx
        mov     $16, %al
        jz      v86_fail
        test    $0x20000, %ecx                      // the image never shows VM
        mov     $17, %al
        jnz     v86_fail
        mov     %ecx, %edx
        and     $0x3000, %edx
        cmp     $0x3000, %edx
        mov     $18, %al
        jne     v86_fail
        // POPF cannot change IOPL from here
        and     $0xFFFFCFFF, %ecx
        pushl   %ecx
        popfl
        pushfl
        popl    %ecx
        and     $0x3000, %ecx
        cmp     $0x3000, %ecx
        mov     $19, %al
        jne     v86_fail
        notrap  20

// ---- INT n goes through the IDT to ring 0, and comes back ----
        int     $0x30
        expect  0x30, 0, 21
// a gate the caller may not use is a #GP naming the vector
        mov     $2, %bl
        int     $0x31
        expect  13, 0x18a, 22

// ---- IRET is a real-mode IRET ----
        pushf
        push    %cs
        push    $1f
        iret
        mov     $23, %al
        jmp     v86_fail
1:      notrap  24
        pushf                                       // still IOPL 3, still V86
        pop     %cx
        and     $0x3000, %cx
        cmp     $0x3000, %cx
        mov     $25, %al
        jne     v86_fail

// ---- the bitmap still decides port access at IOPL 3 ----
        mov     $2, %bl
        in      $0x70, %al
        expect  13, 0, 26

        xor     %al, %al
v86_fail:
        out     %al, $0xE9
        movw    $1, exiting
        arpl    %ax, %ax

// ---------------------------------------------------------------------------
        .align  4
last_vec:       .word   0
last_err:       .word   0
exiting:        .word   0
iret_esp:       .long   0
xd_faulted:     .byte   0
nm_count:       .byte   0

        .align  16
gdt:
        .quad   0
        .quad   0x00CF9A000000FFFF                  // 0x08 code32
        .quad   0x00CF92000000FFFF                  // 0x10 data32
        .quad   0x00008902000000E8                  // 0x18 TSS at 0x20000, limit 0xE8
        .quad   0x00CFF2000000FFFF                  // 0x20 data, DPL 3
        .quad   0x00CF7A000000FFFF                  // 0x28 code, DPL 3, not present
        .quad   0x004096000000FFFF                  // 0x30 data, expand-down, B, limit 0xFFFF
gdt_end:
gdtr:
        .word   gdt_end - gdt - 1
        .long   gdt

        .align  8
idtr:
        .word   0x32 * 8 - 1
        .long   idt

        .align  16
idt:
        .space  0x32 * 8
