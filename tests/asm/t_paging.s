// Paging behaviour: building a fresh mapping through all four levels, write
// protection via CR0.WP, TLB invalidation, and page-fault error codes.
// Entered in long mode with the low 1 GiB identity mapped by the host.

        .set    PML4,  0x70000
        .set    PDPT2, 0x80000
        .set    PD2,   0x81000
        .set    PT2,   0x82000
        .set    TARGET, 0x8000000000      // virtual address served by PML4[1]
        .set    FRAME, 0x30000            // physical page it maps to

        .code64
        .text
        .globl  _start
_start:
        mov     $0x8000, %rsp
        xor     %r14, %r14

// ---- install an IDT so faults are recoverable ----
//  Gates are built at run time: a 64-bit gate scatters the handler address
//  across three fields, which the assembler cannot express as a relocation.
        lea     idt64(%rip), %rdi
        mov     %rdi, idtr_base(%rip)
        push    %rdi
        xor     %eax, %eax
        mov     $(32 * 16 / 8), %rcx
        rep     stosq
        pop     %rdi

        lea     pf_handler(%rip), %rax
        lea     14 * 16(%rdi), %rsi
        mov     %ax, (%rsi)               // offset 15:0
        movw    $0x08, 2(%rsi)            // selector
        movb    $0, 4(%rsi)               // IST
        movb    $0x8E, 5(%rsi)            // present, DPL 0, interrupt gate
        shr     $16, %rax
        mov     %ax, 6(%rsi)              // offset 31:16
        shr     $16, %rax
        mov     %eax, 8(%rsi)             // offset 63:32

        lidt    idtr(%rip)

// ---- clear the three new table pages ----
        mov     $PDPT2, %rdi
        xor     %rax, %rax
        mov     $(0x3000 / 8), %rcx
        rep     stosq

// ---- link PML4[1] -> PDPT2 -> PD2 -> PT2, and PT2[0] -> FRAME ----
        movq    $(PDPT2 + 3), PML4 + 8    // present + writable
        movq    $(PD2 + 3), PDPT2
        movq    $(PT2 + 3), PD2
        movq    $(FRAME + 3), PT2

        movabs  $TARGET, %rbx

// ---- write through the new mapping, read back through the identity map ----
        movl    $0xC0FFEE, (%rbx)
        cmpl    $0xC0FFEE, FRAME
        jne     fail1

// ---- clearing the writable bit with CR0.WP set must fault on write ----
        movq    $(FRAME + 1), PT2         // present, read-only
        invlpg  (%rbx)

        mov     %cr0, %rax
        or      $0x10000, %rax            // CR0.WP
        mov     %rax, %cr0

        xor     %r14, %r14
        mov     $6, %r13
        movl    $0xDEAD, (%rbx)           // -> #PF, handler skips it
        cmp     $1, %r14
        jne     fail2
        // error code: present (1) + write (2) = 3
        cmp     $3, %r15
        jne     fail3
        // the store must not have landed
        cmpl    $0xC0FFEE, FRAME
        jne     fail4

// ---- without CR0.WP a supervisor write to a read-only page is allowed ----
        mov     %cr0, %rax
        and     $~0x10000, %rax
        mov     %rax, %cr0
        invlpg  (%rbx)

        xor     %r14, %r14
        movl    $0xFEED, (%rbx)
        test    %r14, %r14
        jnz     fail5
        cmpl    $0xFEED, FRAME
        jne     fail6

// ---- unmapping must fault with a not-present error code ----
        movq    $0, PT2
        invlpg  (%rbx)
        xor     %r14, %r14
        mov     $2, %r13
        mov     (%rbx), %eax
        cmp     $1, %r14
        jne     fail7
        cmp     $0, %r15                  // not present, read, supervisor
        jne     fail8

// ---- a stale TLB entry must survive until invlpg ----
        movq    $(FRAME + 3), PT2
        invlpg  (%rbx)
        mov     (%rbx), %eax              // caches the translation
        movq    $0, PT2                   // unmap without invalidating
        xor     %r14, %r14
        mov     (%rbx), %eax              // still served from the TLB
        test    %r14, %r14
        jnz     fail9
        invlpg  (%rbx)
        xor     %r14, %r14
        mov     $2, %r13
        mov     (%rbx), %eax
        cmp     $1, %r14
        jne     fail10

        xor     %eax, %eax
        out     %al, $0xE9
        hlt

fail1:  mov $1, %al
        jmp report
fail2:  mov $2, %al
        jmp report
fail3:  mov $3, %al
        jmp report
fail4:  mov $4, %al
        jmp report
fail5:  mov $5, %al
        jmp report
fail6:  mov $6, %al
        jmp report
fail7:  mov $7, %al
        jmp report
fail8:  mov $8, %al
        jmp report
fail9:  mov $9, %al
        jmp report
fail10: mov $10, %al
report:
        out     %al, $0xE9
        hlt

// Page-fault handler: record that it ran plus the error code, then step over
// the faulting instruction.  Lengths vary between the cases below,
// so the caller stages the faulting instruction's length in %r13.
pf_handler:
        mov     $1, %r14
        pop     %r15                      // error code
        add     %r13, (%rsp)              // skip the faulting instruction
        iretq

        .align  16
idtr:
        .word   16 * 32 - 1
idtr_base:
        .quad   0

        .align  16
idt64:
        .space  32 * 16
