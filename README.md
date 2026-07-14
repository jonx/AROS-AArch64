# AROS-AArch64 — AmigaOS on Apple Silicon

**AmigaOS, running as a native app on your Mac — and drivable end-to-end by a
program with nobody at the keyboard.**

AROS-AArch64 brings [AROS](https://aros.org) — the open-source AmigaOS
reimplementation — to 64-bit ARM, and then runs it *hosted* on Apple Silicon:
AROS is an ordinary arm64 macOS process, macOS owns every driver, and AROS
reaches them through standard exec I/O. Display, clipboard, audio, sockets,
volumes — each is that one idea applied to one more surface.

![Macaros — the AROS Wanderer desktop running as a native app on an Apple Silicon Mac](docs/aros-apple-silicon-macaros.png)

This repository is the **graft / host layer**. The AROS operating-system source
we modify lives in a separate sibling checkout, the
[github.com/jonx/AROS](https://github.com/jonx/AROS/tree/aarch64-darwin-graft)
fork (branch `aarch64-darwin-graft`).

> **New here?** **[GETTING-STARTED.md](GETTING-STARTED.md)** takes you from an
> empty Mac to a running system: source → toolchain → build → run.

## What is this, and why

Two audiences meet here:

- **The Amiga / retro world** gets AmigaOS as a first-class, fast, native
  application on modern Apple hardware — not an emulator of a specific old
  machine, but the real AROS operating system compiled for AArch64.
- **The OS / systems world** gets **AROS's first native AArch64 CPU bring-up** —
  a greenfield backend (vectors, MMU, context switch, exception model) that is
  reusable on every ARM64 target, done clean-room.

Reaching the Mac *hosted* is a deliberate choice: it sidesteps the undocumented
Apple-Silicon hardware — custom interrupt controller, signed boot — almost
entirely, so the effort goes into the OS, not into reverse-engineering a locked
laptop. **Native on bare-metal Apple Silicon is an explicit non-goal.**

### The one rule that shapes everything

> **An AI agent must be able to run the whole loop unattended — build → boot →
> observe → judge — with no manual step.**

Every design decision serves that rule, and it is the project's most distinctive
idea. Two consequences fall straight out of it:

- The hard CPU work happens **on QEMU**, not on a real MacBook, because QEMU
  exposes the machine *programmatically* — serial, QMP, gdbstub — and a
  locked-down Mac does not.
- The hosted side **always keeps a programmatic pixel channel beside any
  on-screen window**, because a live window can't be verified by screen-capture
  without a manual permission click. The loop must never need one.

## The harness: puppeteering a live AmigaOS from the command line

The headline capability is **`graft/aros-ctl`** — a CLI that drives the hosted
AROS running in its Cocoa/Metal window with **no human at the keyboard and no
window-server session**. It boots AROS, types into the Shell, clicks and moves
the mouse, opens menus, spins the wheel, captures the framebuffer, and reads the
guest's logs and task states — all as ordinary shell commands. It is at once the
project's test harness and the seed of an embeddable "drive AmigaOS from your
own software" API.

```sh
graft/aros-ctl run                 # boot AROS windowed, in the background
graft/aros-ctl wait 3              # let it reach the "1>" Shell prompt
graft/aros-ctl type "echo hello"
graft/aros-ctl enter
graft/aros-ctl shot                # capture the framebuffer — no screen-recording prompt
graft/aros-ctl stop                # graceful guest power-down
```

Two properties make this trustworthy rather than a screen-scraping hack:

- **Injected input is indistinguishable from real input.** Commands travel as
  single lines over one control FIFO into the window's host shim, which turns
  them into synthetic events and drains them *before* live `NSEvent`s in the
  same pump. Downstream — input HIDD → `input.device` → `console.device` →
  Shell — nothing can tell an injected keystroke from a typed one.
- **Screenshots come from an offscreen oracle.** `shot` reads the last rendered
  target (BGRA → PNG/PPM), not the on-screen drawable, so capture is
  deterministic and needs **no Screen-Recording / TCC approval** — the essential
  property for an unattended loop.

The full command set covers lifecycle (`run`, `status`, `stop`, `kill`,
`wait`), input (`type`, `enter`, `key`, `cmdc`/`cmdv`, `mouse`, `wheel`,
`click`, `button`, `menu`, `resize`), settings (`setting`, `clipboard`), and
capture / introspection (`shot`, `record` for TCC-free `.mov` demos, `log`,
`tasks` — which prints every task's state and backtrace even on a wedged guest —
`crash`, `diag`, `libs`). The one-line `K`/`M`/`B`/`S` wire protocol is
deliberately the shape of a future in-process `libAROS` input/capture API. See
[docs/features/control-harness/](docs/features/control-harness/README.md).

## Vision & roadmap

Three objectives, pursued so the two genuinely hard problems (the CPU backend;
Apple-Silicon specifics) are never fought at the same time:

1. **A native AArch64 backend for AROS** — the greenfield CPU bring-up, proven
   on QEMU. Reusable on every ARM64 target; the genuine standalone contribution.
2. **AmigaOS as a native macOS app on Apple Silicon** — AROS as a hosted arm64
   process, reaching every driver through macOS via exec I/O.
3. **An embeddable, scriptable AROS** — an engine/shell split so AmigaOS can be
   *driven and embedded*, not just booted. The direction is sketched in
   [`hosted/libaros/IDEAS.md`](hosted/libaros/IDEAS.md): promote `aros-ctl`'s
   `K`/`M`/`B`/`S` verbs into typed in-process calls, expose screen+input,
   console, and lifecycle as host-agnostic seams, and turn AROS into a guest
   *subsystem you call into* — embeddable in Mac software, drivable from CI or an
   LLM agent, and eventually fused two-way with the host.

Remaining beyond today's state is polish and upstreaming: shaking out ABI edge
cases, growing an app ecosystem, and submitting the AArch64 work to the AROS
development tree. The full arc and rationale live in [ROADMAP.md](ROADMAP.md).

## Current status

### Native AArch64 backend — complete, on QEMU `virt`

The clean-room CPU bring-up is done and green in the unattended loop
(`make test`), milestones M1–M10: serial / EL1 entry, C runtime, exception
vectors (`VBAR_EL1`, SVC/BRK), MMU (identity map + translation faults), GICv2
timer IRQ, a page allocator, cooperative **and** preemptive multitasking, an
injected-keystroke Shell, and a framebuffer verified by screendump. Detail:
[PHASE1.md](PHASE1.md) · [HARDWARE.md](HARDWARE.md).

### Hosted on Apple Silicon — AmigaOS boots to the desktop

Running as a native arm64 macOS process, **AROS boots all the way to a Wanderer
desktop.** exec, kernel.resource, dos.library, and the full boot-module set come
up, `SYS:` mounts, and the AmigaDOS **Shell runs typed commands** against the
complete standard **C: command set (116 commands)**. Multitasking, W^X
executable loading, and console I/O work.

Hosted capabilities — each one "macOS owns the driver, AROS reaches it via exec
I/O" applied to a surface:

| Surface | State | How |
|---|---|---|
| **Display** | ✅ built | Live Cocoa/Metal window; AROS-side `cocoa.hidd` over the full graphics/intuition/layers stack |
| **Keyboard + mouse** | ✅ built | Same event path as real `NSEvent`s; drives Shell and desktop |
| **Wheel scrolling** | ✅ built | End-to-end: host wheel → NewMouse rawkeys → `IDCMP_RAWKEY` |
| **Native menus** | ✅ built | gadtools Intuition menu strips |
| **Clipboard** | ✅ built | Two-way `NSPasteboard` ↔ `clipboard.device` (RAmiga-C/V) |
| **Audio** | ✅ built | CoreAudio-backed AHI sub-driver |
| **Networking** | ✅ built | `bsdsocket.library` forwarded to native sockets (TCP/IP + DNS) |
| **Host volumes** | ✅ built | A Mac folder mounted as `MacRO:` / `MacRW:`, drag-from-Finder |
| **Media** | ✅ built | ffmpeg decode + FFViewX/FFView viewer; `ffmpeg.datatype` with drag-and-drop |
| **GPU 2D** | ✅ built | `gpufx.library` compute shim (YUV→RGB + scale, ~5–7× on the video path) |
| **Rust `std`** | ✅ built | Runs natively — net, fs, env, args, process, time, thread verified live |

Every capability has a grounded design + spec under
[docs/features/](docs/features/README.md).

**Macaros**, the host wrapper, packages all of this as a double-clickable
`.app` — menu bar, About panel, custom icon, schema-driven "AROS Settings"
window — via `graft/make-aros-app.sh`.

Two things worth calling out:

- **A full GPUI application runs on booted AROS.**
  [Feraille](https://github.com/jonx/Feraille) — a native file manager — boots
  as `C:Feraille` through a from-scratch GPUI software-raster backend
  (tiny-skia + cosmic-text, blitted via CyberGraphics), with complete themed
  chrome, native Intuition menus, `asl.library` file requesters, and a real
  `SYS:` listing. It's proof the hosted stack is a real application platform,
  not just a booting kernel. (The app and its GPUI backend fork are developed in
  sibling checkouts and are not yet upstreamed.)
- **A 68k JIT (`run68k`)** runs self-contained classic-Amiga 68k binaries,
  integer and 68881/68882 hardware FP, byte-exact-verified against an
  independent interpreter. It vendors [Emu68](https://github.com/michalsc/Emu68)
  (MPL-2.0) — the one non-clean-room component.

## Getting started

Requirements: an **Apple-Silicon Mac** (M1 or newer) with a recent macOS,
`xcode-select --install`, and [Homebrew](https://brew.sh). This is an
`aarch64-darwin`-only project — Intel and Linux are not targets.

### Fast path — the 68k JIT, ~2 minutes, no AROS build

```sh
brew install llvm lld
git clone https://github.com/jonx/AROS-AArch64.git
cd AROS-AArch64
make run68k                                          # -> build/run68k
build/run68k hosted/jit68k/apps68k/bin/mandel.exe    # renders a Mandelbrot, exits 0
```

Full 68k usage — hunk executables, stdout piping, crash bundles — is in
[hosted/jit68k/run68k.md](hosted/jit68k/run68k.md).

### Full path — build and boot hosted AROS

Lay the two repos side by side (scripts assume `../aros-upstream`):

```sh
git clone https://github.com/jonx/AROS-AArch64.git aros-aarch64
git clone -b aarch64-darwin-graft https://github.com/jonx/AROS.git aros-upstream
```

Install the host build prerequisites:

```sh
brew install llvm lld cmake zstd autoconf automake gawk bison flex netpbm libpng gnu-sed
python3 -m pip install mako --break-system-packages
```

You do **not** install a cross-compiler by hand — AROS's `configure
--with-toolchain=llvm` builds its own pinned **clang / LLVM 20.1.0** targeting
`aarch64-unknown-aros` (a one-time ~1–2 h compile; the resulting `crosstools`
directory is then reused). A bare `make` will try to rebuild that toolchain and
break — use the runnable recipe, which wraps the whole build into a stable,
reusable tree:

```sh
graft/build-darwin-aarch64.sh        # builds hosted AROS into ~/aros-build,
                                     # toolchain into ~/aros-crosstools (both stable, reusable)
```

Then build the host shims, deploy, and run:

```sh
make cocoametal-dylib pasteboard-dylib coreaudio-dylib bsdsock-dylib
graft/aros-ctl deploy                          # stage shims + Cocoa monitor into the boot tree
AROS_CTL_STARTUP_MODE=desktop graft/run-window.sh   # boot to the Wanderer desktop
graft/make-aros-app.sh                          # -> build/Macaros.app (double-clickable)
graft/aros-ctl run                              # ...or drive it headlessly (type / click / shot)
```

Full prerequisites, the sibling-checkout layout, toolchain notes, and the
build/deploy gotchas are in **[GETTING-STARTED.md](GETTING-STARTED.md)**,
[docs/features/build/README.md](docs/features/build/README.md), and
[docs/features/deployment/README.md](docs/features/deployment/README.md).

## Repository layout

Work spans **two sibling checkouts** — this repo (the host layer) and the
separate AROS OS-source tree (the
[jonx/AROS](https://github.com/jonx/AROS/tree/aarch64-darwin-graft) fork,
branch `aarch64-darwin-graft`).

```
aros-aarch64/                     ← THIS repo (the graft / host layer)
├── boot/        Bare-metal AArch64 kernel for QEMU virt: start.S, mmu.c, irq.c, task.c, fb.c …
├── harness/     The unattended loop: run.sh, run-hosted.sh, qmp.py, lldb-dump.sh, test.sh
├── hosted/      Host shims + the embeddable-engine work:
│   ├── cocoametal/   Cocoa/Metal display + Macaros app + control FIFO
│   ├── clipboard/    NSPasteboard ↔ clipboard.device bridge
│   ├── hostvolume/   Mac-folder-as-AROS-volume handler
│   ├── coreaudio/    CoreAudio AHI sub-driver
│   ├── bsdsocket/    bsdsocket.library → native sockets
│   ├── ffmpeg/       libav* built native for AROS + FFViewX/FFView viewer
│   ├── gpufx/        GPU 2D (YUV→RGB + scale) compute shim + gpufx.library
│   ├── rust/         Rust std port for AROS
│   ├── jit68k/       the 68k→AArch64 JIT + the run68k CLI
│   └── libaros/      the embeddable-engine direction (IDEAS.md)
├── graft/       AArch64-darwin patch set, build/run scripts, and the aros-ctl harness
├── docs/features/   grounded design + spec per capability (index: docs/features/README.md)
└── ROADMAP / PHASE1 / PHASE2 / GRAFT / HARDWARE / NOTES / TODO / CLAUDE   planning + decisions

../aros-upstream/                 ← the AROS OS source — jonx/AROS fork, branch aarch64-darwin-graft
                                     rom/, workbench/, arch/all-darwin, arch/aarch64-all …
```

## Contributing

Experimental and actively developed. Expect rough edges, and read
[SECURITY.md](SECURITY.md) before pointing it at anything sensitive. Issues and
small, focused PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md), and
[CLAUDE.md](CLAUDE.md) for the operating manual (including the clean-room
independent-work process every host feature follows).

## License

This repo is licensed under the **AROS Public License** ([LICENSE](LICENSE),
APL 1.1, MPL-derived) — the same license AROS itself uses, so anything destined
for upstream carries over cleanly. The host-side work is **independent /
clean-room** — written from public APIs, published standards, the AROS tree, and
this project's own spikes; no third-party implementation source was consulted.

**One deliberate exception:** the 68k JIT (`run68k`) vendors
**[Emu68](https://github.com/michalsc/Emu68)** (MPL-2.0) as isolated files
behind a documented license boundary — not clean-room, not AROS-licensed. It is
the repo's only third-party code. Full disclosure:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
