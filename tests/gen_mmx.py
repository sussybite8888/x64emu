#!/usr/bin/env python3
"""Generate correctness tests for the MMX instructions.

The expected values come from a model of the manual written out below, not from
the emulator.  `python3 tests/gen_mmx.py --verify` builds the same cases into a
native x86-64 program (natively, or under Rosetta on Apple silicon) and
compares every result with the model's.

Windows XP's win32k blends alpha with these, and they were missing: an MMX form
raised #UD, which in win32k is a bug check, and the unprefixed moves ran as XMM
moves.  Besides the arithmetic, the test checks what MMX does to the x87 unit
around it: TOP and the tags, EMMS, and a save and restore through FXSAVE.
"""

import os
import random
import subprocess
import sys
import tempfile

M64 = (1 << 64) - 1


def lanes(v, w):
    return [(v >> (8 * w * i)) & ((1 << (8 * w)) - 1) for i in range(8 // w)]


def join(ls, w):
    out = 0
    for i, x in enumerate(ls):
        out |= (x & ((1 << (8 * w)) - 1)) << (8 * w * i)
    return out


def sx(x, w):
    bits = 8 * w
    return x - (1 << bits) if x & (1 << (bits - 1)) else x


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def lanewise(w, fn):
    return lambda d, s: join([fn(a, b) for a, b in zip(lanes(d, w), lanes(s, w))], w)


def signed_lanewise(w, fn):
    return lanewise(w, lambda a, b: fn(sx(a, w), sx(b, w)))


def pack(win, wout, lo, hi):
    def f(d, s):
        ins = [sx(x, win) for x in lanes(d, win)] + [sx(x, win) for x in lanes(s, win)]
        return join([clamp(x, lo, hi) for x in ins], wout)
    return f


def unpack(w, high):
    def f(d, s):
        dl, sl = lanes(d, w), lanes(s, w)
        half = len(dl) // 2
        pick = slice(half, None) if high else slice(0, half)
        out = []
        for a, b in zip(dl[pick], sl[pick]):
            out += [a, b]
        return join(out, w)
    return f


def shift(w, kind):
    bits = 8 * w

    def f(d, s):
        out = []
        for a in lanes(d, w):
            if kind == 'l':
                out.append(0 if s >= bits else a << s)
            elif kind == 'r':
                out.append(0 if s >= bits else a >> s)
            else:
                out.append(sx(a, w) >> min(s, bits - 1))
        return join(out, w)
    return f


def pmaddwd(d, s):
    dl, sl = lanes(d, 2), lanes(s, 2)
    return join([sx(dl[2 * i], 2) * sx(sl[2 * i], 2) +
                 sx(dl[2 * i + 1], 2) * sx(sl[2 * i + 1], 2) for i in range(2)], 4)


OPS = {
    'paddb':    lanewise(1, lambda a, b: a + b),
    'paddw':    lanewise(2, lambda a, b: a + b),
    'paddd':    lanewise(4, lambda a, b: a + b),
    'paddq':    lanewise(8, lambda a, b: a + b),
    'psubb':    lanewise(1, lambda a, b: a - b),
    'psubw':    lanewise(2, lambda a, b: a - b),
    'psubd':    lanewise(4, lambda a, b: a - b),
    'psubq':    lanewise(8, lambda a, b: a - b),
    'paddusb':  lanewise(1, lambda a, b: min(a + b, 0xff)),
    'paddusw':  lanewise(2, lambda a, b: min(a + b, 0xffff)),
    'psubusb':  lanewise(1, lambda a, b: max(a - b, 0)),
    'psubusw':  lanewise(2, lambda a, b: max(a - b, 0)),
    'paddsb':   signed_lanewise(1, lambda a, b: clamp(a + b, -128, 127)),
    'paddsw':   signed_lanewise(2, lambda a, b: clamp(a + b, -32768, 32767)),
    'psubsb':   signed_lanewise(1, lambda a, b: clamp(a - b, -128, 127)),
    'psubsw':   signed_lanewise(2, lambda a, b: clamp(a - b, -32768, 32767)),
    'pcmpeqb':  lanewise(1, lambda a, b: -1 if a == b else 0),
    'pcmpeqw':  lanewise(2, lambda a, b: -1 if a == b else 0),
    'pcmpeqd':  lanewise(4, lambda a, b: -1 if a == b else 0),
    'pcmpgtb':  signed_lanewise(1, lambda a, b: -1 if a > b else 0),
    'pcmpgtw':  signed_lanewise(2, lambda a, b: -1 if a > b else 0),
    'pcmpgtd':  signed_lanewise(4, lambda a, b: -1 if a > b else 0),
    'pminub':   lanewise(1, min),
    'pmaxub':   lanewise(1, max),
    'pminsw':   signed_lanewise(2, min),
    'pmaxsw':   signed_lanewise(2, max),
    'pavgb':    lanewise(1, lambda a, b: (a + b + 1) >> 1),
    'pavgw':    lanewise(2, lambda a, b: (a + b + 1) >> 1),
    'pmullw':   lanewise(2, lambda a, b: a * b),
    'pmulhuw':  lanewise(2, lambda a, b: (a * b) >> 16),
    'pmulhw':   signed_lanewise(2, lambda a, b: (a * b) >> 16),
    'pmuludq':  lambda d, s: (d & 0xffffffff) * (s & 0xffffffff),
    'pmaddwd':  pmaddwd,
    'psadbw':   lambda d, s: sum(abs(a - b) for a, b in zip(lanes(d, 1), lanes(s, 1))),
    'packsswb': pack(2, 1, -128, 127),
    'packuswb': pack(2, 1, 0, 255),
    'packssdw': pack(4, 2, -32768, 32767),
    'punpcklbw': unpack(1, False),
    'punpcklwd': unpack(2, False),
    'punpckldq': unpack(4, False),
    'punpckhbw': unpack(1, True),
    'punpckhwd': unpack(2, True),
    'punpckhdq': unpack(4, True),
    'pand':     lambda d, s: d & s,
    'pandn':    lambda d, s: ~d & s,
    'por':      lambda d, s: d | s,
    'pxor':     lambda d, s: d ^ s,
}

SHIFTS = {
    'psrlw': shift(2, 'r'), 'psrld': shift(4, 'r'), 'psrlq': shift(8, 'r'),
    'psraw': shift(2, 'a'), 'psrad': shift(4, 'a'),
    'psllw': shift(2, 'l'), 'pslld': shift(4, 'l'), 'psllq': shift(8, 'l'),
}
COUNTS = [3, 15, 16, 33, 1 << 40]

EDGE = [0x7f80ff007f80ff00, 0xff007f80ff007f80, 0x7fff8000ffff0000,
        0x00007fff8000ffff, 0x8000800080008000, 0x0102030405060708]


def cases(seed=1):
    rnd = random.Random(seed)
    out = []
    for op, fn in OPS.items():
        pairs = [(EDGE[0], EDGE[1]), (EDGE[2], EDGE[3]), (EDGE[4], EDGE[5]),
                 (rnd.getrandbits(64), rnd.getrandbits(64))]
        for d, s in pairs:
            out.append((op, d, s, fn(d, s) & M64))
    for op, fn in SHIFTS.items():
        for c in COUNTS:
            d = 0x8421f00f7ffe8001
            out.append((op, d, c, fn(d, c) & M64))
    return out


HEADER = '''// MMX: the integer instructions on the eight 64-bit registers that alias
// the x87 stack, and what using them does to the x87 unit.
//
// Generated by tests/gen_mmx.py from a model of the manual, which was itself
// checked against an x86-64 CPU.  Every other case reads its source from
// memory rather than a register, so both operand paths are exercised.
        .code64
        .text
        .globl  _start
_start:
        mov     $0x8000, %rsp
        fninit
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


def q(v):
    return f'        .quad   0x{v & M64:016x}'


def emit():
    code, data, checks = [], [], []
    n = 1

    def check(reg, label, desc):
        nonlocal n
        code.extend([
            f'        movq    {reg}, %rax',
            f'        mov     ${n}, %bl',
            f'        cmp     {label}(%rip), %rax',
            '        jne     fail',
        ])
        checks.append((n, desc))
        n += 1

    def want(label, v):
        data.extend([f'{label}:', q(v)])

    for i, (op, d, s, r) in enumerate(cases()):
        k = n
        code.append(f'        movq    c{k}_d(%rip), %mm0')
        if op in SHIFTS and i % 3 == 2:
            if s < 256:                             # the immediate form too
                code.append(f'        {op:9} ${s}, %mm0')
            else:
                code.append(f'        movq    c{k}_s(%rip), %mm6')
                code.append(f'        {op:9} %mm6, %mm0')
        elif i % 2:
            code.append(f'        {op:9} c{k}_s(%rip), %mm0')
        else:
            code.append(f'        movq    c{k}_s(%rip), %mm1')
            code.append(f'        {op:9} %mm1, %mm0')
        want(f'c{k}_d', d)
        want(f'c{k}_s', s)
        want(f'c{k}_r', r)
        check('%mm0', f'c{k}_r', f'{op} -> 0x{r:016x}')

    v = 0x0123456789abcdef
    # PSHUFW, PINSRW, PEXTRW, PMOVMSKB
    k = n
    sel = 0x1b
    r = join([lanes(v, 2)[(sel >> (2 * i)) & 3] for i in range(4)], 2)
    code.append(f'        pshufw  ${sel:#x}, val(%rip), %mm2')
    want(f'c{k}_r', r)
    check('%mm2', f'c{k}_r', f'pshufw $0x1b -> 0x{r:016x}')
    for imm in (0, 3):
        k = n
        r = (v & ~(0xffff << (16 * imm))) | (0xbeef << (16 * imm))
        code.append('        movq    val(%rip), %mm3')
        if imm:
            code.append('        movw    $0xbeef, w16(%rip)')
            code.append(f'        pinsrw  ${imm}, w16(%rip), %mm3')
        else:
            code.append('        mov     $0x1234beef, %eax')
            code.append(f'        pinsrw  ${imm}, %eax, %mm3')
        want(f'c{k}_r', r)
        check('%mm3', f'c{k}_r', f'pinsrw ${imm} -> 0x{r:016x}')
    for imm in (1, 2):
        r = (v >> (16 * imm)) & 0xffff
        code.extend([
            '        movq    val(%rip), %mm4',
            '        movabs  $-1, %rcx',
            f'        pextrw  ${imm}, %mm4, %ecx',
            f'        mov     ${n}, %bl',
            f'        cmp     $0x{r:x}, %rcx',
            '        jne     fail',
        ])
        checks.append((n, f'pextrw ${imm} -> 0x{r:x}'))
        n += 1
    r = sum(((v >> (8 * i + 7)) & 1) << i for i in range(8))
    code.extend([
        '        movq    val(%rip), %mm4',
        '        pmovmskb %mm4, %ecx',
        f'        mov     ${n}, %bl',
        f'        cmp     $0x{r:x}, %ecx',
        '        jne     fail',
    ])
    checks.append((n, f'pmovmskb -> 0x{r:x}'))
    n += 1

    # MOVD zero-extends into the register and takes the low dword out of it
    k = n
    code.extend([
        '        movq    val(%rip), %mm5',
        '        mov     $0x89abcdef, %eax',
        '        movd    %eax, %mm5',
    ])
    want(f'c{k}_r', 0x89abcdef)
    check('%mm5', f'c{k}_r', 'movd r32 -> mm zero-extends')
    code.extend([
        '        movq    val(%rip), %mm5',
        '        movabs  $-1, %rcx',
        '        movd    %mm5, %ecx',
        f'        mov     ${n}, %bl',
        '        mov     $0x89abcdef, %edx',                # zero-extended
        '        cmp     %rdx, %rcx',
        '        jne     fail',
    ])
    checks.append((n, 'movd mm -> r32'))
    n += 1

    # MASKMOVQ to (%rdi) and MOVNTQ
    k = n
    fill, src, mask = 0x5a5a5a5a5a5a5a5a, 0x1122334455667788, 0x8000ff0000800080
    r = 0
    for i in range(8):
        b = (src if (mask >> (8 * i + 7)) & 1 else fill) >> (8 * i) & 0xff
        r |= b << (8 * i)
    code.extend([
        f'        movq    c{k}_f(%rip), %mm0',
        '        movntq  %mm0, buf(%rip)',
        f'        movq    c{k}_s(%rip), %mm0',
        f'        movq    c{k}_m(%rip), %mm1',
        '        lea     buf(%rip), %rdi',
        '        maskmovq %mm1, %mm0',
        '        movq    buf(%rip), %mm7',
    ])
    data.extend([f'c{k}_f:', q(fill), f'c{k}_s:', q(src), f'c{k}_m:', q(mask)])
    want(f'c{k}_r', r)
    check('%mm7', f'c{k}_r', f'maskmovq -> 0x{r:016x}')

    # MMX empties the stack: TOP 0, every tag valid; EMMS marks them empty
    code.extend([
        '        fninit',
        '        fld1',                                   # TOP 7
        '        movq    val(%rip), %mm3',
        '        fnstsw  %ax',
        f'        mov     ${n}, %bl',
        '        test    $0x3800, %ax',
        '        jne     fail',
        '        fxsave64 area(%rip)',
        f'        mov     ${n + 1}, %bl',
        '        cmpb    $0xff, area+4(%rip)',
        '        jne     fail',
        '        emms',
        '        fxsave64 area(%rip)',
        f'        mov     ${n + 2}, %bl',
        '        cmpb    $0, area+4(%rip)',
        '        jne     fail',
    ])
    checks += [(n, 'MMX sets TOP to 0'), (n + 1, 'MMX marks every register valid'),
               (n + 2, 'EMMS marks every register empty')]
    n += 3

    # An MMX value is the significand of an x87 register whose sign and
    # exponent are all ones, and FXSAVE and FXRSTOR carry it exactly
    pats = [0x0123456789abcdef ^ (0x1111111111111111 * i) for i in range(8)]
    for i in range(8):
        code.append(f'        movq    pat{i}(%rip), %mm{i}')
        data.extend([f'pat{i}:', q(pats[i])])
    code.extend([
        '        fxsave64 area(%rip)',
        '        mov     area+32+5*16(%rip), %rax',
        f'        mov     ${n}, %bl',
        '        cmp     pat5(%rip), %rax',
        '        jne     fail',
        '        movzwl  area+40+5*16(%rip), %eax',
        f'        mov     ${n + 1}, %bl',
        '        cmp     $0xffff, %eax',
        '        jne     fail',
        '        emms',
        '        fninit',
        '        fld1',
        '        fldpi',
        '        pxor    %mm0, %mm0',
        '        fxrstor64 area(%rip)',
    ])
    checks += [(n, 'FXSAVE stores an MMX value as the significand'),
               (n + 1, 'with the sign and exponent all ones')]
    n += 2
    for i in (0, 5, 7):
        check(f'%mm{i}', f'pat{i}', f'FXRSTOR brings mm{i} back exactly')

    assert n < 255, 'check numbers must fit the one-byte status'
    text = HEADER + '\n'.join(code) + TAIL + '''
        .align  16
area:   .space  512
buf:    .quad   0
w16:    .word   0
        .align  8
val:    .quad   0x0123456789abcdef
''' + '\n'.join(data) + '\n'
    return text, checks


def verify():
    """Compare the model with an x86-64 CPU, case by case."""
    cs = cases()
    lines = ['#include <stdio.h>', 'int main(void) {', 'unsigned long long d, s;']
    for op, dv, sv, _ in cs:
        lines.append(f'd = 0x{dv:016x}ULL; s = 0x{sv:016x}ULL;')
        lines.append('__asm__ volatile("movq (%%0), %%%%mm0\\n movq (%%1), %%%%mm1\\n '
                     '%s %%%%mm1, %%%%mm0\\n movq %%%%mm0, (%%0)\\n emms" :: "r"(&d), "r"(&s) '
                     ': "memory");' % op)
        lines.append('printf("%016llx\\n", d);')
    lines.append('return 0; }')
    with tempfile.TemporaryDirectory() as tmp:
        src, exe = os.path.join(tmp, 'v.c'), os.path.join(tmp, 'v')
        open(src, 'w').write('\n'.join(lines))
        subprocess.run(['clang', '-arch', 'x86_64', '-O0', src, '-o', exe], check=True)
        got = subprocess.run(['arch', '-x86_64', exe], check=True,
                             capture_output=True, text=True).stdout.split()
    bad = [(op, d, s, r, int(g, 16)) for (op, d, s, r), g in zip(cs, got) if int(g, 16) != r]
    for op, d, s, r, g in bad:
        print(f'{op}: d={d:016x} s={s:016x} model={r:016x} cpu={g:016x}')
    print(f'{len(cs) - len(bad)} of {len(cs)} cases agree with the CPU')
    return not bad


if __name__ == '__main__':
    if '--verify' in sys.argv:
        sys.exit(0 if verify() else 1)
    here = os.path.dirname(os.path.abspath(__file__))
    text, checks = emit()
    open(os.path.join(here, 'asm', 't_mmx.s'), 'w').write(text)
    with open(os.path.join(here, 'asm', 't_mmx.checks'), 'w') as f:
        for code, desc in checks:
            f.write(f'{code}\t{desc}\n')
    print(f'wrote t_mmx.s ({len(checks)} checks)')
