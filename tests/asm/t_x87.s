// x87 arithmetic, comparison and the load/store paths.
// Reports 0 on the debug port for success, else the failing check number.
        .code64
        .text
        .globl  _start
_start:
        mov     $0x8000, %rsp
        finit

// ---- load, add, store a double ----
        fldl    d3_5(%rip)
        fldl    d1_25(%rip)
        faddp                            // st0 = 4.75
        fstpl   out(%rip)
        movsd   out(%rip), %xmm0
        movq    out(%rip), %rax
        movabs  $0x4013000000000000, %rcx   // 4.75
        cmp     %rcx, %rax
        mov     $1, %bl
        jne     fail

// ---- multiply and divide ----
        fldl    d3_5(%rip)
        fldl    d1_25(%rip)
        fmulp                            // 4.375
        fstpl   out(%rip)
        movq    out(%rip), %rax
        movabs  $0x4011800000000000, %rcx
        cmp     %rcx, %rax
        mov     $2, %bl
        jne     fail

        // the memory form avoids the historical fdivp/fdivrp operand swap
        fldl    d3_5(%rip)
        fdivl   d1_25(%rip)              // 3.5 / 1.25 = 2.8
        fstpl   out(%rip)
        movq    out(%rip), %rax
        movabs  $0x4006666666666666, %rcx
        cmp     %rcx, %rax
        mov     $3, %bl
        jne     fail

// ---- integer load and store ----
        movl    $-7, ival(%rip)
        fildl   ival(%rip)
        fldl    d1_25(%rip)
        faddp                            // -5.75
        fstpl   out(%rip)
        movq    out(%rip), %rax
        movabs  $0xC017000000000000, %rcx
        cmp     %rcx, %rax
        mov     $4, %bl
        jne     fail

// ---- FCOMI drives the integer flags ----
        fldl    d1_25(%rip)
        fldl    d3_5(%rip)               // st0=3.5 st1=1.25
        fcomi   %st(1), %st
        mov     $5, %bl
        jbe     fail                     // 3.5 > 1.25
        fstp    %st(0)
        fstp    %st(0)

        fldl    d3_5(%rip)
        fldl    d1_25(%rip)              // st0=1.25 st1=3.5
        fcomi   %st(1), %st
        mov     $6, %bl
        jae     fail                     // 1.25 < 3.5
        fstp    %st(0)
        fstp    %st(0)

// ---- FCOM / FNSTSW, the classic comparison sequence ----
        fldl    d3_5(%rip)
        fldl    d3_5(%rip)
        fcompp
        fnstsw  %ax
        and     $0x4500, %eax
        cmp     $0x4000, %eax            // C3 set: equal
        mov     $7, %bl
        jne     fail

// ---- sqrt and the loop that osakaOS hangs in ----
        fldl    d16(%rip)
        fsqrt
        fstpl   out(%rip)
        movq    out(%rip), %rax
        movabs  $0x4010000000000000, %rcx   // 4.0
        cmp     %rcx, %rax
        mov     $8, %bl
        jne     fail

        // The shape osakaOS's pow() uses: accumulator and loop counter live in
        // memory, and the loop condition comes from FCOMIP.  Without a working
        // FPU the counter never advances and this never terminates.
        movabs  $0x3FF0000000000000, %rax        // 1.0
        mov     %rax, acc(%rip)
        movq    $0, cnt(%rip)
1:      fldl    acc(%rip)
        fmull   d3_5(%rip)
        fstpl   acc(%rip)                        // acc *= 3.5
        fldl    cnt(%rip)
        fld1
        faddp
        fstpl   cnt(%rip)                        // counter += 1
        fldl    cnt(%rip)
        fldl    d3(%rip)
        fcompi  %st(1), %st                      // 3 vs counter
        fstp    %st(0)
        ja      1b
        fldl    acc(%rip)
        fstpl   out(%rip)
        movq    out(%rip), %rax
        movabs  $0x4045700000000000, %rcx   // 3.5^3 = 42.875
        cmp     %rcx, %rax
        mov     $9, %bl
        jne     fail

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %bl, %al
        out     %al, $0xE9
        hlt

        .align 8
d3_5:   .double 3.5
d1_25:  .double 1.25
d16:    .double 16.0
d1:     .double 1.0
d3:     .double 3.0
dzero:  .double 0.0
out:    .quad 0
acc:    .quad 0
cnt:    .quad 0
ival:   .long 0
