#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/halogen-android-simd-contract-test"
CXX="${HOST_CXX:-g++}"
"$CXX" -std=c++20 -O2 -Wall -Wextra -Werror \
  "$ROOT/src/test/android_simd_contract_test.cpp" -o "$OUT"
"$OUT"
