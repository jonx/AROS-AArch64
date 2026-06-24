# AROS-AArch64

Bringing a 64-bit ARM (AArch64) backend to [AROS](https://aros.org) — the
open-source AmigaOS reimplementation — on QEMU `virt` first, with Apple Silicon
as the eventual hosted target.

This repo is built around one rule: **an AI agent must be able to run the whole
loop unattended** — build, boot, observe, judge — with no manual step. QEMU
`virt` is the Phase-1 target precisely because it exposes the machine
programmatically (serial, QMP, gdbstub), which is what makes that possible.

## Quick start

```sh
brew install qemu llvm lld     # clang + ld.lld + lldb + qemu-system-aarch64
make run                       # build an AArch64 ELF, boot on QEMU, verify latest milestone
make test                      # boot once, assert every milestone marker
make shot                      # also capture a framebuffer screendump
```

`make run` (latest milestone) and `make test` (full regression) both go green;
`make shot` captures the framebuffer:

![M9 framebuffer — four quadrants](docs/m9-framebuffer.png)

## Status — Phase 1 complete ✅

A full native AArch64 bring-up on QEMU `virt`, each milestone gated by the loop:

| # | Milestone | What works |
|---|-----------|-----------|
| M1 | serial | EL1 entry, PL011 UART, clean semihosting exit |
| M2 | C runtime | `.bss`/stack, `kprintf` (`%d/%u/%x/%lx/%p/%s/%c`) |
| M3 | exceptions | `VBAR_EL1`, vector table, SVC/BRK decode + recover |
| M4 | MMU | identity map, `SCTLR.M`, verified translation fault |
| M5 | timer IRQ | GICv2 + EL1 physical timer, tick counter |
| M6 | phys memory | free-list page allocator |
| M7 | context switch | two cooperative tasks on separate stacks |
| M8 | shell | UART RX + injected-keystroke command loop |
| M9 | framebuffer | ramfb via fw_cfg, screendump-verified |

Every hardware fact is grounded against the real DTB / Linux headers / QEMU
source (see [HARDWARE.md](HARDWARE.md)), and verified live in the loop. Next:
see [ROADMAP.md](ROADMAP.md) (Phase 2 = hosted-on-macOS) and [NOTES.md](NOTES.md)
(Phase 1 retrospective + what's deferred).

## What's here

| Path | Purpose |
|------|---------|
| `boot/` | the kernel: `start.S`, `uart.c`, `exc.c`+`vectors.S`, `mmu.c`, `irq.c`, `pmm.c`, `task.c`+`switch.S`, `shell.c`, `fb.c`, `kmain.c` |
| `harness/run.sh` | the loop: build → boot headless → observe/drive → uniform verdict |
| `harness/qmp.py` | QMP client (framebuffer screendump) |
| `harness/lldb-dump.sh` | scripted lldb CPU-state dump over QEMU's gdbstub |
| `harness/test.sh` | regression: one boot, assert every milestone marker |
| `Makefile` | agent entry points: `run`, `test`, `shot`, `dbg`, `dtb`, `clean` |
| `ROADMAP.md` / `PHASE1.md` | the three-phase arc / Phase-1 milestones |
| `HARDWARE.md` / `NOTES.md` | grounded hardware map / architecture + decisions |

## License

AROS is distributed under the [AROS Public License](https://aros.org/license/).
Code here intended for upstream follows suit; see individual files.
