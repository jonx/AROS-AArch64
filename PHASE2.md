# Phase 2 — Hosted on macOS

The payoff path: AROS as a **native arm64 macOS process**, with macOS owning every
driver (console, memory, later display/input). This is also the de-facto AROS
contribution — upstream's `arch/aarch64-all` is already a *hosted* (`emulation`)
flavour, just unfinished. We complete that, on Apple Silicon.

The loop is even simpler than QEMU: the target IS a Mac process, so "build → run →
observe" is just running the binary and reading stdout (`make hosted-run`).

We de-risk by spiking the scary parts cheapest-first, before committing to the
full port.

Status: ✅ done · 🔜 next · ⬜ planned

### H0/H1 — Foundation ✅
A native arm64 Mach-O process runs our bare-metal `ctx_switch` (now `_ctx_switch`
for Mach-O) at EL0, cooperatively scheduling tasks whose console is macOS stdout
and whose stacks are macOS `malloc`. Proves the AROS-side machinery is portable
native→hosted, and — the real risk of step 1 — that **host calls (`printf`) work
on a switched, host-allocated stack**.
**Observe:** `[H1] hosted context switch ok: A=3 B=3`. **Files:** `hosted/host.c`,
`hosted/switch.S`, `harness/run-hosted.sh`.

### H2 — Hosted preemption ✅
`hosted/preempt.c`: a periodic `SIGALRM` is the hosted "timer interrupt"; the
handler swaps the saved registers in the signal's `mcontext` so it returns into a
different task — the hosted analog of the M5/M10 timer IRQ. Workers never yield,
yet both run ~9.4k times over ~200 ticks → **macOS-hosted preemption works**.
Grounded: `-arch arm64` ⇒ `__DARWIN_OPAQUE_ARM_THREAD_STATE64==0`, so the plain
`__ss.{__x,__fp,__lr,__sp,__pc}` fields are valid (no pointer-auth surgery).
**Observe:** `[H2] ... A ran=N B ran=M (no yields)`. **Files:** `hosted/preempt.c`.

### H3 — The host-call ABI shim ✅
The make-or-break layer (it killed the old Darwin-PPC port). Real AROS code is
built to generic AAPCS64; calling macOS libc crosses into Apple's arm64 ABI,
which diverges — above all, **variadic args go on the stack, not in registers**,
even when arg registers are free. `hosted/abishim.S` is the hand-written
marshaller that bridges an AROS-side call descriptor (fixed args + a 64-bit arg
array) into Apple's variadic ABI; a double rides through as its bit pattern
(Apple parks variadic FP in the integer stack slots too). Grounded against the
exact assembly this machine's `clang` emits (not the JS-only Apple doc) — all
four AAPCS64 divergences confirmed empirically; see NOTES.md "H3 grounding".
**Observe:** `[H3] host-call ABI shim ok: ...` — correct path prints `11 22 33`/
`7 3.5 Z`/`<AROS>`, a naive register-passing control prints `0 0 0` (divergence
shown real *and* bridged). **Files:** `hosted/abishim.S`, `hosted/abishim.c`.
**Run:** `make hosted-abi`.

### Beyond — toward a real hosted AROS
Map AROS `exec` onto this process: the scheduler (H2) becomes `core_Schedule`/
`cpu_Switch`; memory pools over `mmap`; a console/display via the host (stdout
first, then a Cocoa/Metal or X11 window); then bootstrap the AROS module system.
