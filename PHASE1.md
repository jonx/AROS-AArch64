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

### M2 — C runtime 🔜
Zero `.bss`, set up the stack, jump from asm into C, print from C over the UART
(a tiny `putc`/`puts`/`kprintf`). This is the boundary where bring-up stops being
assembly and becomes C — the layer most of AROS lives in.
**Observe:** `[M2] hello from C` marker. **Risk:** relocations / `adrp` ranges
once C code and a literal pool exist; keep the image small and position-correct.

### M3 — Exception vectors ⬜
Install `VBAR_EL1`, write the 16-entry vector table, deliberately trigger a
synchronous exception and report ESR/ELR/FAR from the handler, then recover.
**Observe:** marker + lldb CPU-state (this is the first milestone where the
failure mode is "we faulted," so the lldb channel earns its keep).

### M4 — MMU on ⬜
Build initial page tables (identity-map RAM + device range, a cached mapping for
RAM), set TCR/MAIR/TTBR, enable the MMU via SCTLR, and keep printing afterward.
**Observe:** marker that prints *after* `SCTLR.M=1`. **Risk:** the classic
turn-on-the-MMU-and-vanish; bisect with the lldb channel + QEMU's `-d mmu`.

### M5 — Timer interrupt ⬜
Bring up the GICv2/v3 distributor+CPU interface, enable the generic timer, take a
periodic IRQ, count ticks. First asynchronous event — the heartbeat a scheduler
needs.
**Observe:** marker showing tick count climbing.

### M6 — Physical memory ⬜
A simple page allocator over the RAM the DTB reports (or a hardcoded range to
start). The substrate `exec`'s memory pools sit on.
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
