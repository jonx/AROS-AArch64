# AROS AArch64 bring-up — agent loop entry points.
#
#   make run                 build + boot + verify the default marker ([M1])
#   make run MARKER='[M3]'   verify a specific serial marker
#   make shot MARKER='[M9]'  same, plus a framebuffer screendump
#   make dbg                 boot frozen with a gdbstub + scripted lldb state dump
#   make clean
#
# Toolchain: LLVM (clang cross-compiles to any target; ld.lld emits ELF). The
# eventual real AROS port will use AROS's own GCC crosstools — this is just the
# bring-up toolchain. Override LLVM=... if your brew prefix differs.

LLVM    ?= /opt/homebrew/opt/llvm/bin
LLD     ?= /opt/homebrew/opt/lld/bin
CC      := $(LLVM)/clang
LD      := $(LLD)/ld.lld
OBJCOPY := $(LLVM)/llvm-objcopy

TARGET  := aarch64-none-elf
WARN    := -Wall -Wextra
COMMON  := --target=$(TARGET) -ffreestanding -nostdlib $(WARN)
ASFLAGS := $(COMMON)
# MMU is off until M4: all RAM is Device memory, so force aligned accesses and
# keep the compiler off the FP/NEON registers (not enabled yet).
CFLAGS  := $(COMMON) -O2 -mstrict-align -mgeneral-regs-only -fno-stack-protector

ELF     := build/aros-aarch64.elf
OBJS    := build/start.o build/kmain.o build/uart.o build/shell.o build/exc.o build/vectors.o build/mmu.o build/irq.o build/pmm.o build/task.o build/switch.o build/fb.o build/sched.o
MARKER  ?= [M10]
# Cumulative markers a healthy boot prints, in order. Extend as milestones land.
MARKERS ?= [M2] [M3] [M4] [M5] [M6] [M7] [M8] [M9] [M10a] [M10]
# Keystrokes fed to the M8 shell over the serial socket (\n decoded by printf %b).
INPUT   ?= ping\nticks\nquit\n

.PHONY: image run shot dbg test hosted hosted-run hosted-preempt hosted-abi hosted-exec hosted-mem hosted-kern hosted-display hosted-cocoametal cocoametal-dylib cocoametal-abi cocoametal-hiddsim cocoametal-d2t cocoametal-input cocoametal-settings hosted-coreaudio hosted-clipboard hosted-hostvolume hosted-bsdsocket hosted-library hosted-signal hosted-msgport hosted-device hosted-execboot hosted-jit68k hosted-jit68k-hardened hosted-jit68k-j2 hosted-jit68k-j3 hosted-jit68k-j4 hosted-jit68k-j5a hosted-jit68k-j5b hosted-jit68k-j5c hosted-jit68k-j5d hosted-jit68k-j5e hosted-jit68k-j5f hosted-jit68k-j5g hosted-jit68k-j5h hosted-jit68k-j5i hosted-jit68k-j5j hosted-jit68k-apps hosted-test clean

build:
	@mkdir -p build

build/%.o: boot/%.S | build
	$(CC) $(ASFLAGS) -c $< -o $@

build/%.o: boot/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJS) boot/linker.ld
	$(LD) -T boot/linker.ld $(OBJS) -o $@

image: $(ELF)
	@echo ">> built $(ELF)"

run: image
	IMG=$(ELF) INPUT='$(INPUT)' ./harness/run.sh '$(MARKER)'

shot: image
	IMG=$(ELF) INPUT='$(INPUT)' SHOT=1 ./harness/run.sh '$(MARKER)'

dbg: image
	SYMS=$(ELF) ./harness/lldb-dump.sh

test: image
	IMG=$(ELF) INPUT='$(INPUT)' ./harness/test.sh $(MARKERS)

# ---- Phase 2: hosted on macOS (a native arm64 process; macOS owns the drivers) ----
HOST_BIN := build/host-aros
hosted: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/host.c hosted/switch.S -o $(HOST_BIN)

hosted-run: hosted
	BIN=$(HOST_BIN) ./harness/run-hosted.sh '[H1]'

hosted-preempt: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/preempt.c -o build/host-preempt
	BIN=build/host-preempt ./harness/run-hosted.sh '[H2]'

# H3: the host-call ABI shim — marshal AROS-side args into Apple's arm64 variadic
# ABI (varargs on the stack). The make-or-break cross-ABI boundary, hand-written.
hosted-abi: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/abishim.c hosted/abishim.S -o build/host-abishim
	BIN=build/host-abishim ./harness/run-hosted.sh '[H3] host-call ABI shim ok'

# H4: the AROS exec scheduler model, hosted — priority TaskReady + the real
# core_Schedule/cpu_Switch/core_Switch/core_Dispatch call graph over SIGALRM.
hosted-exec: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/exec.c -o build/host-exec
	BIN=build/host-exec ./harness/run-hosted.sh '[H4] hosted AROS scheduler ok'

# H5: the AROS exec memory model, hosted — MemHeader/MemChunk first-fit + coalesce
# free-list allocator over an mmap'd region (macOS owns the pages).
hosted-mem: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/mem.c -o build/host-mem
	BIN=build/host-mem ./harness/run-hosted.sh '[H5] hosted AROS AllocMem ok'

# H6: a tiny hosted exec — H4 scheduler + H5 allocator composed. Tasks are
# AllocMem'd from the heap, scheduled preemptively, allocator made Forbid-safe.
hosted-kern: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/kern.c -o build/host-kern
	BIN=build/host-kern ./harness/run-hosted.sh '[H6] hosted exec ok'

# H7: the host display driver — AROS draws a framebuffer from its heap, macOS
# presents it (ImageIO PNG). The agent observes the pixels via the PNG file.
hosted-display: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/display.c -o build/host-display \
		-framework ImageIO -framework CoreGraphics -framework CoreFoundation
	BIN=build/host-display ./harness/run-hosted.sh '[H7] hosted display ok'

# D1: the Apple-native Cocoa/Metal display shim — prove the offscreen Metal
# present pipeline + readback oracle, standalone (no AROS build). Also runs the
# resolution-parametric [D2] check (640x512) and the [D] shader-stage check
# (cm_set_effect / CM_FX_SCANLINE: present-time effect, NOT in the oracle path).
# Offscreen BGRA8 target is the source of truth; the present is a render pass
# (framebufferOnly=YES); a live NSWindow is a non-fatal bonus.
# Host clang (NOT AROS crosstools); -fobjc-arc; clean-room from the spec.
hosted-cocoametal: | build
	clang -fobjc-arc -arch arm64 -O2 -Wall -Wextra \
		hosted/cocoametal/cocoametal.m hosted/cocoametal/cocoametal_window.m \
		hosted/cocoametal/d1_test.m -o build/host-cocoametal \
		-framework Metal -framework Foundation -framework CoreGraphics \
		-framework ImageIO -framework QuartzCore -framework AppKit
	BIN=build/host-cocoametal ./harness/run-hosted.sh '[D1] PASS'

# Item 1 (INTERFACE.md §1c): the dlopen-loadable cocoametal.dylib — the REAL
# artifact the AROS side loads via hostlib.resource (HostLib_Open + GetInterface).
# Built from cocoametal.m + cocoametal_window.m (+ the cm_abi_version added in
# cocoametal.m); d1_test.m is NOT in the dylib. Pulls no AROS headers. Every cm_*
# symbol is exported with DEFAULT visibility via cocoametal.exports (the 10 frozen
# names in §1a order), the binary is NOT stripped (dlsym resolves by name), and it
# is ad-hoc codesigned so a hosted process can dlopen it on this Mac.
COCOAMETAL_DYLIB := build/cocoametal.dylib
cocoametal-dylib: | build
	clang -fobjc-arc -arch arm64 -O2 -Wall -Wextra -dynamiclib \
		-install_name @rpath/cocoametal.dylib \
		-exported_symbols_list hosted/cocoametal/cocoametal.exports \
		hosted/cocoametal/cocoametal.m hosted/cocoametal/cocoametal_window.m \
		hosted/cocoametal/cocoametal_settings.m \
		-o $(COCOAMETAL_DYLIB) \
		-framework Metal -framework Foundation -framework CoreGraphics \
		-framework QuartzCore -framework AppKit
	codesign -s - -f $(COCOAMETAL_DYLIB)
	@echo ">> built $(COCOAMETAL_DYLIB) (exported cm_* symbols:)"
	@nm -gU $(COCOAMETAL_DYLIB) | grep ' _cm_' || true

# Item 2 (INTERFACE.md §8 #2 — highest value): the dlopen-based ABI conformance
# test. Plain C, links NONE of the .m files; it dlopens build/cocoametal.dylib the
# exact way HostLib_GetInterface does, dlsym's all 10 frozen symbols (errcount must
# be 0), checks cm_abi_version()==CM_ABI_VERSION, then drives open->upload->present
# ->readback(asserts the §6 oracle: 4 quadrants + marker exact)->pump->set_effect/
# target_size->close through the resolved function pointers. Green = the seam wires.
cocoametal-abi: cocoametal-dylib
	clang -arch arm64 -O2 -Wall -Wextra \
		-Ihosted/cocoametal hosted/cocoametal/abi_test.c -o build/cocoametal-abi
	BIN=build/cocoametal-abi ./harness/run-hosted.sh '[ABI] PASS'

# D3 host-support (INTERFACE.md §2a + §8): the HIDD-shaped behavioral harness —
# the de-risk + reference for the AROS bitmap-class UpdateRect wiring. Plain C,
# links NONE of the .m files; it dlopens build/cocoametal.dylib (the REAL boundary)
# and drives it the way the AROS HIDD will, BEYOND abi_test's single sequence:
# AROS owns a host-side W*H*4 BGRA8 framebuffer (the AllocMem stand-in) filled with
# the PINNED §2a CMPixelDesc; lazy cm_open on first "Show"; a DIRTY-RECT STREAM of
# partial/overlapping cm_upload_rect+cm_present (the many-small-UpdateRects pattern,
# not a full-frame blit); then cm_readback asserts the composed oracle == an
# independent host reference framebuffer BYTE-EXACT (§6 under realistic usage) and a
# known-pixel round-trip proves B/G/R/A land in the asserted byte positions (catches
# a swizzle bug where the AROS side can't see it). Bounded + watchdog. Marker
# [HIDDSIM] PASS. Additive — no ABI change.
cocoametal-hiddsim: cocoametal-dylib
	clang -arch arm64 -O2 -Wall -Wextra \
		-Ihosted/cocoametal hosted/cocoametal/hiddsim_test.c -o build/cocoametal-hiddsim
	BIN=build/cocoametal-hiddsim ./harness/run-hosted.sh '[HIDDSIM] PASS'

# Item 3 (INTERFACE.md §8 #3 — the de-risk): D2 under the REAL graft threading
# model. Drives cm_open (window) + cm_present (nextDrawable) + cm_pump_events from
# the MAIN pthread under manual CFRunLoopRunInMode(kCFRunLoopDefaultMode,0,true) —
# NEVER NSApplicationMain / [NSApp run]. Documents the minimal AppKit init the boot
# task must do once and reports whether window/nextDrawable work hand-pumped; the
# offscreen + cm_readback oracle must pass regardless. Links the .m files directly
# (it is a host harness exercising the threading model, not the dlopen seam).
cocoametal-d2t: | build
	clang -fobjc-arc -arch arm64 -O2 -Wall -Wextra \
		hosted/cocoametal/cocoametal.m hosted/cocoametal/cocoametal_window.m \
		hosted/cocoametal/d2t_test.m -o build/cocoametal-d2t \
		-framework Metal -framework Foundation -framework CoreGraphics \
		-framework QuartzCore -framework AppKit -framework CoreFoundation
	BIN=build/cocoametal-d2t ./harness/run-hosted.sh '[D2t] PASS'

# D4/D5 (INTERFACE.md §5 — input): the REAL cm_pump_events drain. Drives the input
# pump under the same main-pthread / manual-CFRunLoop / NO-NSApplicationMain model
# as D2t, then SYNTHESIZES NSEvents and injects them in-process via
# [NSApp postEvent:atStart:] (no TCC/accessibility) and asserts the drained
# CMEvent[] field-for-field: [D4] mouse move (exact logical x,y, Y-flip) + LMB
# down/up (code=0 pressed 1/0); [D5] keyDown/Up with a known keyCode + Shift
# (code==keyCode, pressed 1/0, mods&CM_MOD_SHIFT). Value-asserting markers
# [D4] PASS / [D5] PASS. Links the .m files (it exercises the AppKit pump path).
cocoametal-input: | build
	clang -fobjc-arc -arch arm64 -O2 -Wall -Wextra \
		hosted/cocoametal/cocoametal.m hosted/cocoametal/cocoametal_window.m \
		hosted/cocoametal/input_test.m -o build/cocoametal-input \
		-framework Metal -framework Foundation -framework CoreGraphics \
		-framework QuartzCore -framework AppKit -framework CoreFoundation
	BIN=build/cocoametal-input ./harness/run-hosted.sh '[D4D5] PASS'

# SET (INTERFACE.md §9 — settings & options, ABI v2): the host settings panel +
# key/value option ABI. Drives, under the same main-pthread / manual-CFRunLoop /
# NO-NSApplicationMain model as D2t: (1) cm_set_option(CM_OPT_EFFECT,SCANLINE) ->
# cm_present -> the PRESENTED path reflects the effect (odd rows darker, via
# cm_render_effect_readback) while the OFFSCREEN ORACLE stays pass-through
# unchanged; cm_get_option reflects it. (2) cm_set_option of an AROS-facing key
# (CM_OPT_REQUEST_MODE_W=640,_H=512) -> cm_pump_events returns a CM_EV_SETTING
# carrying the key/value (host did NOT act). (3) NSUserDefaults persistence
# round-trip: set an option, simulate reopen (re-read defaults), assert restored.
# Links the .m files (incl. cocoametal_settings.m for the panel + persistence).
# Bounded + watchdog. Value-asserting marker [SET] PASS.
cocoametal-settings: | build
	clang -fobjc-arc -arch arm64 -O2 -Wall -Wextra \
		hosted/cocoametal/cocoametal.m hosted/cocoametal/cocoametal_window.m \
		hosted/cocoametal/cocoametal_settings.m hosted/cocoametal/settings_test.m \
		-o build/cocoametal-settings \
		-framework Metal -framework Foundation -framework CoreGraphics \
		-framework QuartzCore -framework AppKit -framework CoreFoundation
	BIN=build/cocoametal-settings ./harness/run-hosted.sh '[SET] PASS'

# V: the host-volume Mac glue — self-contained NFC normalization (table-driven,
# NOT CFStringNormalize), the ".<name>.amimeta" sidecar (atomic temp+rename,
# omit-when-default), and Latin-1<->UTF-8 filename charset glue, proved against
# the real macOS FS in a temp dir. Plain host clang (no framework); clean-room
# from docs/features/host-volume/spec.md. These are the functions the AROS
# emul-handler per-host overlay will call (built later by the AROS crosstools).
hosted-hostvolume: | build
	clang -O2 -Wall -Wextra hosted/hostvolume/hv_norm.c \
		hosted/hostvolume/hv_charset.c hosted/hostvolume/hv_meta.c \
		hosted/hostvolume/v_test.c -o build/host-hostvolume
	BIN=build/host-hostvolume ./harness/run-hosted.sh '[V] PASS'

# A: the CoreAudio host ring + headless/silent offline-render proof — a single-
# producer/single-consumer lock-free ring of int16 stereo PCM (AHIST_S16S) feeds
# an offline kAudioUnitSubType_GenericOutput AudioUnit whose render callback pulls
# from the ring (RT contract: memcpy + int16->float32, no locks/alloc/blocking),
# driven by AudioUnitRender to a WAV in run/. Asserts RMS + Goertzel-440Hz +
# underruns==0 over a run that wraps the ring ~108x under a real two-thread race.
# Host clang (NOT AROS crosstools); clean-room from the spec; no live device.
hosted-coreaudio: | build
	clang -arch arm64 -O2 -Wall -Wextra \
		hosted/coreaudio/coreaudio_shim.c hosted/coreaudio/a_test.c \
		-o build/host-coreaudio \
		-framework AudioToolbox -framework AudioUnit \
		-framework CoreFoundation -framework Foundation
	BIN=build/host-coreaudio ./harness/run-hosted.sh '[A] PASS'

# C: the NSPasteboard clipboard host shim — prove pasteboard text get/set, the
# changeCount change-signal source, and the ISO-8859-1<->UTF-8 transcode the bridge
# mandates, standalone (no AROS build). Uses a uniquely-named NSPasteboard so it
# never touches the user's real clipboard. Host clang (NOT AROS crosstools);
# -fobjc-arc; clean-room from clipboard-bridge/spec.md.
hosted-clipboard: | build
	clang -fobjc-arc -arch arm64 -O2 -Wall -Wextra \
		hosted/clipboard/pasteboard.m hosted/clipboard/c_test.m \
		-o build/host-clipboard \
		-framework Foundation -framework AppKit
	BIN=build/host-clipboard ./harness/run-hosted.sh '[C] PASS'

# N: the bsdsocket host pump — non-blocking host BSD sockets + a kqueue readiness
# pump thread that converts fd-readiness into a per-target wake (the stand-in for
# an AROS Signal/WaitSelect), proved standalone against a localhost TCP echo
# server (hermetic, no entitlement, no DNS). Asserts: [N-1] non-blocking connect
# (EINPROGRESS via the pump) + send + recv round-trip; [N-2] WaitSelect-style —
# register several sockets, drive a subset, the pump reports EXACTLY the ready
# set; [N-3] a would-block recv returns EWOULDBLOCK and the pump LATER wakes when
# data arrives (no busy-spin). Host clang (NOT AROS crosstools), libSystem has
# sockets+kqueue; clean-room from docs/features/bsdsocket-net/spec.md.
hosted-bsdsocket: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/bsdsocket/*.c -o build/host-bsdsocket
	BIN=build/host-bsdsocket ./harness/run-hosted.sh '[N] PASS'

# H8: a tiny exec.library via the real AROS LVO mechanism — JumpVec table built by
# MakeLibrary, indirect LVO dispatch, SetFunction hot-patch. Data-pointer vectors,
# so no Apple-Silicon W^X / MAP_JIT wall.
hosted-library: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/library.c -o build/host-library
	BIN=build/host-library ./harness/run-hosted.sh '[H8] hosted exec.library ok'

# H9: exec Wait()/Signal() — tasks that genuinely block on TS_WAIT/TaskWait and
# wake via Signal. Producer/consumer ping-pong + a free-runner proof.
hosted-signal: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/signal.c -o build/host-signal
	BIN=build/host-signal ./harness/run-hosted.sh '[H9] hosted exec Wait/Signal ok'

# H10: exec message ports — PutMsg/WaitPort/GetMsg/ReplyMsg on Wait/Signal. The
# canonical client/server request-reply (device-I/O) loop, hosted.
hosted-msgport: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/msgport.c -o build/host-msgport
	BIN=build/host-msgport ./harness/run-hosted.sh '[H10] hosted exec message ports ok'

# H11: a device backed by a real macOS file — AROS exec I/O (DoIO/IORequest) over
# the message ports drives pread/pwrite on a real file. The "macOS owns the
# drivers" thesis, end to end.
hosted-device: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/device.c -o build/host-device
	BIN=build/host-device ./harness/run-hosted.sh '[H11] hosted device ok'

# H12 (capstone): exec.library boot — the full exec reached through the LVO hub.
# Services (AllocMem/FreeMem/Signal/Wait/AddTask) live in the jump-vector table
# below SysBase; tasks call them through the base, scheduled preemptively.
hosted-execboot: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/execboot.c -o build/host-execboot
	BIN=build/host-execboot ./harness/run-hosted.sh '[H12] exec.library boot ok'

# J1: the W^X-aware MAP_JIT executable-memory layer — the substrate the adapted
# Emu68 emitter ([J2]) and the native LoadSeg path both sit on. mmap(MAP_JIT) +
# pthread_jit_write_protect_np(0/1) + sys_icache_invalidate; a hand-assembled
# AArch64 stub (movz w0,#imm; ret) is written, finalized, and CALLED, asserting
# the exact returned constant (stale I-cache = wrong value, not a crash).
#
# Entitlement/codesign, RESOLVED empirically on this Mac (macOS 26.5, Apple silicon):
#   * The default linker AD-HOC signature (NO hardened runtime) already permits
#     MAP_JIT — so the plain build below PASSES with NO codesign step.
#   * Under the HARDENED RUNTIME (codesign -o runtime, as graft/bootrun.sh uses),
#     mmap(MAP_JIT) fails EINVAL UNLESS com.apple.security.cs.allow-jit is granted.
#     `make hosted-jit68k-hardened` reproduces that resolved incantation.
hosted-jit68k: | build
	clang -arch arm64 -O2 -Wall -Wextra \
		hosted/jit68k/jit_region.c hosted/jit68k/j1_test.c -o build/host-jit68k
	BIN=build/host-jit68k ./harness/run-hosted.sh '[J1] PASS'

# Same binary under the hardened runtime + the allow-jit entitlement — the exact
# signing the AROS bootstrap needs once it adopts -o runtime (R-JIT-ENTITLE).
hosted-jit68k-hardened: | build
	clang -arch arm64 -O2 -Wall -Wextra \
		hosted/jit68k/jit_region.c hosted/jit68k/j1_test.c -o build/host-jit68k-hardened
	codesign -s - -f -o runtime \
		--entitlements hosted/jit68k/jit68k.entitlements.plist build/host-jit68k-hardened
	BIN=build/host-jit68k-hardened ./harness/run-hosted.sh '[J1] PASS'

# J2: prove the ADOPTED Emu68 AArch64 emitter (the verbatim, MPL-quarantined
# hosted/jit68k/emu68/A64.h) runs HOSTED in our [J1] MAP_JIT region. The glue
# (j2_build.c, OURS) hand-decodes a fixed register-only 68k block
#   moveq #10,d0 ; moveq #7,d1 ; add.l d1,d0 ; rts   (expect d0=17)
# into AArch64 with Emu68's encoders, writes it into the MAP_JIT cache, and runs
# it under W^X. The result (full d0..d7/a0..a7/ccr/pc register file) is asserted
# BIT-IDENTICAL to a from-scratch INDEPENDENT 68k interpreter (j2_interp.c, OURS —
# NOT Emu68's own decode). Validates the [J0] bet that Emu68's emitter separates
# cleanly from its bare-metal runtime. The Emu68 emitter is #included from the
# quarantine dir (-Ihosted/jit68k/emu68); no Emu68 source is copied into our files.
#
# Build/sign reuses the [J1] path (plain ad-hoc already permits MAP_JIT on this Mac).
hosted-jit68k-j2: | build
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k/emu68 \
		hosted/jit68k/jit_region.c hosted/jit68k/j2_build.c \
		hosted/jit68k/j2_interp.c hosted/jit68k/j2_test.c -o build/host-jit68k-j2
	BIN=build/host-jit68k-j2 ./harness/run-hosted.sh '[J2] PASS'

# J3: prove the 68k -> native LVO-call bridge (the integration boundary). Three
# grounded parts, all value-asserting:
#   (1) vector recognition: compute the 68k jump-target  libbase - n*6  via the REAL
#       negative-offset rule (__AROS_GETJUMPVEC, LIB_VECTSIZE==6;
#       arch/m68k-all/include/aros/cpu.h:82,81) and assert it round-trips to n;
#   (2) the marshaller: three native AArch64 stubs declared with the REAL register
#       macros AROS_LHA/AROS_UFHA (libcall.h:1586 / asmcall.h:822), each with a
#       DIFFERENT 68k register map (D0 ; D0+A0 ; A1+D1+D2). A reverse-H3 marshal
#       thunk is EMITTED via the adopted Emu68 emitter (emu68/A64.h) into the [J1]
#       MAP_JIT region: it reads the source 68k registers from a struct M68KState,
#       places them in AAPCS64 x0..x7, blr's the stub, and stores the return in d0;
#   (3) verify: each stub records the exact args it saw; PASS only if every
#       function's args AND its 68k-d0 return are exact.
# Reuses the [J1] build/sign path (plain ad-hoc already permits MAP_JIT on this Mac).
# The Emu68 emitter is #included from the quarantine dir (-Ihosted/jit68k/emu68);
# no Emu68 source is copied into our files.
hosted-jit68k-j3: | build
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k/emu68 \
		hosted/jit68k/jit_region.c hosted/jit68k/j3_vector.c \
		hosted/jit68k/j3_marshal.c hosted/jit68k/j3_test.c -o build/host-jit68k-j3
	BIN=build/host-jit68k-j3 ./harness/run-hosted.sh '[J3] PASS'

# J4: prove the load -> relocate -> place-in-sandbox -> translate -> run -> return
# chain end-to-end for a REAL (hand-assembled) big-endian 68k hunk binary whose
# entry code uses only the register-only opcodes the [J2] path handles (moveq/rts).
#   * Minimal hunk loader (OURS, j4_loader.c): parse HUNK_HEADER/CODE/DATA/RELOC32/END,
#     allocate each hunk in a 32-bit sandbox, apply HUNK_RELOC32 EXACTLY as the real
#     AROS loader rom/dos/internalloadseg_aos.c:292-332 (read BE32 at offset, add the
#     target hunk's sandbox base, write BE32). Hunk types from doshunks.h.
#   * The test binary has a HUNK_CODE (moveq #42,d0 ; rts) + a HUNK_DATA pointer slot
#     + a HUNK_RELOC32 that patches it into the CODE hunk -> relocation is exercised.
#   * The entry is translated through the [J2] Emu68-emitter path (emu68/A64.h) into
#     the [J1] MAP_JIT region and RUN under W^X, returning the 68k d0.
#   * Value-asserts (PASS iff BOTH): (a) the relocated DATA pointer == CODE_base +
#     addend, byte-exact big-endian; (b) the executed entry returns d0 == 42. A
#     negative control (skip relocation -> raw addend) proves the relocation assert
#     bites. Watchdog 10 s -> FAIL.
# DEFERRED to [J5]: the full Emu68 decoder + register-allocator lift (memory ops,
# branches, real jsr-through-vector) + the pointer/sandbox boundary for memory ops
# and library calls from the running program. This spike proves the loader/relocator/
# sandbox/run pipeline, not a rich CPU.
# Reuses the [J1] build/sign path (plain ad-hoc already permits MAP_JIT on this Mac).
# The Emu68 emitter is #included from the quarantine dir (-Ihosted/jit68k/emu68);
# no Emu68 source is copied into our files.
hosted-jit68k-j4: | build
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k/emu68 \
		hosted/jit68k/jit_region.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/j4_build.c hosted/jit68k/j4_test.c -o build/host-jit68k-j4
	BIN=build/host-jit68k-j4 ./harness/run-hosted.sh '[J4] PASS'

# J5a: translate a small block that TOUCHES MEMORY through the sandbox-pointer
# boundary, verified against an INDEPENDENT reference. A scoped increment of the
# [J5] decoder/RA mountain — load/store + the sandbox boundary only.
#   * Block: move.l (a0),d0 ; addq #1,d0 ; move.l d0,(a0) ; rts  (load via A0, +1,
#     store back). Loaded from a REAL big-endian hunk binary via the [J4] loader
#     (reused), placed in a 32-bit sandbox.
#   * EA decode + memory access are HAND-ROLLED (j5a_build.c, OURS) around the
#     adopted Emu68 EMITTER (emu68/A64.h): Emu68's M68k_EA.c + RegisterAllocator64.c
#     do NOT lift incrementally for a hosted sandbox — they assume An is a host
#     pointer (1:1 MMU, no sandbox base), read every ext word through the ICACHE
#     software cache (cache.c), and keep SR/CTX in EL0 system registers. The
#     [J5a] adoption finding is documented in j5a_jit68k.h.
#   * Sandbox-pointer boundary: each access maps An -> host = (host_mem-origin)+An
#     (UXTW add), BOUNDS-CHECKS An (single unsigned (An-origin)>u(size-4) compare,
#     clean fault on out-of-range — no host OOB), and byteswaps big-endian (REV).
#   * Value-asserts (PASS iff ALL): JITed registers == the independent interpreter's
#     (j5a_interp.c, OURS, no Emu68); JITed sandbox MEMORY == the interpreter's,
#     byte-exact big-endian; d0 == value+1 and the stored longword == value+1.
#   * Negative controls (each must bite): skip the store (memory unchanged);
#     wrong-endianness (no REV -> diverges); out-of-range A0 (must fault cleanly).
#     Watchdog 10 s -> FAIL.
# DEFERRED to [J5b]: branches/loops, full opcode + addressing-mode coverage, OUR
# register allocator around the emitter, real jsr-through-vector decode from a
# stream, library calls from the running program, and a sandbox-backed allocator
# for return-pointers outside the sandbox.
# Reuses the [J1] build/sign path (plain ad-hoc already permits MAP_JIT on this Mac).
# The Emu68 emitter is #included from the quarantine dir (-Ihosted/jit68k/emu68);
# no Emu68 source is copied into our files.
hosted-jit68k-j5a: | build
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k/emu68 \
		hosted/jit68k/jit_region.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/j5a_build.c hosted/jit68k/j5a_interp.c \
		hosted/jit68k/j5a_test.c -o build/host-jit68k-j5a
	BIN=build/host-jit68k-j5a ./harness/run-hosted.sh '[J5a] PASS'

# J5b: translate a self-contained 68k LOOP — a real conditional BACKWARD branch with
# genuine condition codes — in a SINGLE jit_region, verified against an INDEPENDENT
# reference. A scoped increment of the [J5] decoder/RA mountain: control flow only.
#   * Loop: moveq #0,d0 ; moveq #5,d1 ; L: add.l d1,d0 ; subq.l #1,d1 ; bne.s L ; rts
#     (sums 5+4+3+2+1 = 15 into d0 over 5 iterations, d1=0). Loaded from a REAL
#     big-endian hunk binary via the [J4] loader (reused), placed in a 32-bit sandbox.
#   * REAL condition codes: subq.l #1,d1 is emitted as `subs w_d1,w_d1,#1` (the
#     FLAG-SETTING subtract, emu68/A64.h); the bne.s is an AArch64 `b.ne` (A64_CC_NE,
#     Z==0) consuming the NZCV the subs just produced. The full 68k CCR (N/Z/V/C/X) is
#     ALSO recomputed into state->ccr with NON-flag-setting ops (cset/orr/str) emitted
#     between the subs and the b.ne, so the branch still sees the subs flags. (68k
#     subtract C = borrow = AArch64 carry-CLEAR; derived explicitly.)
#   * SINGLE-REGION internal backward branch: the whole loop is emitted once; the
#     loop top is a recorded output-word index and the b.ne offset is (target-word -
#     bne-word) — NEGATIVE. No cross-region chaining (deferred to [J5c]).
#   * EA decode / branch / CCR are HAND-ROLLED (j5b_build.c, OURS) around the adopted
#     Emu68 EMITTER (emu68/A64.h) — Emu68's M68k_EA.c + RegisterAllocator64.c do NOT
#     lift incrementally (the [J5a] finding); NO NEW Emu68 file vendored, so the
#     Exhibit-B check is unchanged. Only existing A64.h encoders are used.
#   * Value-asserts (PASS iff ALL): JITed registers == the independent interpreter's
#     (j5b_interp.c, OURS, no Emu68, with the real subtract flag rule); JITed CCR ==
#     the interpreter's full N/Z/V/C/X; d0==15 && d1==0 && Z set; the loop ran exactly
#     5 iterations and terminated.
#   * Negative control (must bite): emit the backward branch as ALWAYS-taken (broken Z
#     test) -> the loop never terminates; run in a forked child with its own 2s alarm
#     and assert the child HUNG (was killed by the alarm). Main watchdog 10s -> FAIL.
# DEFERRED to [J5c]: cross-region block chaining + an instruction cache, full Bcc/DBcc
# condition coverage, forward branches across blocks, real jsr-through-vector decode
# from a stream, library calls from the running program, and OUR register allocator.
# Reuses the [J1] build/sign path (plain ad-hoc already permits MAP_JIT on this Mac).
# The Emu68 emitter is #included from the quarantine dir (-Ihosted/jit68k/emu68);
# no Emu68 source is copied into our files.
hosted-jit68k-j5b: | build
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k/emu68 \
		hosted/jit68k/jit_region.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/j5b_build.c hosted/jit68k/j5b_interp.c \
		hosted/jit68k/j5b_test.c -o build/host-jit68k-j5b
	BIN=build/host-jit68k-j5b ./harness/run-hosted.sh '[J5b] PASS'

# J5c: RE-HOST Emu68's REAL per-opcode decoders + register allocator (NOT hand-rolled),
# to prove broad opcode coverage is reachable by ADOPTING Emu68's decode logic. The
# verbatim, MPL-quarantined emu68/M68k_LINE{8,9,B,C,D}.c + M68k_MOVE.c + M68k_MULDIV.c +
# M68k_EA.c are DRIVEN (via the line dispatch) to translate a richer block than the
# hand-rolled [J2]..[J5b] path can reach:
#   moveq #-5,d2 ; add.l d2,d0 ; sub.l d3,d0 ; and.l d4,d0 ; or.l d5,d0 ; eor.l d6,d1 ;
#   muls.w d7,d1 ; cmp.l d1,d0 ; and.l d2,d2 ; rts   (8 opcodes, 6 real LINE decoders).
# This required PROVIDING hosted replacements for exactly the three [J5a] couplings:
#   HOOK 1 sandbox/EA       — surface present; the richer block is register-direct (the
#                             memory-EA modes stay blocked by EA's no-base + BE-CPU emit).
#   HOOK 2 cache_read_16    — j5c_shims.c: big-endian fetch straight from the host stream,
#                             splicing back the high 32 bits the uint32_t param truncates
#                             (a DEEPER fetch coupling: Emu68's fetch addr is 32-bit).
#   HOOK 3 RA SR/CTX        — j5c_ra.c (OURS): memory-backed CCR (ldr/str from the state
#                             struct), NOT mrs/msr TPIDR_EL0; D0..D7/A0..A7 in the Emu68 map.
# A FOURTH portability coupling: Emu68's decoders use GNU __attribute__((alias)) function
# aliases, which clang/Mach-O REJECTS — emu68_darwinize.pl (OURS) rewrites the alias chains
# into plain-C tail-call forwarders in build-dir copies, KEEPING the quarantine byte-verbatim.
#   * Value-asserts (PASS iff ALL): JITed D0..D7/A0..A7 == an INDEPENDENT from-scratch
#     interpreter (j5c_interp.c, OURS, no Emu68), byte-exact; moveq #-5 REAL sign-extend
#     (d2==0xFFFFFFFB); the final CCR Z/N == the reference's (non-trivial: N set).
#   * Negative control (must bite): corrupt the decoded opcode stream -> the REAL decoder
#     emits a different (valid) instruction -> JITed value diverges from the reference.
#     Watchdog 10s -> FAIL.
# VERDICT (printed): re-hosting Emu68's REAL decoder + RA WORKS for register/ALU/control
# opcodes; broad coverage of that class = vendor more M68k_LINE*.c + extend the oracle.
# The memory-EA modes remain blocked (edit M68k_EA.c — the [J5a] surgery).
# The darwinize step regenerates build/emu68-darwin/*.c from the quarantine on each build.
hosted-jit68k-j5c: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_MOVE M68k_MULDIV M68k_EA; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k -Ihosted/jit68k/emu68 \
		-Wno-unused-function \
		hosted/jit68k/jit_region.c hosted/jit68k/j5c_shims.c hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5c_build.c hosted/jit68k/j5c_interp.c hosted/jit68k/j5c_test.c \
		build/emu68-darwin/M68k_LINE8.c build/emu68-darwin/M68k_LINE9.c \
		build/emu68-darwin/M68k_LINEB.c build/emu68-darwin/M68k_LINEC.c \
		build/emu68-darwin/M68k_LINED.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c build/emu68-darwin/M68k_EA.c \
		-o build/host-jit68k-j5c
	BIN=build/host-jit68k-j5c ./harness/run-hosted.sh '[J5c] PASS'

# [J5d] BROADEN the [J5c] re-hosting so the WHOLE apps68k corpus runs through the JIT.
# Where [J5c] drove the REAL Emu68 decoders for ONE straight-line register block, [J5d]
# is a little engine: a per-basic-block translator driving the REAL decoders for every
# data/ALU/move/memory opcode + OUR re-hosted dispatcher ("MainLoop") owning inter-block
# control flow, the (An)/(An)+ sandbox-memory EA, and the jsr-through-vector -> [J3]
# library bridge. It runs all four corpus programs (mul=42, fact=120, arraysum=150,
# libcall=0 + the AllocMem/PutChar/FreeMem stub log) byte-exact vs an INDEPENDENT
# from-scratch interpreter (j5d_interp.c, OURS, no Emu68).
#   * Vendors M68k_LINE5.c (addq/subq) + M68k_CC.c (EMIT_TestCondition, link-only)
#     verbatim into the quarantine (Exhibit-B re-grep clean; NOTICE updated).
#   * The (An) EA edit is the disclosed [J5a] fix applied to the BUILD-DIR copy of
#     M68k_EA.c by emu68_darwinize.pl: each (An)-class load/store site is rewritten to
#     call OUR j5d_ea_mem emitter (sandbox-base add + REV byteswap + post/pre index).
#     The QUARANTINE M68k_EA.c stays BYTE-VERBATIM (diff vs upstream empty).
#   * Reuses the [J5c] HOOK 2 fetch + HOOK 3 memory-backed RA (j5c_shims.c, j5c_ra.c)
#     and the REAL [J3] marshaller (j3_marshal.c) + vector math (j3_vector.c).
#   * Negative control (must bite): corrupt mul's add dest reg -> the REAL decoder emits
#     a different valid insn -> d0 diverges from 42. Watchdog 15s -> FAIL.
hosted-jit68k-j5d: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE0 M68k_LINE4 M68k_LINE5 M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_LINEE M68k_MOVE M68k_MULDIV M68k_CC; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/M68k_EA.c build/emu68-darwin/M68k_EA.c --ea-sandbox
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k -Ihosted/jit68k/emu68 \
		-Ihosted/jit68k/apps68k -Wno-unused-function \
		hosted/jit68k/jit_region.c hosted/jit68k/j5c_shims.c hosted/jit68k/j5g_shims.c hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5d_engine.c hosted/jit68k/j5d_ea_helpers.c hosted/jit68k/j5d_interp.c \
		hosted/jit68k/j5d_test.c \
		hosted/jit68k/j3_vector.c hosted/jit68k/j3_marshal.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/apps68k/stublib.c \
		build/emu68-darwin/M68k_LINE0.c build/emu68-darwin/M68k_LINE4.c \
		build/emu68-darwin/M68k_LINE5.c build/emu68-darwin/M68k_LINE8.c \
		build/emu68-darwin/M68k_LINE9.c build/emu68-darwin/M68k_LINEB.c \
		build/emu68-darwin/M68k_LINEC.c build/emu68-darwin/M68k_LINED.c \
		build/emu68-darwin/M68k_LINEE.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c \
		build/emu68-darwin/M68k_EA.c build/emu68-darwin/M68k_CC.c \
		-o build/host-jit68k-j5d
	BIN=build/host-jit68k-j5d ./harness/run-hosted.sh '[J5d] PASS'

# [J5e] THE OPTIMIZE DELIVERABLE: a block-scoped register allocator. The REAL Emu68
# decoders already keep the 68k Dn/An in fixed host regs across a block (no per-op spill);
# what [J5d] did naively was bracket EVERY block with a fixed frame loading all 16 Dn/An +
# storing all 16 back unconditionally (32 state ldr/str/block). [J5e]'s RA (j5c_ra.c) tracks
# which regs are READ before written (live-in) and WRITTEN (dirty) as the decoders run, and
# the engine (j5d_engine.c) loads ONLY live-in regs in the prologue + stores back ONLY dirty
# regs in the epilogue. SPILL POLICY: every block exit (RTS / branch / the jsr->[J3] library
# bridge) stores dirty regs to the state struct BEFORE the boundary, so the memory state is
# consistent for the bridge marshal / next block. The marker `[J5e] PASS` is gated on BOTH
# the corpus staying byte-exact vs the independent interpreter AND a measured reduction in
# emitted instructions + state-memory traffic. Same sources/decoders as [J5d]; only the
# test driver differs (it reports the before/after numbers). Watchdog 15s -> FAIL.
hosted-jit68k-j5e: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE0 M68k_LINE4 M68k_LINE5 M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_LINEE M68k_MOVE M68k_MULDIV M68k_CC; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/M68k_EA.c build/emu68-darwin/M68k_EA.c --ea-sandbox
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k -Ihosted/jit68k/emu68 \
		-Ihosted/jit68k/apps68k -Wno-unused-function \
		hosted/jit68k/jit_region.c hosted/jit68k/j5c_shims.c hosted/jit68k/j5g_shims.c hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5d_engine.c hosted/jit68k/j5d_ea_helpers.c hosted/jit68k/j5d_interp.c \
		hosted/jit68k/j5e_test.c \
		hosted/jit68k/j3_vector.c hosted/jit68k/j3_marshal.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/apps68k/stublib.c \
		build/emu68-darwin/M68k_LINE0.c build/emu68-darwin/M68k_LINE4.c \
		build/emu68-darwin/M68k_LINE5.c build/emu68-darwin/M68k_LINE8.c \
		build/emu68-darwin/M68k_LINE9.c build/emu68-darwin/M68k_LINEB.c \
		build/emu68-darwin/M68k_LINEC.c build/emu68-darwin/M68k_LINED.c \
		build/emu68-darwin/M68k_LINEE.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c \
		build/emu68-darwin/M68k_EA.c build/emu68-darwin/M68k_CC.c \
		-o build/host-jit68k-j5e
	BIN=build/host-jit68k-j5e ./harness/run-hosted.sh '[J5e] PASS'

# [J5f] GENERALISE the flat-PC engine into a PC-DRIVEN dispatcher with a REAL 68k RETURN
# STACK + a PC-keyed BLOCK CACHE. Where [J5d]/[J5e] ran a flat PC (rts = top-level exit,
# jsr d16(A6) = library vector, 8-bit Bcc only), [J5f] adds: nested bsr/jsr/rts that push
# and pop big-endian 68k return addresses on a7 in the SANDBOX; computed jsr(An)/jmp(An)
# whose target comes from a register; the full Bcc/BRA/BSR .B/.W/.L displacement widths;
# and a block cache so a loop body / repeatedly-called subroutine translates ONCE. The
# new subroutine program (apps68k/sumsq.s -> bin/sumsq.exe, sum of squares 1..5 = 55 via a
# `square` subroutine that nests a `mul` helper, called from a loop + once via a COMPUTED
# jsr(a0)) runs through the SAME engine that drives the REAL Emu68 per-opcode decoders. The
# marker `[J5f] PASS` is gated on the result (55), the FULL register file (incl. a7 back at
# the initial SP), AND the sandbox memory INCLUDING THE RETURN STACK all byte-exact vs the
# independent from-scratch interpreter (j5d_interp.c, OURS, no Emu68 — extended to model the
# same SP/stack/control-flow), plus the return-stack telemetry (pushes==pops, max nest depth
# 2, >=1 computed jump) and the block-cache win (translations << executions, real hits).
# Negative controls bite: a corrupt muls source reg -> wrong result; a wild computed
# jmp(a1) (a1=0, out of sandbox) -> caught cleanly (no host crash). Same engine/decoders as
# [J5d]/[J5e]; only the engine's control-flow generalisation + the test driver differ.
# Watchdog 15s -> FAIL. NO new Emu68 file vendored (the return stack / branch decode /
# computed jumps are dispatcher-level C, not emitted decoders) -> Exhibit-B unchanged/clean.
hosted-jit68k-j5f: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE0 M68k_LINE4 M68k_LINE5 M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_LINEE M68k_MOVE M68k_MULDIV M68k_CC; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/M68k_EA.c build/emu68-darwin/M68k_EA.c --ea-sandbox
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k -Ihosted/jit68k/emu68 \
		-Ihosted/jit68k/apps68k -Wno-unused-function \
		hosted/jit68k/jit_region.c hosted/jit68k/j5c_shims.c hosted/jit68k/j5g_shims.c hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5d_engine.c hosted/jit68k/j5d_ea_helpers.c hosted/jit68k/j5d_interp.c \
		hosted/jit68k/j5f_test.c \
		hosted/jit68k/j3_vector.c hosted/jit68k/j3_marshal.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/apps68k/stublib.c \
		build/emu68-darwin/M68k_LINE0.c build/emu68-darwin/M68k_LINE4.c \
		build/emu68-darwin/M68k_LINE5.c build/emu68-darwin/M68k_LINE8.c \
		build/emu68-darwin/M68k_LINE9.c build/emu68-darwin/M68k_LINEB.c \
		build/emu68-darwin/M68k_LINEC.c build/emu68-darwin/M68k_LINED.c \
		build/emu68-darwin/M68k_LINEE.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c \
		build/emu68-darwin/M68k_EA.c build/emu68-darwin/M68k_CC.c \
		-o build/host-jit68k-j5f
	BIN=build/host-jit68k-j5f ./harness/run-hosted.sh '[J5f] PASS'

# [J5g] BROADEN the ISA + addressing-mode coverage toward running any self-contained 68k
# program. Where [J5d]..[J5f] drove the register/ALU/control class (LINE5/8/9/B/C/D/MOVE/
# MULDIV) over (An)/(An)+/-(An), [J5g] VENDORS three MORE real Emu68 decoders verbatim and
# drives them, plus the full M68000 addressing modes:
#   * vendors M68k_LINE0.c (immediates/bit ops: ori/andi/eori/subi/addi/cmpi/btst/...),
#     M68k_LINE4.c (misc: clr/neg/not/tst/ext/swap/lea/pea/movem/...), and M68k_LINEE.c
#     (shifts/rotates: asl/asr/lsl/lsr/rol/ror) BYTE-VERBATIM (Exhibit-B re-grep clean,
#     diff vs upstream 305f686 empty, NOTICE updated). The engine dispatcher drives
#     EMIT_line0/line4/lineE for groups 0/4/E.
#   * extends emu68_darwinize.pl's --ea-sandbox transform: in addition to the direct
#     (An)-class sites, it now rewrites the FOUR EA funnel helpers (load/store_reg_from/
#     to_addr[_offset]) so the (d16,An), (d8,An,Xn), abs.w/abs.l, (d16,PC)/(d8,PC,Xn)
#     modes all route through OUR sandbox EA (base-adjust + REV + index/scale) — the
#     quarantine M68k_EA.c stays byte-verbatim; only the build copy is patched.
#   * adds j5g_shims.c (link stubs for the un-driven LINE4 sub-ops: debug/disasm trace
#     gate + M68K_PopReturnAddress) so the verbatim files LINK.
# The demanding program (apps68k/bubsort.s -> bin/bubsort.exe, vasm -no-opt): a bubble sort
# of {17,3,42,8,99,23} via (d8,An,Xn.L) indexed memory load/store, then a checksum/mixer
# over the sorted array using the full shift/rotate + immediate (LINE0) + misc (LINE4) set,
# -> d0 = 0x00F5B9F5. Run through the REAL decoders, asserted byte-exact (the full register
# file + the sandbox memory INCLUDING the in-place sorted array) vs the independent
# from-scratch interpreter (j5d_interp.c, OURS, no Emu68 — extended to cover every new
# opcode/mode/size). Negative control: flip the sort branch -> the array sorts wrong -> the
# checksum diverges (the byte-exact assert bites). Watchdog 15s -> FAIL.
hosted-jit68k-j5g: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE0 M68k_LINE4 M68k_LINE5 M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_LINEE M68k_MOVE M68k_MULDIV M68k_CC; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/M68k_EA.c build/emu68-darwin/M68k_EA.c --ea-sandbox
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k -Ihosted/jit68k/emu68 \
		-Ihosted/jit68k/apps68k -Wno-unused-function -Wno-xor-used-as-pow \
		hosted/jit68k/jit_region.c hosted/jit68k/j5c_shims.c hosted/jit68k/j5g_shims.c \
		hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5d_engine.c hosted/jit68k/j5d_ea_helpers.c hosted/jit68k/j5d_interp.c \
		hosted/jit68k/j5g_test.c \
		hosted/jit68k/j3_vector.c hosted/jit68k/j3_marshal.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/apps68k/stublib.c \
		build/emu68-darwin/M68k_LINE0.c build/emu68-darwin/M68k_LINE4.c \
		build/emu68-darwin/M68k_LINE5.c build/emu68-darwin/M68k_LINE8.c \
		build/emu68-darwin/M68k_LINE9.c build/emu68-darwin/M68k_LINEB.c \
		build/emu68-darwin/M68k_LINEC.c build/emu68-darwin/M68k_LINED.c \
		build/emu68-darwin/M68k_LINEE.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c build/emu68-darwin/M68k_EA.c \
		build/emu68-darwin/M68k_CC.c \
		-o build/host-jit68k-j5g
	APPS68K_DIR=hosted/jit68k/apps68k BIN=build/host-jit68k-j5g \
		./harness/run-hosted.sh '[J5g] PASS'

# [J5h] CLOSE the X-bit multi-precision chain coverage gap [J5g] deferred. A self-contained
# 64-bit-arithmetic 68k program (apps68k/mp64.s -> bin/mp64.exe, vasm -no-opt real hunk):
#   * 64-bit ADD  via add.l (low) + addx.l (high): the carry out of the low longword,
#     recorded in the 68k X bit, is consumed by the high longword's addx.l.
#   * 64-bit NEGATE via neg.l (low) + negx.l (high): X carries the borrow lo->hi.
#   -> d0 = 0x000004FC.  Run through the REAL Emu68 LINED (add/addx) + LINE4 (neg/negx)
# decoders + our dispatcher, asserted BYTE-EXACT — the full register file AND the CCR byte
# INCLUDING the X bit AND the sandbox memory — vs the independent from-scratch interpreter
# (j5d_interp.c, OURS, no Emu68; extended with addx/subx/negx + the multi-precision Z rule).
# Resolves the [J5g] deferral: the register-direct addx/subx/negx/neg/not X-bit handling was
# empirically ground against the PRM (4th ed., ADDX/SUBX/NEGX flag rows) and found byte-exact
# CORRECT real 68k in Emu68 — the deferral was conservative (the ops were un-oracled, not
# proven wrong). NO new Emu68 file is vendored: addx/subx/negx live in the already-driven,
# already-vendored LINE4/LINE9/LINED decoders. Negative control: flip addx.l back to a plain
# add.l (drop the X carry) -> the high longword is off by one -> the byte-exact assert bites.
# Watchdog 15s -> FAIL.
hosted-jit68k-j5h: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE0 M68k_LINE4 M68k_LINE5 M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_LINEE M68k_MOVE M68k_MULDIV M68k_CC; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/M68k_EA.c build/emu68-darwin/M68k_EA.c --ea-sandbox
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k -Ihosted/jit68k/emu68 \
		-Ihosted/jit68k/apps68k -Wno-unused-function -Wno-xor-used-as-pow \
		hosted/jit68k/jit_region.c hosted/jit68k/j5c_shims.c hosted/jit68k/j5g_shims.c \
		hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5d_engine.c hosted/jit68k/j5d_ea_helpers.c hosted/jit68k/j5d_interp.c \
		hosted/jit68k/j5h_test.c \
		hosted/jit68k/j3_vector.c hosted/jit68k/j3_marshal.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/apps68k/stublib.c \
		build/emu68-darwin/M68k_LINE0.c build/emu68-darwin/M68k_LINE4.c \
		build/emu68-darwin/M68k_LINE5.c build/emu68-darwin/M68k_LINE8.c \
		build/emu68-darwin/M68k_LINE9.c build/emu68-darwin/M68k_LINEB.c \
		build/emu68-darwin/M68k_LINEC.c build/emu68-darwin/M68k_LINED.c \
		build/emu68-darwin/M68k_LINEE.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c build/emu68-darwin/M68k_EA.c \
		build/emu68-darwin/M68k_CC.c \
		-o build/host-jit68k-j5h
	APPS68K_DIR=hosted/jit68k/apps68k BIN=build/host-jit68k-j5h \
		./harness/run-hosted.sh '[J5h] PASS'

# [J5i] the 68k EXCEPTION / SR model. A real vasm-assembled hunk program (apps68k/j5i.s ->
# bin/j5i.exe, -kick1hunks for the jmp-finish RELOC32) installs 68k exception handlers in a
# sandbox vector table (the VBR stand-in @ 0x00240000) and raises three exceptions from three
# REAL causes — trap #1 (-> vector 33), divu.w #0 (-> vector 5), ILLEGAL (-> vector 4) — plus
# hand-built micro-tests for the SR+PC frame/rte resume and a bus error (out-of-sandbox jmp ->
# vector 2, the graft/cpu_aarch64.h SIGSEGV seam modeled in-band). OUR C dispatcher owns the
# exception model (Emu68's bare-metal EMIT_Exception/VBR path is a no-op stub in the re-hosted
# runtime); the body opcodes still run through the REAL Emu68 decoders. Each exception is
# asserted byte-exact (registers + CCR/SR + sandbox memory + the per-exception frame log) vs
# the independent from-scratch oracle (j5d_interp.c, OURS). Negative control: NOP the vector
# store so no handler is installed -> the value diverges (clean fault, no host crash). The
# whole existing corpus stays byte-exact ([J1]-[J5h] + apps68k green). Watchdog 15s -> FAIL.
hosted-jit68k-j5i: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE0 M68k_LINE4 M68k_LINE5 M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_LINEE M68k_MOVE M68k_MULDIV M68k_CC; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/M68k_EA.c build/emu68-darwin/M68k_EA.c --ea-sandbox
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k -Ihosted/jit68k/emu68 \
		-Ihosted/jit68k/apps68k -Wno-unused-function -Wno-xor-used-as-pow \
		hosted/jit68k/jit_region.c hosted/jit68k/j5c_shims.c hosted/jit68k/j5g_shims.c \
		hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5d_engine.c hosted/jit68k/j5d_ea_helpers.c hosted/jit68k/j5d_interp.c \
		hosted/jit68k/j5i_test.c \
		hosted/jit68k/j3_vector.c hosted/jit68k/j3_marshal.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/apps68k/stublib.c \
		build/emu68-darwin/M68k_LINE0.c build/emu68-darwin/M68k_LINE4.c \
		build/emu68-darwin/M68k_LINE5.c build/emu68-darwin/M68k_LINE8.c \
		build/emu68-darwin/M68k_LINE9.c build/emu68-darwin/M68k_LINEB.c \
		build/emu68-darwin/M68k_LINEC.c build/emu68-darwin/M68k_LINED.c \
		build/emu68-darwin/M68k_LINEE.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c build/emu68-darwin/M68k_EA.c \
		build/emu68-darwin/M68k_CC.c \
		-o build/host-jit68k-j5i
	APPS68K_DIR=hosted/jit68k/apps68k BIN=build/host-jit68k-j5i \
		./harness/run-hosted.sh '[J5i] PASS'

# [J5j] THE CAPABILITY CAPSTONE: a SUBSTANTIAL, recognisable real 68k program through the
# JIT. A fixed-point integer Mandelbrot ASCII renderer (apps68k/mandel.s -> bin/mandel.exe,
# vasm -no-opt) — three nested loops (row x col x iterate, ~50k inner iterations), each with
# signed muls.w fixed-point multiplies + asr shifts + the full add/sub/cmp + Bcc set +
# (d16,a5) displacement-EA memory loads/stores, plus a PutChar library call per cell + a
# newline per row through the [J3] negative-offset LVO bridge. Runs through the REAL Emu68
# per-opcode decoders + OUR re-hosted PC-driven dispatcher; its PutChar OUTPUT STREAM, final
# registers, and full sandbox memory are asserted BYTE-EXACT vs the independent from-scratch
# interpreter (j5d_interp.c, OURS, no Emu68) — AND the fractal is printed so it's visible.
# The capstone surfaced + closed a real oracle coverage gap: the immediate-source ALU forms
# add.l/sub.l/cmp.l #imm,Dn (LINED/LINEB 0xD0BC/0x90BC/0xB0BC, which vasm emits under -no-opt)
# were translated correctly by the JIT (the REAL EMIT_lineD/lineB decoders handle the
# immediate EA) but were missing from the oracle; j5d_interp.c now models them and the
# byte-exact assert verifies the real decoder against the extension. Negative control: corrupt
# the escape compare's destination register so the streams diverge (the assert bites). NO new
# Emu68 file is vendored (the decoders are the already-vendored verbatim set); the change is
# entirely in OUR files (the oracle + the program + the test). Watchdog 20s -> FAIL.
hosted-jit68k-j5j: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE0 M68k_LINE4 M68k_LINE5 M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_LINEE M68k_MOVE M68k_MULDIV M68k_CC; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/M68k_EA.c build/emu68-darwin/M68k_EA.c --ea-sandbox
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k -Ihosted/jit68k/emu68 \
		-Ihosted/jit68k/apps68k -Wno-unused-function -Wno-xor-used-as-pow \
		hosted/jit68k/jit_region.c hosted/jit68k/j5c_shims.c hosted/jit68k/j5g_shims.c \
		hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5d_engine.c hosted/jit68k/j5d_ea_helpers.c hosted/jit68k/j5d_interp.c \
		hosted/jit68k/j5j_test.c \
		hosted/jit68k/j3_vector.c hosted/jit68k/j3_marshal.c hosted/jit68k/j4_loader.c \
		hosted/jit68k/apps68k/stublib.c \
		build/emu68-darwin/M68k_LINE0.c build/emu68-darwin/M68k_LINE4.c \
		build/emu68-darwin/M68k_LINE5.c build/emu68-darwin/M68k_LINE8.c \
		build/emu68-darwin/M68k_LINE9.c build/emu68-darwin/M68k_LINEB.c \
		build/emu68-darwin/M68k_LINEC.c build/emu68-darwin/M68k_LINED.c \
		build/emu68-darwin/M68k_LINEE.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c build/emu68-darwin/M68k_EA.c \
		build/emu68-darwin/M68k_CC.c \
		-o build/host-jit68k-j5j
	APPS68K_DIR=hosted/jit68k/apps68k BIN=build/host-jit68k-j5j \
		./harness/run-hosted.sh '[J5j] PASS'

# apps68k: run REAL 68k Amiga programs (vasm-assembled hunk executables) through the
# JIT. The toolchain (tools/build-vasm.sh builds vasm from source) produces the
# big-endian AmigaOS hunk binaries in apps68k/bin/ from the *.s sources; the runner
# loads each into the [J4] sandbox (with real HUNK_RELOC32 relocation) and runs ALL
# FOUR THROUGH THE [J5d] JIT ENGINE — Emu68's REAL per-opcode decoders for every ALU/
# move/memory opcode + OUR re-hosted dispatcher for inter-block control flow + the (An)
# sandbox-memory EA edit + the jsr-through-vector -> [J3] library bridge:
#   * mul.exe       -> d0 = 42   (moveq/add.l/subq.l/bne.s/rts)
#   * fact.exe      -> d0 = 120  (+ reg-to-reg move.l + cmp.l + nested loops)
#   * arraysum.exe  -> d0 = 150  (+ relocated lea DATA, add.l (a0)+ via the REAL EA decoder)
#   * libcall.exe   -> d0 = 0    (+ AllocMem/PutChar/FreeMem via jsr -off(a6) -> [J3] bridge)
# Each register file + sandbox memory is asserted byte-exact vs an INDEPENDENT from-
# scratch interpreter (j5d_interp.c, OURS, no Emu68); NO faked passes.
# Prereqs: the *.exe binaries are committed; to regenerate, run
#   apps68k/tools/build-vasm.sh && apps68k/tools/assemble.sh
# The vendored Emu68 decoders are darwinized (alias-forwarders + the (An) EA edit) into
# build/emu68-darwin/ first; the quarantine stays byte-verbatim. No Emu68 source is
# copied into our glue.
hosted-jit68k-apps: | build
	mkdir -p build/emu68-darwin
	for f in M68k_LINE0 M68k_LINE4 M68k_LINE5 M68k_LINE8 M68k_LINE9 M68k_LINEB M68k_LINEC M68k_LINED M68k_LINEE M68k_MOVE M68k_MULDIV M68k_CC; do \
		perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/$$f.c build/emu68-darwin/$$f.c; \
	done
	perl hosted/jit68k/emu68_darwinize.pl hosted/jit68k/emu68/M68k_EA.c build/emu68-darwin/M68k_EA.c --ea-sandbox
	clang -arch arm64 -O2 -Wall -Wextra -Ihosted/jit68k/emu68 -Ihosted/jit68k \
		-Ihosted/jit68k/apps68k -Wno-unused-function \
		hosted/jit68k/apps68k/runner.c hosted/jit68k/apps68k/stublib.c \
		hosted/jit68k/j4_loader.c \
		hosted/jit68k/j5c_shims.c hosted/jit68k/j5g_shims.c hosted/jit68k/j5c_ra.c \
		hosted/jit68k/j5d_engine.c hosted/jit68k/j5d_ea_helpers.c hosted/jit68k/j5d_interp.c \
		hosted/jit68k/j3_vector.c hosted/jit68k/j3_marshal.c hosted/jit68k/jit_region.c \
		build/emu68-darwin/M68k_LINE0.c build/emu68-darwin/M68k_LINE4.c \
		build/emu68-darwin/M68k_LINE5.c build/emu68-darwin/M68k_LINE8.c \
		build/emu68-darwin/M68k_LINE9.c build/emu68-darwin/M68k_LINEB.c \
		build/emu68-darwin/M68k_LINEC.c build/emu68-darwin/M68k_LINED.c \
		build/emu68-darwin/M68k_LINEE.c build/emu68-darwin/M68k_MOVE.c \
		build/emu68-darwin/M68k_MULDIV.c \
		build/emu68-darwin/M68k_EA.c build/emu68-darwin/M68k_CC.c \
		-o build/host-jit68k-apps
	APPS68K_DIR=hosted/jit68k/apps68k BIN=build/host-jit68k-apps \
		./harness/run-hosted.sh '[apps68k] PASS'

# Phase-2 regression matrix: build + run every hosted spike, assert each marker.
hosted-test:
	./harness/test-hosted.sh

# Re-ground the hardware map against the ACTUAL machine: dump + decode the DTB
# this exact QEMU/flags combination emits. Source of truth for HARDWARE.md.
dtb: | build
	qemu-system-aarch64 -machine virt,dumpdtb=build/virt.dtb -cpu cortex-a72 -display none
	dtc -I dtb -O dts build/virt.dtb -o build/virt.dts 2>/dev/null
	@echo ">> decoded device tree -> build/virt.dts"

clean:
	rm -rf run build
