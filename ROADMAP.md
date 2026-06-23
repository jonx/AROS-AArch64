# AROS-AArch64 — Roadmap

The big-picture arc, so the plan doesn't live only in a chat log. Phase 1 has its
own detailed milestone checklist in [PHASE1.md](PHASE1.md); this file is the map
above it and the rationale for the ordering.

## The one rule that shapes everything

An AI agent must be able to run the **whole loop unattended** — build → boot →
observe → judge — with no manual step. Every phase is chosen and ordered to keep
that true. It's also why the hard CPU work happens on QEMU, not on real Apple
hardware: QEMU exposes the machine programmatically (serial, QMP, gdbstub), and a
locked-down MacBook does not.

## Two independent hard problems — never worked at once

1. **The AArch64 CPU backend** — vectors, MMU, context switch, exception model.
   Greenfield, reusable on *every* ARM64 target, and the genuine contribution.
2. **Apple Silicon specifics** — undocumented hardware, custom interrupt
   controller, signed boot. Deferred as long as possible.

Phase 1 does #1 entirely on QEMU. Phase 2 reaches the Mac by going *hosted* (AROS
as a process on macOS, macOS owns the drivers) — which sidesteps #2 almost
entirely. Native-on-Apple-Silicon is explicitly a non-goal.

---

## Phase 0 — Toolchain & harness ✅ (done)

The autonomous loop itself. LLVM cross-toolchain (clang + ld.lld + lldb) + QEMU,
a `make run` that builds an AArch64 ELF, boots it headless on QEMU `virt`, and
emits one uniform PASS/FAIL verdict. Observation channels validated on the Mac:
serial markers, QEMU fault trace, lldb CPU-state. See [NOTES.md](NOTES.md).

## Phase 1 — AArch64 backend on QEMU `virt`  (in progress)

Bring the lowest layer up on 64-bit ARM, on a fully observable target. Milestones
**A0…M9**: loop → serial → C runtime → exception vectors → MMU → timer IRQ →
physical memory → context switch → shell → framebuffer. Detail + status in
[PHASE1.md](PHASE1.md). **Currently: M2 (C runtime).**

Exit criteria: AROS's bring-up primitives (the things `exec` + an AArch64
`kernel.resource` depend on) demonstrably working on QEMU, each gated by a green
loop.

## Phase 2 — Hosted on macOS  (planned)

Swap the platform layer from bare-metal-QEMU to a process running under macOS,
so macOS owns every driver. The payoff: AROS in a window on the MacBook Air.

- **Mach-O bootstrap** — a normal macOS executable that loads the AROS image
  (the AROSBootstrap equivalent), instead of a bare-metal `-kernel` blob.
- **Host-call ABI shim** — the make-or-break layer. Every AROS→host call (memory,
  threads, I/O) must honour Apple's AArch64 calling convention exactly. This is
  the boundary that historically killed the Darwin-PPC hosted port; treat it as
  the primary risk.
- **Display / input / sound via the host** — start with X11 (XQuartz) since the
  old Intel Darwin port had prior art there, then consider something more native.

Note: AArch64 binaries share their software island with the ARM Pi world, not the
big x86 AROS catalog — so app availability is a Phase-2/3 concern (recompiling
contrib apps), not something that comes for free.

## Phase 3 — Polish & upstream  (planned)

Shake out ABI edge cases, get a real application ecosystem building, and submit to
the `aros-development-team` tree per their CONTRIBUTING guidelines so it doesn't
bit-rot as a private fork. The standalone deliverable even if Phase 2 stalls:
**AROS's first AArch64 backend**, which the whole project currently lacks.

---

### Observability is the through-line

Each phase keeps a faithful "way of seeing" so the loop never needs a human:
QEMU's serial/QMP/gdbstub in Phase 1; macOS's own debugging + a window in Phase 2.
If a step can't be observed unattended, it gets redesigned until it can.
