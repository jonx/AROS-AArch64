// AROS AArch64 bring-up — shared kernel declarations.
// Small on purpose; grows as milestones land.
#ifndef KERN_H
#define KERN_H

#include <stdint.h>

// printf-to-UART, defined in kmain.c, reused everywhere (M2).
void kprintf(const char *fmt, ...);

// Exception vectors (M3): install VBAR_EL1; defined in exc.c / vectors.S.
void vectors_init(void);

// MMU (M4): build an identity map and enable translation; defined in mmu.c.
void mmu_init(void);

// Interrupts + timer (M5): GICv2 + EL1 physical timer; defined in irq.c.
void gic_init(void);
void timer_init(unsigned hz);
void irqs_enable(void);
void irq_dispatch(void);
extern volatile uint64_t timer_ticks;

// Read/write an AArch64 system register by name, e.g. SYSREG_READ("esr_el1").
#define SYSREG_READ(reg) ({ uint64_t _v; __asm__ volatile("mrs %0, " reg : "=r"(_v)); _v; })
#define SYSREG_WRITE(reg, val) \
    __asm__ volatile("msr " reg ", %0" :: "r"((uint64_t)(val)) : "memory")

#endif /* KERN_H */
