# The Graft — from the Phase-2 spikes to the real AROS tree

Phase 2's hosted spikes (H1–H8) de-risked the entire *host-facing* surface of a
hosted AROS on Apple Silicon. This file is the bridge: exactly where each proven
idea plugs into the real AROS source tree, grounded against
`/Users/user/Source/aros-upstream` (file paths + line numbers below). It turns "the
mountain" from a gesture into a punch list.

The honest headline: **the graft is integration, not spiking.** AROS already has a
*darwin hosted* backend — but it targets i386/x86_64/ppc/arm only, it has no
AArch64, and it is bit-rotted to ~2010-era Xcode. The work is to add AArch64 *and*
modernise that backend for current macOS.

## What AROS already has (grounded)

- **A darwin hosted flavour.** `configure` (`aros-upstream/configure:10800`) sets
  `aros_target_arch="darwin"`, `aros_flavour="emulation"`, pulls the SDK via
  `xcrun --show-sdk-path`, and switches on `target_cpu`.
- **A unix/darwin host kernel.** `arch/all-unix/` provides the hosted host side
  (signals as interrupts, `mmap` memory, `hostdisk`, the `unixio`/X11 display
  HIDD); `arch/all-darwin/` adds the Darwin specifics (bootstrap, `hostdisk`
  geometry, and the per-CPU register glue in `arch/all-darwin/kernel/cpu_*.h`).
- **The library/LVO machinery is arch-clean.** 64-bit AROS uses data-pointer
  vectors (`arch/x86_64-all/include/aros/cpu.h`), so it ports with no codegen.

## What's missing or broken for AArch64 (the punch list)

### 1. `configure`: no AArch64 case in the darwin flavour — and it's stale
`aros-upstream/configure:10815` switches `target_cpu` over `i386 / x86_64 / ppc /
arm`, then **hard-errors** on anything else (`:10904`,
*"Unsupported target CPU for darwin hosted flavour"*). Add an `*aarch64*|*arm64*`
case setting `aros_target_cpu="aarch64"`, the object format, `llvm_target_cpu=
"AArch64"`, and the kernel tool flags (`-arch arm64`). Note the existing cases use
`kernel_tool_prefix="*-apple-darwin10-"` (darwin10 = macOS 10.6) and iPhone
`Developer/usr/bin` paths — these don't exist on a modern Apple-Silicon Mac, so
the case must also use the native LLVM toolchain (`aros_toolchain=llvm`,
clang `-arch arm64`) rather than a darwin10 cross-prefix.
*Prototype:* our `Makefile` already drives exactly this toolchain
(`clang -arch arm64 …`, the H1–H8 builds).

### 2. NEW `arch/all-darwin/kernel/cpu_aarch64.h` — the host register glue
The peers `cpu_x86_64.h`, `cpu_ppc.h`, `cpu_arm.h`, `cpu_i386.h` exist;
`cpu_aarch64.h` does not. It must define, mirroring `cpu_arm.h`:
`regs_t = ucontext_t*`; `Rn/SP/LR/PC/CPSR(context)` reading
`context->uc_mcontext->__ss.__x[n] / __sp / __lr / __pc / __cpsr`; and
`SAVEREGS/RESTOREREGS` copying between that `__ss` and AROS's
`struct ExceptionContext`.
*Prototype:* **H2 and H4** are this file in embryo — `hosted/preempt.c` and
`hosted/exec.c` already read/write `uc_mcontext->__ss.{__x,__fp,__lr,__sp,__pc}`
to save and restore tasks. The grounded note from H2 (`-arch arm64` ⇒
`__DARWIN_OPAQUE_ARM_THREAD_STATE64==0`, so the plain `__ss` fields are valid)
is exactly the knowledge this header encodes.

### 3. FIX `arch/aarch64-all/include/aros/cpucontext.h` — `struct ExceptionContext`
Today it is `{ IPTR r[29]; IPTR fp; IPTR sp; IPTR pc; }` — it mislabels x30 as
`fp`, omits **SPSR**, and has no FP/NEON pointer. This isn't cosmetic: the darwin
host kernel's `SAVEREGS`/`RESTOREREGS` (`cpu_arm.h:92`) `CopyMemQuick` straight
between the macOS `mcontext.__ss` and `struct ExceptionContext`, *relying on
identical layout*. So the fix must make `ExceptionContext` match Darwin's
`_STRUCT_ARM_THREAD_STATE64` (`__x[29]`, `__fp`, `__lr`, `__sp`, `__pc`, `__cpsr`).
*Prototype:* our Phase-1 trap frame (`boot/kern.h`: `x[31]` + `elr` + `spsr`) is
already the correct shape; H4's `struct Task` carries the full `_STRUCT_MCONTEXT64`.

### 4. Complete the `arch/aarch64-all` native CPU bits
`cpu_Switch`/`cpu_Dispatch`/`core_*` wired to the trap frame, plus the
`kernel.resource` glue. The hosted flavour gets the OS-side kernel from
`arch/all-unix`/`arch/all-darwin`, so the AArch64-specific need is the context
machinery.
*Prototype:* **H4** reproduces the exact `core_Schedule`/`cpu_Switch`/`core_Switch`/
`core_Dispatch` contract (grounded against `arch/arm-native/kernel/*`); our `boot/`
has the bare-metal version of the same primitives.

### 5. Crosstools / toolchain
The darwin cases reference dead `*-apple-darwin10-` toolchains. AArch64 should ride
AROS's LLVM toolchain path (`config/llvm_def`, `aros_toolchain=llvm`) using the
host clang/lld with `-arch arm64`, plus `clang_rt.builtins-aarch64`. Verifying that
AROS's `mmake` + crosstools bootstrap accept an `aarch64-darwin` target is the
first thing that will surface unknowns — and the first real build to attempt.

### 6. Memory & libraries — already cleared
- **Memory:** `arch/all-unix` backs `exec` memory with `mmap`; H5 reproduced the
  `MemHeader`/`MemChunk` allocator faithfully. No AArch64-specific blocker.
- **Libraries:** H8 confirmed the LVO/`SetFunction` mechanism is data-pointer
  vectors on 64-bit — **no Apple-Silicon W^X / MAP_JIT wall.** No blocker.

## Spike → graft-file map

| Spike | Proves | Becomes / informs |
|-------|--------|-------------------|
| H1/H2 | ctx switch + preemption at EL0 via `mcontext` | `arch/all-darwin/kernel/cpu_aarch64.h` |
| H3 | AROS→Apple arm64 variadic ABI bridge | host-call paths in `arch/all-unix` exec glue |
| H4 | `core_Schedule`/`cpu_Switch` + `TaskReady` | `arch/aarch64-all` cpu_* + the `cpu_aarch64.h` save/restore |
| H5 | `MemHeader`/`MemChunk` allocator over `mmap` | confirms `arch/all-unix` memory backing ports |
| H6 | composition + `Forbid` compiler barrier | the real `Forbid()`/`Permit()` arbitration around exec |
| H7 | host framebuffer → presented by macOS | a native display HIDD (vs the stale `unixio`/X11 one) |
| H8 | LVO table + `SetFunction`, no W^X | confirms `MakeLibrary`/`SetFunction` need no AArch64 work |
| — | `struct ExceptionContext` is wrong upstream | fix `arch/aarch64-all/include/aros/cpucontext.h` |

## Live grounding (run on this Apple-Silicon Mac)

Not just read — *run*. `aros-upstream/configure --target=aarch64-darwin
--disable-crosstools`, out-of-tree, on this M-series Mac:

- **The target is accepted.** `checking for AROS style target... aarch64-darwin`,
  parsed to `target_cpu=aarch64`, `target_os=darwin`, `toolchain family... gnu`.
  So `aarch64-darwin` is a *recognised* target string; the rejection at
  `configure:10904` is only reached after the whole build environment is satisfied
  (it sits well past the prerequisite checks).
- **The first walls are the GNU build-tool prerequisites, not AArch64.** configure
  stops, one at a time, on: `gawk`, then `aclocal`/`automake`, then (after those)
  `pngtopnm` (netpbm) — and it *probes for ancient versions* (`autoconf259`,
  `autoconf253`, `automake-1.9`, i.e. autoconf 2.5x / automake 1.9, ~2004), more
  evidence of the decade-old bit-rot. Installed `gawk`, `automake`, `autoconf` to
  advance the probe; the next is netpbm, and more will follow.
- **Conclusion, grounded live:** there is no AArch64 *research* blocker here — the
  build system runs and accepts the target. The work is (1) standing up AROS's
  full (old-leaning) build-tool environment, then (2) the AArch64 + modernisation
  punch list above. That is integration + environment work, precisely the mountain.

## Live build progress — the trail blazed (run on this Apple-Silicon Mac)

The graft is no longer theory: AROS now *configures and starts compiling* for a
brand-new `darwin-aarch64` target. Work is on the `aarch64-darwin-graft` branch of
`aros-upstream`; the exact recipe is `graft/build-darwin-aarch64.sh`. What works,
in order:

1. **Target string.** AROS parses `$target` as `<arch>-<cpu>` (configure:3655), so
   the correct invocation is **`--target=darwin-aarch64`** (not `aarch64-darwin`,
   which parses as arch=`aarch64` and is rejected). The `configure` patch (the
   `*aarch64*` arm in the darwin flavour) is then reached and used.
2. **Prerequisites.** The host-tool chain configure walks: `gawk`, `automake`/
   `autoconf`, `bison`/`flex`, `netpbm` (`pngtopnm`/`ppmtoilbm`), `libpng`,
   `gnu-sed` (`gsed`), Python `mako`, and an `objcopy` shim (`llvm-objcopy`; macOS
   has none). All satisfiable via brew/pip.
3. **`configure` SUCCEEDS** (exit 0) — *"Now run 'make' to build the project"* —
   generating the full build system under `bin/darwin-aarch64/`.
4. **A working cross-toolchain.** AROS's LLVM toolchain wants `clang`/`ld.lld`/
   `llvm-*` under `<install>/bin`. A thin set of wrappers — native LLVM `clang`
   retargeted `--target=aarch64-unknown-none-elf -fuse-ld=lld` (so it emits
   **ELF**, not Mach-O, and links with lld since Apple's `ld` can't do ELF), the
   rest symlinked — handed to `--with-aros-toolchain-install`, passes AROS's
   target-compiler test.
5. **All AROS host tools build** (`fd2inline`, `sfdc`, `collect-aros`, …).
6. **Dropped the dead ACPICA gate.** `arch/all-native/acpica` made the global
   `includes-copy` depend on downloading ACPICA (native-x86, irrelevant to hosted
   aarch64, URL now 404s). The branch removes that dependency.
7. **It COMPILES real AROS source for darwin-aarch64** — the build reaches and
   compiles `compiler/alib/*.c` with the aarch64-ELF toolchain.

### The current wall (the next real piece of work)
The build stops in `compiler/alib` with `clang: error: unknown argument
'-noposixc'`. `-noposixc` is an **AROS compiler-spec flag** (`config/specs.in`,
`config/elf-specs.in`): it conditionally controls AROS include paths and lib
linking. AROS's GCC understands it via `-specs=`; AROS's *LLVM* toolchain
understands it because AROS ships a **patched clang**
(`tools/crosstools/llvm/clang-*.src-aros.diff`). Stock Homebrew clang does not.

So the next phase is the genuine toolchain construction: either (a) build AROS's
patched LLVM crosstools (download `llvm-11.0.0.src` + the aros diff and build it —
the "intended" path, a long LLVM-from-source build), or (b) replicate the AROS
specs logic inside the clang wrapper (teach it the `-noposixc`/`-nostdc`/… flags
and the include/lib injection they gate). Either is multi-session; both are now
*scoped and grounded*, not unknown.

## Honest assessment

Every *hosted* unknown is answered; nothing above is a research risk anymore. But
the graft is a large, iterative integration: extend + modernise the darwin hosted
backend, add the AArch64 CPU glue, fix the unfinished `arch/aarch64-all`, get the
crosstools to accept `aarch64-darwin`, then drive `configure`/`mmake` and fix what
breaks — repeatedly, against a backend nobody has built in a decade. That is the
next body of work, and it is grounded here rather than guessed.
