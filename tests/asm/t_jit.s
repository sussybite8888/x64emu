// Shapes of code the JIT has to handle at the edges of a block.
//
// Interpreted, these are ordinary instructions; what they test is what the
// compiler does with them.  tests/run_jit.mjs makes every instruction a block
// head, so somewhere a block will end exactly where each case puts the
// pressure.  Reports 0 on the debug port for success.
        .code64
        .text
        .globl  _start

_start:
        mov     $0x8000, %rsp
// Every case runs many times over.  Code is compiled between runs of the
// machine, after it has first executed; only a repeat runs the compiled copy.
        mov     $3000, %r15d
again:

// ---- a jump followed into a block that is then full -------------------
// A block follows an unconditional jump within its page.  When the jump is
// the last instruction the block has room for, the block ends there -- and
// must leave for the jump's target, not the bytes after it.  Getting that
// wrong ran them: Windows XP crashed in win32k.sys a minute into its boot.
//
// Blocks run back to back from the loop head: the first holds the two XORs
// and 94 INCs (96, the most a block takes), so the second starts at INC 94
// and its 96th instruction is the JMP.
        xor     %eax, %eax
        xor     %ecx, %ecx
        .rept   189
        inc     %eax
        .endr
        jmp     1f
        .rept   40
        inc     %ecx                    // never executed
        .endr
1:      cmp     $189, %eax
        mov     $1, %bl
        jne     fail
        test    %ecx, %ecx
        mov     $2, %bl
        jne     fail

// ---- the same with a conditional branch taken out of a full block -----
        xor     %eax, %eax
        xor     %ecx, %ecx
        .rept   120
        inc     %eax
        .endr
        cmp     $120, %eax
        je      2f
        .rept   40
        inc     %ecx
        .endr
2:      test    %ecx, %ecx
        mov     $3, %bl
        jne     fail

// ---- a loop closed by a branch back to the block's own start ----------
        xor     %eax, %eax
        mov     $1000, %ecx
3:      add     $3, %eax
        dec     %ecx
        jnz     3b
        cmp     $3000, %eax
        mov     $4, %bl
        jne     fail

// ---- flags left pending across a side exit ----------------------------
// The compare's flags are still deferred when the block leaves through the
// taken branch; the code there reads them through SETcc.
        mov     $5, %eax
        cmp     $7, %eax
        jb      4f
        mov     $5, %bl
        jmp     fail
4:      setb    %dl
        setl    %dh
        cmp     $0x0101, %dx
        mov     $6, %bl
        jne     fail

        dec     %r15d
        jnz     again

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %bl, %al
        out     %al, $0xE9
        hlt
