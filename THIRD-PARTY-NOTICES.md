# Third-party notices

Almost all of this repository is original work under the AROS Public License
(see [LICENSE](LICENSE)). The host-side feature work is independent, written from
public APIs, published standards, and the AROS tree under the
[independent-work process](docs/features/CLEANROOM.md).

**One component is third-party code and is NOT clean-room / NOT AROS-licensed:**
the 68k JIT (`run68k`) adopts the **Emu68** instruction decoders and AArch64
emitter. This notice records that dependency and exactly how it is used, so the
distinction is unambiguous.

## Emu68 (68k → AArch64 translation core)

- **Project:** Emu68 — https://github.com/michalsc/Emu68
- **License:** Mozilla Public License 2.0 (MPL-2.0) — file-level copyleft
- **Version pinned:** commit `305f686f84712f88c4d80d35769af5c60a4e988b`
  (v1.0.7, 2025-12-08), fetched 2026-06-24
- **Where it lives:** `hosted/jit68k/emu68/` — a **quarantine directory** holding
  Emu68 files **vendored byte-verbatim**, with their original MPL-2.0 Exhibit-A
  headers intact and unmodified.

### What is Emu68's, and what is ours

The boundary is deliberate and is the reason MPL-2.0 (file-level copyleft) is
satisfied without relicensing our code:

- **Emu68's (MPL-2.0, in `hosted/jit68k/emu68/`):** the AArch64 instruction
  emitter (`A64.h`) and the real per-opcode 68k decoders (`M68k_LINE*.c`,
  `M68k_MOVE.c`, `M68k_EA.c`, `M68k_MULDIV.c`, `M68k_CC.c`, plus the headers they
  need). These are kept verbatim; the only build-time transformation is a
  mechanical "darwinize" of internal alias chains in **build-dir copies**, never
  in the source files here.
- **Ours (AROS-licensed, elsewhere under `hosted/jit68k/`):** the JIT engine and
  dispatcher (`j5d_engine.c`), the register allocator (`j5c_ra.c`), the hosted
  runtime hooks / EA helpers / shims (`j5c_shims.c`, `j5c_build.c`,
  `j5d_ea_helpers.c`, `j5g_shims.c`), the ELF/hunk loader, the LVO/host-call
  bridge, and the independent from-scratch verification oracle (`j5d_interp.c`).

Our files **`#include` the quarantined Emu68 headers and call/link the vendored
decoders** (the Makefile targets compile with `-Ihosted/jit68k/emu68`). **No Emu68
function body is copied into any AROS-licensed file** (MPL-2.0 FAQ Q11–Q13). The
two licenses meet only at a link/`#include` boundary, which MPL-2.0 permits.

### Authoritative record

The full, file-by-file account (every vendored file, why it was taken, which
milestone `[J5c]`/`[J5d]`/`[J5g]`/`[J5o]` added it, and the exact runtime
couplings bridged by our glue) is in **[hosted/jit68k/emu68/NOTICE](hosted/jit68k/emu68/NOTICE)**.
The adoption decision and its rationale are in
[docs/features/68k-jit/design.md](docs/features/68k-jit/design.md) (`[J0]`) and the
license map in [docs/features/CLEANROOM.md](docs/features/CLEANROOM.md).

### Redistribution

MPL-2.0 requires that these files keep their license headers and that this notice
of their origin and license accompany the distribution. If you redistribute the
`hosted/jit68k/emu68/` files, keep them under MPL-2.0.
</content>
