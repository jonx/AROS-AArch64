// AROS AArch64 bring-up — M5: GICv2 + EL1 physical timer = the first async event.
//
// Foreshadows AROS's intr.c / kernel_systimer.c. Grounded from the DTB (GICv2,
// GICD 0x0800_0000, GICC 0x0801_0000, timer PPI 14 → INTID 30) and Linux
// arm-gic.h (register offsets). The generic timer fires a periodic IRQ; the
// handler counts ticks, re-arms the timer, and EOIs the GIC.

#include "kern.h"

#define GICD_BASE       0x08000000UL
#define GICC_BASE       0x08010000UL
#define GICD_CTLR       0x000
#define GICD_ISENABLER  0x100
#define GICD_IPRIORITYR 0x400
#define GICC_CTLR       0x000
#define GICC_PMR        0x004
#define GICC_IAR        0x00c
#define GICC_EOIR       0x010

#define TIMER_INTID     30          // EL1 physical timer = PPI 14 → INTID 30

static inline void w32(unsigned long b, unsigned o, uint32_t v) { *(volatile uint32_t *)(b + o) = v; }
static inline uint32_t r32(unsigned long b, unsigned o) { return *(volatile uint32_t *)(b + o); }

volatile uint64_t timer_ticks = 0;
static uint64_t timer_interval = 0;

void gic_init(void)
{
    w32(GICD_BASE, GICD_CTLR, 1);                       // enable distributor
    // Per-INTID priority is byte-addressed; 0 = highest. Then set-enable the PPI.
    ((volatile uint8_t *)(GICD_BASE + GICD_IPRIORITYR))[TIMER_INTID] = 0x00;
    w32(GICD_BASE, GICD_ISENABLER + (TIMER_INTID / 32) * 4, 1u << (TIMER_INTID % 32));
    w32(GICC_BASE, GICC_PMR, 0xFF);                     // allow all priorities
    w32(GICC_BASE, GICC_CTLR, 1);                       // enable CPU interface
}

void timer_init(unsigned hz)
{
    uint64_t freq;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
    timer_interval = freq / hz;
    __asm__ volatile("msr cntp_tval_el0, %0" :: "r"(timer_interval));
    __asm__ volatile("msr cntp_ctl_el0, %0" :: "r"(1UL));   // ENABLE=1, IMASK=0
}

// Called from the IRQ/FIQ vector. Ack, handle, re-arm, EOI.
void irq_dispatch(void)
{
    uint32_t iar = r32(GICC_BASE, GICC_IAR);
    uint32_t intid = iar & 0x3ff;
    if (intid == TIMER_INTID) {
        timer_ticks++;
        __asm__ volatile("msr cntp_tval_el0, %0" :: "r"(timer_interval));  // re-arm + deassert
    }
    if (intid < 1020)
        w32(GICC_BASE, GICC_EOIR, iar);
}

void irqs_enable(void)
{
    __asm__ volatile("msr daifclr, #3" ::: "memory");   // unmask IRQ (I) and FIQ (F)
}
