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
CFLAGS  := --target=$(TARGET) -ffreestanding -nostdlib -Wall -Wextra

ELF     := build/aros-aarch64.elf
MARKER  ?= [M1]

.PHONY: image run shot dbg clean

build:
	@mkdir -p build

build/start.o: boot/start.S | build
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): build/start.o boot/linker.ld
	$(LD) -T boot/linker.ld build/start.o -o $@

image: $(ELF)
	@echo ">> built $(ELF)"

run: image
	IMG=$(ELF) ./harness/run.sh '$(MARKER)'

shot: image
	IMG=$(ELF) SHOT=1 ./harness/run.sh '$(MARKER)'

dbg: image
	SYMS=$(ELF) ./harness/lldb-dump.sh

clean:
	rm -rf run build
