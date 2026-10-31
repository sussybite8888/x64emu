#!/usr/bin/env python3
"""Generate single-instruction differential test cases.

Each case is one instruction plus a full initial machine state.  Running the
same case on real silicon and on the emulator and comparing the resulting state
finds semantic bugs without anyone having to predict the answer first -- which
matters because every CPU bug found in this emulator so far lived in a corner
nobody thought to write a test for.

One instruction per case is deliberate: when a case fails there is nothing to
bisect, the failing instruction is the case.

Some flags are architecturally undefined after certain instructions, and real
hardware is free to differ from any reasonable emulator there.  Each template
carries a mask of the flags it leaves undefined so those never register as
failures; chasing them would be chasing ghosts.
"""
import json
import random
import sys

CF, PF, AF, ZF, SF, OF = 1 << 0, 1 << 2, 1 << 4, 1 << 6, 1 << 7, 1 << 11
ARITH = CF | PF | AF | ZF | SF | OF

# RSP is never an operand and never compared: the native runner reaches its
# cases with a CALL, so the stack pointer is the host's, not the test's.
R64 = ['rax', 'rcx', 'rdx', 'rbx', 'rbp', 'rsi', 'rdi',
       'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15']
R32 = ['eax', 'ecx', 'edx', 'ebx', 'ebp', 'esi', 'edi',
       'r8d', 'r9d', 'r10d', 'r11d', 'r12d', 'r13d', 'r14d', 'r15d']
R16 = ['ax', 'cx', 'dx', 'bx', 'bp', 'si', 'di',
       'r8w', 'r9w', 'r10w', 'r11w', 'r12w', 'r13w', 'r14w', 'r15w']
R8 = ['al', 'cl', 'dl', 'bl', 'bpl', 'sil', 'dil',
      'r8b', 'r9b', 'r10b', 'r11b', 'r12b', 'r13b', 'r14b', 'r15b']
BY_SIZE = {1: R8, 2: R16, 4: R32, 8: R64}
IDX = {n: i for i, n in enumerate(
    ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
     'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'])}
# map any width's name back to the architectural register number
REGNUM = {}
for _sz, _names in BY_SIZE.items():
    for _i, _n in enumerate(_names):
        REGNUM[_n] = IDX[R64[_i]]

ALU = ['add', 'or', 'adc', 'sbb', 'and', 'sub', 'xor', 'cmp']
LOGIC = {'and', 'or', 'xor'}
SHIFT = ['shl', 'shr', 'sar', 'rol', 'ror', 'rcl', 'rcr']
CC = ['o', 'no', 'b', 'ae', 'e', 'ne', 'be', 'a',
      's', 'ns', 'p', 'np', 'l', 'ge', 'le', 'g']

# Memory operands are anchored on a scratch page that both sides map at the
# same address, with R15 pointing at its middle so a backwards string operation
# has somewhere to go.  Every generated address stays well inside the page, so
# no case can fault on one side and not the other.
SCRATCH = 0x300000
SCRATCH_LEN = 4096
SCRATCH_PTR = SCRATCH + SCRATCH_LEN // 2
SUFFIX = {1: 'b', 2: 'w', 4: 'l', 8: 'q'}

XMM = [f'xmm{i}' for i in range(16)]
ST = [f'st({i})' for i in range(8)]
# Precision control is pinned to double so the two sides agree exactly: the
# emulator keeps its register file in f64 while hardware works in 80-bit
# extended, and only at PC=53 do the arithmetic results match bit for bit.
# The rounding field is varied, because that is the part guests actually
# change and the part that was being ignored.
CW_BASE = 0x027f
# Transcendentals are approximations that no two implementations agree on to
# the last bit, so they are generated but never strictly compared.
X87_APPROX = {'fsin', 'fcos', 'fptan', 'fpatan', 'f2xm1', 'fyl2x',
              'fyl2xp1', 'fsincos', 'fsqrt'}
# Packed integer operations: lane width and saturation rules are where these go
# wrong, and none of them depend on the floating point state.
SSE_INT = ['paddb', 'paddw', 'paddd', 'paddq', 'paddsb', 'paddsw',
           'paddusb', 'paddusw', 'psubb', 'psubw', 'psubd', 'psubq',
           'psubsb', 'psubsw', 'psubusb', 'psubusw',
           'pand', 'pandn', 'por', 'pxor',
           'pcmpeqb', 'pcmpeqw', 'pcmpeqd', 'pcmpgtb', 'pcmpgtw', 'pcmpgtd',
           'pmullw', 'pmulhw', 'pmulhuw', 'pmuludq', 'pavgb', 'pavgw',
           'pminub', 'pmaxub', 'pminsw', 'pmaxsw', 'psadbw',
           'packsswb', 'packuswb', 'packssdw',
           'punpcklbw', 'punpckhbw', 'punpcklwd', 'punpckhwd',
           'punpckldq', 'punpckhdq', 'punpcklqdq', 'punpckhqdq']
SSE_SHIFT = ['psllw', 'pslld', 'psllq', 'psrlw', 'psrld', 'psrlq',
             'psraw', 'psrad', 'pslldq', 'psrldq']
SSE_FLT = ['addps', 'addpd', 'addss', 'addsd', 'subps', 'subpd', 'subss', 'subsd',
           'mulps', 'mulpd', 'mulss', 'mulsd', 'divps', 'divpd', 'divss', 'divsd',
           'minps', 'minpd', 'minss', 'minsd', 'maxps', 'maxpd', 'maxss', 'maxsd',
           'sqrtps', 'sqrtpd', 'sqrtss', 'sqrtsd',
           'andps', 'andpd', 'andnps', 'andnpd', 'orps', 'orpd', 'xorps', 'xorpd',
           'unpcklps', 'unpckhps', 'unpcklpd', 'unpckhpd']
# Anything whose operands are floats needs finite inputs: x86 propagates the
# source NaN's payload and WebAssembly produces a canonical one, so a NaN in
# would be a difference that says nothing about the emulator's arithmetic.
FLOAT_OPS = set(SSE_FLT) | {'cvtss2sd', 'cvtsd2ss', 'cvtps2pd', 'cvtpd2ps',
                            'cvttss2si', 'cvttsd2si', 'cvtss2si', 'cvtsd2si',
                            'ucomiss', 'ucomisd', 'comiss', 'comisd',
                            'cvtps2dq', 'cvttps2dq', 'cmpps', 'cmppd',
                            'cmpss', 'cmpsd_x', 'shufps', 'shufpd'}

# Counts that sit on the boundaries where masking and the overflow rule change.
COUNTS = [0, 1, 2, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255]


def imm_for(size):
    """A mix of ordinary and boundary-shaped immediates."""
    pool = [0, 1, 2, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff,
            0x7fffffff, 0x80000000, 0xffffffff, -1, -2, -128, -129]
    v = random.choice(pool + [random.getrandbits(32)])
    lim = {1: 0x7f, 2: 0x7fff, 4: 0x7fffffff, 8: 0x7fffffff}[size]
    return max(-lim - 1, min(lim, v if v <= lim else v - (1 << 32)))


def mem_operand(rnd, cons):
    """An address inside the scratch page, sometimes with a scaled index."""
    disp = rnd.randrange(-128, 129)
    if rnd.random() < 0.55:
        return f'{disp}(%r15)'
    idx = rnd.choice([r for r in R64 if r != 'r15'])
    scale = rnd.choice([1, 2, 4, 8])
    # The index has to stay small or the address leaves the page.
    cons[REGNUM[idx]] = ('range', 0, 24)
    return f'{disp}(%r15,%{idx},{scale})'


def gen_case(rnd):
    """One instruction and the flags it leaves undefined."""
    kind = rnd.choice([
        'alu_rr', 'alu_rr', 'alu_ri', 'alu_ri', 'test', 'shift_i', 'shift_i',
        'shift_cl', 'incdec', 'negnot', 'imul1', 'imul2', 'imul3', 'mul',
        'div', 'bt', 'bit_scan', 'setcc', 'cmov', 'movx', 'shdd', 'xchg',
        'cmpxchg', 'bswap', 'popcnt', 'lea',
        'alu_rm', 'alu_rm', 'alu_mr', 'alu_mr', 'alu_mi', 'mov_rm', 'mov_mr',
        'mov_mi', 'shift_m', 'incdec_m', 'negnot_m', 'xchg_m', 'cmpxchg_m',
        'bt_m', 'string', 'string', 'imul_m', 'movx_m',
        'sse_int', 'sse_int', 'sse_shift', 'sse_flt', 'sse_flt', 'sse_cmp',
        'sse_shuf', 'sse_cvt', 'sse_mem', 'sse_movmsk',
        'x87_arith', 'x87_arith', 'x87_unary', 'x87_const', 'x87_cmp',
        'x87_stack', 'x87_int', 'x87_cmov',
    ])
    size = rnd.choice([1, 2, 4, 8])
    regs = BY_SIZE[size]
    a, b = rnd.choice(regs), rnd.choice(regs)

    cons = {}
    if kind.startswith('x87_'):
        # Six registers are loaded, so indices stay inside the occupied part of
        # the stack and there is room for a push without overflowing.
        i1, i2 = rnd.randrange(1, 6), rnd.randrange(1, 6)
        if kind == 'x87_arith':
            op = rnd.choice(['fadd', 'fsub', 'fsubr', 'fmul', 'fdiv', 'fdivr'])
            # Both directions exist: one writes ST(0), the other writes ST(i)
            # and the reversed forms swap which operand is subtracted from
            # which -- a pairing that is easy to wire up backwards.
            form = rnd.random()
            if form < 0.4:
                return f'{op} %st({i1}), %st', 0, cons
            if form < 0.8:
                return f'{op} %st, %st({i1})', 0, cons
            return f'{op}p %st, %st({i1})', 0, cons
        if kind == 'x87_unary':
            return rnd.choice(['fabs', 'fchs', 'frndint', 'fsqrt', 'fscale',
                               'fprem', 'fprem1', 'f2xm1']), 0, cons
        if kind == 'x87_const':
            return rnd.choice(['fld1', 'fldz', 'fldpi', 'fldl2e', 'fldl2t',
                               'fldlg2', 'fldln2']), 0, cons
        if kind == 'x87_cmp':
            op = rnd.choice(['fcom', 'fcomp', 'fucom', 'fucomp',
                             'fcomi', 'fcomip', 'fucomi', 'fucomip'])
            if op in ('ftst',):
                return op, 0, cons
            return f'{op} %st({i1})', 0, cons
        if kind == 'x87_stack':
            op = rnd.choice(['fxch', 'fld', 'fst', 'fstp', 'fincstp', 'fdecstp'])
            if op in ('fincstp', 'fdecstp'):
                return op, 0, cons
            return f'{op} %st({i1})', 0, cons
        if kind == 'x87_cmov':
            cc = rnd.choice(['b', 'e', 'be', 'u', 'nb', 'ne', 'nbe', 'nu'])
            return f'fcmov{cc} %st({i1}), %st', 0, cons
        # Integer loads and stores through memory: these are the ones the
        # rounding mode reaches.
        mem = mem_operand(rnd, cons)
        if rnd.random() < 0.5:
            return f'{rnd.choice(["filds", "fildl", "fildll"])} {mem}', 0, cons
        return f'{rnd.choice(["fistps", "fistpl", "fistpll", "fisttpll"])} {mem}', 0, cons

    if kind.startswith('sse_'):
        x, y = rnd.choice(XMM), rnd.choice(XMM)
        if kind == 'sse_int':
            return f'{rnd.choice(SSE_INT)} %{x}, %{y}', 0, cons
        if kind == 'sse_shift':
            op = rnd.choice(SSE_SHIFT)
            if op in ('pslldq', 'psrldq') or rnd.random() < 0.6:
                return f'{op} ${rnd.choice([0, 1, 7, 8, 15, 16, 31, 32, 63, 64, 200])}, %{y}', 0, cons
            return f'{op} %{x}, %{y}', 0, cons
        if kind == 'sse_flt':
            op = rnd.choice(SSE_FLT)
            return f'{op} %{x}, %{y}', 0, cons
        if kind == 'sse_cmp':
            op = rnd.choice(['cmpps', 'cmppd', 'cmpss', 'cmpsd'])
            return f'{op} ${rnd.randrange(0, 8)}, %{x}, %{y}', 0, cons
        if kind == 'sse_shuf':
            op = rnd.choice(['pshufd', 'pshuflw', 'pshufhw', 'shufps', 'shufpd'])
            return f'{op} ${rnd.randrange(0, 256)}, %{x}, %{y}', 0, cons
        if kind == 'sse_cvt':
            op = rnd.choice(['cvtss2sd', 'cvtsd2ss', 'cvtps2pd', 'cvtpd2ps',
                             'cvtdq2ps', 'cvtps2dq', 'cvttps2dq', 'cvtdq2pd'])
            if rnd.random() < 0.35:
                # to and from the general registers
                g32 = [r for r in R32 if REGNUM[r] != 15]
                g64 = [r for r in R64 if REGNUM[r] != 15]
                op = rnd.choice(['cvtsi2ss', 'cvtsi2sd', 'cvttss2si', 'cvttsd2si',
                                 'cvtss2si', 'cvtsd2si', 'movd', 'movq'])
                g = rnd.choice(g64 if rnd.random() < 0.5 else g32)
                if op in ('cvtsi2ss', 'cvtsi2sd') or (op in ('movd', 'movq') and rnd.random() < 0.5):
                    if op == 'movd':
                        g = rnd.choice(g32)
                    if op == 'movq':
                        g = rnd.choice(g64)
                    return f'{op} %{g}, %{y}', 0, cons
                if op == 'movd':
                    g = rnd.choice(g32)
                if op == 'movq':
                    g = rnd.choice(g64)
                return f'{op} %{x}, %{g}', 0, cons
            return f'{op} %{x}, %{y}', 0, cons
        if kind == 'sse_movmsk':
            g = rnd.choice([r for r in R32 if REGNUM[r] != 15])
            return f'{rnd.choice(["pmovmskb", "movmskps", "movmskpd"])} %{x}, %{g}', 0, cons
        # Loads and stores use the unaligned forms so a case can never fault on
        # alignment, which would stop the native runner rather than report.
        op = rnd.choice(['movups', 'movupd', 'movdqu'])
        mem = mem_operand(rnd, cons)
        if rnd.random() < 0.5:
            return f'{op} {mem}, %{x}', 0, cons
        return f'{op} %{x}, {mem}', 0, cons

    if kind in ('alu_rm', 'alu_mr', 'alu_mi', 'mov_rm', 'mov_mr', 'mov_mi',
                'shift_m', 'incdec_m', 'negnot_m', 'xchg_m', 'cmpxchg_m',
                'bt_m', 'imul_m', 'movx_m'):
        # R15 is the scratch base and must not also be an operand.
        regs = [r for r in BY_SIZE[size] if REGNUM[r] != 15]
        a, b = rnd.choice(regs), rnd.choice(regs)
        mem = mem_operand(rnd, cons)
        if kind == 'alu_rm':
            op = rnd.choice(ALU)
            return f'{op} {mem}, %{a}', (AF if op in LOGIC else 0), cons
        if kind == 'alu_mr':
            op = rnd.choice(ALU)
            return f'{op} %{a}, {mem}', (AF if op in LOGIC else 0), cons
        if kind == 'alu_mi':
            op = rnd.choice(ALU)
            return (f'{op}{SUFFIX[size]} ${imm_for(size)}, {mem}',
                    (AF if op in LOGIC else 0), cons)
        if kind == 'mov_rm':
            return f'mov {mem}, %{a}', 0, cons
        if kind == 'mov_mr':
            return f'mov %{a}, {mem}', 0, cons
        if kind == 'mov_mi':
            return f'mov{SUFFIX[size]} ${imm_for(size)}, {mem}', 0, cons
        if kind == 'shift_m':
            op = rnd.choice(SHIFT)
            bits = size * 8
            c = rnd.choice(COUNTS) & 0xff
            eff = c & (0x3f if size == 8 else 0x1f)
            undef = AF | (0 if c == 1 else OF)
            if op in ('shl', 'shr', 'sar') and eff >= bits:
                undef |= CF
            return f'{op}{SUFFIX[size]} ${c}, {mem}', undef, cons
        if kind == 'incdec_m':
            return f'{rnd.choice(["inc", "dec"])}{SUFFIX[size]} {mem}', 0, cons
        if kind == 'negnot_m':
            return f'{rnd.choice(["neg", "not"])}{SUFFIX[size]} {mem}', 0, cons
        if kind == 'xchg_m':
            return f'xchg %{a}, {mem}', 0, cons
        if kind == 'cmpxchg_m':
            return f'cmpxchg %{a}, {mem}', 0, cons
        if kind == 'imul_m':
            if size == 1:
                return f'imul{SUFFIX[1]} {mem}', PF | AF | ZF | SF, cons
            return f'imul {mem}, %{a}', PF | AF | ZF | SF, cons
        if kind == 'movx_m':
            src = rnd.choice([1, 2, 4])
            dst = rnd.choice([d for d in (2, 4, 8) if d > src])
            if src == 4:
                return f'movslq {mem}, %{R64[rnd.randrange(14)]}', 0, cons
            op = rnd.choice(['movz', 'movs'])
            sfx = SUFFIX[src] + SUFFIX[dst]
            return f'{op}{sfx} {mem}, %{BY_SIZE[dst][rnd.randrange(14)]}', 0, cons
        # BT against memory indexes an arbitrarily long bit string rather than
        # masking to the operand width, so the offset register is kept small
        # enough that the address stays on the page.
        op = rnd.choice(['bt', 'bts', 'btr', 'btc'])
        if size == 1:
            size = 4
            regs = [r for r in R32 if REGNUM[r] != 15]
            a = rnd.choice(regs)
        if rnd.random() < 0.5:
            cons[REGNUM[a]] = ('range', -256, 256)
            return f'{op} %{a}, {mem}', PF | AF | ZF | SF | OF, cons
        return (f'{op}{SUFFIX[size]} ${rnd.randrange(0, size * 8)}, {mem}',
                PF | AF | ZF | SF | OF, cons)

    if kind == 'string':
        op = rnd.choice(['movs', 'stos', 'lods', 'cmps', 'scas'])
        sz = rnd.choice([1, 2, 4, 8])
        rep = rnd.choice(['', '', 'rep ', 'repe ', 'repne '])
        if op in ('movs', 'stos') and rep in ('repe ', 'repne '):
            rep = 'rep '
        if op in ('lods',) and rep:
            rep = ''                      # a repeated LODS is legal but pointless
        # Source and destination sit near the middle of the page and the count
        # stays small, so neither direction can walk off it.
        cons[6] = ('ptr', -64, 64)        # rsi
        cons[7] = ('ptr', -64, 64)        # rdi
        cons[1] = ('range', 0, 9)         # rcx
        undef = 0 if op in ('cmps', 'scas') else ARITH
        # DF selects the direction, so it has to be part of the initial state.
        return f'{rep}{op}{SUFFIX[sz]}', undef, cons, 0x400

    if kind == 'alu_rr':
        op = rnd.choice(ALU)
        return f'{op} %{b}, %{a}', (AF if op in LOGIC else 0)
    if kind == 'alu_ri':
        op = rnd.choice(ALU)
        return f'{op} ${imm_for(size)}, %{a}', (AF if op in LOGIC else 0)
    if kind == 'test':
        return (f'test %{b}, %{a}' if rnd.random() < 0.5
                else f'test ${imm_for(size)}, %{a}'), AF
    if kind == 'shift_i':
        op = rnd.choice(SHIFT)
        bits = size * 8
        c = rnd.choice(COUNTS) & 0xff
        eff = c & (0x3f if size == 8 else 0x1f)
        undef = AF | (0 if c == 1 else OF)
        # SHL/SHR/SAR leave CF undefined once the count reaches the operand
        # width; the rotates keep it defined, and RCL/RCR reduce modulo
        # width+1 rather than width, which is exactly the rule to exercise.
        if op in ('shl', 'shr', 'sar') and eff >= bits:
            undef |= CF
        return f'{op} ${c}, %{a}', undef
    if kind == 'shift_cl':
        op = rnd.choice(SHIFT)
        if a == 'cl':
            a = 'dl'
        # CL is constrained below to stay under the operand width so CF stays
        # defined and the case is worth comparing.
        return f'{op} %cl, %{a}', AF | OF, {1: ('range', 0, size * 8)}
    if kind == 'incdec':
        return f'{rnd.choice(["inc", "dec"])} %{a}', 0
    if kind == 'negnot':
        return f'{rnd.choice(["neg", "not"])} %{a}', 0
    if kind == 'imul1':
        return f'imul %{a}', PF | AF | ZF | SF
    if kind == 'imul2':
        if size == 1:
            size, regs = 4, R32
            a, b = rnd.choice(regs), rnd.choice(regs)
        return f'imul %{b}, %{a}', PF | AF | ZF | SF
    if kind == 'imul3':
        if size == 1:
            size, regs = 4, R32
            a, b = rnd.choice(regs), rnd.choice(regs)
        return f'imul ${imm_for(size)}, %{b}, %{a}', PF | AF | ZF | SF
    if kind == 'mul':
        return f'mul %{a}', PF | AF | ZF | SF
    if kind == 'div':
        # Operands are constructed to divide exactly, so no case ever raises
        # #DE -- a divide fault would kill the native runner rather than
        # reporting a difference.  The divisor must not live in RAX or RDX:
        # the dividend is written into that pair afterwards, which would
        # overwrite the divisor and occasionally zero it.
        d = rnd.choice([r for r in regs if REGNUM[r] not in (0, 2)])
        return f'{rnd.choice(["div", "idiv"])} %{d}', ARITH
    if kind == 'bt':
        op = rnd.choice(['bt', 'bts', 'btr', 'btc'])
        if size == 1:
            size, regs = 4, R32
            a, b = rnd.choice(regs), rnd.choice(regs)
        return ((f'{op} %{b}, %{a}' if rnd.random() < 0.5
                 else f'{op} ${rnd.randrange(0, 64)}, %{a}'), PF | AF | ZF | SF | OF)
    if kind == 'bit_scan':
        if size == 1:
            size, regs = 4, R32
            a, b = rnd.choice(regs), rnd.choice(regs)
        # the destination is undefined when the source is zero, so the
        # generator guarantees a non-zero source below
        return f'{rnd.choice(["bsf", "bsr"])} %{b}, %{a}', CF | PF | AF | SF | OF
    if kind == 'setcc':
        return f'set{rnd.choice(CC)} %{rnd.choice(R8)}', 0
    if kind == 'cmov':
        if size < 4:
            size, regs = 4, R32
            a, b = rnd.choice(regs), rnd.choice(regs)
        return f'cmov{rnd.choice(CC)} %{b}, %{a}', 0
    if kind == 'movx':
        src = rnd.choice([1, 2])
        dst = rnd.choice([s for s in (2, 4, 8) if s > src])
        op = rnd.choice(['movz', 'movs'])
        sfx = {1: 'b', 2: 'w'}[src] + {2: 'w', 4: 'l', 8: 'q'}[dst]
        return f'{op}{sfx} %{BY_SIZE[src][rnd.randrange(15)]}, ' \
               f'%{BY_SIZE[dst][rnd.randrange(15)]}', 0
    if kind == 'shdd':
        if size < 2:
            size, regs = 4, R32
            a, b = rnd.choice(regs), rnd.choice(regs)
        op = rnd.choice(['shld', 'shrd'])
        bits = size * 8
        c = rnd.choice([x for x in COUNTS if x < bits] + [rnd.randrange(bits)])
        return f'{op} ${c}, %{b}, %{a}', AF | OF
    if kind == 'xchg':
        return f'xchg %{b}, %{a}', 0
    if kind == 'cmpxchg':
        return f'cmpxchg %{b}, %{a}', 0
    if kind == 'bswap':
        if size < 4:
            size, regs = 4, R32
            a = rnd.choice(regs)
        return f'bswap %{a}', 0
    if kind == 'popcnt':
        if size == 1:
            size, regs = 4, R32
            a, b = rnd.choice(regs), rnd.choice(regs)
        return f'popcnt %{b}, %{a}', 0
    # lea exercises the address arithmetic without touching memory
    base, index = rnd.choice(R64), rnd.choice([r for r in R64 if r != 'r13'])
    scale = rnd.choice([1, 2, 4, 8])
    disp = imm_for(4)
    dst = rnd.choice(rnd.choice([R32, R64]))
    return f'lea {disp}(%{base},%{index},{scale}), %{dst}', 0


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rnd = random.Random(seed)

    import struct
    lines = ['.text', '.globl cases', '.balign 32', 'cases:']
    cases = []
    for i in range(n):
        got = gen_case(rnd)
        asm, undef = got[0], got[1]
        cons = got[2] if len(got) > 2 else {}
        flmask = got[3] if len(got) > 3 else 0
        # Register values mix boundaries with noise: sign bits, all-ones and
        # zero find carry and overflow bugs that random bits never reach.
        regs = []
        for _ in range(16):
            regs.append(rnd.choice([
                0, 1, 2, 0xff, 0x7f, 0x80, 0xffff, 0x8000, 0x7fff,
                0xffffffff, 0x80000000, 0x7fffffff,
                0xffffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff,
                rnd.getrandbits(64), rnd.getrandbits(64),
            ]))
        # A zero source would leave BSF/BSR's destination undefined.
        mnemonic = asm.split()[0]
        if mnemonic in ('bsf', 'bsr'):
            src = REGNUM[asm.split('%')[1].split(',')[0]]
            if regs[src] == 0:
                regs[src] = 0x1234
        # Division is set up to come out exact, so no case can raise #DE.
        # Matched exactly, not by prefix: divps and divsd also start with "div"
        # and have nothing to do with the integer divider.
        if mnemonic in ('div', 'idiv'):
            d = asm.split('%')[1].strip()
            dn, dsz = REGNUM[d], {1: 1, 2: 2, 4: 4, 8: 8}[
                1 if d in R8 else 2 if d in R16 else 4 if d in R32 else 8]
            div = rnd.randrange(1, 1 << (dsz * 8 - 1))
            q = rnd.randrange(0, 1 << (dsz * 8 - 2))
            r = rnd.randrange(0, div)
            prod = q * div + r
            regs[dn] = div
            if dsz == 1:
                regs[0] = (regs[0] & ~0xffff) | (prod & 0xffff)
            else:
                lo_mask = (1 << (dsz * 8)) - 1
                regs[0] = (regs[0] & ~lo_mask) | (prod & lo_mask)
                regs[2] = (regs[2] & ~lo_mask) | ((prod >> (dsz * 8)) & lo_mask)
        # R15 anchors every memory operand.
        regs[15] = SCRATCH_PTR
        for rn, spec in cons.items():
            if spec[0] == 'range':
                regs[rn] = rnd.randrange(spec[1], spec[2]) & 0xffffffffffffffff
            else:                                       # a pointer into scratch
                regs[rn] = SCRATCH_PTR + rnd.randrange(spec[1], spec[2])
        flags = (rnd.getrandbits(16) & (ARITH | flmask)) | 2   # bit 1 reads as one
        # XMM starts from a mix of noise and the patterns that make lane
        # ordering and saturation mistakes visible.
        mnem = asm.split()[0].lstrip('rep').strip() or asm.split()[0]
        if mnem in FLOAT_OPS:
            singles = mnem.endswith('ps') or mnem.endswith('ss') or 'ss2' in mnem \
                or mnem in ('cvtdq2ps', 'cvtps2dq', 'cvttps2dq', 'cvtsi2ss')
            xm = bytearray()
            pool = [0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 3.5, -7.25, 1e10, -1e-10,
                    123456.75, 1.0 / 3.0]
            for _ in range(16):
                if singles:
                    xm += struct.pack('<4f', *[rnd.choice(pool) for _ in range(4)])
                else:
                    xm += struct.pack('<2d', *[rnd.choice(pool) for _ in range(2)])
            cases.append({'i': i, 'asm': asm, 'undef': undef, 'xmm': xm.hex(),
                          'cw': CW_BASE, 'st': [1.0] * 8,
                          'regs': [f'{v:016x}' for v in regs], 'flags': flags})
            lines += [f'    {asm}', '    ret', '    .balign 32']
            continue
        xm = bytearray()
        for _ in range(16):
            pick = rnd.random()
            if pick < 0.25:
                xm += bytes(16)
            elif pick < 0.4:
                xm += b'\xff' * 16
            elif pick < 0.55:
                xm += struct.pack('<qq', rnd.choice([1, -1, 1 << 62, -(1 << 62)]),
                                  rnd.choice([0, -1, 1 << 30]))
            else:
                xm += bytes(rnd.getrandbits(8) for _ in range(16))
        lines += [f'    {asm}', '    ret', '    .balign 32']
        # The rounding mode is varied only for the instructions that round as
        # their whole purpose.  Arithmetic under a directed mode is a known gap
        # -- WebAssembly only rounds to nearest -- so varying it there would
        # report that one limitation thousands of times over.
        rounds = asm.split()[0] in ('frndint', 'fistps', 'fistpl', 'fistpll',
                                    'fists', 'fistl')
        cw = CW_BASE | ((rnd.randrange(0, 4) << 10) if rounds else 0)
        stpool = [0.0, 1.0, -1.0, 2.0, -2.0, 0.5, 2.5, -2.5, 2.7, -2.7, 3.5,
                  6.6, 10.0, 100.0, 0.125, 1e10, -1e-10, 1234.5, -7.25, 3.0]
        if asm.split()[0] in ('fprem', 'fprem1'):
            # Hardware reduces only part of the way when the exponents differ by
            # 64 or more and reports it through C2; that partial step is not
            # modelled, so the operands are kept close enough to complete.
            stpool = [1.0, -1.0, 2.0, -2.0, 0.5, 2.5, -2.5, 2.7, -2.7, 3.5,
                      6.6, 10.0, 100.0, 0.125, 1234.5, -7.25, 3.0, 7.0]
        st = [rnd.choice(stpool) for _ in range(8)]
        cases.append({'i': i, 'asm': asm, 'undef': undef, 'xmm': xm.hex(),
                      'cw': cw, 'st': st,
                      'regs': [f'{v:016x}' for v in regs], 'flags': flags})

    # The native runner reads its initial states from a flat binary rather
    # than parsing JSON in C: 16 registers, the flags, then the XMM file.
    with open('init.bin', 'wb') as f:
        for c in cases:
            for v in c['regs']:
                f.write(struct.pack('<Q', int(v, 16)))
            f.write(struct.pack('<Q', c['flags']))
            f.write(bytes.fromhex(c['xmm']))
            f.write(struct.pack('<Q', c['cw']))
            f.write(struct.pack('<8d', *c['st']))

    with open('cases.s', 'w') as f:
        f.write('\n'.join(lines) + '\n')
    with open('cases.json', 'w') as f:
        json.dump({'slot': 32, 'cases': cases}, f)
    print(f'{n} cases')


if __name__ == '__main__':
    main()
