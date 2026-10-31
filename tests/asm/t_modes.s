// Boot path exercise: starts in 16-bit real mode at physical 0, enables
// protected mode, builds page tables, enters long mode, then checks that
// paging, segment bases and privilege transitions all behave.
// Reports 0 on the debug port for success.

        .set    PML4, 0x70000
        .set    PDPT, 0x71000
        .set    PD,   0x72000

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

// ---- check that real mode segmentation shifts the selector by 4 ----
//  Two different selectors are aimed at the same linear address; a store
//  through one has to be visible through the other.
        mov     $0x1000, %ax
        mov     %ax, %fs
        movw    $0xBEEF, %fs:0x10        // linear 0x10010
        mov     $0x1001, %ax
        mov     %ax, %gs
        mov     %gs:0x0, %ax             // linear 0x10010 as well
        cmp     $0xBEEF, %ax
        jne     fail16

// ---- enter protected mode ----
        lgdt    gdtr
        mov     %cr0, %eax
        or      $1, %eax
        mov     %eax, %cr0
        ljmp    $0x08, $pm_entry

fail16:
        mov     $1, %al
        out     %al, $0xE9
        hlt

// ---------------------------------------------------------------------------
        .code32
pm_entry:
        mov     $0x10, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     $0x7000, %esp

// ---- 32-bit protected mode sanity ----
        mov     $0x11223344, %eax
        mov     %eax, 0x20000
        cmpl    $0x11223344, 0x20000
        jne     fail32

// ---- build identity page tables covering the low 1 GiB ----
        mov     $PML4, %edi
        xor     %eax, %eax
        mov     $0x2000, %ecx            // clear PML4 + PDPT (2 pages worth)
        rep     stosb

        movl    $(PDPT + 7), PML4        // present, writable, user
        movl    $(PD + 7), PDPT

        mov     $PD, %edi
        mov     $0x87, %eax              // present, writable, user, 2 MiB page
        xor     %ecx, %ecx
1:      mov     %eax, (%edi)
        movl    $0, 4(%edi)
        add     $0x200000, %eax
        add     $8, %edi
        inc     %ecx
        cmp     $512, %ecx
        jb      1b

// ---- PAE, long mode enable, paging ----
        mov     %cr4, %eax
        or      $0x20, %eax              // CR4.PAE
        mov     %eax, %cr4

        mov     $PML4, %eax
        mov     %eax, %cr3

        mov     $0xC0000080, %ecx        // EFER
        rdmsr
        or      $0x100, %eax             // LME
        wrmsr

        mov     %cr0, %eax
        or      $0x80000000, %eax        // PG
        mov     %eax, %cr0

        ljmp    $0x18, $lm_entry

fail32:
        mov     $2, %al
        out     %al, $0xE9
        hlt

// ---------------------------------------------------------------------------
        .code64
lm_entry:
        mov     $0x20, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     $0x7000, %rsp

// ---- confirm long mode really is active: use r8 and a 64-bit immediate ----
        movabs  $0x1122334455667788, %r8
        movabs  $0x1122334455667788, %rax
        cmp     %rax, %r8
        jne     fail64_3

// ---- paging is on: the identity map must be readable ----
        mov     0x20000, %eax
        cmp     $0x11223344, %eax
        jne     fail64_4

// ---- FS base comes from a MSR in long mode, not from the descriptor ----
        mov     $0xC0000100, %ecx        // FS_BASE
        mov     $0x30000, %eax
        xor     %edx, %edx
        wrmsr
        movq    $0x5A5A5A5A, %fs:0x100   // physical 0x30100
        cmpq    $0x5A5A5A5A, 0x30100
        jne     fail64_5

// ---- install an IDT and take a page fault on an unmapped address ----
        lea     idt64(%rip), %rdi
        mov     %rdi, idtr_base(%rip)
        push    %rdi
        xor     %eax, %eax
        mov     $(64 * 16 / 8), %rcx
        rep     stosq
        pop     %rdi

        lea     pf_handler(%rip), %rax
        lea     14 * 16(%rdi), %rsi
        mov     $0x8E, %dl
        call    make_gate

        lea     int30_handler(%rip), %rax
        lea     0x30 * 16(%rdi), %rsi
        mov     $0xEE, %dl                // DPL 3 so INT 0x30 is allowed
        call    make_gate

        lidt    idtr(%rip)

        movabs  $0x4000000000, %rbx      // far outside the 1 GiB identity map
        mov     $0, %r14
        mov     (%rbx), %eax             // -> #PF, handler sets r14 (2 bytes)
        cmp     $0xF, %r14
        jne     fail64_6

        // CR2 must hold the faulting address
        mov     %cr2, %rax
        cmp     %rbx, %rax
        jne     fail64_7

// ---- software interrupt and IRET ----
        mov     $0, %r13
        int     $0x30
        cmp     $0x99, %r13
        jne     fail64_8

// ---- SYSCALL / SYSRET round trip ----
        mov     $0xC0000081, %ecx        // STAR: kernel CS 0x18, user CS 0x08
        mov     $0, %eax
        mov     $0x00080018, %edx
        wrmsr
        mov     $0xC0000082, %ecx        // LSTAR
        lea     syscall_target(%rip), %rax
        mov     %rax, %rdx
        shr     $32, %rdx
        wrmsr
        mov     $0xC0000080, %ecx        // enable SCE in EFER
        rdmsr
        or      $1, %eax
        wrmsr

        // raise IOPL to 3 so the ring 3 code SYSRET lands in may still use OUT
        pushfq
        orq     $0x3000, (%rsp)
        popfq

        mov     $0, %r12
        syscall                          // returns to ring 3 via SYSRET
        cmp     $0x77, %r12
        jne     fail64_9

        // confirm SYSRET really dropped privilege
        mov     %cs, %ax
        and     $3, %ax
        cmp     $3, %ax
        jne     fail64_10

        xor     %eax, %eax
        out     %al, $0xE9
        hlt

syscall_target:
        mov     $0x77, %r12
        sysretq

fail64_3: mov $3, %al
        jmp report
fail64_4: mov $4, %al
        jmp report
fail64_5: mov $5, %al
        jmp report
fail64_6: mov $6, %al
        jmp report
fail64_7: mov $7, %al
        jmp report
fail64_8: mov $8, %al
        jmp report
fail64_9: mov $9, %al
        jmp     report
fail64_10: mov $10, %al
report:
        out     %al, $0xE9
        hlt

// ---- interrupt handlers ----
// Build one 64-bit interrupt gate: %rax handler, %rsi gate, %dl type byte.
make_gate:
        mov     %ax, (%rsi)
        movw    $0x18, 2(%rsi)
        movb    $0, 4(%rsi)
        mov     %dl, 5(%rsi)
        shr     $16, %rax
        mov     %ax, 6(%rsi)
        shr     $16, %rax
        mov     %eax, 8(%rsi)
        movl    $0, 12(%rsi)
        ret

pf_handler:
        mov     $0xF, %r14
        add     $8, %rsp                 // discard the error code
        // skip the faulting instruction: mov (%rbx), %eax is 2 bytes
        addq    $2, (%rsp)
        iretq

int30_handler:
        mov     $0x99, %r13
        iretq

// ---------------------------------------------------------------------------
        .align  16
gdt:
        .quad   0
        .quad   0x00CF9A000000FFFF       // 0x08 code32
        .quad   0x00CF92000000FFFF       // 0x10 data32
        .quad   0x00AF9A000000FFFF       // 0x18 code64 (L=1)
        .quad   0x00CF92000000FFFF       // 0x20 data
gdt_end:

gdtr:
        .word   gdt_end - gdt - 1
        .long   gdt

        .align  16
idtr:
        .word   16 * 64 - 1
idtr_base:
        .quad   0

        .align  16
idt64:
        .space  64 * 16
