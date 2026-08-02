# Changelog

## 2026-08-02 - The 68k translator now checks itself against a second implementation

- **A conformance suite covers the addressing modes**, not just whole programs.
  Every translator bug so far was found by a real program dying days later,
  somewhere unrelated to the cause, because a program only exercises whatever
  its compiler happened to emit. There is now one small test per instruction and
  addressing-mode pair, each run through the translator and through an
  independent interpreter, comparing registers, flags and memory. 103 of 104
  agree exactly.
- **It found a crash on its first run.** Any 68k program that read the processor
  status register brought the whole thing down with an illegal instruction. That
  is an ordinary thing for older code to do, and it would have surfaced sooner or
  later as one more unexplained failure.
- **Where the checker cannot check, it says so.** Cases the reference
  implementation does not understand are listed by name rather than counted as
  passes. That list is now down to one.

## 2026-08-02 - A real Amiga archiver compresses and extracts on AROS/aarch64

- **LhA works.** The original 68k LhA 2.15, unmodified, compresses a file into
  an archive, lists it, and extracts it again. The archive it writes is valid
  LHA that other tools read, and the extracted file is byte-identical to the
  original. This is a 1991 Amiga binary doing its actual job on an Apple Silicon
  Mac, not a port and not a rebuild.
- **Two more programs from the test set now run**, and one was being blamed
  unfairly. AddText had been reported as needing a full Amiga emulator because
  it appeared to touch the hardware; it never did, it was being sent to a wrong
  address by the bug above. Any program previously rejected that way is worth
  retrying.
- **Structure layouts are derived from the OS, not typed in.** An AmigaOS
  structure and a native AROS one differ in byte order, pointer width and
  alignment, so anything crossing between a 68k program and AROS has to be
  rebuilt field by field. Those offsets now come out of the AROS headers
  automatically for both layouts, and the generator refuses to emit if it stops
  reproducing layouts that are known facts about the Amiga.

## 2026-08-02 - LhA runs, and a whole class of silent 68k miscompilation is fixed

- **68k programs can read their own data again.** Position-independent code, which
  is to say every Amiga executable, reads its constants and its jump tables
  relative to the program counter. That form of access was being computed from a
  register this Mac does not let us use, so it silently returned the wrong bytes.
  A program would then jump through a garbage table and execute its own data.
  This affected everything that was not compiled a particular way, and it is
  fixed; what is still unsupported now says so by name instead of reading a
  wrong address.
- **A run can no longer hang forever waiting for a dialog nobody can see.** When
  a 68k program asked for a path that could not be resolved, AmigaOS raised its
  usual "please insert volume" requester. Driven headlessly there is nobody to
  answer, and the whole run stopped dead with nothing in the log. Those calls
  now fail normally, which is what the program expects anyway.
- **LhA, the classic Amiga archiver, runs.** It prints its banner, reads its
  arguments, opens files and starts writing an archive. Directory scanning is
  the next piece it needs.
- **exec.RawDoFmt works**, which matters more than it sounds: it is the
  formatting engine behind every Amiga program's printf. It calls back into the
  program's own code once per character, so it now runs inside the emulated
  program rather than being faked from outside.

## 2026-08-02 - The 68k engine finds library calls it used to walk straight past

- **A whole class of silent failure is gone.** A 68k program does not always
  call a library the textbook way. It copies the base into another register,
  hoists the call address out of a loop, or jumps straight to it. The engine
  only recognised some of those spellings, and missing one was silent: it jumped
  into the middle of the library's data and started interpreting it as
  instructions, failing thousands of steps later at an address with no visible
  connection to the program. lha and ADocReader both died this way. Both now get
  through, and every program in the test set that used to fail this way now
  either runs or names exactly what it still needs.
- **Jump tables are understood.** The compiled form of a `switch` statement was
  not recognised as a branch at all, so the decoder ran off the end of the
  function into the table itself.
- **Twenty libraries are bridged instead of seven**, 99 calls instead of 64,
  including the Amiga floating-point libraries, which turn out to need no
  hand-written code at all. Adding another library is now one name on a list.

## 2026-08-02 - 68k programs reach more of AROS, without the calls being written by hand

- **The library bridge is now mostly generated.** When a 68k program calls an
  AmigaOS library, something has to turn its 68k registers into a real native
  AROS call. Those crossings were being written out one at a time. AROS already
  describes every library vector precisely (its C prototype and which 68k
  register each argument arrives in), so they are now *derived* from that
  description instead: 64 crossings across dos, exec, utility, intuition,
  graphics, icon and commodities, none of them hand-written. Programs get
  pattern matching, string and case handling, environment variables, file
  attributes and more, and the list grows when AROS's own does.
- **A generated crossing never overrides a considered one.** Hand-written cases
  run first; the derived table is the fallback. Where a signature is not the
  whole truth, the call is refused by name with the reason recorded rather than
  guessed at. `utility.UDivMod32` is the example worth having: its prototype
  says it returns one value, but it really returns a quotient *and* a remainder
  in a second register, so generating it would have produced silently wrong
  arithmetic with no crash to notice.
- **A guest cannot reach past its sandbox into the machine.** Several
  kernel-level exec calls look trivially simple and would have been swept in
  (rebooting, disabling interrupts, dropping into the debugger, blocking the
  task that hosts the emulator). exec is now allowlisted rather than
  denylisted, so the default for a kernel API is "no".

## 2026-08-02 - Copy and paste work in the shell again, in both directions

- **Paste into the shell works.** Right-Amiga+V (either ⌘ on a Mac keyboard,
  including the right one) puts the Mac clipboard at the prompt. It had been
  silently doing nothing in the boot console: that window opens lazily, and the
  console handler was listening on the window's message port as it stood at
  startup, before the window existed. So no menu entry in that window worked
  either, Copy, Paste, About or Close.
- **Copying out of the shell works.** Mark console text with the mouse and press
  Right-Amiga+C and the text is on the Mac clipboard. Nothing had been writing
  the AROS clipboard from the console at all, so this direction could not work
  however healthy the bridge was.
- **One keypress, one paste.** The chord used to be delivered twice, once to the
  console and once as a menu shortcut, which pasted the clipboard twice and
  copied it twice. It now has a single owner.
- **The Mac clipboard is read more broadly**, so text copied from applications
  that publish it in a less common form still crosses over, instead of the Paste
  menu offering a clip that never arrived.
- **A busy Mac clipboard no longer blocks the other direction.** An application
  that rewrites the Mac clipboard on a timer used to keep AROS-to-Mac copies
  from ever being noticed.

## 2026-08-01 - 68k programs that need the real Amiga hardware now say so

- **A program that drives the Amiga chips gets a clear answer instead of a
  crash.** Some classic software talks straight to the hardware rather than to
  the operating system, and translation cannot serve that. Those programs now
  stop with a plain sentence naming exactly what they wanted, for example the
  custom chip register `$DFF180`, rather than dying mysteriously.
- **It works even when the program hides the address.** If the hardware address
  is worked out while the program runs, so nothing can spot it by inspection
  beforehand, the system still catches the moment it is touched and gives the
  same clear answer.
- **New `scan68k` tool**: point it at a 68k program and it tells you how the
  program would run here and why, without running it. Ordinary programs are
  never mistaken for hardware-bangers.
- Still open: pointing those programs at a real emulator automatically, and
  remembering the choice per program.

## 2026-08-01 - Classic 68k Amiga programs run from the AROS shell

- **Type the name of a 68k Amiga program and it runs.** A real big-endian
  AmigaOS executable, the kind that only ever ran on a 68000, now runs on
  Apple Silicon as an ordinary AROS process: output goes to your console,
  arguments arrive the AmigaDOS way, the exit code comes back, and CTRL-C
  stops it. No emulator window, no separate machine, nothing to configure.
- **It behaves like a program, not an experiment.** Several 68k programs can
  run at once alongside native ones, a program that crashes takes only itself
  down (and leaves a crash report behind), and one that asks for an operating
  system function we have not taught it yet says exactly which one instead of
  failing mysteriously.
- The output is identical, byte for byte, to the same programs run through the
  standalone translator, including hardware floating point and a full
  Dhrystone benchmark run.
- Known limits: this covers system-friendly programs that talk to the OS.
  Programs that drive the Amiga hardware directly are not supported yet, and
  the set of OS functions available to 68k code is still small and growing.

## 2026-08-01 - Macaros 0.2: three applications, on the desktop, in one download

- **The desktop has application icons now.** Macaros boots to Wanderer with
  Zed, Ferail and Moonstone sitting on the backdrop, each with its own
  artwork, each one double-click away. They stay in `C:` as well, so the shell
  keeps working exactly as before.
- **Moonstone ships with the release.** The game and the assets it reads are
  embedded in the bundle, so it runs on a Mac that has never seen the source
  tree. Its music is left out: those files are decoded but nothing plays them
  until AROS has an audio backend for them.
- **Real icons, not the four-colour kind.** A generator turns each project's
  own artwork into a Workbench icon. AROS could already read this icon format
  but threw away the one field that says what the icon *is*, so every such
  icon was mistaken for a document; that is fixed in the OS side.
- **Two reasons an icon launch used to fail, both fixed.** A program started
  from an icon gets its stack from that icon, and the file manager wanted more
  than it was given. And a program with no shell behind it cannot answer a
  system requester, so the editor now reads the error instead of stopping on
  a dialog nobody can dismiss.
- **The editor's settings survive an update.** In the release its home is the
  shared Mac folder, not the volume inside the app bundle, which is read-only
  and replaced wholesale on every install.
- **A crashing application no longer takes Macaros with it.** Quitting the file
  manager ended the whole session: it aborts on exit, and the crash reporter
  then walked a broken frame chain, faulted inside itself, and stopped the
  host before it could say anything. The reporter now distrusts that chain,
  and the release boots with trap containment on, so a fault shows a
  recoverable alert and costs you that one program.

## 2026-07-30 - the terminal grows an interrupt key, and the editor stops guessing about files

- **Ctrl-C stops a running command in the terminal.** The Amiga break
  convention, wired end to end: the terminal consumes the keystroke and
  delivers the break signal to the shell's process, which the running command
  shares. A `Wait 60` dies in the time it takes to press the key. This also
  gives the editor's own stop-a-task buttons real meaning, and required fixing
  a small OS gap on the way: the tag that promises a new shell's CLI number
  has been declared since the nineties and implemented never.
- **The editor notices outside changes in about a second, not half a minute.**
  AROS cannot report file changes, so the editor had been walking the project
  on a timer. It now asks the Mac underneath, which does know, and is told
  about each folder as it changes. Folders on volumes not shared with the Mac
  keep the old behaviour.
- **The window title shows real punctuation.** The title bar speaks Latin-1
  and the editor speaks UTF-8, so the dash between project and filename
  arrived as three stray glyphs. Typographic characters now fold to their
  plain equivalents at the boundary.
- The phantom "threads sidebar" button is gone: it toggled a panel that does
  not exist on AROS, doing nothing except hiding itself.

## 2026-07-26 - A working terminal inside the editor, and a fix for random crashes

- **Zed's terminal panel runs a real AROS shell.** Open it, type a command, see
  its output. AROS has no pseudo-terminal, which was assumed to be a hard
  prerequisite; it turns out not to be. Two pieces were missing. AROS starts two
  kinds of shell and only asks you which if you know to ask: the default runs one
  command and exits, which is what running a command means and is useless as a
  terminal. And with no terminal device, nothing echoes what you type or moves
  the cursor to the start of the next line, so the terminal does both itself.
- Still missing without a pseudo-terminal: the shell is not told how big the
  window is, so full-screen programs have nothing to fit themselves to; there is
  no way to interrupt a running command; and there is no prompt.
- **Rust programs no longer corrupt memory at random.** A background thread was
  given a quarter of the stack space the same code gets everywhere else. AROS
  puts nothing between one task's stack and whatever is below it, so running off
  the end quietly overwrites something else, and the crash lands somewhere
  unrelated minutes later. The same overflow had been showing up as three
  different, equally misleading failures. Threads now get the usual 2 MB.
- **A failed program launch now says why.** Every failure used to come back as
  "command could not be run", whatever had actually gone wrong.
- **The terminal shows a prompt, and output appears as it is written.** Both were
  the same AROS bug: writes to a pipe were held in a buffer until it filled,
  where writes to a screen are sent after every line. So a command like `Dir`
  seemed to do nothing until you typed the next one, and the shell printed no
  prompt, having concluded from its input that nobody was there. Pipes are now
  treated as what they are.
- **The keyboard layout is applied on every boot**, not only when starting the
  desktop. A plain boot came up US whatever the layout was set to, and since
  everything reads the keyboard the same way, so did the editor.
- **The terminal opens on a bare prompt**, the way a shell should. The working
  directory used to be applied by typing a `CD` at the shell, and the editor's
  environment by typing a `Set` for each variable, so a new terminal opened on a
  stack of prompts for commands nobody had typed. AROS can give a new program its
  directory outright, and nothing on AROS reads the variables an editor sets.
- **The editor notices outside changes in about a second, not half a minute.**
  AROS has no way to report file changes, so the editor had been looking for
  them: walking the project on a timer, which is both slow and wasteful. It now
  asks the Mac underneath instead, which does know, and gets told about each
  folder as it changes. A file created on the Mac shows up in the tree in about
  two seconds where it used to take twenty to thirty. Folders on volumes that
  are not shared with the Mac keep the old behaviour.
- **Errors from file operations on worker threads now arrive at all.** The C
  runtime keeps errno per-thread for the editor's own code, but the system
  libraries it calls write a single shared cell that nothing on the thread
  side read -- so any failure they reported was invisible, which is the root
  of every "failed with no reason" symptom this week. The runtime now reads
  both places.
- **The editor now knows the filesystem is case-insensitive.** Its check
  creates a file and then the same name in uppercase, expecting "already
  exists" as the answer on a filesystem like ours. That answer was being
  mistranslated (first into nothing at all, then into "not found" by an
  incomplete translation table of ours), so the check errored and guessed
  wrong. The translation now comes from the system's own table. The wrong
  guess was mostly harmless -- it made the editor treat differently-cased
  names as different files, which the filesystem does not.
- **A file operation that fails now says why.** AROS reports failures through a
  channel that does not reliably reach the one the Rust runtime reads, so asking
  about a file that is not there came back as a failure with no reason attached,
  which a caller cannot tell apart from a broken disk. It matters most to the
  file watcher: the editor's language server rebuilds constantly, creating and
  deleting working directories as it goes, and the watcher regularly asks about
  one that has just been deleted. Told "gone" it steps over it; told nothing it
  abandoned the scan. An external edit now shows up in twenty to thirty seconds
  rather than upwards of a minute, though that is one measurement and the
  polling is still the underlying cost.
- **Changes made to a file outside the editor are picked up** after all: a file
  created on the Mac appears in the tree, and an edit to an open file reloads it.
  This was listed as missing on 2026-07-25 and was fixed, unnoticed, by the path
  handling that went in the same day. It is slow, though: a new file showed up
  within half a minute and a changed one took between half a minute and a
  minute and a half, against a two-second polling interval on a nineteen-file
  project. Why it is that much slower than it asks to be is not yet established.
  AROS cannot report a change, so the editor has to keep looking, and a way for
  it to be told instead is the real fix.

## 2026-07-25 - Programs can talk to programs they start

- A Rust program on AROS can now **run another program and talk to it while it
  runs**: read its output as it appears rather than only after it finishes, send
  it input, and be told when it exits along with its real exit code. Before this,
  starting a program meant waiting for it to end and only then reading what it
  wrote. This is what an editor needs to host a language server or a build tool
  on AROS itself, and it is the groundwork for a real terminal.
- Two things had to be worked around. AROS's shell reports every failure as the
  same generic error, so the actual exit code is now read from where the shell
  keeps it. And a program started without anything to type at it used to inherit
  the console and wait forever for input that was never coming; it now gets an
  empty input instead.


## 2026-07-25 - Zed stops freezing, and shows live diagnostics

- The editor no longer freezes after a minute of use, and **rust-analyzer errors
  now appear** as red underlines with an error count in the status bar. Both were
  the same bug: a lock library used across the Rust ecosystem has no AROS support,
  so when a thread waited for a lock it spun in a tight loop instead of sleeping.
  AROS gives threads of equal priority equal turns, so that one spinning thread
  starved every other one, including the editor's own display thread and the one
  reading the language server's replies. Threads now sleep properly on AROS.
- The editor **window can be resized** by dragging its size gadget, and the layout
  reflows with it. It asked for a size gadget but never declared how small or
  large it could get, and AROS then pins a window to the size it opened at.

## 2026-07-25 - The real Zed editor runs on AROS

- `C:Zed` is now **Zed's own binary**, not a shim built over its editor crates.
  It opens a project and shows the real thing: a file tree you can expand, editor
  tabs, breadcrumbs, syntax highlighting, a status bar, and the side panels.
- Three fixes got it from "links" to "usable". Zed's tokio runtime on AROS has no
  I/O driver, so every HTTP request (telemetry, registry fetches) panicked a
  worker thread seconds after startup and took the editor down; AROS now uses
  Zed's offline HTTP client, which the language server does not go through.
  And the file tree would not expand a single folder: every file reported the
  same file id, which the project scanner reads as a symlink loop. The Rust
  runtime on AROS now reports real file ids, which any program that identifies
  files this way needed anyway.
- Not there yet: the language server still runs on the Mac rather than on AROS.
  (External file changes *are* noticed, contrary to what this entry first said;
  see the 2026-07-27 entry.)

## 2026-07-25 - The window boots at 1366x768

- AROS now comes up at **1366x768** instead of 800x600. The desktop has to be
  idle to change resolution, so the size you boot into is the one you get to
  work in, and 800x600 was too small for a real editor window. The mode ladder
  is unchanged, so dragging the window edge still snaps through all 16 modes.

## 2026-07-25 - Zed: live language-server diagnostics

- The editor now shows **real rust-analyzer diagnostics** on AROS: open a Rust
  file and genuine errors are underlined in the code and marked in the scrollbar,
  answered by a real language server analysing the project. The server runs on
  the Mac and the editor talks to it over a socket, since AROS cannot yet run
  rust-analyzer itself.
- Two fixes made it work. File paths now translate between AROS volumes and the
  host, so the editor and the language server agree on which file is being
  discussed (before this, no server ever started). And a long-standing hazard in
  the Rust runtime's `readlink` was fixed: when the filesystem reported "buffer
  too small" for something that is not a symlink, it kept doubling its buffer
  until memory ran out and the program died. It now gives up cleanly. This one
  affected any Rust program on AROS that inspects paths, not just the editor.

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
