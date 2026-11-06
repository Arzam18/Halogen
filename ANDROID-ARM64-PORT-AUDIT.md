# Halogen Android ARM64 NEON / Dotprod Port Audit

Date: 2026-11-06  
Upstream source snapshot: Halogen 16.8.1  
Network identifier: `ed164cf2`  
Minimum Android API: 24  
NDK requested by CI: r27c (27.2.12479018)  
Workflow: `.github/workflows/android-arm64.yml` (`workflow_dispatch` only)

## Objective

Build two separate Android AArch64 UCI binaries from the same Halogen source and the same official NNUE network:

1. `arm64-neon`: baseline ARMv8-A + NEON, without Dotprod instructions.
2. `arm64-dotprod`: ARMv8.2-A + Dotprod, with the explicit SDOT NNUE kernel.

Both use `-O3`, LTO, section garbage collection, static C++ runtime linkage, 16 KiB ELF segment alignment, and Cortex-A76 scheduling (`-mtune=cortex-a76`). The baseline binary remains the compatibility fallback. The Dotprod binary must only be used on processors that support ARM dot-product instructions.

## Important source findings

- The upstream source already contains AArch64 NEON and Dotprod NNUE implementations. The port does not replace the engine's trained network, search, or evaluation heuristics.
- `SIMD::dpbusd_i32()` selects `vdotq_s32()` only when `USE_NEON_DOTPROD` is defined. The baseline NEON branch performs signed-byte widening multiply plus pairwise accumulation.
- The NEON FT activation uses `vqdmulhq_s16()` with a six-bit input shift; the x86 path uses `pmulhw` with a seven-bit shift. For the clamped nonnegative input domain `[0, 255]`, these expressions are exactly equivalent. The Android port retains this arithmetic and tests its complete 65,536-value input pair domain.
- The source Makefile originally used the target `CXX` to compile the `verbatim` network converter. Under Android cross-compilation that creates a target-architecture helper which is then executed on the x86 GitHub runner. This port separates `HOST_CXX` from the Android target compiler. For both 128-bit ARM variants, the converter is compiled natively with the SSE4 128-bit data layout; this keeps the generated network layout consistent with NEON and Dotprod.
- The original huge-page allocator calls `aligned_alloc()`. Android Bionic added this libc function at API level 28, so it is unavailable for an API-24 minimum target. The Android path now uses `posix_memalign()`, requests 2 MiB alignment where possible, and falls back to the C++ type's required alignment if that larger reservation fails. Memory is still released with `free()`.

## Changes in this port

- `src/Makefile`: explicit Android `neon` and `neon-dotprod` ISA and Cortex-A76 tuning flags; independent native `HOST_CXX` for the network converter; x86 SSE4 converter layout selected for both 128-bit ARM targets; host compiler and converter flags added to the incremental build fingerprint; network download uses fail-fast/retry options.
- `src/simd/define.hpp`: compile-time guards reject a non-AArch64 NEON build and reject a Dotprod macro unless the compiler target advertises `__ARM_FEATURE_DOTPROD`.
- `src/utility/huge_pages.h`: API-24-compatible Android aligned allocation and lower-alignment fallback.
- `src/network/inference.hpp`: documents the exact NEON/x86 FT fixed-point scaling identity; no evaluator arithmetic changed.
- `src/test/android_simd_contract_test.cpp` and `scripts/test-simd-contracts.sh`: exhaustive fixed-point and saturation contract tests plus one million signed-byte dot-product groups.
- `scripts/build-android-arm64.sh`: downloads the pinned official network, builds NEON and Dotprod separately using NDK API 24 Clang, checks that their preprocessed networks are byte-identical, strips debug symbols, and emits build metadata/checksums.
- `scripts/verify-android-arm64.sh`: verifies AArch64 ELF, Android linker, no `libc++_shared.so`, 16 KiB load-segment alignment, NEON in the baseline without SDOT, and SDOT in the Dotprod executable.
- `.github/workflows/android-arm64.yml`: manual-only Android build, runs arithmetic tests with GCC and Clang, and uploads separate NEON, Dotprod, and diagnostic artifacts.

## Validation performed in this workspace

| Check | Result | Notes |
|---|---|---|
| GCC arithmetic contracts | PASS | Exhaustive FT scaling (65,536 input pairs), one million dot-product groups, full int16 saturation domain |
| Clang arithmetic contracts | PASS | Same cases as GCC |
| Android allocator path | PASS | Host-simulated `__ANDROID__` build and 2 MiB alignment allocation/free |
| Shell syntax | PASS | All added shell scripts pass `bash -n` |
| Workflow YAML syntax | PASS | Parsed with PyYAML |
| Makefile compiler separation | PASS | Dry-run shows host `g++` for `verbatim.cpp` and Android API-24 Clang for engine objects |
| Full native host build | PASS | Halogen 16.8.1 SSE4 host build with synthetic zero network only |
| UCI smoke test | PASS | Synthetic-network host binary answered `uci`, `isready`, completed depth 3, and returned `bestmove` |
| AArch64 NEON code generation | PASS | Clang 17 `armv8-a+simd` probe emitted NEON operations and no SDOT |
| AArch64 Dotprod code generation | PASS | Clang 17 `armv8.2-a+dotprod` probe emitted SDOT |

## Not yet verified — do not mark as Android-successful yet

- This workspace did not have Android NDK r27c installed and could not reach GitHub to download the official NNUE file. Therefore the full Android engine binaries have **not** been built here.
- The native UCI smoke test used an explicitly synthetic all-zero raw network. It verifies the host build and UCI path only; it says nothing about playing strength or Elo.
- The actual Android API-24 builds, official-network inference, phone-side UCI/search, sustained stability/thermal behavior, and A/B strength testing remain pending.
- Do not infer a strength improvement from the presence of NEON or SDOT alone. Compare both binaries with identical engine options, network, openings, time control, hash size, thread count, and test conditions before drawing any Elo conclusion.

## GitHub Actions procedure

1. Upload `Halogen-Android-ARM64-NEON-Dotprod-Modified-Files-Only.zip` over the Halogen repository root.
2. Open Actions and run **Halogen Android ARM64 NEON + Dotprod** using `workflow_dispatch`.
3. Confirm all three artifacts are uploaded. Install `arm64-neon` as the baseline and only use `arm64-dotprod` where the device supports Dotprod.
4. Run `uci`, `isready`, `position startpos`, and a timed/depth search on both binaries on the phone.
5. Perform a fixed-condition A/B match against the previous binary and record W/D/L, nodes, NPS, temperature, and stability. Treat this as a testing build until those checks are complete.

## Network provenance

The build script downloads `ed164cf2.nn` from the Halogen Networks GitHub release URL encoded in the upstream Makefile and embeds the architecture-preprocessed network in each executable. No substitute network or synthetic weights are included in the release artifacts.
