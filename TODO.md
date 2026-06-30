# Project backlog (TODO)

Granular, cross-cutting tasks not tied to a single session and not big enough to be
a [ROADMAP.md](ROADMAP.md) phase. Per-subsystem design + status lives in
[docs/features/](docs/features/README.md); this is the "we'll get to it" list.

## Host app / FFView
- [ ] **FFView drag-and-drop** — register an AppWindow so dropping a file icon from
      Wanderer opens it in the viewer. (User-requested.)
- [ ] **Datatypes integration** — a `libavcodec`-backed picture/animation datatype so
      the desktop / MultiView opens media (and launches FFView). See "Remaining work"
      in [ffmpeg-native](docs/features/ffmpeg-native/README.md).

## OS / build
- [ ] **Full OS rebuild with `-ffixed-x18`** — the make.cfg config is committed and
      `gfx.hidd` is rebuilt; rebuild the rest so every module is x18-safe. Pending the
      AROS maintainers' call on reserving x18 ABI-wide vs preserving it in the host
      context switch. See the x18 finding in [NOTES.md](NOTES.md).

## Rust on AROS
- The Rust `std` port keeps its own resume map (errno/time/env/fs/thread/net plus the
  AROS-side `clock_gettime` and `SetVar` blockers it surfaced) in
  [hosted/rust/STD-PORT.md](hosted/rust/STD-PORT.md).
