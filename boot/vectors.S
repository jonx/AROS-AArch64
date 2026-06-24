// AROS AArch64 bring-up — M3: the exception vector table.
//
// This foreshadows AROS's `arch/<cpu>-native/kernel/intvecs.s`. The AArch64
// vector table is 16 entries × 0x80 bytes (2 KiB total), and VBAR_EL1 must point
// at a 2 KiB-aligned base (low 11 bits are RES0). The 16 entries are four groups
// of four (Sync, IRQ, FIQ, SError):
//   0x000  Current EL with SP_EL0
//   0x200  Current EL with SP_ELx   <- we run here (EL1h), so traps land at 0x200
//   0x400  Lower EL using AArch64
//   0x600  Lower EL using AArch32
//
// Each slot is just a branch to a trampoline that saves a trap frame, calls the
// C handler exc_handler(frame, kind), restores, and ERETs. ESR/ELR/SPSR/FAR are
// read in C straight from the system registers (live until we ERET; we don't nest).

.macro VEC target
    .balign 0x80
    b   \target
.endm

// Save x0-x30 into a 256-byte frame (16-byte aligned). x[i] at offset 8*i.
.macro EXC_SAVE
    sub  sp, sp, #256
    stp  x0,  x1,  [sp, #16*0]
    stp  x2,  x3,  [sp, #16*1]
    stp  x4,  x5,  [sp, #16*2]
    stp  x6,  x7,  [sp, #16*3]
    stp  x8,  x9,  [sp, #16*4]
    stp  x10, x11, [sp, #16*5]
    stp  x12, x13, [sp, #16*6]
    stp  x14, x15, [sp, #16*7]
    stp  x16, x17, [sp, #16*8]
    stp  x18, x19, [sp, #16*9]
    stp  x20, x21, [sp, #16*10]
    stp  x22, x23, [sp, #16*11]
    stp  x24, x25, [sp, #16*12]
    stp  x26, x27, [sp, #16*13]
    stp  x28, x29, [sp, #16*14]
    str  x30,      [sp, #16*15]
.endm

.macro EXC_RESTORE
    ldp  x0,  x1,  [sp, #16*0]
    ldp  x2,  x3,  [sp, #16*1]
    ldp  x4,  x5,  [sp, #16*2]
    ldp  x6,  x7,  [sp, #16*3]
    ldp  x8,  x9,  [sp, #16*4]
    ldp  x10, x11, [sp, #16*5]
    ldp  x12, x13, [sp, #16*6]
    ldp  x14, x15, [sp, #16*7]
    ldp  x16, x17, [sp, #16*8]
    ldp  x18, x19, [sp, #16*9]
    ldp  x20, x21, [sp, #16*10]
    ldp  x22, x23, [sp, #16*11]
    ldp  x24, x25, [sp, #16*12]
    ldp  x26, x27, [sp, #16*13]
    ldp  x28, x29, [sp, #16*14]
    ldr  x30,      [sp, #16*15]
    add  sp, sp, #256
.endm

.macro EXC_TRAMP kind
    EXC_SAVE
    mov  x1, #\kind             // kind: 0 sync, 1 irq, 2 fiq, 3 serror, 4 invalid
    mov  x0, sp                 // x0 = trap frame pointer
    bl   exc_handler
    EXC_RESTORE
    eret
.endm

.section .text
.balign 0x800
.global exc_vectors
exc_vectors:
    VEC vec_invalid     // Cur EL SP0:    Sync
    VEC vec_invalid     //                IRQ
    VEC vec_invalid     //                FIQ
    VEC vec_invalid     //                SError
    VEC vec_el1_sync    // Cur EL SPx:    Sync   (0x200) — where our traps land
    VEC vec_el1_irq     //                IRQ    (0x280) — M5
    VEC vec_el1_fiq     //                FIQ
    VEC vec_el1_serr    //                SError
    VEC vec_invalid     // Lower AArch64: Sync
    VEC vec_invalid     //                IRQ
    VEC vec_invalid     //                FIQ
    VEC vec_invalid     //                SError
    VEC vec_invalid     // Lower AArch32: Sync
    VEC vec_invalid     //                IRQ
    VEC vec_invalid     //                FIQ
    VEC vec_invalid     //                SError

vec_el1_sync: EXC_TRAMP 0
vec_el1_irq:  EXC_TRAMP 1
vec_el1_fiq:  EXC_TRAMP 2
vec_el1_serr: EXC_TRAMP 3
vec_invalid:  EXC_TRAMP 4
