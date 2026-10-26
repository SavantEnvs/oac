#!/usr/bin/env bash
# mayhem/build.sh — build the oac decoder fuzz target (sanitized, instrumented library) and the
# project's own test programs (normal flags, separate build dir). Re-runnable and offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Sanitized + SanCov-instrumented library. fuzzer-no-link instruments the library itself (not just
#    the harness TU), so coverage is non-zero under Mayhem.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B mayhem/build-fuzz -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
      -DOAC_BUILD_TESTING=OFF -DOAC_BUILD_PROGRAMS=OFF
cmake --build mayhem/build-fuzz -j"$MAYHEM_JOBS" --target oac

# 2) The fuzz harness (upstream's tests/oac_decode_fuzzer.c) and its standalone reproducer.
LIBOAC="$SRC/mayhem/build-fuzz/liboac.a"
[ -f "$LIBOAC" ] || { echo "build.sh: $LIBOAC missing" >&2; exit 1; }
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    "$SRC/tests/oac_decode_fuzzer.c" /tmp/lsan_off.o -I"$SRC/include" "$LIBOAC" -lm \
    -o /mayhem/oac-decode-fuzzer
$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
    "$SRC/tests/oac_decode_fuzzer.c" /tmp/standalone_main.o /tmp/lsan_off.o -I"$SRC/include" "$LIBOAC" -lm \
    -o /mayhem/oac-decode-fuzzer-standalone

# 3) The project's own tests + demo tool, normal flags, separate build dir (what test.sh runs).
cmake -S . -B mayhem/build-test -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
      -DOAC_BUILD_TESTING=ON -DOAC_BUILD_PROGRAMS=ON
cmake --build mayhem/build-test -j"$MAYHEM_JOBS" \
      --target test_oac_api test_oac_padding test_oac_decode test_oac_extensions oac_demo
