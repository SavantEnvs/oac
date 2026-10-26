#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run the project's own test programs (built by build.sh with normal flags) and assert on the
# summary line each prints; then decode committed streams with oac_demo and assert exact output sizes.
# A neutered binary prints nothing, so every check below fails.
T="$SRC/mayhem/build-test"
SEEDS="$SRC/mayhem/oac-decode-fuzzer/testsuite"
passed=0; failed=0
ok()   { echo "PASS: $1"; passed=$((passed+1)); }
bad()  { echo "FAIL: $1" >&2; failed=$((failed+1)); }

for b in test_oac_api test_oac_padding test_oac_decode test_oac_extensions oac_demo; do
  [ -x "$T/$b" ] || { echo "missing $T/$b — build.sh should have produced it" >&2; emit_ctrf "oac-tests" 0 1 0; exit 1; }
done

run_suite() {  # name, expected-marker-regex, command...
  local name="$1" marker="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -eq 0 ] && grep -Eq "$marker" <<<"$out"; then ok "$name"; else echo "$out" | tail -15 >&2; bad "$name (rc=$rc)"; fi
}

run_suite test_oac_api        'All API tests passed\.'            "$T/test_oac_api"
run_suite test_oac_padding    'All padding tests passed\.'        "$T/test_oac_padding"
run_suite test_oac_decode     'Testing oac_pcm_soft_clip\.\.\. OK\.' env SEED=1 "$T/test_oac_decode"
run_suite test_oac_extensions 'Tests completed successfully\.'    "$T/test_oac_extensions"

# Known-answer decodes: committed oac_demo streams -> exact PCM byte count (decoded frames x samples x
# channels x 2 bytes), and the PCM must not be silence.
kat() {  # stream, rate, channels, expected-bytes
  local out="${TMPDIR:-/tmp}/oac_kat_$$.pcm" size nz
  rm -f "$out"
  "$T/oac_demo" -d "$2" "$3" "$SEEDS/$1.bit" "$out" >/dev/null 2>&1
  size=$(stat -c %s "$out" 2>/dev/null || echo 0)
  nz=$(tr -d '\0' < "$out" 2>/dev/null | wc -c)
  rm -f "$out"
  if [ "$size" -eq "$4" ] && [ "$nz" -gt $(( $4 / 2 )) ]; then ok "decode $1 -> $size bytes"
  else bad "decode $1: got $size bytes ($nz non-zero), expected $4"; fi
}
kat silk_nb_mono       8000  1 6720
kat silk_wb_mono_cbr   16000 1 13440
kat celt_fb_stereo     48000 2 80640
kat celt_swb_2p5ms     24000 1 19320
kat mixed_stereo_40ms  48000 2 84480

emit_ctrf "oac-tests" "$passed" "$failed" 0
