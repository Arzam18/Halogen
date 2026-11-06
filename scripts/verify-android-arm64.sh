#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <neon-binary> <dotprod-binary> <ndk-llvm-bin>" >&2
  exit 2
fi

NEON_BIN="$1"
DOTPROD_BIN="$2"
LLVM_BIN="$3"
READELF="$LLVM_BIN/llvm-readelf"
OBJDUMP="$LLVM_BIN/llvm-objdump"

for tool in "$READELF" "$OBJDUMP"; do
  [[ -x "$tool" ]] || { echo "Missing NDK tool: $tool" >&2; exit 1; }
done

verify_common() {
  local binary="$1"
  local label="$2"
  [[ -x "$binary" ]] || { echo "$label binary missing or not executable" >&2; exit 1; }
  "$READELF" -h "$binary" | grep -Eq 'Machine:.*AArch64' || {
    echo "$label is not an AArch64 ELF" >&2; exit 1;
  }
  "$READELF" -l "$binary" | grep -Fq '/system/bin/linker64' || {
    echo "$label does not use Android's 64-bit linker" >&2; exit 1;
  }
  if "$READELF" -d "$binary" | grep -Fq 'libc++_shared.so'; then
    echo "$label unexpectedly depends on libc++_shared.so" >&2; exit 1
  fi
  # Every loadable segment must be aligned for Android's 16 KiB page-size devices.
  "$READELF" -l "$binary" | awk '
    /LOAD/ { found=1; if ($NF != "0x4000") bad=1 }
    END { if (!found || bad) exit 1 }
  ' || { echo "$label has a LOAD segment not aligned to 16 KiB" >&2; exit 1; }
  "$OBJDUMP" -d "$binary" > "${binary}.disassembly.txt"
}

verify_common "$NEON_BIN" "ARM64 NEON"
verify_common "$DOTPROD_BIN" "ARM64 Dotprod"

if ! grep -Eiq '\b(add|sub|mul|smax|smin|sqdmulh|sadalp|smlal|ld1|st1|uzp1|zip1)\s+v[0-9]+' "${NEON_BIN}.disassembly.txt"; then
  echo "NEON build contains no recognized Advanced SIMD vector instructions" >&2
  exit 1
fi
if grep -Eiq '\b(sdot|udot|usdot|sudot)\b' "${NEON_BIN}.disassembly.txt"; then
  echo "Baseline NEON build unexpectedly contains Dotprod instructions" >&2
  exit 1
fi
if ! grep -Eiq '\bsdot\s+v[0-9]+' "${DOTPROD_BIN}.disassembly.txt"; then
  echo "Dotprod build contains no SDOT instruction" >&2
  exit 1
fi

printf 'PASS: AArch64 ELF, Android linker, 16 KiB LOAD alignment, and static C++ runtime checks\n'
printf 'PASS: baseline uses NEON without Dotprod; Dotprod build emits SDOT\n'
