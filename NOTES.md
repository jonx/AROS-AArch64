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

### H5: the AROS exec memory model, hosted (grounded against the real tree)
Same discipline as H4, applied to memory. Read the actual allocator —
`rom/exec/{allocate,deallocate}.c` and the `stdAlloc`/`stdDealloc` core in
`rom/exec/memory.c`, plus `struct MemHeader`/`MemChunk` in
`include/exec/memory.h` — and reproduced it faithfully in `hosted/mem.c`:
first-fit walk of a single-linked free list, split-and-return-first on a partial
fit, address-ordered coalescing insert on free (merge prev if `p1+bytes==p3`,
merge next if `p4==p2`), `MEMCHUNK_TOTAL`=16 rounding, `MEMF_CLEAR`/`MEMF_REVERSE`,
`FreeTwice` overlap detection. The region is one `mmap` — macOS owns the pages,
exec owns the policy (the hosted memory story). Verified in the loop with a
stress battery and hard invariants (free-list ordered/non-overlapping/in-bounds,
`sum(chunks)==mh_Free`, full coalesce back to a single chunk after free-all).
Deliberately dropped from the spike: the managed-mem (`MemHeaderExt`) path and the
`mhac` index cache — a lookup accelerator, not a correctness feature. With H4
(scheduler) this gives the two load-bearing `exec` subsystems, hosted and proven,
before the graft.

### H6: composition (H4+H5) caught a real bug isolated spikes couldn't
Tied the scheduler (H4) and allocator (H5) into one process (`hosted/kern.c`):
tasks are `AllocMem`'d from the heap and scheduled preemptively, with
`Forbid()`/`Permit()` (AROS dispatch-disable) guarding the allocator. The first
cut *failed* — the free list ended 512 bytes inconsistent (`free_sum < mh_Free`).
Root cause, and the lesson: **`forbid_cnt` is `volatile` but `struct MemHeader`
is not, and C only orders volatile-to-volatile accesses.** At `-O2` the compiler
hoisted/sank the non-volatile free-list writes *outside* the Forbid window, where
a SIGALRM caught the list half-updated. The fix is a compiler barrier
(`asm volatile("" ::: "memory")`) in Forbid/Permit, tying the allocator's memory
ops to the window; a single underlying thread means no CPU fence is needed for
same-core signal delivery. This is precisely the class of bug a hosted port must
get right, and it only appears under composition — neither the scheduler nor the
allocator spike could surface it alone. Also fixed: shutdown must respect Forbid
too (don't snapshot the system mid-critical-section). Verified stable across
repeated runs (`make hosted-kern` → `[H6]`).

**Size note (slow-ai):** `hosted/kern.c` is ~330 lines — over the 200-line flag,
but it's a deliberate integration milestone (two subsystems + the glue) kept in
one runnable file to match the harness's one-binary-per-marker design. Each
subsystem is clearly sectioned; at the real graft these become separate AROS
modules anyway.

### H7: the host display, observed unattended (the M9 trick, hosted)
Applied "macOS owns the drivers" to the display. AROS draws into a framebuffer
`AllocMem`'d from its own heap; the host presents it by encoding to PNG via
macOS ImageIO/CoreGraphics. The ImageIO call sequence was grounded against the
live toolchain first (a scratch `pngprobe` that I compiled, ran, and *read back*
as an image) before writing the driver — same ground-it-don't-dream rule. Crucial
for the project's constraint: the agent observes the screen through a PNG file it
can read, so "seeing pixels" stays unattended, exactly like M9's QMP screendump.
The scene is pixel-asserted (four-colour squares exact, title bar present, a white
'A'-crossbar pixel, bluish sky) so there's a real PASS/FAIL behind the image, not
just "a file exists". An actual on-screen Cocoa window is deferred on purpose: a
live window can only be verified unattended via `screencapture`, which needs macOS
Screen-Recording (TCC) permission — a manual approval that violates the no-manual-
steps rule. Render-to-PNG sidesteps that entirely; the window is a later
human-facing nicety, not a loop dependency.

### H8: the library/LVO mechanism — and a host-risk that ISN'T one
Before spiking the library system I asked the host-specific question: does AROS
build its library jump vectors as *runtime-generated code*? If so, doing that
hosted hits Apple Silicon's W^X / MAP_JIT wall (you can't just write executable
memory). Grounded the answer in the AROS tree: 32-bit ARM and m68k DO use
executable `FULLJMP` vectors — but 64-bit native arches do not.
`arch/x86_64-all/include/aros/cpu.h` says it outright: *"On x86-64 we use vector
table consisting only of pointers. We do not include jump code in them."*
(`__AROS_USE_FULLJMP` is off; `FullJumpVec` is only for `LoadSeg` headers.)
AArch64 follows the same 64-bit convention. **So the library system is plain
function pointers + indirect calls — no codegen, no W^X wall.** H8
(`hosted/library.c`) proves it live: `MakeLibrary` builds the `JumpVec` table
below the base, calls dispatch through `__AROS_GETVECADDR`, and `SetFunction`
hot-patches a vector (contract from `rom/exec/setfunction.c`: negative byte
offset `-LVO*LIB_VECTSIZE`, `Forbid()`, return old vector). This is the grounding
discipline catching a *non*-problem before I built a workaround for it — as
valuable as catching a real one.

### H9: Wait()/Signal() — making the scheduler a real exec
H4/H6 round-robin tasks but they never block; a real exec is built on tasks that
*wait* (for a message, a device, a semaphore) and get *signalled*. H9 adds the
genuine AROS state machine (`hosted/signal.c`), grounded against
`rom/exec/{wait,signal}.c`: `Wait` sets `TS_WAIT` + `tc_SigWait`, enqueues on
`TaskWait`, and yields; `Signal` ORs into `tc_SigRecvd` and, if the target waited
on those bits, moves it back to `TaskReady`. The hosted realisation of "yield":
once a task is `TS_WAIT`, `core_Switch` won't re-queue it (it only re-queues
`TS_RUN`), so the next timer tick parks it off the ready list — that *is* blocking.
A volatile re-read of `tc_State` in the wait loop defeats the compiler caching the
state in a register (same family of bug as the H6 barrier). Verified with a
lock-step producer↔consumer ping-pong (100=100, each blocking 100×) and a
free-runner that does ~1000× the work — proving the pair really yield. No lost
wakeups: `Wait` checks `tc_SigRecvd` before blocking, so a `Signal` that races
ahead of the `Wait` is still seen.

### H10: message ports — the exec IPC layer (and device-I/O shape)
Layered the real AROS port mechanism on H9's Wait/Signal (`hosted/msgport.c`),
grounded against `rom/exec/{putmsg,getmsg,waitport}.c`. `PutMsg` = `AddTail` then
`Signal(mp_SigTask, 1<<mp_SigBit)`; `WaitPort` blocks on the port's signal bit
until the queue is non-empty; `GetMsg` = `RemHead`; `ReplyMsg` = `PutMsg` back to
`mn_ReplyPort`. The point: this is the exact shape of AROS device I/O (send an
IORequest to a port, block for the reply), so proving it hosted proves the I/O
path a hosted AROS uses to reach host resources. Verified with a client↔server
request/reply loop (server squares each request): ~124 round-trips, server
processed exactly as many (no message loss), zero wrong replies, both tasks
blocking on their ports under preemption. With H4/H5/H6/H8/H9 this rounds out the
essential exec: scheduling, memory, libraries, signals, messages.

### H11: a device backed by a real macOS file — the thesis, end to end
This is the Phase-2 mission statement made concrete: *macOS owns the drivers,
AROS reaches them via standard exec I/O.* `hosted/device.c` runs the real exec
I/O path — a client builds an `IOStdReq`, `DoIO()` does `BeginIO` (`PutMsg` to the
device's port) then `WaitIO` (block for the reply), and a device task performs the
actual `pread`/`pwrite` on a real file — grounded against `exec/io.h` and
`rom/exec/doio.c`. It composes the whole stack: scheduler (H6) + Wait/Signal (H9)
+ message ports (H10), and the host syscalls run on a switched task stack under
preemption (the H1 property, now at the device layer). Verified two independent
ways: the client checks each read == its write, and main then re-reads the file
*through the host* to confirm the bytes physically landed (128 bytes all equal to
the last round's pattern). 62 round-trips, zero errors. The `(struct Message *)io
== &io->io_Message` identity (io_Message first in IOStdReq) is what lets a replied
message be cast straight back to its IORequest — faithful to AROS.

### H12: exec.library boot — the capstone that ties it all together
The 11 spikes each proved one mechanism; H12 (`hosted/execboot.c`) assembles them
into a single coherent miniature exec, the AROS way: `exec.library` is the hub,
and its services (`AllocMem`/`FreeMem`, `Signal`/`Wait`, `AddTask` + the scheduler)
live in the negative-offset LVO jump-vector table below `SysBase`, reached by the
tasks through the library base — exactly the `__AROS_GETVECADDR(SysBase, lvo)`
dispatch that defines AROS. The faithful detail that matters: this is not "call the
functions directly", it's "call them through the vector table", which I *prove* by
`SetFunction`-instrumenting `LVO_Signal` and showing its counter (~398) tracks the
ping-pong handshakes. Two tasks AddTask'd via LVO run a lock-step Signal/Wait
exchange, allocating buffers via `AllocMem` LVO, scheduled preemptively. It is the
"a tiny AROS exec actually runs on the MacBook, every call going through the real
exec hub" demonstration — the satisfying close of the spike phase.

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

## Phase 2 retrospective (stepping back)

**What we built:** eight standalone spikes (`hosted/`, `make hosted-test` all
green) that de-risk the entire *host-facing* surface of a hosted AROS on Apple
Silicon, each grounded against an authoritative source and verified live:
foundation + preemption (H1/H2), the host-call ABI boundary (H3), the real `exec`
scheduler and memory models and their composition (H4/H5/H6), the host display
(H7), and the library/LVO mechanism (H8). The scariest historical risk — the
cross-ABI host call that killed Darwin-PPC — is retired.

**What's genuinely solid:** the hosted loop is as unattended as Phase 1 (run the
Mach-O binary, read stdout or a PNG, get one verdict), and the grounding
discipline kept paying:
- it *retired* real risks (Apple's variadic-args-on-stack ABI — H3);
- it *caught a real composition bug* nothing else could (the `Forbid` compiler
  barrier — `volatile` orders only volatile-to-volatile, so `-O2` sank allocator
  writes outside the critical section — H6);
- it *cleared a non-risk before I built a workaround* (64-bit AROS library vectors
  are data pointers, so no Apple-Silicon W^X / MAP_JIT wall — H8).

**Honest scope (what these spikes are and aren't):** they are faithful
reproductions of AROS's *shapes and contracts*, hand-written in standalone files
(one binary per marker, to fit the harness). They are NOT the AROS tree compiled
and running. Deliberate simplifications, noted not faked: single underlying thread
(so `Forbid` needs only a compiler barrier, no CPU fence); allocator drops the
managed-mem path + index cache; scheduler omits signals/`Wait`, SMP, ETask CPU
accounting; the display is render-to-PNG, not an on-screen window; LVO numbers are
illustrative. Each note says what was dropped and why.

**The mountain, named honestly:** every *hosted* unknown is now answered, so the
remaining work is no longer spike-able — it's the **graft**: build AROS's own
crosstools for `aarch64-darwin`, drive its `configure`/`mmake` to emit a hosted
binary, fix the unfinished `arch/aarch64-all` (e.g. the wrong `ExceptionContext`),
and bootstrap the real `exec.library` on these primitives. That's large-scale
integration in the AROS tree, not a session-sized spike — and it's the next thing
to ground rather than reimplement.

## 2026-06-24 — Hosted AROS BOOTS on Apple Silicon

The graft is no longer "the next thing to ground": **real AROS now loads, relocates
and runs on this Mac.** `exec.library` (175KB) + `kernel.resource` (70KB) +
`hostlib.resource` come up with valid `SysBase`/`KernelBase`; a SIGSEGV is caught via
the `cpu_aarch64.h` host-signal→AROS-trap bridge and AROS prints its AArch64 register
dump + native Guru alert. It halts at a cold-start trap (no `dos.library` in a
3-module kickstart). Run it: `~/aros-darwin/run.sh`. Full map: `graft/WORKFLOW.md`;
upstream friction (25 items): `graft/UPSTREAM-NOTES.md`.

### Key decisions / trade-offs under the "make it boot" push

- **`-mcmodel=large` for the kickstart modules, instead of a GOT in the loader.**
  AArch64 clang routes *weak* symbols (`__aros_libreq_SysBase`) through the GOT even
  with `-fno-pic`, and the simple bootstrap loader has none. Large model emits
  absolute `movz/movk` (only `MOVW_UABS`/`ABS64` relocs). Trade-off: bigger modules
  + a full recompile, for a much simpler, self-contained loader (no near-code GOT).
- **Map the AROS RAM pool `RW`, not `RWX`** (and drop `MAP_32BIT`) on Apple Silicon.
  W^X refuses a one-shot RWX anon `mmap` even with JIT entitlements; early boot runs
  from the kickstart RO region anyway. Consciously deferred: executing code *loaded
  into* the pool (LoadSeg) needs the W^X-aware path later.
- **Force-load a hand-built static C runtime (`libkrnmem.a`).** The proper fix is for
  the freestanding modules to link `stdc.static` so its *strong* `memset`/`strcmp`/…
  win over the weak StdC stubs; archive semantics wouldn't pull them, so I carved the
  mem/str/format dependency-closure into `libkrnmem.a` and `--whole-archive`'d it.
  Trade-off: assembled by hand in the build dir — needs a real mmake rule.
- **A deliberately minimal 3-module kickstart** to *get a boot* and see AROS's own
  output, accepting the cold-start halt. The rest of the OS is the next body of work.

### With more time, I would (now)

- Give `libkrnmem.a` a real mmake rule (or make the kernel/exec/hostlib links pull
  `stdc.static` strong-over-weak cleanly) and find the proper `configure` home for
  `-mcmodel=large` / `-D__arm64__`, so a clean checkout reproduces the boot.
- Implement `arch/aarch64-all/stdc/setjmp.s` (still a weak stub).
- Walk the cold-start: add `dos.library` + the boot module set, chase the next traps.

## 2026-06-25 — [J5b] control flow in the 68k JIT (a real loop, real condition codes)

Scoped increment of the `[J5]` decoder mountain. Translated a self-contained 68k loop
`moveq #0,d0 ; moveq #5,d1 ; L: add.l d1,d0 ; subq.l #1,d1 ; bne.s L ; rts` (→ d0=15,
5 iterations) in ONE `jit_region` with an **internal backward branch**, real condition
codes, verified byte-exact against an independent from-scratch interpreter.

### Key decisions / trade-offs

- **The branch reads real NZCV straight from the `subs`.** `subq.l #1,d1` is emitted as
  `subs w_d1,w_d1,#1` (the flag-setting subtract, `A64.h:320`); the conditional
  `bne.s` is an AArch64 `b.ne` (`A64_CC_NE`, Z=0) that consumes those flags directly —
  the AArch64 NZCV *is* the live 68k branch condition. No CCR=0 shortcut.
- **68k CCR recomputed with NON-flag-setting ops to preserve `subs`→`b.ne` adjacency.**
  Right after the `subs`, before the branch, the block derives the 68k CCR bits
  (N from result bit31, Z from result==0, C/X from the subtract borrow rule, V from
  signed overflow) using `cset`/`orr`/`str` etc. — none of which touch NZCV — so the
  branch still sees the `subs` flags. The asserted `state->ccr` is therefore the real,
  full N/Z/V/C/X, matching the interpreter's subtract flag rule. (68k subtract C = NOT
  AArch64 C, since ARM sets C on no-borrow; handled explicitly.)
- **Single region, internal backward branch.** The whole loop is emitted once; the
  loop-top is a label (a word index) inside the emitted code and the `b.ne` offset is
  `loop_top_idx − bne_idx` (negative). `b_cc`/`b` take signed word offsets and
  `ASSERT_OFFSET` is a no-op at `-O2`, so two's-complement backward branches encode
  cleanly. No cross-region chaining (deferred to `[J5c]`).
- **Watchdog turns an infinite loop into FAIL.** 10s SIGALRM. The negative control
  breaks the Z computation (emit `b.al` / wrong condition) to force divergence or a
  caught hang, proving the iteration/termination asserts bite.
- **No new Emu68 file** — only existing `A64.h` encoders (`add_reg`, `subs_immed`,
  `b_cc`, `b`, `cset`, ldr/str, `mov_immed_u16`). Exhibit-B grep unchanged.

### With more time (→ [J5c])

Cross-region block chaining + an instruction cache, full `Bcc`/`DBcc` condition
coverage, forward branches across blocks, real `jsr`-through-vector decode from a
stream, library calls from the running program, and OUR register allocator (still
memory-backed here).

## 2026-06-25 — [J5n] PLAN: the DIAGNOSTICS subsystem (crash bundles) — gates, not yet code

A faults-are-never-silent subsystem for the 68k JIT: every fault produces one
self-contained, shareable **crash bundle** (`tar.gz`) with everything to reproduce
and diagnose. INTERNAL/host-side; the frozen seam (jit_region API, struct M68KState
layout, the [J3] LVO contract, the [J5i] exception model) is NOT touched.

### Gate 1 — reference summary (what the existing code establishes)

- **The fault funnel already half-exists.** `j5d_engine.c` routes every fault through
  `raise_exception(sb, st, vnum, frame_pc, &handler, errbuf, errlen)` (vectors 2/3/4/5/
  32+n) and through `RFAIL(msg)` (clean dispatcher errors). The dispatcher main loop
  (`j5d_run`, lines 821-1054) decodes each terminator and computes the next PC — this is
  the one place a global instruction counter, the diff-lockstep step, and replay-to-N
  all belong. `g_stats` already tracks per-block/insn counts.
- **The oracle is `j5d_interp_run`** (j5d_interp.c) — same signature as `j5d_run`, its own
  state + sandbox. It is the basis for the differential mode (run both in lockstep, trap on
  first divergence). It already supports the exception log via `j5d_interp_set_exc_log`.
- **The host-signal bridge shape is `graft/cpu_aarch64.h`** — `Xn(ctx,n)`, `FP/LR/SP/PC/
  CPSR(ctx)`, `GPSTATE`/`FPSTATE`, and `struct ExceptionContext`. On Darwin arm64 the
  mcontext exposes `__ss.__x[0..28], __fp, __lr, __sp, __pc, __cpsr` (non-opaque). I mirror
  exactly this to dump host x0–x30/sp/pc from a signal `ucontext`.
- **The loader skips `HUNK_SYMBOL`/`HUNK_DEBUG`** (j4_loader.c:223-249). The symbol hunk
  format is verified: `[BE32 name-len-in-longs][name padded to longs][BE32 value]`, zero
  length terminates; value is hunk-relative (add the hunk base, like a reloc). vasm WITHOUT
  `-nosym` emits a real SYMBOL hunk (confirmed: `mul.s` → symbol `loop` value 0x6).
- **Determinism holds:** single 68k execution, sandbox, deterministic stub OS, no host
  threads. So a global instruction number #N is reproducible and replay-to-N is sound.
- **Test/build convention:** one standalone `jXX_test.c` per spike, a Makefile target that
  darwinizes the emu68 decoders into `build/emu68-darwin/` then clang-links the OURS files +
  the test, run via `harness/run-hosted.sh '[J5n] PASS'` with a SIGALRM watchdog.

### Gate 2 — change-set (one line per file)

NEW (all OURS, AROS-licensed, no Emu68 source copied):
- `hosted/jit68k/j5n_diag.h` — the diagnostics API: `j5d_fault(kind,detail,ctx)` funnel,
  bundle writer, flight-recorder ring, symbol map, diff/replay config, host-signal net.
- `hosted/jit68k/j5n_diag.c` — implements the funnel, REPORT.txt (two-level), bundle dir +
  `tar -czf`, the LOUD banner, core.snapshot, program.exe+sha256, MANIFEST/REPRODUCE,
  flight recorder, 68k+host register dumps, both stacks (68k return-stack walk + native
  `backtrace()`), the SIGSEGV/SIGBUS/SIGILL/SIGFPE handlers + `sigaltstack`.
- `hosted/jit68k/j5n_symbols.h/.c` — parse HUNK_SYMBOL (+ HUNK_DEBUG if usable) into a
  PC→symbol map; `j5n_sym_lookup(pc)` for the call-stack/report. Loader stays unchanged
  (I parse the file buffer independently, so j4_loader.c is not modified).
- `hosted/jit68k/j5n_test.c` — the `[J5n]` driver: trigger each fault kind, assert a bundle
  with REPORT.txt+core.snapshot+program.exe+MANIFEST.txt+REPRODUCE.txt + banner + REPORT
  contents; differential trap with diverge.txt; replay-to-N lands at #N; host-signal net;
  regression note; bundle cleanup.
- `apps68k/diagfault.s` (small) — a labeled program that deliberately faults (div0 / illegal
  / OOB) at a known instruction, assembled WITH symbols, to exercise symbol mapping +
  replay-to-N on a real hunk. Built by a tools step; `.exe` committed.

EDIT (engine — additive hooks only, behind a config struct; off the hot path):
- `hosted/jit68k/j5d_engine.c` — (a) a global instruction counter `++` per dispatched 68k
  instruction; (b) call the diag funnel at each `raise_exception`/`RFAIL` site (one wrapper
  macro, so all paths route through `j5d_fault`); (c) per-instruction hook for diff-lockstep
  + replay-to-N break, gated by a config pointer that is NULL unless a mode is enabled; (d)
  push (PC,opcode) into the flight-recorder ring. NO struct/seam change — `j5d_run`'s
  signature is unchanged; the diag config is set via a separate `j5d_set_diag()` like the
  existing `j5d_set_exc_log()`.
- `Makefile` — add `hosted-jit68k-j5n` target (darwinize + link OURS + j5n_*), and a tools
  step to assemble `diagfault.exe` with symbols.

### Gate 3 — data-flow paragraph

The engine runs deterministically; a file-scope `g_insn_number` increments once per
dispatched 68k instruction in `j5d_run`. A diag config (set by `j5d_set_diag`, NULL = the
fast path the whole corpus uses) carries: the loaded program bytes + sha + sandbox handle,
the symbol map, the flight-recorder ring, and optional diff/replay parameters. On ANY fault,
every `raise_exception`/`RFAIL` site (and the host-signal handlers) calls `j5d_fault(kind,
detail, host_ctx)`. The funnel snapshots M68KState + sandbox image, walks the 68k return
stack (A7 + saved return addresses → symbols), captures the native `backtrace()`, dumps host
registers from the signal `ucontext` (or "no host ctx" for a clean in-band fault), drains the
flight recorder, writes the bundle dir, `tar -czf`s it, prints the banner, and returns. In
diff mode, before each instruction the oracle steps one instruction over its mirror state and
the engine compares register/CCR/relevant memory; first divergence writes `diverge.txt` then
faults. In replay mode, the run breaks exactly when `g_insn_number == N`. The bundle's
`REPRODUCE.txt` records `run-to #N` + `git rev-parse HEAD` + build config, so another machine
re-runs the same program to the same fault.

### Gate 4 — trade-offs, uncertainties, mitigations

- **Lockstep granularity = per 68k INSTRUCTION, but the JIT executes per BLOCK.** The JIT
  doesn't expose mid-block state. Mitigation: run the oracle instruction-by-instruction and
  compare at BLOCK boundaries (the JIT's natural observation points — exactly where state is
  flushed to M68KState, per the seam). I locate the first diverging instruction by, on a
  block-level mismatch, re-running the oracle instruction-stepped through that block to name
  the exact insn. This is honest: I'll document "block-boundary detection, instruction-
  precise localization." For the injected-divergence test I can force a known mismatch.
- **`j5d_fault` from a signal handler must be async-signal-safe-ish.** Mitigation: use
  `sigaltstack`; do the heavy bundle writing with low-level `write`/`open` where practical,
  accept that this is a crash path (we are already dying) and a best-effort bundle is the
  goal; never re-enter the JIT. Document the async-signal caveat.
- **Symbol/line info:** vasm emits HUNK_SYMBOL (label→offset) reliably; HUNK_DEBUG line info
  is toolchain-dependent and may be absent. Plan: symbols-always, line-info-if-present,
  report honestly what was obtained. The corpus is stripped, so the symbol demo uses a
  purpose-built labeled `diagfault.exe`.
- **Real host-signal net (E in INTERFACE.md) is an AROS-integration row.** I install the
  handlers around the host-side test execution so a genuine out-of-sandbox HOST access is
  caught and bundled (the spec's explicit ask) — but the production SIGSEGV→`j5d_raise_
  exception` wiring inside AROS stays the owner's track; I do not fake it.
- **Seam unchanged:** I add a side-channel `j5d_set_diag()` (mirrors `j5d_set_exc_log()`),
  never touch struct M68KState/j5d_m68k_state layout, jit_region.h, the [J3] contract, or the
  [J5i] model. The engine edits are additive and NULL-gated.

### Bundle root README.txt (added at coordinator/user request)
A plain-language `README.txt` at the bundle ROOT for a non-expert who just hit the crash:
one line on what it is, the ONE action (send the whole .tar.gz), a one-line plain gloss of
each file, and a short "For the developer" section (diff pins the wrong instruction; the
coordinate+snapshot reproduce it via `run-to #N`; the two-level 68k+host dump says program-
bug vs JIT-bug). Complements MANIFEST.txt (the precise index); README.txt is the friendly
overview. The crash banner points at the archive AND says "open README.txt inside if unsure."

### Deferred (honest, stated up front)
- Snapshot-LOAD/inspect mode (load `core.snapshot` and dump): include if tractable, else
  documented as deferred (the snapshot is still WRITTEN + reload-described in MANIFEST).
- True per-instruction JIT lockstep (would need block-splitting); using block-boundary
  detection + oracle instruction-localization instead.

### [J5n] DONE — what shipped, and the decisions that landed during the build

Built + green: `make hosted-jit68k-j5n` prints `[J5n] PASS` (harness verdict PASS). The
binary actually printed the LOUD banner with the absolute bundle path, the differential trap
at the exact instruction, and the replay-to-N landing on #N. A sample bundle's
README.txt/REPORT.txt were cat'd and the program SHA-256 round-trips (bundle digest == the
committed diagfault.exe). The whole corpus + `[J1]`–`[J5m]` re-ran green; the frozen seam is
git-confirmed unchanged (no diff to `jit_region.h` / `j5d_jit68k.h` / the `j3_*` contract).

Decisions that landed:
- **The funnel routes through `j5d_fault`; the engine stays NULL-gated.** All fault sites
  (`raise_exception` failures, `RFAIL`, and a NEW `J5N_UNHANDLED` check) funnel only when a
  diag config is registered (`j5d_set_diag`, mirroring `j5d_set_exc_log`). With no diag the
  engine is byte-for-byte as before — that's why every existing marker stayed green.
- **`J5N_UNHANDLED` was the key insight for correct fault kinds.** The `[J5i]` model
  "succeeds" raising an exception even when the vector is 0 (uninstalled) — it dispatches to
  PC 0 and cascades to a bus error. I must NOT change `[J5i]`. So a diag-only check fires the
  funnel at the ORIGIN (div0/illegal/bus with the right kind) BEFORE the cascade masks it.
  No-op when diag is NULL, so `[J5i]` is untouched.
- **Optional dependency via weak symbols.** The other `[J5*]` tests link `j5d_engine.c` but
  NOT `j5n_diag.c`. I gave the engine WEAK stub definitions of the four diag hooks it calls;
  `j5n_diag.c`'s strong defs win when linked, the weak no-ops satisfy the linker otherwise.
  This is what keeps the diagnostics genuinely optional + the existing targets unchanged.
- **The differential is block-boundary + oracle-localized, as planned.** `j5d_run_diff` runs
  the JIT block-by-block and advances the instruction-precise interp oracle to each boundary
  (a `stop-at-PC` side-channel I added to the interp), comparing there. The injected
  divergence (JIT bridge returns a different d0 than the oracle bridge — a separate
  `ref_lvo`) traps deterministically at 0x21000A.
- **#N alignment was the subtle bug.** The engine counts per-block; the oracle per-
  instruction. I made the engine count `body_insns` + 1-per-terminator so its #N equals the
  oracle's instruction index, so the crash #N and `JIT68K_RUNTO=N` land on the same PC.
- **Chaining gated off under diag** (it's a hot-path optimization; diagnostics are off the
  hot path) so per-block accounting + fault localization are exact. The chained corpus
  (`[J5k]`/`[J5j]`) registers no diag, so it keeps full chaining — re-confirmed green.

### Things to discuss in the [J5n] walkthrough
- The weak-symbol trick for the optional diag dependency — clean, or would a separate
  `j5d_engine` compile flag be clearer?
- Block-boundary vs true per-instruction lockstep: the honest trade, and when block-splitting
  would be worth it.
- The signal-handler bundle write is best-effort (we're already dying); the one real guard I
  added was clamping the 68k stack walk to the sandbox so a corrupt a7 can't fault the handler.

## bsdsocket.library (host networking) — implementation log

Building the `bsdsocket-net` feature (real TCP/IP by forwarding AROS's
`bsdsocket.library` to the Mac's BSD sockets). Design/spec:
`docs/features/bsdsocket-net/`. Working the chunks host-first (fast loop), AROS
graft last (ephemeral cross-build).

### Key decisions
- **Host pump packaged as a dylib, peer of cocoametal/pasteboard.**
  `build/libbsdsockhost.dylib` (`make bsdsock-dylib`) exports exactly
  `hosted/bsdsocket/bsdsock.exports`; the AROS side reaches it via
  `hostlib.resource` (`HostLib_Open`+`HostLib_GetPointer`), the proven pattern.
  ABI verified by `make bsdsock-abi` ([NABI]) — dlopen + resolve all 19 symbols.
- **The readiness→wake seam is `ps_create_cb`.** The standalone proof wakes a
  self-pipe; the graft installs `Signal(task, readySig)` via `ps_create_cb(wake,
  cookie)`. The pump code is unchanged — only the callback differs (the single
  swap point the spec promised). Callback runs on the pump (host) thread →
  host-wake discipline is the AROS side's job.
- **Module location: `arch/all-unix/bsdsocket/`, not `all-darwin/`.** Confirmed
  tree-wide there is no unix host-socket bsdsocket (only Windows mingw32); the
  host-neutral core benefits every hosted AROS, with kqueue isolated in one file
  (`readiness_*`). Linux `epoll` backend is a bounded follow-on, not built here.
- **errno table built explicitly (`errno_xlate.c`), and it mattered.** The spec's
  "don't assume identity" caught a real one: macOS `EOPNOTSUPP==102` vs AmiTCP
  `EOPNOTSUPP==45` — a genuine non-identity map. Rest of the BSD socket range is
  identity but asserted entry-by-entry. `make bsdsock-errno` ([NERR]) = 25/25.

### Grounding finding — host-thread Signal is unsafe on darwin (reshapes the park)
Before writing the AROS-side park I checked the proven darwin drivers, and the
spec's core assumption (the kqueue pump thread raises `Signal(task, readySig)`) is
**wrong for this port**. `cocoa_input.c:546` is explicit: a task woken from host
interrupt/thread context runs in "supervisor mode" under the threaded scheduler and
**trips every semaphore op**; both proven drivers (input ~50 Hz, the working
clipboard ~5 Hz) **poll `timer.device` (`Delay()`)** and never `Signal` from a host
thread. So the design changes: keep the kqueue pump (efficient in-kernel readiness +
`pump_drain` stash), but the AROS-side WaitSelect/recv park is a **`Delay()` poll of
`pump_drain`**, not `Wait` on a host-raised signal; the pump callback just sets an
atomic flag. Documented in spec §R-DARWIN-WAKE, design.md "The bridge", and
host-wake-pattern.md R-W2. This is "ground it, don't dream it" catching a
load-bearing error before code — the host dylib already built is unaffected (the
pump + drain are exactly what the poll needs).

### Status
- [N1]–[N3] (pump round-trip / WaitSelect-style readiness / non-blocking park):
  PASS (pre-existing spike, re-verified 9/9).
- [NABI] dlopen ABI + the `ps_create_cb` wake seam through the boundary: PASS.
- [N4]/[NERR] errno translation table: PASS 25/25.
- **[N5] library graft — BUILDS.** `arch/all-unix/bsdsocket/` (14 files: genmodule
  conf, per-task SocketBase, hostlib wiring under Disable(), the data-path LVOs with
  the timer-poll park, sockopt/misc, stubs) compiles + links end-to-end against the
  darwin-aarch64 crosstools → a 34KB `AROS/Libs/bsdsocket.library`. Committed on
  `aarch64-darwin-graft` in ../aros-upstream. Build-bugs found+fixed along the way:
  `HostLibBase` field-vs-`#define` clash (→ field `hostlib`), missing
  `<sys/errno.h>`/`TICKS_PER_SEC`, two `*/`-in-comment terminations, and the
  AmiTCP-vs-libc `fd_set` collision (forward-declared in the stubbed WaitSelect).
- **[N5a] library LOADS + INITIALISES live — PROVEN on booted AROS.** Deployed
  libbsdsockhost.dylib to ~/lib, booted via aros-ctl, typed `version
  bsdsocket.library full` at the shell → **`bsdsocket.library 3.0 (28-06-26)`**, no
  trap. That single line proves the whole high-risk integration: OpenLibrary loaded
  the genmodule module, `bsdsocket_Init` ran (hostlib → libSystem **and**
  libbsdsockhost both HostLib_Open'd + interfaces resolved), **pump_start (the
  kqueue pthread) came up under the threaded scheduler without crashing**, and
  BSDSocket_OpenLib made a per-task base. Proof image:
  docs/features/bsdsocket-net/library-load-proof.png.
- **[N5b] LIVE TCP ROUND-TRIP — PROVEN, both ends.** Built an AROS client
  `socktest` (C: command using the inline defines/bsdsocket.h LVO stubs) + a host
  localhost echo server. Booted AROS, ran `socktest` at the shell →
  **`[N5B] PASS: round-trip echoed 'PING42' (6 bytes)`**, and the host echo server
  logged `client connected / bounced 6 bytes / client closed`. So the real
  bsdsocket.library data path works live on Apple Silicon: `socket()` → `connect()`
  (non-blocking + the darwin **timer-poll park** + `SO_ERROR`) → `send` → `recv`
  echoed-equal → `CloseSocket`, errno-translated, per-task SocketBase, kqueue pump —
  no trap. The H11 two-sided check. Proof: docs/features/bsdsocket-net/roundtrip-proof.png;
  test programs stashed in hosted/bsdsocket/n5b/.
  - Build notes: the client uses `defines/bsdsocket.h` directly (clib protos pull
    sys/types.h, uninstalled in -quick) and links posixc (AmiTCP sys/socket.h pulls
    sys/types.h, which lives in the posixc include tree — so NOT -noposixc).
  - The headless emergency-CLI boot currently crashes in dos/LoadSeg (a pre-existing
    boot fragility, unrelated to bsdsocket); the windowed-boot CLI was used instead.
- **[WS] WaitSelect (LVO 21) + [N6] outbound internet — PROVEN LIVE.** Implemented
  the real timer-poll WaitSelect (register fds with the pump, Delay-poll pump_drain +
  the *sigmask bits, rebuild the fd_sets, rewrite *sigmask; AmiTCP fd_set/timeval
  mirrored locally to dodge the net_types collision). Ran `nettest` on booted AROS:
  - **`[WS] PASS: WaitSelect woke on read-ready, recv echoed the byte`**
  - **`[N6] PASS: AROS fetched over the internet from 1.1.1.1 -> 'HTTP/1.1 301 Moved Permanently'`**
  AROS made a real outbound TCP connection to 1.1.1.1:80 and did an HTTP/1.0 GET — on
  Apple Silicon, through this bsdsocket.library. Proof:
  docs/features/bsdsocket-net/waitselect-internet-proof.png.
- **The feature is functionally complete** (per the spec's [N1]–[N6] scope): host
  pump + errno + the AROS library; socket/bind/listen/accept/connect/send/recv/
  WaitSelect all live; localhost round-trip AND real-internet fetch proven.
- **[DNS] resolver — DONE & PROVEN LIVE.** Implemented `gethostbyname` (LVO 35) the
  darwin-safe way: host `getaddrinfo` on a detached pthread (libbsdsockhost.dylib
  `hs_resolve_start/poll/free`), the AROS LVO **timer-polls** the result (only the
  calling task parks), then builds a per-task `struct hostent`. `nettest` on booted
  AROS: **`[DNS] PASS: resolved one.one.one.one -> 1.1.1.1, fetched 'HTTP/1.1 301'`**.
  Proof: docs/features/bsdsocket-net/dns-proof.png.
- **FEATURE COMPLETE** — the bsdsocket.library does sockets + WaitSelect + DNS, all
  proven live on Apple Silicon (AROS genuinely on the internet). Remaining LVOs are
  secondary/rarely-used stubs outside the [N1]–[N6] scope (gethostbyaddr,
  get{net,serv,proto}by*, inet_*, Obtain/ReleaseSocket, Dup2Socket, SocketBaseTagList,
  send/recvmsg, GetSocketEvents) — fillable as needs arise.

### Trade-off / to discuss in the walkthrough
- `errno_xlate.{c,h}` is authored + host-tested in `hosted/bsdsocket/`; the AROS
  module needs the same file. Kept pure int→int (no errno.h dependency) so one
  copy compiles in both worlds — but the AROS module currently gets its own copy
  (upstreamable/self-contained) at the cost of a hand-sync. Worth a check rule.

## 2026-06-28 — [LED+THEME] PLAN: Amiga status-bar LEDs + a Dark/Light/System theme

Host-layer feature for the Daedalos window: turn the footer into a proper **status
bar** with Amiga-style **Power + Activity LEDs**, and add a **theme switch
(Dark / Light / System)** so the whole app — title bar, menus, Settings, and the
footer — reads as one coherent appearance. Worked under /slow-ai (gates first).
All host-side in `hosted/cocoametal/`; **no `../aros-upstream` change, ABI stays 2.**

### Decisions (answered by John before code)
- **Second LED = Power + Activity, host-only.** Power is real (running + the
  `CM_OPT_POWER` lifecycle). The host can't see real AROS disk I/O without an OS-tree
  hook + an ABI bump, so the second LED is an honest **Activity** light driven by
  `cm_present` cadence — labeled Activity, not DF0. A true DF0 disk LED is a documented
  follow-up (needs `arch/*/trackdisk`/emul hook + ABI v3 + HIDD rebuild).
- **Theme via `NSApp.appearance`, three-way:** System (nil) / Light (Aqua) / Dark
  (DarkAqua). New host-acted key `CM_OPT_THEME = 0x05` in the reserved `0x05..0x0F`
  range — exactly the `CM_OPT_RETINA = 0x04` precedent, so **CM_ABI_VERSION stays 2**.
  Default **System**.
- **Native material status bar:** an `NSVisualEffectView` (titlebar/window material)
  for the footer background — auto-tracks the theme, native vibrancy, least code.

### Change-set (one line per file)
- `cocoametal.h` — add `CMTheme {SYSTEM,LIGHT,DARK}` + `CM_OPT_THEME = 0x05` (host-acted).
- `cocoametal.m` — `CMContext.theme`; set/get cases; persist via `cm__apply_persisted_
  options`; weak no-op `cm__apply_theme_appkit` (mirrors `cm__set_fullscreen_appkit`);
  a cheap `cm__note_present()` activity tick in `cm_present`.
- NEW `cocoametal_statusbar.m` — the status bar view (brand + LED cluster), the LED
  model, strong `cm__apply_theme_appkit` (sets `NSApp.appearance`), the present-driven
  activity sampler. Keeps `window.m` from bloating.
- `cocoametal_window.m` — replace the inline footer (lines ~253-263) with the new
  builder; `FOOTER_H` unchanged.
- `settings.json` + `cocoametal_settings_schema.m` — a `display.theme` popup →
  `hostOption CM_OPT_THEME`; one line in the `CM_OPT_*` const map.
- `cocoametal_shell.m` — a `View ▸ Theme` submenu (System/Light/Dark) with checkmarks.
- `Makefile` — add `cocoametal_statusbar.m` to the `cocoametal-dylib` source list.

### Trade-offs / uncertainties
- The black Metal area (the guest framebuffer) is deliberately NOT themed — only the
  app chrome + footer. "Matches the app" = chrome coherence, not recoloring AROS.
- Does `NSApp.appearance` reflow live windows under our hand-pumped run loop (no
  `[NSApp run]`)? The one doc-only unknown — verified by screenshotting each theme.

### Things to discuss in the [LED+THEME] walkthrough
- The DF0-disk-LED honesty call (Activity now, real disk later) — right boundary?
- `NSApp.appearance` under the hand-pumped loop — did it reflow cleanly?
- Is a host-acted `CM_OPT_THEME` the right home, vs a pure-defaults pref the status
  bar reads itself (no ABI surface at all)?

### [LED+THEME] DONE — what shipped + the decisions that landed
Built + green: `make cocoametal-statusbar` → `[STATUS] PASS`, and the existing
`[ABI]`/`[GSHELL]`/`[D1]`/`[D2t]`/`[D4D5]`/`[J5l fullscreen]`/`[LIVE]`/`[SET]` all
re-ran green. CM_ABI_VERSION stayed **2**. New TU `cocoametal_statusbar.m`; the
footer is now a native-material status bar (brand + PWR/ACT LEDs); theme is the
host-acted `CM_OPT_THEME = 0x05`, surfaced in Settings (General ▸ Appearance) and
View ▸ Theme, persisted in `cocoametal.theme`.

Decisions that landed during the build:
- **The Activity LED is labeled `ACT`, not `DF0`.** It's honestly a present-cadence
  light (the host can't see AROS disk I/O), so calling it DF0 would misrepresent it.
- **`presentCount` was already there** — the Activity LED samples it via a new
  `cm__present_count` accessor on a 0.1s main-loop NSTimer (common modes), so
  `cm_present` itself is untouched. The timer DOES fire under the hand-pumped run
  loop (proven: activity peaks 1.00 on presents, decays to 0.00 when they stop).
- **`NSApp.appearance` reflows live under the hand-pumped loop** — the one doc-only
  uncertainty, now resolved: the [STATUS] test asserts Dark→DarkAqua, Light→Aqua,
  System→nil on the live `NSApp` + window, no `[NSApp run]`. We also push the
  appearance onto each window + `displayIfNeeded` to force an immediate redraw.
- **Power LED needed a sentinel.** `reqPower`'s default 0 aliases `CM_POWER_REQUEST_
  DOWN`, so a fresh context would read as "shutting down". Added `powerReq` (init -1
  = running/green); amber on reset/request-down, red on force-down/quit.
- **The footer is host chrome the oracle can't see** (it's outside the Metal view, so
  `cm_readback`/`cm_capture_png` miss it). Verified the project way instead: [STATUS]
  asserts the AppKit objects directly AND renders the CMLEDView to a PNG via
  `cacheDisplayInRect` (no Screen-Recording/TCC) — proving the LEDs draw real
  saturated green+amber pixels (`run/…/aros-statusbar-leds.png`).
- **Link discipline:** `cocoametal_window.m` now calls `cm__build_status_bar`, which
  only `cocoametal_statusbar.m` defines. The non-statusbar test builds (d1/d2t/input/
  fullscreen/livedraw link window.m but not the status bar) link via a weak nil stub
  in the AppKit-free `cocoametal.m` (`@class NSView;` keeps it AppKit-free) — the same
  weak/strong split as `cm__install_shell`. All those targets re-ran green.

Pre-existing, NOT mine: `cocoametal-hiddsim` FAILs on its *incremental* sub-rect
upload→compose assert. My diff never touches `cm_upload_rect`/`cm_present`/
`cm_readback`/the oracle, and `[ABI]` (full-frame oracle, exact) passes — it's the
documented fbRing "requires full-frame uploads" tension in untouched code.

## Things to discuss in the walkthrough

- Why QEMU-first instead of attacking Apple Silicon head-on (observability + the
  undocumented-hardware wall — see the conversation that started this).
- The "all observation channels normalize to one verdict block" design, and why
  that's what makes an AI agent able to drive months of OS bring-up unattended.
- Where this plugs into real AROS: M2–M8 mirror what AROS's `exec` + the AArch64
  `kernel.resource` will need (vectors, MMU, context switch). Phase 1 is that
  backend in miniature, proven on QEMU, before grafting onto the AROS tree.
