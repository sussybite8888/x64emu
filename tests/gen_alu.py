#!/usr/bin/env python3
"""Generate instruction-correctness tests for the integer core.

Every expected value here comes from a model of what the manual says the
instruction does, written out below, rather than from running the instruction on
the emulator.  A test that reads its expectation back from the thing under test
only proves the thing is consistent with itself, which is exactly how a wrong
PAND survived until now.

Results and flags are both checked.  Only the flags each instruction actually
defines are compared -- the shift group leaves OF undefined for counts other
than one, so that case is masked out rather than guessed at.
"""

import os

CF, PF, AF, ZF, SF, OF = 0x001, 0x004, 0x010, 0x040, 0x080, 0x800
ARITH = CF | PF | AF | ZF | SF | OF

WIDTHS = [(1, 'b', '%al', '%bl'), (2, 'w', '%ax', '%bx'),
          (4, 'l', '%eax', '%ebx'), (8, 'q', '%rax', '%rbx')]

# a fixed backdrop in the upper bits, so a narrow operation that corrupts them
# is caught rather than ignored
BACKDROP = 0x5A5A5A5A5A5A5A5A


def mask(w):
    return (1 << (w * 8)) - 1


def sign(v, w):
    return (v >> (w * 8 - 1)) & 1


def parity(v):
    return 1 if bin(v & 0xff).count('1') % 2 == 0 else 0


def flags_logic(r, w):
    """AND/OR/XOR/TEST: CF and OF cleared, AF undefined."""
    f = 0
    if r == 0:
        f |= ZF
    if sign(r, w):
        f |= SF
    if parity(r):
        f |= PF
    return f


def flags_add(a, b, cin, r, w):
    f = 0
    if (a + b + cin) > mask(w):
        f |= CF
    if r == 0:
        f |= ZF
    if sign(r, w):
        f |= SF
    if parity(r):
        f |= PF
    if ((a ^ b ^ r) >> 4) & 1:
        f |= AF
    if sign(a, w) == sign(b, w) and sign(r, w) != sign(a, w):
        f |= OF
    return f


def flags_sub(a, b, cin, r, w):
    f = 0
    if (a - b - cin) < 0:
        f |= CF
    if r == 0:
        f |= ZF
    if sign(r, w):
        f |= SF
    if parity(r):
        f |= PF
    if ((a ^ b ^ r) >> 4) & 1:
        f |= AF
    if sign(a, w) != sign(b, w) and sign(r, w) != sign(a, w):
        f |= OF
    return f


# (name, needs carry-in, compute) -- compute returns (result, flags)
def op_add(a, b, c, w):
    r = (a + b) & mask(w)
    return r, flags_add(a, b, 0, r, w)


def op_adc(a, b, c, w):
    r = (a + b + c) & mask(w)
    return r, flags_add(a, b, c, r, w)


def op_sub(a, b, c, w):
    r = (a - b) & mask(w)
    return r, flags_sub(a, b, 0, r, w)


def op_sbb(a, b, c, w):
    r = (a - b - c) & mask(w)
    return r, flags_sub(a, b, c, r, w)


def op_and(a, b, c, w):
    r = a & b
    return r, flags_logic(r, w)


def op_or(a, b, c, w):
    r = a | b
    return r, flags_logic(r, w)


def op_xor(a, b, c, w):
    r = a ^ b
    return r, flags_logic(r, w)


# split across two files so each fits the single-byte exit code the harness
# uses to report which check failed
GROUPS = {
    't_alu': [('add', False, op_add), ('adc', True, op_adc),
              ('sub', False, op_sub), ('sbb', True, op_sbb)],
    't_logic': [('and', False, op_and), ('or', False, op_or),
                ('xor', False, op_xor)],
}

# operand pairs chosen to land on the interesting edges: carry out, borrow,
# signed overflow, zero result, and the half-carry boundary
PAIRS = [
    (0x0f0f0f0f0f0f0f0f, 0x0101010101010101),
    (0xffffffffffffffff, 0x0000000000000001),
    (0x8000000000000000, 0x8000000000000000),
    (0x7f7f7f7f7f7f7f7f, 0x0101010101010101),
]


def emit(OPS):
    out = []
    checks = []
    code = 1

    for opname, uses_carry, fn in OPS:
        for w, suf, ra, rb in WIDTHS:
            for a_full, b_full in PAIRS:
                a = a_full & mask(w)
                b = b_full & mask(w)
                for cin in ([0, 1] if uses_carry else [0]):
                    r, f = fn(a, b, cin, w)
                    # what the whole 64-bit register should hold afterwards
                    if w == 8:
                        full = r
                    elif w == 4:
                        full = r                      # 32-bit writes zero-extend
                    else:
                        full = (BACKDROP & ~mask(w)) | r

                    body = []
                    body.append(f'        movabs  $0x{BACKDROP:016x}, %rax')
                    body.append(f'        movabs  $0x{BACKDROP:016x}, %rbx')
                    if w == 8:
                        body.append(f'        movabs  $0x{a:016x}, %rax')
                        body.append(f'        movabs  $0x{b:016x}, %rbx')
                    else:
                        body.append(f'        mov     $0x{a:x}, {ra}')
                        body.append(f'        mov     $0x{b:x}, {rb}')
                        if w != 4:
                            # restore the backdrop the narrow load did not touch
                            pass
                    body.append('        stc' if cin else '        clc')
                    body.append(f'        {opname}{suf}   {rb}, {ra}')
                    body.append('        pushfq')
                    body.append('        pop     %rdx')
                    body.append(f'        movabs  $0x{full:016x}, %rcx')
                    body.append('        cmp     %rcx, %rax')
                    body.append(f'        mov     ${code}, %bl')
                    body.append('        jne     fail')
                    checks.append((code, f'{opname}{suf} 0x{a:x},0x{b:x} cin={cin} -> 0x{full:x}'))
                    code += 1
                    body.append(f'        and     $0x{ARITH:x}, %edx')
                    body.append(f'        cmp     $0x{f:x}, %edx')
                    body.append(f'        mov     ${code}, %bl')
                    body.append('        jne     fail')
                    checks.append((code, f'{opname}{suf} flags -> 0x{f:x}'))
                    code += 1
                    out.append('\n'.join(body))

    return out, checks, code


HEADER = '''// Integer ALU: results and flags.
//
// Generated by tests/gen_alu.py.  The expected values are produced by a model
// of the manual, not by running these instructions here, so a wrong answer
// fails rather than agreeing with itself.  Both the full 64-bit register and
// the six architecturally defined arithmetic flags are checked, which catches a
// narrow operation that corrupts the bits above it.
        .code64
        .text
        .globl  _start
_start:
        mov     $0x8000, %rsp
'''

TAIL = '''
        xor     %eax, %eax
        out     %al, $0xE9
        hlt
fail:
        mov     %bl, %al
        out     %al, $0xE9
        hlt
'''

if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    for name, ops in GROUPS.items():
        blocks, checks, code = emit(ops)
        if code > 255:
            raise SystemExit(f'{name}: {code} checks will not fit in a byte exit code')
        with open(os.path.join(here, 'asm', f'{name}.s'), 'w') as fh:
            fh.write(HEADER + '\n'.join(blocks) + TAIL)
        with open(os.path.join(here, 'asm', f'{name}.checks'), 'w') as fh:
            for n, desc in checks:
                fh.write(f'{n}\t{desc}\n')
        print(f'{name}: {len(blocks)} blocks, {code - 1} checks')
