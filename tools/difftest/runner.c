/* Execute the generated cases on real silicon and record the resulting state.
 *
 * Each case is one instruction followed by a RET, sitting in its own slot of an
 * executable page.  The trampoline loads the requested register, flag and XMM
 * state, calls the slot, and writes back what came out.
 *
 * Memory operands are anchored on a scratch page mapped at a fixed address that
 * the emulator identity-maps too, so both sides address the same bytes.  The
 * page is reset from a fixed pattern before every case, and hashed afterwards,
 * so a store landing in the wrong place shows up without shipping four kilobytes
 * per case across the network.
 *
 * RSP is neither loaded nor reported: the slot is reached with a CALL, so the
 * stack pointer during the case belongs to this program, not to the test.
 *
 *   cc -O2 -o runner runner.c   ./runner cases.bin init.bin results.bin
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <signal.h>
#include <setjmp.h>

#define SCRATCH   0x300000UL
#define SCRATCH_LEN 4096

typedef struct {
    uint64_t r[16];          /*   0 */
    uint64_t fl;             /* 128 */
    uint8_t  xmm[16][16];    /* 136 */
    uint64_t cw;             /* 392  x87 control word, low 16 bits */
    double   st[8];          /* 400  ST(0..7) on the way in, ST(0..3) out */
    uint64_t sw;             /* 464  x87 status word, out only */
} state_t;

state_t g_in, g_out;
void *g_slot;

static sigjmp_buf g_jb;
static volatile sig_atomic_t g_fault;

extern void run_case(void);
__asm__(
".text\n"
".globl run_case\n"
"run_case:\n"
"  push %rbp\n  push %rbx\n  push %r12\n  push %r13\n  push %r14\n  push %r15\n"
"  lea g_in(%rip), %rax\n"
/* The x87 stack is filled by pushing the eight values in reverse, so ST(0)
 * ends up holding st[0] with TOP back at zero and every tag valid.  Loading
 * the control word first is what puts the requested rounding mode in place
 * before anything rounds. */
"  fninit\n"
"  fldcw 392(%rax)\n"
"  fldl 440(%rax)\n  fldl 432(%rax)\n"
"  fldl 424(%rax)\n  fldl 416(%rax)\n  fldl 408(%rax)\n  fldl 400(%rax)\n"
/* XMM next, then flags, then the general registers with the base last. */
"  movdqu 136(%rax), %xmm0\n   movdqu 152(%rax), %xmm1\n"
"  movdqu 168(%rax), %xmm2\n   movdqu 184(%rax), %xmm3\n"
"  movdqu 200(%rax), %xmm4\n   movdqu 216(%rax), %xmm5\n"
"  movdqu 232(%rax), %xmm6\n   movdqu 248(%rax), %xmm7\n"
"  movdqu 264(%rax), %xmm8\n   movdqu 280(%rax), %xmm9\n"
"  movdqu 296(%rax), %xmm10\n  movdqu 312(%rax), %xmm11\n"
"  movdqu 328(%rax), %xmm12\n  movdqu 344(%rax), %xmm13\n"
"  movdqu 360(%rax), %xmm14\n  movdqu 376(%rax), %xmm15\n"
"  pushq 128(%rax)\n"
"  popfq\n"
"  mov 8(%rax), %rcx\n   mov 16(%rax), %rdx\n  mov 24(%rax), %rbx\n"
"  mov 40(%rax), %rbp\n  mov 48(%rax), %rsi\n  mov 56(%rax), %rdi\n"
"  mov 64(%rax), %r8\n   mov 72(%rax), %r9\n   mov 80(%rax), %r10\n"
"  mov 88(%rax), %r11\n  mov 96(%rax), %r12\n  mov 104(%rax), %r13\n"
"  mov 112(%rax), %r14\n mov 120(%rax), %r15\n"
"  mov 0(%rax), %rax\n"
"  call *g_slot(%rip)\n"
/* RAX is saved first so it can be reused; MOV, PUSHFQ and POP all leave the
 * flags alone, so they survive until they are read. */
"  mov %rax, g_out+0(%rip)\n   mov %rcx, g_out+8(%rip)\n"
"  mov %rdx, g_out+16(%rip)\n  mov %rbx, g_out+24(%rip)\n"
"  mov %rbp, g_out+40(%rip)\n  mov %rsi, g_out+48(%rip)\n"
"  mov %rdi, g_out+56(%rip)\n  mov %r8,  g_out+64(%rip)\n"
"  mov %r9,  g_out+72(%rip)\n  mov %r10, g_out+80(%rip)\n"
"  mov %r11, g_out+88(%rip)\n  mov %r12, g_out+96(%rip)\n"
"  mov %r13, g_out+104(%rip)\n mov %r14, g_out+112(%rip)\n"
"  mov %r15, g_out+120(%rip)\n"
"  pushfq\n"
"  pop %rax\n"
"  mov %rax, g_out+128(%rip)\n"
"  lea g_out(%rip), %rax\n"
"  movdqu %xmm0, 136(%rax)\n   movdqu %xmm1, 152(%rax)\n"
"  movdqu %xmm2, 168(%rax)\n   movdqu %xmm3, 184(%rax)\n"
"  movdqu %xmm4, 200(%rax)\n   movdqu %xmm5, 216(%rax)\n"
"  movdqu %xmm6, 232(%rax)\n   movdqu %xmm7, 248(%rax)\n"
"  movdqu %xmm8, 264(%rax)\n   movdqu %xmm9, 280(%rax)\n"
"  movdqu %xmm10, 296(%rax)\n  movdqu %xmm11, 312(%rax)\n"
"  movdqu %xmm12, 328(%rax)\n  movdqu %xmm13, 344(%rax)\n"
"  movdqu %xmm14, 360(%rax)\n  movdqu %xmm15, 376(%rax)\n"
/* The status word is taken before anything else touches the stack, because a
 * store can set C1.  ST(0..3) are then read without popping, so TOP and the
 * tags stay as the instruction left them; eight were pushed and nothing pops
 * more than two, so all four are always occupied. */
"  fnstsw 464(%rax)\n"
"  fstl 400(%rax)\n"
"  fxch %st(1)\n  fstl 408(%rax)\n  fxch %st(1)\n"
"  fxch %st(2)\n  fstl 416(%rax)\n  fxch %st(2)\n"
"  fxch %st(3)\n  fstl 424(%rax)\n  fxch %st(3)\n"
"  cld\n"
"  pop %r15\n  pop %r14\n  pop %r13\n  pop %r12\n  pop %rbx\n  pop %rbp\n"
"  ret\n"
);

static void handler(int sig) { g_fault = sig; siglongjmp(g_jb, 1); }

static void *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); *len = ftell(f); fseek(f, 0, SEEK_SET);
    void *p = malloc(*len);
    if (fread(p, 1, *len, f) != *len) { perror("read"); exit(1); }
    fclose(f);
    return p;
}

static uint64_t fnv(const uint8_t *p, size_t n) {
    /* Written in hex so the offset basis cannot silently lose a digit, which
     * it did once and made every case disagree about memory. */
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ULL; }
    return h;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: runner cases.bin init.bin out.bin\n"); return 1; }
    size_t clen, ilen;
    uint8_t *code = slurp(argv[1], &clen);
    uint64_t *init = slurp(argv[2], &ilen);
    const size_t SLOT = 32, PER = 8 * 58, n = clen / SLOT;   /* gpr, flags, xmm, cw, st */
    if (ilen / PER != n) { fprintf(stderr, "case/init count mismatch\n"); return 1; }

    void *page = mmap(NULL, (clen + 4095) & ~4095UL, PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) { perror("mmap code"); return 1; }
    memcpy(page, code, clen);

    uint8_t *scratch = mmap((void *)SCRATCH, SCRATCH_LEN, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (scratch != (uint8_t *)SCRATCH) { perror("mmap scratch"); return 1; }
    uint8_t pattern[SCRATCH_LEN];
    for (int i = 0; i < SCRATCH_LEN; i++) pattern[i] = (uint8_t)(i * 7 + 0x5a);

    for (int s = 0; s < 4; s++) {
        int sigs[] = { SIGSEGV, SIGILL, SIGFPE, SIGBUS };
        struct sigaction sa; memset(&sa, 0, sizeof sa);
        sa.sa_handler = handler; sa.sa_flags = SA_NODEFER;
        sigaction(sigs[s], &sa, NULL);
    }

    FILE *out = fopen(argv[3], "wb");
    for (size_t i = 0; i < n; i++) {
        const uint64_t *rec = &init[i * 58];
        memcpy(g_in.r, rec, 16 * 8);
        g_in.fl = rec[16];
        memcpy(g_in.xmm, &rec[17], 16 * 16);
        g_in.cw = rec[49];
        memcpy(g_in.st, &rec[50], 8 * 8);
        memcpy(scratch, pattern, SCRATCH_LEN);
        memset(&g_out, 0, sizeof g_out);
        g_fault = 0;
        if (sigsetjmp(g_jb, 1) == 0) {
            g_slot = (char *)page + i * SLOT;
            run_case();
        }
        uint32_t fault = (uint32_t)g_fault, pad = 0;
        uint64_t hash = fnv(scratch, SCRATCH_LEN);
        fwrite(g_out.r, 8, 16, out);
        fwrite(&g_out.fl, 8, 1, out);
        fwrite(&fault, 4, 1, out);
        fwrite(&pad, 4, 1, out);
        fwrite(g_out.xmm, 1, 256, out);
        fwrite(&hash, 8, 1, out);
        fwrite(&g_out.sw, 8, 1, out);
        fwrite(g_out.st, 8, 4, out);        /* ST(0..3) */
    }
    fclose(out);
    fprintf(stderr, "ran %zu cases\n", n);
    return 0;
}
