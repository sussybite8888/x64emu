#!/usr/bin/env python3
"""Generate multiply and divide tests.

The wide forms write two registers and set CF and OF from whether the upper half
carries information, which is easy to get subtly wrong.  Division is modelled
with truncation toward zero, the way x86 defines it, rather than Python's floor
division -- the two disagree for every negative operand, so using Python's
operators directly would bake a wrong answer into the test.
"""

import os

CF, OF = 0x001, 0x800

WIDTHS = [
    (1, 'b', '%al', '%bl'),
    (2, 'w', '%ax', '%bx'),
    (4, 'l', '%eax', '%ebx'),
    (8, 'q', '%rax', '%rbx'),
]

# operand pairs: one that stays inside the low half, one that spills into the
# high half, and one at the signed extremes
PAIRS = [0x0d, 0xb5, 0x7f]
SEEDS = [0x0000000000000007, 0x9E3779B97F4A7C15, 0x00000000FFFFFFFF]


def mask(w):
    return (1 << (w * 8)) - 1


def bits(w):
    return w * 8


def to_signed(v, w):
    return v - (1 << bits(w)) if v >> (bits(w) - 1) else v


def trunc_div(a, b):
    """Quotient truncated toward zero and the matching remainder, as x86 does."""
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return q, a - q * b


def emit_mul():
    blocks, checks, code = [], [], 1
    for signed in (False, True):
        name = 'imul' if signed else 'mul'
        for w, suf, ra, rb in WIDTHS:
            for seed in SEEDS:
                a = seed & mask(w)
                b = (seed >> 3 | 0x51) & mask(w)
                if signed:
                    prod = to_signed(a, w) * to_signed(b, w)
                else:
                    prod = a * b
                lo = prod & mask(w)
                hi = (prod >> bits(w)) & mask(w)
                # CF and OF say the upper half carries information
                if signed:
                    full = to_signed(lo, w)
                    upper_needed = prod != full
                else:
                    upper_needed = hi != 0
                fl = (CF | OF) if upper_needed else 0

                b_ = [f'        movabs  $0x{a:016x}, %rax',
                      f'        movabs  $0x{b:016x}, %rbx',
                      f'        {name}{suf}  {rb}']
                # the high half must be saved before PUSHFQ, which lands in
                # %rdx and would otherwise overwrite it; MOV leaves flags alone
                if w == 1:
                    b_.append('        movzbl  %ah, %ecx')
                elif w == 2:
                    b_.append('        movzwl  %dx, %ecx')
                elif w == 4:
                    b_.append('        mov     %edx, %ecx')
                else:
                    b_.append('        mov     %rdx, %rcx')
                b_.append('        pushfq')
                b_.append('        pop     %rdx')
                if w == 1:
                    b_.append('        movzbl  %al, %eax')
                elif w == 2:
                    b_.append('        movzwl  %ax, %eax')
                elif w == 4:
                    b_.append('        mov     %eax, %eax')
                b_ = [x for x in b_ if x]
                b_.append(f'        movabs  $0x{lo:016x}, %rsi')
                b_.append('        cmp     %rsi, %rax')
                b_.append(f'        mov     ${code}, %bl')
                b_.append('        jne     fail')
                checks.append((code, f'{name}{suf} 0x{a:x}*0x{b:x} lo -> 0x{lo:x}'))
                code += 1
                b_.append(f'        movabs  $0x{hi:016x}, %rsi')
                b_.append('        cmp     %rsi, %rcx')
                b_.append(f'        mov     ${code}, %bl')
                b_.append('        jne     fail')
                checks.append((code, f'{name}{suf} hi -> 0x{hi:x}'))
                code += 1
                b_.append(f'        and     $0x{CF | OF:x}, %edx')
                b_.append(f'        cmp     $0x{fl:x}, %edx')
                b_.append(f'        mov     ${code}, %bl')
                b_.append('        jne     fail')
                checks.append((code, f'{name}{suf} CF/OF -> 0x{fl:x}'))
                code += 1
                blocks.append('\n'.join(b_))
    return blocks, checks, code


def emit_div():
    blocks, checks, code = [], [], 1
    for signed in (False, True):
        name = 'idiv' if signed else 'div'
        for w, suf, ra, rb in WIDTHS:
            for divisor_seed in PAIRS:
                d = divisor_seed if divisor_seed else 1
                # a dividend whose quotient is guaranteed to fit
                hi = (d // 2) if d > 1 else 0
                lo = 0x3456789ABCDEF012 & mask(w)
                dividend = (hi << bits(w)) | lo
                if signed:
                    sd = to_signed(d, w)
                    sdividend = dividend - (1 << (2 * bits(w))) \
                        if dividend >> (2 * bits(w) - 1) else dividend
                    q, r = trunc_div(sdividend, sd)
                    if not (-(1 << (bits(w) - 1)) <= q < (1 << (bits(w) - 1))):
                        continue
                    q &= mask(w)
                    r &= mask(w)
                else:
                    q, r = dividend // d, dividend % d
                    if q > mask(w):
                        continue

                b_ = []
                if w == 1:
                    b_.append(f'        mov     $0x{dividend & 0xffff:x}, %ax')
                    b_.append(f'        mov     $0x{d:x}, %bl')
                else:
                    b_.append(f'        movabs  $0x{lo:016x}, %rax')
                    b_.append(f'        movabs  $0x{hi:016x}, %rdx')
                    b_.append(f'        movabs  $0x{d:016x}, %rbx')
                b_.append(f'        {name}{suf}  {rb}')
                if w == 1:
                    b_.append('        movzbl  %ah, %ecx')
                    b_.append('        movzbl  %al, %eax')
                elif w == 2:
                    b_.append('        movzwl  %dx, %ecx')
                    b_.append('        movzwl  %ax, %eax')
                elif w == 4:
                    b_.append('        mov     %edx, %ecx')
                    b_.append('        mov     %eax, %eax')
                else:
                    b_.append('        mov     %rdx, %rcx')
                b_.append(f'        movabs  $0x{q:016x}, %rsi')
                b_.append('        cmp     %rsi, %rax')
                b_.append(f'        mov     ${code}, %bl')
                b_.append('        jne     fail')
                checks.append((code, f'{name}{suf} 0x{dividend:x}/0x{d:x} q -> 0x{q:x}'))
                code += 1
                b_.append(f'        movabs  $0x{r:016x}, %rsi')
                b_.append('        cmp     %rsi, %rcx')
                b_.append(f'        mov     ${code}, %bl')
                b_.append('        jne     fail')
                checks.append((code, f'{name}{suf} r -> 0x{r:x}'))
                code += 1
                blocks.append('\n'.join(b_))
    return blocks, checks, code


HEADER = '''// {what}.
//
// Generated by tests/gen_muldiv.py.  Division truncates toward zero on x86,
// which is not what Python's // does for negative operands, so the model spells
// the truncation out rather than borrowing the host language's answer.
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
    for fname, fn, what in [('t_mul', emit_mul, 'Multiply: both halves and CF/OF'),
                            ('t_div', emit_div, 'Divide: quotient and remainder')]:
        blocks, checks, code = fn()
        if code > 255:
            raise SystemExit(f'{fname}: {code} checks exceed the byte exit code')
        with open(os.path.join(here, 'asm', f'{fname}.s'), 'w') as fh:
            fh.write(HEADER.format(what=what) + '\n'.join(blocks) + TAIL)
        with open(os.path.join(here, 'asm', f'{fname}.checks'), 'w') as fh:
            for n, desc in checks:
                fh.write(f'{n}\t{desc}\n')
        print(f'{fname}: {len(blocks)} blocks, {code - 1} checks')
