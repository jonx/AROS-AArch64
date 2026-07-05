# Changelog

## 2026-07-05 - initial public release

First public snapshot of the port. State at release:

- Hosted AROS boots to a crash-free Wanderer desktop in a native Cocoa/Metal
  window on Apple Silicon (Macaros.app), with keyboard/mouse, clipboard
  bridge, CoreAudio sound, host BSD sockets (TCP/IP + DNS), a host-volume
  handler, and opt-in crash containment.
- 68k JIT (`run68k`): classic Amiga hunk binaries run via an AArch64
  translator built on the vendored Emu68 decoders (MPL-2.0), with an
  independent interpreter as cross-check oracle; Rust (no_std and most of
  std) runs on it.
- Rust std runs on aarch64 AROS (net/fs/env/args/process/time/thread
  verified live); ffmpeg-based FFView image/video viewer runs natively.
- Control harness `aros-ctl` drives the windowed OS headlessly
  (type/click/screenshot/task-dump) for unattended verification.
- The AROS OS-source changes live on the fork
  ([jonx/AROS](https://github.com/jonx/AROS), branch `aarch64-darwin-graft`);
  this repo carries the host layer, tooling, and documentation.
