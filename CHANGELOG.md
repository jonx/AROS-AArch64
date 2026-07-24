# Changelog

## 2026-07-24 - Async networking runs on AROS

- The async networking stack (`async-io`/`mio`/`tokio`) now drives real sockets
  on hosted AROS, verified with a live async TCP round-trip. This is the
  foundation the editor's networked features sit on (HTTP, language servers over
  the network, the agent panel). Two pieces made it work: a reactor that reports
  socket readiness through `bsdsocket` `WaitSelect`, and a small unified-fd shim
  so the Rust socket crates — which drive sockets as ordinary file descriptors —
  work against AROS, where sockets and files live in separate descriptor spaces.
  See [docs/features/zed-editor/os-requirements.md](docs/features/zed-editor/os-requirements.md).

## 2026-07-24 - Pipes for live tools (PIPE: + readiness)

- `PIPE:` is now mounted on every boot, and its handler gained what an async
  runtime needs to stream a child process's output live: a read-readiness signal
  (tell me when this pipe has data, delivered as a signal the reactor can wait on
  alongside sockets), a non-blocking mode (reads return "would block" instead of
  stalling), and a fix so ordinary reads return as soon as data is available
  instead of hanging until the buffer fills. This is the groundwork for running a
  language server or build tool directly on AROS and for the integrated terminal.
  Verified live end to end.

## 2026-07-24 - Zed workspace: tabs, syntax highlighting, status bar

- `C:ZedAros` now boots the real Zed **Workspace** on AROS, not just a bare
  editor: opening a file (`ZedAros MacRW:foo.rs`) shows it in a pane with an
  editor **tab** and the window title tracking the file, through a real Zed
  `Project` reading the AROS filesystem.
- **Syntax highlighting** works (tree-sitter grammars registered directly, and
  the syntax theme applied to them) — keywords, types, strings, and comments are
  colored.
- The **status bar** renders with a live cursor-position (Ln:Col) item plus an
  AROS marker.
- The **file tree** (project panel) works: `ZedAros MacRW:proj` opens a folder
  and shows its contents in a dock, read live from the AROS filesystem. (Its
  git-status integration is off on AROS, since that path pulled an
  embedded-database dependency needing OS primitives AROS lacks.)
- A minimal **app menu** (File / Edit / Quit) via native Intuition menus
  (right-mouse-button). Networking/wasm/terminal stay stubbed. See
  [docs/features/zed-editor](docs/features/zed-editor/README.md#the-zed-crate-boot-editor-core-on-aros).

## 2026-07-24 - Per-thread errno

- Each thread now has its own `errno`. It used to be shared across the whole
  program, so two threads failing system calls at the same time could read each
  other's error code and misreport what went wrong. This matters for the
  multi-threaded async runtime the editor port is built on. Non-threaded
  programs are unaffected. Verified live.

## 2026-07-24 - Non-blocking sockets for async networking

- Sockets can now run in real non-blocking mode. Setting a socket non-blocking
  (`FIONBIO`) makes a call that would wait return a would-block status right away
  instead of stalling, which is what an async runtime (the reactor behind
  `tokio`/`async-io`) needs to drive many connections at once. Blocking sockets
  are unchanged. This unblocks the networked side of the editor port (HTTP, LSP
  over the network, the agent panel). Verified live end to end.

## 2026-07-24 - Clock reads the real date

- Hosted AROS now boots with the correct date and time. The clock was starting
  at an ~1978 epoch because the boot never seeded it from the Mac, so every file
  timestamp and `Date` was wrong. The boot now runs `SetClock LOAD`, which reads
  the host wall-clock through the existing battclock bridge, so timestamps and
  logs are right from a fresh boot.

## 2026-07-23 - Zed editor-core boots on AROS

- The real GPL Zed `editor` crate now boots on hosted AROS. `C:ZedAros` opens a
  native window rendering an editor buffer with line numbers and the base theme,
  through the gpui_aros CPU backend, with networking, wasm, and terminal
  stubbed. This is the "minimal editor-core" path (a `zed_aros_app` staticlib
  entry over the whole `editor` dependency graph, ~50 crates given AROS arms),
  distinct from the Apache gpui-component editor that already shipped file + LSP
  support. Build and boot it with `hosted/zed/build.sh`. Typed input into the
  window is not wired yet. See
  [docs/features/zed-editor](docs/features/zed-editor/README.md#the-zed-crate-boot-editor-core-on-aros).

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
- View ▸ Resolution menu: pick a standard size (640×480 up to 2560×1600)
  straight from the menu bar instead of dragging the window; the current size
  is checkmarked.

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
