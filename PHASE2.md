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

### H2 — Hosted preemption 🔜
A macOS timer signal (`SIGALRM`) drives task switching by swapping the saved
register state in the signal's `ucontext`/`mcontext` — the hosted analog of the
M5/M10 timer IRQ. This tests the next risk: can we preempt and switch contexts in
an arm64 macOS process? If yes, the hosted scheduler is viable.

### H3 — The host-call ABI shim ⬜
The make-or-break layer (it killed the old Darwin-PPC port). Real AROS code is
built by AROS's own crosstools with the AROS ABI; calling macOS functions crosses
into Apple's arm64 ABI, which has quirks (variadic args on the stack, stack
alignment, char/short promotion). H1 used a matching ABI (Apple clang both sides);
H3 must bridge the real cross-ABI boundary. Ground against Apple's arm64 ABI docs.

### Beyond — toward a real hosted AROS
Map AROS `exec` onto this process: the scheduler (H2) becomes `core_Schedule`/
`cpu_Switch`; memory pools over `mmap`; a console/display via the host (stdout
first, then a Cocoa/Metal or X11 window); then bootstrap the AROS module system.
