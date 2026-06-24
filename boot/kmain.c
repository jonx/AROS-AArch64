// AROS AArch64 bring-up — M2: the C runtime.
//
// start.S hands control here once the stack is up and .bss is zeroed. This is
// the boundary where bring-up stops being assembly and becomes the C layer most
// of AROS lives in. It carries a minimal PL011 UART driver and a tiny kprintf
// that every later milestone reuses (M3 prints ESR/ELR in hex, M5 prints ticks).
//
// Constraints while the MMU is off (until M4): all RAM is Device memory, so
// accesses must be naturally aligned (we build with -mstrict-align) and no
// floating-point/NEON is available yet (-mgeneral-regs-only).

#include <stdint.h>
#include <stdarg.h>
#include "kern.h"

// ---- PL011 UART (QEMU 'virt' wires UART0 here) ----
#define UART0_BASE 0x09000000UL
#define UART_DR    0x00
#define UART_FR    0x18
#define UART_LCRH  0x2c
#define UART_CR    0x30
#define UART_FR_TXFF (1u << 5)   // transmit FIFO full

static inline void mmio_w32(unsigned long base, unsigned off, uint32_t v) {
    *(volatile uint32_t *)(base + off) = v;
}
static inline uint32_t mmio_r32(unsigned long base, unsigned off) {
    return *(volatile uint32_t *)(base + off);
}

static void uart_init(void) {
    mmio_w32(UART0_BASE, UART_LCRH, 0x70);    // 8-bit word, FIFO enabled
    mmio_w32(UART0_BASE, UART_CR,   0x301);   // UARTEN | TXE | RXE
}

static void uart_putc(char c) {
    while (mmio_r32(UART0_BASE, UART_FR) & UART_FR_TXFF) { /* wait for space */ }
    mmio_w32(UART0_BASE, UART_DR, (uint8_t)c);
}

#define UART_FR_RXFE (1u << 4)   // receive FIFO empty
static int uart_getc(void) {
    while (mmio_r32(UART0_BASE, UART_FR) & UART_FR_RXFE) { /* wait for input */ }
    return (int)(mmio_r32(UART0_BASE, UART_DR) & 0xff);
}

// ---- tiny kprintf: %c %s %d %u %x %p, plus %l{d,u,x} ----
static void put_uint(unsigned long v, unsigned base, int width, char pad) {
    char buf[32];
    const char *digits = "0123456789abcdef";
    int i = 0;
    if (v == 0) buf[i++] = '0';
    while (v) { buf[i++] = digits[v % base]; v /= base; }
    while (i < width) buf[i++] = pad;
    while (i--) uart_putc(buf[i]);
}

static void put_str(const char *s) {
    for (; *s; ++s) {
        if (*s == '\n') uart_putc('\r');   // cook \n -> \r\n for the terminal
        uart_putc(*s);
    }
}

void kprintf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    for (; *fmt; ++fmt) {
        if (*fmt != '%') {
            if (*fmt == '\n') uart_putc('\r');
            uart_putc(*fmt);
            continue;
        }
        switch (*++fmt) {
        case 's': put_str(va_arg(ap, const char *)); break;
        case 'c': uart_putc((char)va_arg(ap, int)); break;
        case 'u': put_uint(va_arg(ap, unsigned), 10, 0, ' '); break;
        case 'x': put_uint(va_arg(ap, unsigned), 16, 0, ' '); break;
        case 'p': put_str("0x"); put_uint((unsigned long)va_arg(ap, void *), 16, 16, '0'); break;
        case 'd': {
            long v = va_arg(ap, int);
            if (v < 0) { uart_putc('-'); v = -v; }
            put_uint((unsigned long)v, 10, 0, ' ');
            break;
        }
        case 'l':
            switch (*++fmt) {
            case 'u': put_uint(va_arg(ap, unsigned long), 10, 0, ' '); break;
            case 'x': put_uint(va_arg(ap, unsigned long), 16, 0, ' '); break;
            case 'd': {
                long v = va_arg(ap, long);
                if (v < 0) { uart_putc('-'); v = -v; }
                put_uint((unsigned long)v, 10, 0, ' ');
                break;
            }
            default: uart_putc('%'); uart_putc('l'); uart_putc(*fmt); break;
            }
            break;
        case '%': uart_putc('%'); break;
        default: uart_putc('%'); uart_putc(*fmt); break;
        }
    }
    va_end(ap);
}

static unsigned current_el(void) {
    unsigned long v;
    __asm__ volatile("mrs %0, CurrentEL" : "=r"(v));
    return (unsigned)((v >> 2) & 3);   // CurrentEL[3:2]
}

static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

// M8: a minimal line shell over the UART. The harness injects keystrokes into the
// serial socket (the "drive" half of the channel); we echo and dispatch.
static void shell_run(void) {
    char line[64];
    kprintf("[M8a] shell ready (commands: ping, ticks, quit)\n");
    for (;;) {
        kprintf("shell> ");
        int n = 0, ch;
        while ((ch = uart_getc()) != '\r' && ch != '\n') {
            if (ch == 0x7f || ch == 0x08) {            // backspace
                if (n) { n--; kprintf("\b \b"); }
                continue;
            }
            if (n < (int)sizeof(line) - 1) { line[n++] = (char)ch; uart_putc((char)ch); }
        }
        uart_putc('\n');
        line[n] = 0;
        if (streq(line, "ping"))       kprintf("pong\n");
        else if (streq(line, "ticks")) kprintf("ticks=%lu\n", timer_ticks);
        else if (streq(line, "quit"))  { kprintf("[M8] shell ok (got quit)\n"); return; }
        else if (n)                    kprintf("unknown: %s\n", line);
    }
}

// Entry from start.S. x0_at_entry is whatever the boot path left in x0; under
// QEMU's ELF -kernel it is 0 (NOT the DTB — see start.S / HARDWARE.md). Printed
// so the grounded fact stays verified by the loop. Returning hands back to the
// semihosting exit.
void kmain(unsigned long x0_at_entry) {
    uart_init();
    kprintf("[M2] hello from C (EL%u) x0=%p\n", current_el(), (void *)x0_at_entry);

    // M3: install exception vectors, then deliberately trap to prove they work.
    vectors_init();
    kprintf("[M3a] VBAR set, triggering traps\n");
    __asm__ volatile("svc #0");     // -> sync exception, EC=0x15, resumes after
    __asm__ volatile("brk #0");     // -> sync exception, EC=0x3c, handler skips it
    kprintf("[M3] vectors ok\n");

    // M4: enable the MMU. The print AFTER proves we identity-mapped correctly and
    // didn't vanish (UART still reachable, code still executing).
    kprintf("[M4a] enabling MMU (identity map)...\n");
    mmu_init();
    // Prove translation is real: 0x80000000 is left unmapped (L1 entry 2 = 0), so
    // touching it must fault with FAR = that address. The handler skips the load.
    __asm__ volatile("ldr x9, [%0]" :: "r"(0x80000000UL) : "x9", "memory");
    kprintf("[M4] MMU verified (SCTLR.M=%u, identity map + translation fault), alive\n",
            (unsigned)(SYSREG_READ("sctlr_el1") & 1));

    // M5: first asynchronous event — GICv2 + EL1 physical timer at 100 Hz.
    kprintf("[M5a] init GICv2 + EL1 phys timer (INTID 30)\n");
    gic_init();
    timer_init(100);
    irqs_enable();
    while (timer_ticks < 5)         // sleep until the timer IRQ has fired 5×
        __asm__ volatile("wfi");
    kprintf("[M5] timer IRQ ok, ticks=%lu\n", timer_ticks);

    // M6: physical page allocator. Prove alloc, read/write, free, and LIFO reuse.
    kprintf("[M6a] pmm init (heap above _end)\n");
    pmm_init();
    uint64_t total = pmm_free_count();
    void *a = pmm_alloc(), *b = pmm_alloc(), *c = pmm_alloc();
    *(volatile uint64_t *)a = 0xA5A5A5A5A5A5A5A5UL;
    *(volatile uint64_t *)c = 0xC3C3C3C3C3C3C3C3UL;
    int rw = (*(volatile uint64_t *)a == 0xA5A5A5A5A5A5A5A5UL)
          && (*(volatile uint64_t *)c == 0xC3C3C3C3C3C3C3C3UL);
    pmm_free(b);
    void *d = pmm_alloc();           // LIFO -> should hand back b
    kprintf("[M6] pmm ok: total=%lu pages a=%p b=%p c=%p rw=%d reuse=%d free=%lu\n",
            total, a, b, c, rw, (d == b), pmm_free_count());

    // M7: cooperative context switch between two tasks on separate stacks.
    tasks_demo();

    // M8: minimal shell — reads injected keystrokes from the UART, dispatches.
    shell_run();

    // M9: framebuffer via ramfb. Draw, then stay up ~3s so the harness can grab a
    // QMP screendump before we exit cleanly.
    fb_init();
    uint64_t t = timer_ticks;
    while (timer_ticks < t + 300)        // ~3s at 100 Hz
        __asm__ volatile("wfi");
}
