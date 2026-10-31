// Bit operations, extensions and exchanges.
//
// Several of these have edge cases emulators habitually miss: a bit offset is
// masked to the operand width for a register but indexes an arbitrarily long
// bit string in memory, INC and DEC must leave CF exactly as they found it, and
// BSF/BSR report a zero source through ZF while leaving the destination alone.
        .code64
        .text
        .globl  _start

.macro  want    reg, value, code
        movabs  $\value, %r14
        cmp     %r14, \reg
        mov     $\code, %r13b
        jne     fail
.endm

.macro  wantcf  bit, code
        mov     $\code, %r13b
.if \bit
        jnc     fail
.else
        jc      fail
.endif
.endm

_start:
        mov     $0x8000, %rsp

// ---- BT / BTS / BTR / BTC on a register --------------------------------
// 0x...15 is 0b00010101, so bits 0, 2 and 4 are set
        movabs  $0x9E3779B97F4A7C15, %rax
        btq     $2, %rax
        wantcf  1, 1
        want    %rax, 0x9E3779B97F4A7C15, 2      // BT must not modify anything

        movabs  $0x9E3779B97F4A7C15, %rax
        btsq    $3, %rax
        wantcf  0, 3
        want    %rax, 0x9E3779B97F4A7C1D, 4

        movabs  $0x9E3779B97F4A7C15, %rax
        btrq    $2, %rax
        wantcf  1, 5
        want    %rax, 0x9E3779B97F4A7C11, 6

        movabs  $0x9E3779B97F4A7C15, %rax
        btcq    $0, %rax
        wantcf  1, 7
        want    %rax, 0x9E3779B97F4A7C14, 8

// a register bit offset is taken modulo the operand width
        movabs  $0x9E3779B97F4A7C15, %rax
        btq     $66, %rax                       // 66 mod 64 == 2
        wantcf  1, 9
        movabs  $0x9E3779B97F4A7C15, %rax
        btq     $65, %rax                       // 65 mod 64 == 1
        wantcf  0, 10

// ---- BT against memory, where the offset indexes a bit string ----------
        mov     $70, %rcx
        btq     %rcx, bitstr(%rip)
        wantcf  1, 11
        mov     $69, %rcx
        btq     %rcx, bitstr(%rip)
        wantcf  0, 12
        mov     $3, %rcx
        btq     %rcx, bitstr(%rip)
        wantcf  1, 13

// ---- BSF / BSR --------------------------------------------------------
        movabs  $0x9E3779B97F4A7C15, %rax
        bsfq    %rax, %rbx
        want    %rbx, 0, 14                     // lowest set bit
        movabs  $0x9E3779B97F4A7C15, %rax
        bsrq    %rax, %rbx
        want    %rbx, 63, 15                    // highest set bit

        movabs  $0x0000000000180000, %rax
        bsfq    %rax, %rbx
        want    %rbx, 19, 16
        bsrq    %rax, %rbx
        want    %rbx, 20, 17

// a zero source is reported through ZF.  The destination is architecturally
// undefined in that case, so it is deliberately not checked.
        xor     %rax, %rax
        movabs  $0xDEADBEEFDEADBEEF, %r15
        bsfq    %rax, %r15
        mov     $18, %r13b
        jnz     fail

// ---- INC / DEC must preserve CF ---------------------------------------
        stc
        movabs  $0x00000000FFFFFFFF, %rax
        incq    %rax
        wantcf  1, 19                            // CF survives INC
        want    %rax, 0x0000000100000000, 20

        clc
        movabs  $0x0000000000000001, %rax
        decq    %rax
        wantcf  0, 21                            // and survives DEC
        want    %rax, 0, 22

// INC still sets OF on signed overflow
        movabs  $0x7FFFFFFFFFFFFFFF, %rax
        incq    %rax
        mov     $23, %r13b
        jno     fail
        want    %rax, 0x8000000000000000, 24

// ---- NEG sets CF from whether the source was non-zero -----------------
        movabs  $0x0000000000000005, %rax
        negq    %rax
        wantcf  1, 25
        want    %rax, 0xFFFFFFFFFFFFFFFB, 26

        xor     %rax, %rax
        negq    %rax
        wantcf  0, 27
        want    %rax, 0, 28

// ---- sign and zero extension ------------------------------------------
        movabs  $0x1122334455667788, %rax
        movsbq  %al, %rbx
        want    %rbx, 0xFFFFFFFFFFFFFF88, 29
        movzbq  %al, %rbx
        want    %rbx, 0x88, 30
        movswq  %ax, %rbx
        want    %rbx, 0x7788, 31
        movzwq  %ax, %rbx
        want    %rbx, 0x7788, 32
        movslq  %eax, %rbx
        want    %rbx, 0x0000000055667788, 33

        movabs  $0x11223344F5667788, %rax
        movslq  %eax, %rbx
        want    %rbx, 0xFFFFFFFFF5667788, 34

// CBW / CWDE / CDQE walk the same value up through the widths
        movabs  $0x00000000000000F0, %rax
        cbtw                                     // AL -> AX
        want    %rax, 0xFFF0, 35
        movabs  $0x000000000000F001, %rax
        cwtl                                     // AX -> EAX
        want    %rax, 0xFFFFF001, 36
        movabs  $0x00000000F0000001, %rax
        cltq                                     // EAX -> RAX
        want    %rax, 0xFFFFFFFFF0000001, 37

// CQO fills RDX with the sign of RAX
        movabs  $0x8000000000000000, %rax
        cqto
        want    %rdx, 0xFFFFFFFFFFFFFFFF, 38
        movabs  $0x0000000000000001, %rax
        cqto
        want    %rdx, 0, 39

// ---- XCHG / XADD / CMPXCHG --------------------------------------------
        movabs  $0x1111111111111111, %rax
        movabs  $0x2222222222222222, %rbx
        xchg    %rbx, %rax
        want    %rax, 0x2222222222222222, 40
        want    %rbx, 0x1111111111111111, 41

        movabs  $0x0000000000000005, %rax
        movabs  $0x0000000000000007, %rbx
        xaddq   %rbx, %rax                       // rax += rbx, rbx = old rax
        want    %rax, 12, 42
        want    %rbx, 5, 43

// CMPXCHG when the comparison succeeds
        movabs  $0x0000000000000042, %rax
        movabs  $0x0000000000000042, %rcx
        movabs  $0x0000000000000099, %rbx
        cmpxchgq %rbx, %rcx
        mov     $44, %r13b
        jne     fail                             // ZF set on success
        want    %rcx, 0x99, 45

// and when it fails, RAX takes the destination's value
        movabs  $0x0000000000000042, %rax
        movabs  $0x0000000000000077, %rcx
        movabs  $0x0000000000000099, %rbx
        cmpxchgq %rbx, %rcx
        mov     $46, %r13b
        je      fail
        want    %rax, 0x77, 47
        want    %rcx, 0x77, 48

// ---- LEA computes an address without touching memory or flags ---------
        movabs  $0x0000000000001000, %rax
        movabs  $0x0000000000000010, %rbx
        lea     0x20(%rax,%rbx,4), %rcx
        want    %rcx, 0x1060, 49
        lea     (%rax,%rax,8), %rcx
        want    %rcx, 0x9000, 50

        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %r13b, %al
        out     %al, $0xE9
        hlt

        .align  16
// bit 3 set in the first quadword, bit 70 in the second
bitstr: .quad   0x0000000000000008
        .quad   0x0000000000000040
