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
make run                       # build an AArch64 ELF, boot it on QEMU, verify [M1]
```

A green run prints:

```
==== VERDICT ====
result=PASS
marker=[M1]
qemu_exit=0
fault_lines=0
```

## What's here

| Path | Purpose |
|------|---------|
| `boot/` | the bare-metal stub: `start.S` + `linker.ld` |
| `harness/run.sh` | the loop: build → boot headless → observe → uniform verdict |
| `harness/qmp.py` | QMP client (framebuffer screendump, etc.) |
| `harness/lldb-dump.sh` | scripted lldb CPU-state dump over QEMU's gdbstub |
| `Makefile` | agent entry points: `run`, `shot`, `dbg`, `clean` |
| `PHASE1.md` | the milestone roadmap (A0…M9) |
| `NOTES.md` | architecture + decision log |

## Status

Phase 1, milestone **M1** — boots to a serial marker on QEMU `virt` and exits
cleanly. See [PHASE1.md](PHASE1.md) for the full roadmap.

## License

AROS is distributed under the [AROS Public License](https://aros.org/license/).
Code here intended for upstream follows suit; see individual files.
