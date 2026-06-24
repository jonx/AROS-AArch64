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

### Grounded: the state of AArch64 in AROS upstream (and what we mirror)
Checked the AROS tree (`/Users/user/Source/aros-upstream`, shallow clone) before
writing native code. Findings: `arch/aarch64-all` is **header-only scaffolding**
(8 files / 452 lines) configured as a *hosted-Linux* flavour
(`aros_flavour="emulation"`, `aarch64-linux-gnueabihf-`) that was never finished —
real ARMv8 atomics (`atomic_v8.h`), an incomplete/buggy `struct ExceptionContext`
(`r[29]; fp; sp; pc`, mislabels x30, no ELR/SPSR), and an empty `asm/mmu.h`. There
is **no native AArch64 kernel** — no boot, vectors, MMU, context switch, timer, or
`kernel.resource`. So "AROS's first *native* AArch64 backend" is accurate; we are
not duplicating finished work. At the graft we *reuse and fix* the existing
`aarch64-all` headers rather than inventing parallel ones.

What we mirror from the real `arm-native` port (20k lines) so Phase-1 code grafts
cleanly later: boot `start`→`kernel_cstart`; vectors `intvecs.s` + `intr.c`
(`__vectorhand_*`) installed by `core_SetupIntr()`; trap frame `struct
ExceptionContext`; MMU `mmu.c`/`core_SetupMMU`; switch `cpu_Switch`/`cpu_Dispatch`;
naming `cpu_*` / `core_*` / `Krn*`; split `rom/kernel` ↔ `arch/<cpu>-all` ↔
`arch/<cpu>-native`. We adopt the *names and shapes* now, not the whole machinery.

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

### H3 grounding: Apple's arm64 ABI divergences (the host-call boundary)
The hosted port's scariest layer is the host-call shim — AROS code (built to
generic AAPCS64 by its own crosstools) calling macOS libc, which follows Apple's
arm64 ABI. I grounded the divergences not against Apple's HTML doc (JS-rendered,
unfetchable as text) but against the **stronger** source: the exact instructions
this machine's own `clang` emits (`-O0 -S` on snprintf/9-arg calls — see the H3
commit). The four divergences from AAPCS64, all confirmed empirically:

1. **Variadic args go on the STACK, one 8-byte slot each** — even when arg
   registers are free. `snprintf("%d %d %d",11,22,33)` `str`s the three ints to
   `[sp],[sp+8],[sp+16]` while `x5..x7` sit unused. *This is the printf killer:*
   a hosted AROS cannot `bl _printf` with varargs in registers.
2. **Variadic FP rides the same integer stack slots** — a `double` is `str d0,
   [sp+8]`, no separate FP save area. So one integer marshalling path carries
   `%d`, `%p` and `%f` alike (pass the double's bit pattern).
3. **Non-variadic stack args pack to natural size** (an `int` spilled past x7 is
   4 bytes at `[sp]`, the next at `[sp+4]`; `char`@0/`short`@2/`char`@4) — not
   the 8-byte slots AAPCS64 uses. Bites only at >8 args; documented, not shimmed.
4. **The caller sign/zero-extends sub-word args to 32 bits** (`ldursb` before the
   call for a `signed char`).

The shim (`hosted/abishim.S`) is the hand-written marshaller for #1/#2 — exactly
the code AROS's host-printf bridge must contain. Proven in the loop (`make
hosted-abi` → `[H3]`): the correct path prints `11 22 33` / `7 3.5 Z` / `<AROS>`;
a deliberately-naive register-passing control prints `0 0 0`, so the divergence is
shown to be real *and* bridged. This is the boundary that killed Darwin-PPC; it's
now de-risked the same cheap way as H1/H2 — a spike, grounded, verified live.

### H4: the AROS exec scheduler, hosted (grounded against the real tree)
After H2 proved hosted preemption, I refused to leave it an ad-hoc round-robin.
Read the actual AROS scheduler — `arch/arm-native/kernel/kernel_scheduler.c`
(`core_Schedule`/`core_Switch`/`core_Dispatch`), `kernel_cpu.c`
(`cpu_Switch`/`cpu_Dispatch` + `STORE_/RESTORE_TASKSTATE`), the exec stubs in
`rom/exec/{dispatch,schedule,reschedule,switch}.c`, and `struct Task` +
`TS_*` in `include/exec/tasks.h` — then rebuilt the hosted scheduler to those
exact names, signatures and contracts (`hosted/exec.c`). The macOS main thread is
modelled as a low-priority "boot" anchor task; the SIGALRM handler is
`core_ExitInterrupt`. Stacks come from `mmap` with real `tc_SPLower/SPUpper`
bounds (the stack-probe check in `core_Switch` is live, not decoration). Proven in
the loop (`make hosted-exec` → `[H4]`): two pri-1 tasks round-robin within ~2%,
two pri-0 tasks starve — i.e. AROS's strict-priority + equal-priority-FIFO
semantics, reproduced exactly. This is the scheduler *spine* both the native and
hosted ports share, now exercised on the MacBook before the graft.

**Grounding caught a real upstream bug to fix at the graft:** AROS's
`arch/aarch64-all/include/aros/cpucontext.h` defines `struct ExceptionContext` as
`{ IPTR r[29]; IPTR fp; IPTR sp; IPTR pc; }` — it mislabels x30 as `fp`, omits
SPSR_EL1 entirely, and has no FP/NEON pointer. Our Phase-1 trap frame
(`boot/kern.h`: `x[31]` + `elr` + `spsr`) is the correct shape. When we graft, we
*fix* that header rather than inherit it — a concrete, grounded AROS contribution.

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

## Phase 1 retrospective (stepping back)

**What we built:** a complete *native* AArch64 bring-up on QEMU virt — boot → C
runtime → exception vectors → MMU → timer IRQ → page allocator → cooperative
scheduler → shell → framebuffer. ~840 lines across 12 files, each milestone
grounded against an authoritative source and verified live in the loop.

**What's genuinely solid:** the autonomous loop (build→boot→observe/drive→verdict,
all channels: serial, fault trace, lldb, framebuffer, plus injected input + a
regression matrix); the grounding discipline, which caught three real errors I'd
otherwise have shipped (x0≠DTB, GICv2-not-v3, AArch32-vs-A64 semihosting); and a
clean file-per-concern layout that mirrors AROS's `arch/<cpu>-native`.

**Known simplifications (honest debt, not bugs):**
- Single core — secondaries parked, no PSCI `CPU_ON`/SMP.
- Identity map only — no virtual address spaces, VA==PA, one L1 table.
- ~~Cooperative scheduler~~ → **M10 made it preemptive**: the timer IRQ saves a
  full trap frame and round-robins tasks (no yields). Still single-core, no task
  priorities/blocking, no per-task address space — a real scheduler is more.
- `pmm` is a flat free-list; no contiguous alloc; RAM size hardcoded to `-m 512`
  (no DTB parse yet).
- Framebuffer in `.bss`, no cache maintenance (fine under QEMU's no-cache model;
  real hardware would need a clean-to-PoC).
- Everything at EL1 — no EL0/userspace, no FP/NEON.

**Strategic insight worth being honest about:** Phase 1 is the *native* CPU
backend. For the original "AROS on my MacBook" **hosted** dream, the directly
reusable pieces are the toolchain, the AArch64 ABI/calling-convention knowledge,
and the context switch (`switch.S`) — *not* the bare-metal drivers (MMU, GIC,
vectors, ramfb), because macOS provides those. So the native track (what we have)
and the hosted track (the MacBook payoff) share a spine — the AArch64 `exec` /
`kernel.resource` logic — but diverge on the driver layer. Both still require the
**graft**: turning these primitives into actual AROS `cpu_Switch`/`core_*`/`Krn*`
functions wired into `rom/kernel` + `exec.library`. That graft is the real Phase-2
mountain, native or hosted.

## Things to discuss in the walkthrough

- Why QEMU-first instead of attacking Apple Silicon head-on (observability + the
  undocumented-hardware wall — see the conversation that started this).
- The "all observation channels normalize to one verdict block" design, and why
  that's what makes an AI agent able to drive months of OS bring-up unattended.
- Where this plugs into real AROS: M2–M8 mirror what AROS's `exec` + the AArch64
  `kernel.resource` will need (vectors, MMU, context switch). Phase 1 is that
  backend in miniature, proven on QEMU, before grafting onto the AROS tree.
