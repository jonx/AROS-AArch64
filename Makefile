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

.PHONY: image run shot dbg test hosted hosted-run hosted-preempt hosted-abi hosted-exec hosted-mem hosted-kern hosted-display hosted-cocoametal cocoametal-dylib cocoametal-abi cocoametal-hiddsim cocoametal-d2t cocoametal-input cocoametal-settings hosted-coreaudio hosted-clipboard hosted-hostvolume hosted-bsdsocket hosted-library hosted-signal hosted-msgport hosted-device hosted-execboot hosted-jit68k hosted-jit68k-hardened hosted-jit68k-j2 hosted-jit68k-j3 hosted-jit68k-j4 hosted-jit68k-j5a hosted-jit68k-j5b hosted-test clean

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
