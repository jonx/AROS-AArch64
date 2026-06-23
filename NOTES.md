# AROS AArch64 — Architecture and Decision Log

This is the project from the long conversation: give AROS a 64-bit ARM (AArch64)
backend, brought up on QEMU `virt` first, with my Apple Silicon MacBook Air as
the eventual hosted target. The non-negotiable constraint is that an AI agent
must be able to run the *whole* loop unattended — build, boot, observe, judge —
with no manual step in the middle. If a step needs a human, it doesn't scale.

## Architecture at a glance

- **Two independent hard problems, never worked at once.** (1) The AArch64 CPU
  backend (vectors, MMU, context switch, exception model) — greenfield, the real
  contribution. (2) Apple Silicon specifics — deferred. Phase 1 does #1 entirely
  on QEMU `virt`, where the machine is observable; Apple hardware is undocumented
  and gives the agent nothing to see, so it comes last.
- **The harness is the product right now.** `make run` → builds an AArch64 ELF →
  boots it headless on QEMU `virt` → observes → prints one uniform verdict block.
  Everything else hangs off this loop.
- **"Seeing" is generalized past screenshots.** The agent observes through
  whichever channel is faithful for the milestone — serial markers, QEMU's fault
  trace, lldb CPU-state, or (from M9) a framebuffer screendump — and always gets
  the same PASS/FAIL block back. It never needs to know which channel mattered.
- **Layout:** `boot/` (start.S + linker.ld, the bare-metal stub), `harness/`
  (run.sh, qmp.py, lldb-dump.sh — the loop and its observation channels),
  `Makefile` (agent entry points), `PHASE1.md` (milestones), this file.

## Key decisions

### Bring-up toolchain: LLVM, not GNU
clang cross-compiles to `aarch64-none-elf` out of the box and lldb is the native
macOS debugger (no gdb codesigning dance, which would have put a manual step in
the loop). The eventual *real* AROS port will use AROS's own GCC crosstools
regardless — so this choice only governs the bring-up phase, and convenience won.
Packages: `qemu`, `llvm` (clang + llvm-objcopy + lldb), and `lld` (separate brew
formula — `llvm` does not ship the linker).

### QEMU `virt` is the Phase-1 target, on purpose
It's the only target that exposes the machine programmatically — PL011 serial to
a logfile-backed socket, QMP for screendumps, a gdbstub for lldb. That's exactly
what makes the unattended loop possible and exactly what a real MacBook denies us.
So the "no manual steps" rule is itself an argument for doing the CPU work on
QEMU first.

### Clean exit via semihosting
A finished program calls semihosting `SYS_EXIT`, so a PASS exits in <1s instead
of waiting out the timeout. A hung boot is reaped by a watchdog. Without both,
the "unattended" claim is false — the loop would block forever on a bad boot.

### Marker discipline
Each milestone prints a unique serial marker (`[M1] …`, `[M2] …`). On an OS
bring-up there's no stack trace — markers are the agent's ground-truth "did it
get further than last time," and one-per-milestone lets it localize a regression.

### Ground against the real machine, not priors
Every hardware fact is verified against an authoritative source before code is
written against it — the DTB the actual QEMU binary emits (`make dtb`), the QEMU
board docs, the arm64 boot protocol — and recorded in `HARDWARE.md` with its
citation. This already paid for itself at M2: (1) the docs say the default GIC is
v3, but our exact invocation emits **v2** — the machine wins; (2) the boot
protocol says x0 = DTB, but QEMU's ELF `-kernel` path actually enters with
**x0 = 0**, which would have made M6's "read RAM from the DTB" silently dereference
null. Assumptions get *proven in the loop* (kmain prints the value) rather than
assumed. This is the project's standing rule: ground it, don't dream it.

## Trade-offs made under time pressure

- `start.S` parks secondary CPUs in a `wfe` spin rather than implementing PSCI
  CPU bring-up. Fine until we need SMP; revisit around the scheduler milestones.
- Fault detection in the harness is a grep over QEMU's `-d int` trace, with the
  benign semihosting pseudo-exception filtered out. Good enough; a determined
  bad path could still slip a fault past the regex. Tighten if it ever lies.
- The portable timeout is a bash watchdog because stock macOS has no GNU
  `timeout`. Works, but it's a TERM-then-KILL hack, not airtight.

## With more time, I would

- Add a `make test` that runs the whole milestone suite and reports a matrix, so
  a regression in M3 is caught while working on M7.
- Wire the framebuffer/screendump path (M9) earlier as dead code, so the "pixel"
  way of seeing is exercised before Wanderer actually needs it.

## Things to discuss in the walkthrough

- Why QEMU-first instead of attacking Apple Silicon head-on (observability + the
  undocumented-hardware wall — see the conversation that started this).
- The "all observation channels normalize to one verdict block" design, and why
  that's what makes an AI agent able to drive months of OS bring-up unattended.
- Where this plugs into real AROS: M2–M8 mirror what AROS's `exec` + the AArch64
  `kernel.resource` will need (vectors, MMU, context switch). Phase 1 is that
  backend in miniature, proven on QEMU, before grafting onto the AROS tree.
