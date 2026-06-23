// AROS AArch64 bring-up — M1: prove the autonomous loop on bare metal.
//
// This is NOT AROS. It is the smallest program that exercises the whole loop:
// QEMU enters at _start, we bring up the PL011 UART, write a marker string, then
// ask QEMU to power off (semihosting) so a successful run exits in <1s instead
// of waiting out the harness timeout. The harness greps the marker and PASSes.
//
// QEMU 'virt' facts this relies on (confirmed via the -d int trace):
//   * PL011 UART lives at 0x0900_0000; data reg at +0x00, LCRH +0x2c, CR +0x30.
//   * -kernel enters the primary CPU at EL1.
//   * secondary CPUs also enter here, so we park any with a non-zero MPIDR.

.section .text.boot, "ax"
.global _start
_start:
    // Park secondary cores: only the boot CPU (affinity 0) proceeds.
    mrs     x0, mpidr_el1
    and     x0, x0, #0xff
    cbnz    x0, halt

    // Set up a stack (reserved at the top of the image by the linker script).
    adrp    x0, _stack_top
    add     x0, x0, :lo12:_stack_top
    mov     sp, x0

    // --- minimal PL011 init so we're not poking a disabled UART ---
    movz    x20, #0x0900, lsl #16       // x20 = UART base 0x0900_0000
    mov     w1, #0x70                   // LCRH: 8-bit word, FIFO enabled
    str     w1, [x20, #0x2c]
    mov     w1, #0x301                  // CR: UARTEN | TXE | RXE
    str     w1, [x20, #0x30]

    // --- write the marker string, byte by byte ---
    adrp    x19, msg
    add     x19, x19, :lo12:msg
1:
    ldrb    w0, [x19], #1
    cbz     w0, exit
    strb    w0, [x20]                   // UARTDR @ base+0x00
    b       1b

exit:
    // Semihosting SYS_EXIT (requires -semihosting). On AArch64 the parameter
    // register points to a {reason, exit_code} block — NOT the reason directly.
    mov     x0, #0x18                   // SYS_EXIT
    adrp    x1, exit_block
    add     x1, x1, :lo12:exit_block
    hlt     #0xf000

halt:
    // Fallback if semihosting is disabled: spin so the harness timeout reaps us.
    wfe
    b       halt

.section .data
.align 3
exit_block:
    .quad   0x20026                     // ADP_Stopped_ApplicationExit
    .quad   0                           // exit status 0

.section .rodata
msg:
    .asciz  "[M1] aarch64 serial alive\n"
