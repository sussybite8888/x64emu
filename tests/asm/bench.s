// Microbenchmarks, one per hot path.  Each runs a fixed number of iterations
// and then halts; the harness divides instructions by wall time.
//
// The entry point picks a loop from the value the host leaves in %r15:
//   0 register ALU   1 memory   2 branches   3 mixed   4 string ops
//   5 dispatch only (NOP)   6 one-byte ALU (no ModRM)

        .code64
        .text
        .globl  _start
_start:
        mov     $0x200000, %rsp
        cmp     $1, %r15
        je      mem_loop
        cmp     $2, %r15
        je      branch_loop
        cmp     $3, %r15
        je      mixed_loop
        cmp     $4, %r15
        je      string_loop
        cmp     $5, %r15
        je      nop_loop
        cmp     $6, %r15
        je      inc_loop
        cmp     $7, %r15
        je      mov_loop
        cmp     $8, %r15
        je      lea_loop

// ---- register ALU: no memory operands at all ----
alu_loop:
        mov     $2000000, %rcx
1:      add     %rax, %rbx
        xor     %rdx, %rax
        sub     $3, %rbx
        add     %ebx, %eax
        and     $0xff, %edx
        or      %eax, %edx
        shl     $1, %rbx
        inc     %rsi
        dec     %rcx
        jnz     1b
        hlt

// ---- memory: loads and stores through a base register ----
mem_loop:
        mov     $2000000, %rcx
        mov     $0x100000, %rdi
1:      mov     (%rdi), %rax
        mov     %rax, 8(%rdi)
        mov     16(%rdi), %ebx
        mov     %ebx, 24(%rdi)
        add     (%rdi), %rax
        mov     %rax, 32(%rdi)
        dec     %rcx
        jnz     1b
        hlt

// ---- branches: taken and not taken, plus calls ----
branch_loop:
        mov     $2000000, %rcx
1:      test    %rcx, %rcx
        jz      2f
        cmp     $100, %rcx
        jb      3f
        call    leaf
3:      xor     %rax, %rax
        cmp     %rax, %rax
        jne     2f
        dec     %rcx
        jnz     1b
2:      hlt
leaf:   ret

// ---- mixed: what compiled code actually looks like ----
mixed_loop:
        mov     $1000000, %rcx
        mov     $0x100000, %rdi
1:      mov     (%rdi), %rax
        add     $1, %rax
        mov     %rax, (%rdi)
        movzbl  4(%rdi), %ebx
        imul    $3, %rbx, %rbx
        cmp     $1000, %rbx
        jl      2f
        xor     %ebx, %ebx
2:      mov     %bl, 4(%rdi)
        lea     8(%rdi), %rsi
        mov     (%rsi), %rdx
        shr     $2, %rdx
        or      %rdx, %rax
        test    %rax, %rax
        jz      3f
        dec     %rcx
        jnz     1b
3:      hlt

// ---- string operations under a REP prefix ----
string_loop:
        mov     $200, %r8
1:      mov     $0x100000, %rsi
        mov     $0x180000, %rdi
        mov     $10000, %rcx
        cld
        rep     movsq
        dec     %r8
        jnz     1b
        hlt

// ---- dispatch only: NOP has no ModRM, no operands and no flags ----
//  What is left is fetch, decode and the indirect call, so the gap between
//  this and the ALU loop is what the work itself costs.
nop_loop:
        mov     $2000000, %rcx
1:      .rept   16
        nop
        .endr
        dec     %rcx
        jnz     1b
        hlt

// ---- one-byte ALU: register operands encoded in the opcode ----
inc_loop:
        mov     $2000000, %rcx
1:      .rept   16
        add     %rax, %rbx
        .endr
        dec     %rcx
        jnz     1b
        hlt

// ---- register move: ModRM decode and a register write, but no flags ----
//  The gap against the ADD loop is what computing the six arithmetic flags
//  costs on every single instruction.
mov_loop:
        mov     $2000000, %rcx
1:      .rept   16
        mov     %rax, %rbx
        .endr
        dec     %rcx
        jnz     1b
        hlt

// ---- LEA: full address computation, no memory access and no flags ----
lea_loop:
        mov     $2000000, %rcx
        mov     $0x100000, %rdi
1:      .rept   16
        lea     8(%rdi,%rdi,2), %rax
        .endr
        dec     %rcx
        jnz     1b
        hlt
