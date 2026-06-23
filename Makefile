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
OBJS    := build/start.o build/kmain.o
MARKER  ?= [M2]

.PHONY: image run shot dbg clean

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
	IMG=$(ELF) ./harness/run.sh '$(MARKER)'

shot: image
	IMG=$(ELF) SHOT=1 ./harness/run.sh '$(MARKER)'

dbg: image
	SYMS=$(ELF) ./harness/lldb-dump.sh

# Re-ground the hardware map against the ACTUAL machine: dump + decode the DTB
# this exact QEMU/flags combination emits. Source of truth for HARDWARE.md.
dtb: | build
	qemu-system-aarch64 -machine virt,dumpdtb=build/virt.dtb -cpu cortex-a72 -display none
	dtc -I dtb -O dts build/virt.dtb -o build/virt.dts 2>/dev/null
	@echo ">> decoded device tree -> build/virt.dts"

clean:
	rm -rf run build
