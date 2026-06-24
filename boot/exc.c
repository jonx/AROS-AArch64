// AROS AArch64 bring-up — M3: the C exception handler.
//
// Foreshadows AROS's `arch/<cpu>-native/kernel/intr.c` (handlers there are named
// __vectorhand_*). vectors.S saves a trap frame and calls exc_handler(frame,kind).
// We decode ESR_EL1 and either resume (SVC) or skip the faulting instruction
// (BRK), demonstrating the two recovery styles a real fault handler uses.
//
// EC encodings are grounded against Linux arch/arm64/include/asm/esr.h:
//   EC = ESR_EL1[31:26];  SVC64 = 0x15;  BRK64 = 0x3C;  DABT(cur) = 0x25.

#include "kern.h"

// Mirrors (a corrected superset of) AROS's struct ExceptionContext for aarch64,
// whose upstream version is incomplete (mislabels x30, omits ELR/SPSR). x[i]=xi.
struct trapframe {
    uint64_t x[31];     // x0..x30
};

enum { K_SYNC = 0, K_IRQ, K_FIQ, K_SERROR, K_INVALID };

void exc_handler(struct trapframe *tf, unsigned long kind)
{
    // Async interrupts have no useful syndrome — route straight to the dispatcher.
    // (QEMU virt GICv2 may signal our group-0 timer as IRQ or FIQ; handle both.)
    if (kind == K_IRQ || kind == K_FIQ) {
        irq_dispatch();
        return;
    }

    uint64_t esr  = SYSREG_READ("esr_el1");
    uint64_t elr  = SYSREG_READ("elr_el1");
    uint64_t spsr = SYSREG_READ("spsr_el1");
    uint64_t far  = SYSREG_READ("far_el1");
    unsigned ec   = (unsigned)((esr >> 26) & 0x3f);

    static const char *const kinds[] = { "SYNC", "IRQ", "FIQ", "SError", "INVALID" };
    kprintf("  exc kind=%s EC=0x%x ESR=0x%lx ELR=0x%lx SPSR=0x%lx FAR=0x%lx\n",
            kinds[kind <= K_INVALID ? kind : K_INVALID], ec, esr, elr, spsr, far);

    (void)tf;
    switch (ec) {
    case 0x15:  // SVC64: ELR already points past the svc, so ERET resumes.
        kprintf("[M3b] svc EC=0x%x handled (resume)\n", ec);
        break;
    case 0x3c:  // BRK64: ELR points AT the brk, advance it by 4 to skip.
        kprintf("[M3c] brk EC=0x%x handled (skip)\n", ec);
        SYSREG_WRITE("elr_el1", elr + 4);
        break;
    case 0x24:  // data abort, lower EL
    case 0x25:  // data abort, current EL (M4 unmapped-access demo). FAR = bad VA.
        kprintf("[M4b] data abort EC=0x%x FAR=0x%lx handled (skip)\n", ec, far);
        SYSREG_WRITE("elr_el1", elr + 4);
        break;
    default:
        kprintf("  UNEXPECTED exception — halting (watchdog will reap)\n");
        for (;;)
            __asm__ volatile("wfe");
    }
}

void vectors_init(void)
{
    extern char exc_vectors[];
    SYSREG_WRITE("vbar_el1", (uintptr_t)exc_vectors);
    __asm__ volatile("isb");
}
