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

.PHONY: image run shot dbg test hosted hosted-run hosted-preempt hosted-abi hosted-exec hosted-mem hosted-kern hosted-display hosted-library hosted-test clean

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

# H8: a tiny exec.library via the real AROS LVO mechanism — JumpVec table built by
# MakeLibrary, indirect LVO dispatch, SetFunction hot-patch. Data-pointer vectors,
# so no Apple-Silicon W^X / MAP_JIT wall.
hosted-library: | build
	clang -arch arm64 -O2 -Wall -Wextra hosted/library.c -o build/host-library
	BIN=build/host-library ./harness/run-hosted.sh '[H8] hosted exec.library ok'

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
