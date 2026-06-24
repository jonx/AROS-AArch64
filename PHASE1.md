# Phase 1 — AArch64 backend on QEMU `virt`

The genuine contribution: bring AROS's lowest layer up on 64-bit ARM, on a fully
observable target, before any Apple Silicon work. Every milestone is gated by the
autonomous loop — `make run MARKER='[Mx]'` must go green with **zero manual steps**.
"Observe" names the faithful way of *seeing* for that milestone.

Status legend: ✅ done · 🔜 next · ⬜ planned

---

### A0 — The loop closes ✅
The harness builds an AArch64 ELF, boots it headless on QEMU `virt`, observes, and
emits one uniform PASS/FAIL verdict. PASS→exit 0, FAIL→non-zero, so the agent can
tell when it broke something. All text/state observation channels validated on the
Mac: serial markers, QEMU fault trace, lldb gdbstub CPU-state (with symbols).
**Observe:** the verdict block itself.

### M1 — Serial alive ✅
Bare-metal stub enters at EL1, inits the PL011 UART, prints `[M1] aarch64 serial
alive`, exits cleanly via semihosting. Confirmed entry EL = EL1.
**Observe:** serial marker. **Files:** `boot/start.S`, `boot/linker.ld`.

### M2 — C runtime ✅
`start.S` zeroes `.bss`, sets the stack, hands off to `kmain()` in C. C carries a
PL011 driver + a tiny `kprintf` (verified: `%d %u %x %lx %p %s %c`) that later
milestones reuse. Built `-mstrict-align -mgeneral-regs-only` (MMU off → Device
memory → aligned-only; FP not enabled yet). Confirmed **EL1** from C. Grounding
caught that QEMU's ELF `-kernel` enters with **x0 = 0, not the DTB** (HARDWARE.md).
**Observe:** `[M2] hello from C (EL1) x0=0x0` marker.
**Files:** `boot/start.S`, `boot/kmain.c`, `boot/linker.ld`.

### M3 — Exception vectors ✅
`boot/vectors.S` installs `VBAR_EL1` → a 16-entry × `0x80` table (2 KiB aligned);
each slot saves a trap frame and calls `exc_handler` in `boot/exc.c`. Deliberately
traps via `svc #0` (EC `0x15`, resume) and `brk #0` (EC `0x3c`, skip via `ELR+=4`).
EC values **grounded** from Linux `esr.h` and **verified live** (the handler prints
them); `SPSR=0x...3c5` independently confirms EL1h + DAIF masked. Names foreshadow
AROS `intvecs.s`/`intr.c`/`__vectorhand_*`.
**Observe:** `[M3] vectors ok` + the printed EC. **Files:** `boot/vectors.S`,
`boot/exc.c`, `boot/kern.h`.

### M4 — MMU on ✅
`boot/mmu.c` builds one L1 table (4KB granule, T0SZ=25, 1GB identity blocks:
device for the low GB incl. PL011/GIC, Normal-cacheable+exec for RAM), sets
MAIR/TCR/TTBR0, enables SCTLR.M|C|I — and *survives*. Then proves translation is
real: touching unmapped `0x8000_0000` faults with **EC=0x25, FAR=0x8000_0000,
DFSC=translation-fault-L1** (grounded ESR decode), handler recovers. Descriptor
bits grounded from Linux `pgtable-hwdef.h`. (`-mstrict-align` still set: early boot
before `mmu_init` runs MMU-off, so it stays load-bearing there.)
**Observe:** `[M4]` prints only after the deliberate fault recovers.
**Files:** `boot/mmu.c`.

### M5 — Timer interrupt ⬜
**Grounded (HARDWARE.md):** target is **GICv2** — GICD `0x0800_0000`, GICC
`0x0801_0000`; pin `-machine virt,gic-version=2` so it can't shift under us. Use
the **EL1 physical timer (CNTP), PPI 14 → INTID 30**. Enable, take a periodic IRQ,
count ticks. First asynchronous event — the heartbeat a scheduler needs.
**Observe:** marker showing tick count climbing.

### M6 — Physical memory ⬜
A simple page allocator. **Grounded:** x0 is NOT the DTB on our boot path, so to
size RAM from a device tree we must pass `-dtb` at a known address (or hardcode
the `0x4000_0000`+`-m` range to start). The substrate `exec`'s memory pools sit on.
**Observe:** marker: alloc/free N pages, checksum survives.

### M7 — Context switch ⬜
Save/restore the AArch64 register file + SP across two cooperatively-yielding
tasks. This is the heart of the exec scheduler's CPU dependency — the single most
reusable piece of the whole port.
**Observe:** marker: tasks A and B alternating a fixed number of times.

### M8 — Minimal shell ⬜
Read characters back *from* the UART (via the harness's serial socket — the
"drive," not just "observe", half of the channel) and echo/dispatch a couple of
commands. Proves input as well as output.
**Observe:** harness injects keystrokes over the socket, greps the echoed reply.

### M9 — Framebuffer ⬜
Add a GPU device (`ramfb`/virtio-gpu), draw a known pattern, and verify it with a
QMP screendump. First milestone where the faithful way of seeing is *pixels* —
build and exercise the screendump-compare tooling here, because Phase 2 (Wanderer
on macOS) runs on it constantly.
**Observe:** `make shot` → screendump → image compare.

---

After M9 the bring-up primitives exist on QEMU. **Phase 2** swaps the platform
layer from bare-metal-QEMU to hosted-on-macOS (a Mach-O bootstrap + the host-call
ABI shim — the boundary that historically killed the Darwin-PPC port), letting
macOS own every driver. That's when the MacBook Air becomes the payoff.
