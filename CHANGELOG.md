# Changelog

## 2026-07-22 - dynamic display resolution

- The Macaros window is resizable and the AROS screen resolution follows in
  both directions. Drag the window edge and AROS snaps to the nearest of 16
  display modes when you let go; pick a mode in ScreenMode Preferences and the
  window resizes to match. Fullscreen letterboxes the mode instead of resizing.
  (cocoametal host ABI v3 `cm_set_mode`; the AROS side registers a mode ladder
  and drives the change through `screenmode.prefs` + IPrefs.)
- Fixed a stuck mouse button (a Wanderer drag rectangle) left after a window
  resize, caused by the resize grab's button-down being delivered to AROS after
  AppKit's modal live-resize loop rather than before it.

## 2026-07-21 - host deadlock fix

- Fixed a darwin host-library deadlock: the semaphore host-lock could deadlock
  against host (Metal/libdispatch) threads. Use the Forbid-based lock on darwin,
  and cache the watchdog environment probe that a per-tick `getenv` had been
  arming the deadlock through.

## 2026-07-18 - file-change notifications

- The host filesystem (`EMU:`, where the Mac's files appear inside AROS) now
  implements `StartNotify`/`EndNotify`. Programs are notified when a watched
  file or directory changes through the handler (create, write, delete, rename,
  set-protect/date, make-link), so file-watching applications work.
  Contributed upstream as AROS PR #835.

## 2026-07-17 - stability and upstream contributions

- Merged 70 upstream commits into the fork branch and boot-verified the result.
- Fixes originating from this port, sent upstream: the 64-bit taglist crash
  class (nlist/Zune varargs, PR #826), ScrollRaster/ScrollRasterBF dropping
  negative deltas on aarch64 (PR #822), pthread `timer.device` sharing and
  expired-wait handling, and hosted-darwin forwarding of mis-delivered timer
  ticks (fixes CPU-bound task preemption).
- Small upstream bug/cleanup PRs from the port: keymap `CopyMem` (#830),
  gfx convert-pixels test assertions (#831), RAM disk case-only rename (#832),
  `Run >NIL:` background-CLI noise (#833), console split-CSI reassembly (#834).

## 2026-07-13 - audio, media, keymaps

- AHI CoreAudio is now a first-class darwin/aarch64 build (correct speed and
  pitch).
- ffmpeg: a libavcodec-backed picture datatype (video first-frame previews in
  MultiView and on the desktop), FFView drag-and-drop via an AppWindow, an
  FFProbe media inspector, and an FFThumb headless thumbnailer.
- `kms.library` falls back to `.akmd` text keymap descriptors, so non-default
  keymaps load on aarch64.

## 2026-07-08 - Macaros.app v0.1

- Signed and notarized, self-contained `Macaros.app` DMG built by
  `graft/make-aros-release.sh`; a `RustHello` sample in the bundle; docs refresh.

## 2026-07-07 - GPU compute (gpufx)

- A GPU 2D compute section in the cocoametal shim that shares the display's
  Metal device and command queue, fronted by a native `gpufx.library`. It does
  YUV420 -> RGBA conversion and bilinear scaling on the GPU (measured 5-13x
  faster than the CPU path), wired into FFView's video decode path and the
  present-time scaler.

## 2026-07-06 - input and tooling

- Scroll-wheel events (`CM_EV_WHEEL`), both real host events and injected ones;
  the macOS navigation-key cluster mapped to Amiga rawkeys.
- Stable build-tree locations plus `rebuild-aros.sh` as a recovery tool;
  `aros-ctl wheel` and the `AROS_CTL_DESKTOP_EXTRA` hook.

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
