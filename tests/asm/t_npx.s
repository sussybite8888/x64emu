// The FPU presence probe an NT kernel runs before it trusts the x87.
//
// It does not consult CPUID: it clears CR0.EM, runs FNINIT and checks that the
// status word came back zero and the control word came back 0x037F.  A CPU that
// fails this is treated as having no coprocessor, and the kernel then sets
// CR0.EM -- which also turns every SSE instruction into #UD.
        .code64
        .text
        .globl  _start
_start:
        mov     $0x8000, %rsp

// take the FPU out of emulated mode: clear EM and TS, set MP
        mov     %cr0, %rax
        and     $-13, %rax                      // ~(EM|TS)
        or      $2, %rax                        // MP
        mov     %rax, %cr0

        fninit
        fnstsw  %ax
        mov     $1, %bl
        test    %ax, %ax
        jnz     fail                            // status word must be zero

        fnstcw  ctlword(%rip)
        movw    ctlword(%rip), %ax
        mov     $2, %bl
        cmp     $0x037f, %ax
        jne     fail                            // control word must be 0x037F

        and     $0x103f, %ax                    // the kernel's masked compare
        mov     $3, %bl
        cmp     $0x003f, %ax
        jne     fail

// a loaded control word has to survive a round trip
        movw    $0x027f, ctlword(%rip)
        fldcw   ctlword(%rip)
        movw    $0, ctlword(%rip)
        fnstcw  ctlword(%rip)
        movw    ctlword(%rip), %ax
        mov     $4, %bl
        cmp     $0x027f, %ax
        jne     fail

// and arithmetic must still work afterwards
        fninit
        fld1
        fld1
        faddp   %st, %st(1)
        fistpl  result(%rip)
        mov     $5, %bl
        cmpl    $2, result(%rip)
        jne     fail

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %bl, %al
        out     %al, $0xE9
        hlt

        .align  8
ctlword: .word  0
result:  .long  0
