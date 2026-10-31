#!/usr/bin/env python3
"""Generate shift and rotate tests.

Counts are kept below the operand width throughout.  The manual leaves the
flags undefined once a count exceeds the operand size, so testing those would be
asserting one particular choice rather than the architecture.

Shifts set SF, ZF and PF from the result; rotates touch only CF and OF.  OF is
defined only for a count of one, so it is checked there and masked out
elsewhere.  A count that masks to zero must change nothing at all, flags
included, which is a case emulators routinely get wrong.
"""

import os

CF, PF, ZF, SF, OF = 0x001, 0x004, 0x040, 0x080, 0x800

WIDTHS = [(1, 'b', '%al', [1, 3, 7]), (2, 'w', '%ax', [1, 5, 15]),
          (4, 'l', '%eax', [1, 9, 31]), (8, 'q', '%rax', [1, 17, 63])]

BACKDROP = 0x5A5A5A5A5A5A5A5A
VALUE = 0x9E3779B97F4A7C15


def mask(w):
    return (1 << (w * 8)) - 1


def bits(w):
    return w * 8


def sign(v, w):
    return (v >> (bits(w) - 1)) & 1


def parity(v):
    return 1 if bin(v & 0xff).count('1') % 2 == 0 else 0


def result_flags(r, w):
    """SF, ZF and PF as a shift leaves them."""
    f = 0
    if r == 0:
        f |= ZF
    if sign(r, w):
        f |= SF
    if parity(r):
        f |= PF
    return f


def do_shl(v, c, w, cin):
    r = (v << c) & mask(w)
    cf = (v >> (bits(w) - c)) & 1
    of = sign(r, w) ^ cf
    return r, cf, of, result_flags(r, w)


def do_shr(v, c, w, cin):
    r = v >> c
    cf = (v >> (c - 1)) & 1
    of = sign(v, w)
    return r, cf, of, result_flags(r, w)


def do_sar(v, c, w, cin):
    neg = sign(v, w)
    r = v >> c
    if neg:
        r |= (mask(w) << (bits(w) - c)) & mask(w)
    cf = (v >> (c - 1)) & 1
    return r, cf, 0, result_flags(r, w)


def do_rol(v, c, w, cin):
    n = bits(w)
    e = c % n
    r = ((v << e) | (v >> (n - e))) & mask(w) if e else v
    cf = r & 1
    of = sign(r, w) ^ cf
    return r, cf, of, None


def do_ror(v, c, w, cin):
    n = bits(w)
    e = c % n
    r = ((v >> e) | (v << (n - e))) & mask(w) if e else v
    cf = sign(r, w)
    of = sign(r, w) ^ ((r >> (n - 2)) & 1)
    return r, cf, of, None


def do_rcl(v, c, w, cin):
    n = bits(w) + 1                       # carry participates in the rotation
    x = v | (cin << bits(w))
    e = c % n
    x = ((x << e) | (x >> (n - e))) & ((1 << n) - 1) if e else x
    r = x & mask(w)
    cf = (x >> bits(w)) & 1
    of = sign(r, w) ^ cf
    return r, cf, of, None


def do_rcr(v, c, w, cin):
    n = bits(w) + 1
    x = v | (cin << bits(w))
    e = c % n
    x = ((x >> e) | (x << (n - e))) & ((1 << n) - 1) if e else x
    r = x & mask(w)
    cf = (x >> bits(w)) & 1
    of = sign(r, w) ^ ((r >> (bits(w) - 2)) & 1)
    return r, cf, of, None


GROUPS = {
    't_shift': [('shl', do_shl), ('shr', do_shr), ('sar', do_sar)],
    't_rot': [('rol', do_rol), ('ror', do_ror),
              ('rcl', do_rcl), ('rcr', do_rcr)],
}


def emit(ops):
    blocks, checks, code = [], [], 1
    for name, fn in ops:
        through_carry = name in ('rcl', 'rcr')
        for w, suf, reg, counts in WIDTHS:
            v = VALUE & mask(w)
            for c in counts + [0]:
                cin = 1 if through_carry else 0
                if c == 0:
                    r, cf, of, rf = v, cin, None, None
                else:
                    r, cf, of, rf = fn(v, c, w, cin)
                full = r if w in (4, 8) else (BACKDROP & ~mask(w)) | r

                b = [f'        movabs  $0x{BACKDROP:016x}, %rax']
                if w == 8:
                    b.append(f'        movabs  $0x{v:016x}, %rax')
                else:
                    b.append(f'        mov     $0x{v:x}, {reg}')
                b.append('        stc' if cin else '        clc')
                b.append(f'        {name}{suf}   ${c}, {reg}')
                b.append('        pushfq')
                b.append('        pop     %rdx')
                b.append(f'        movabs  $0x{full:016x}, %rcx')
                b.append('        cmp     %rcx, %rax')
                b.append(f'        mov     ${code}, %bl')
                b.append('        jne     fail')
                checks.append((code, f'{name}{suf} 0x{v:x} by {c} -> 0x{full:x}'))
                code += 1

                # CF always, SF/ZF/PF for shifts, OF only for a count of one
                want, care = 0, CF
                if cf:
                    want |= CF
                if rf is not None:
                    care |= SF | ZF | PF
                    want |= rf
                if c == 1 and of is not None:
                    care |= OF
                    if of:
                        want |= OF
                if c == 0:
                    # a zero count leaves every flag exactly as it was
                    care, want = CF, (CF if cin else 0)
                b.append(f'        and     $0x{care:x}, %edx')
                b.append(f'        cmp     $0x{want:x}, %edx')
                b.append(f'        mov     ${code}, %bl')
                b.append('        jne     fail')
                checks.append((code, f'{name}{suf} flags care=0x{care:x} want=0x{want:x}'))
                code += 1
                blocks.append('\n'.join(b))
    return blocks, checks, code


HEADER = '''// Shifts and rotates: results and the flags they define.
//
// Generated by tests/gen_shift.py.  Counts stay below the operand width because
// the manual leaves the flags undefined beyond it, and a count of zero is
// included because it must change nothing -- not the value and not one flag.
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
            raise SystemExit(f'{name}: {code} checks exceed the byte exit code')
        with open(os.path.join(here, 'asm', f'{name}.s'), 'w') as fh:
            fh.write(HEADER + '\n'.join(blocks) + TAIL)
        with open(os.path.join(here, 'asm', f'{name}.checks'), 'w') as fh:
            for n, desc in checks:
                fh.write(f'{n}\t{desc}\n')
        print(f'{name}: {len(blocks)} blocks, {code - 1} checks')
