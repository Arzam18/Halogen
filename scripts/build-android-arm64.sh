#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK" || ! -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin" ]]; then
  echo "ANDROID_NDK_HOME must point to an installed Android NDK (r27c expected)." >&2
  exit 1
fi

LLVM_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CXX="$LLVM_BIN/aarch64-linux-android24-clang++"
CC="$LLVM_BIN/aarch64-linux-android24-clang"
for tool in "$CXX" "$CC" "$LLVM_BIN/llvm-readelf" "$LLVM_BIN/llvm-objdump" "$LLVM_BIN/llvm-strip"; do
  [[ -x "$tool" ]] || { echo "Missing NDK tool: $tool" >&2; exit 1; }
done

NET_HASH="$(sed -n 's/^[[:space:]]*NET_HASH :=[[:space:]]*//p' "$ROOT/src/Makefile" | head -n 1)"
[[ -n "$NET_HASH" ]] || { echo "Could not read NET_HASH from src/Makefile" >&2; exit 1; }
NETWORK="$ROOT/build/$NET_HASH.nn"
mkdir -p "$ROOT/build" "$ROOT/artifacts/arm64-neon" "$ROOT/artifacts/arm64-dotprod"
if [[ ! -s "$NETWORK" ]]; then
  curl --fail --location --retry 5 --retry-delay 2 \
    "https://github.com/KierenP/Halogen-Networks/releases/download/$NET_HASH/$NET_HASH.nn" \
    -o "$NETWORK"
fi
[[ -s "$NETWORK" ]] || { echo "Halogen network download produced an empty file" >&2; exit 1; }

# The source uses 64-byte aligned network/accumulator arrays. Keep the official
# floating-point contraction policy and avoid shipping debug information.
EXTRA_CXXFLAGS="-DHALOGEN_ANDROID_BUILD=1 -g0 -fomit-frame-pointer -ffunction-sections -fdata-sections"
EXTRA_LDFLAGS="-static-libstdc++ -Wl,--gc-sections -Wl,-z,max-page-size=16384"

HOST_CXX="${HOST_CXX:-g++}"
"$ROOT/scripts/test-simd-contracts.sh"

build_one() {
  local arch="$1"
  local output_dir="$2"
  local output="$output_dir/$(basename "$output_dir")"
  mkdir -p "$output_dir"
  make --no-print-directory -C "$ROOT/src" -j2 \
    ARCH="$arch" release \
    CC="$CC" CXX="$CXX" HOST_CXX="$HOST_CXX" \
    EVALFILE="$NETWORK" \
    EXTRA_CXXFLAGS="$EXTRA_CXXFLAGS" \
    EXTRA_LDFLAGS="$EXTRA_LDFLAGS" \
    EXE="$output"
  [[ -s "$output" ]] || { echo "Build did not produce $output" >&2; exit 1; }
  chmod +x "$output"
  "$LLVM_BIN/llvm-strip" --strip-debug "$output"
  cat > "$output_dir/build-info.txt" <<INFO
Engine: Halogen 16.8.1 source snapshot
Target: aarch64-linux-android24
Architecture: $arch
Compiler: $CXX
NDK: $(grep -m1 'Pkg.Revision' "$NDK/source.properties" | cut -d= -f2- | xargs)
Network: $NET_HASH.nn (embedded through the architecture-specific verbatim converter)
Optimization: -O3 -flto -DNDEBUG -mtune=cortex-a76
Minimum Android API: 24
INFO
  sha256sum "$output" > "$output_dir/SHA256SUMS.txt"
}

build_one neon "$ROOT/artifacts/arm64-neon"
build_one neon-dotprod "$ROOT/artifacts/arm64-dotprod"

# The NEON and Dotprod networks must have identical bytes: they have the same
# 128-bit packing layout, while only the L1 dot-product instruction differs.
NEON_NET="$ROOT/build/neon/verbatim.nn"
DOTPROD_NET="$ROOT/build/neon-dotprod/verbatim.nn"
cmp -s "$NEON_NET" "$DOTPROD_NET" || {
  echo "NEON and Dotprod network preprocessing differs; refusing to package mismatched networks" >&2
  exit 1
}
sha256sum "$NEON_NET" > "$ROOT/artifacts/network-layout-SHA256SUMS.txt"

"$ROOT/scripts/verify-android-arm64.sh" \
  "$ROOT/artifacts/arm64-neon/arm64-neon" \
  "$ROOT/artifacts/arm64-dotprod/arm64-dotprod" \
  "$LLVM_BIN"

printf 'Halogen Android ARM64 builds completed.\n'
