#!/usr/bin/env bash
# fm-pi-loop-detector.test.sh - unit tests for the exported pure helpers in
# pi-extensions/firstmate-pi-loop.ts.
#
# These tests exercise the helpers with injected inputs; no real TTYs, no
# real pi sessions, no file IO. Each helper is compiled to a tiny Node script
# that imports it and runs assertions.
#
# Usage:
#   bash tests/fm-pi-loop-detector.test.sh
#
# Dependencies: node (and the firstmate repo root). No test framework.

set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

# Build each helper as a self-contained Node script that imports the source
# and runs assertions. We use a single temp file per helper to keep each
# test self-contained.

build_helper_test() {
  local helper="$1"
  local assertions="$2"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/fm-pi-loop-test.XXXXXX")"
  if [ ! -f "$tmp" ]; then
    echo "ERROR: mktemp failed, tmp=$tmp" >&2
    return 1
  fi
  mv "$tmp" "$tmp.mjs"
  tmp="$tmp.mjs"
  {
    echo 'import { pathToFileURL } from "node:url";'
    echo "const m = await import(pathToFileURL(\"${ROOT}/pi-extensions/firstmate-pi-loop.ts\").href);"
    echo "const { ${helper} } = m;"
    echo "${assertions}"
  } > "$tmp"
  echo "$tmp"
}

run_test() {
  local script="$1"
  local label="$2"
  if node "$script" > /dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
  fi
  rm -f "$script"
}

# --- stableStringify ---------------------------------------------------------

TMPSCRIPT="$(build_helper_test \
  "stableStringify" \
  '
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
assert(stableStringify(null) === "null", "null");
assert(stableStringify(42) === "42", "number");
assert(stableStringify("hi") === "\"hi\"", "string");
assert(stableStringify(true) === "true", "bool");
// sorted keys
const a = stableStringify({ b: 1, a: 2 });
assert(a === "{\"a\":2,\"b\":1}", "sorted keys");
// nested
const b = stableStringify({ z: [1, 2], y: { b: 1, a: 2 } });
assert(b === "{\"y\":{\"a\":2,\"b\":1},\"z\":[1,2]}", "nested");
console.log("ok");
' \
  "stableStringify")"
run_test "$TMPSCRIPT" "stableStringify: basic types and sorted keys"

# --- normalizeArgs -----------------------------------------------------------

TMPSCRIPT="$(build_helper_test \
  "normalizeArgs" \
  '
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
assert(normalizeArgs(null, 80) === "", "null");
assert(normalizeArgs(undefined, 80) === "", "undefined");
assert(normalizeArgs("hello", 80) === "\"hello\"", "simple string");
// whitespace collapse
const r = normalizeArgs({ b: 1, a: 2 }, 80);
assert(r.includes("a") && r.includes("b"), "sorts and includes");
// truncation
const t = normalizeArgs("a very long argument string that should be truncated", 10);
assert(t.length <= 10, "truncated");
console.log("ok");
' \
  "normalizeArgs")"
run_test "$TMPSCRIPT" "normalizeArgs: null, string, whitespace, truncation"

# --- jaccardSimilarity -------------------------------------------------------

TMPSCRIPT="$(build_helper_test \
  "jaccardSimilarity" \
  '
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
const a = new Set(["x", "y", "z"]);
const b = new Set(["x", "y"]);
const sim = jaccardSimilarity(a, b);
assert(Math.abs(sim - (2 / 3)) < 1e-9, "partial overlap: 0.666...");
const c = new Set(["x", "y", "z"]);
const d = new Set(["x", "y", "z"]);
const sim2 = jaccardSimilarity(c, d);
assert(Math.abs(sim2 - 1.0) < 1e-9, "full overlap: 1.0");
const e = new Set(["a", "b"]);
const f = new Set(["c", "d"]);
const sim3 = jaccardSimilarity(e, f);
assert(Math.abs(sim3 - 0.0) < 1e-9, "no overlap: 0.0");
const g = new Set();
const h = new Set();
const sim4 = jaccardSimilarity(g, h);
assert(Math.abs(sim4 - 0.0) < 1e-9, "both empty: 0.0");
console.log("ok");
' \
  "jaccardSimilarity")"
run_test "$TMPSCRIPT" "jaccardSimilarity: partial, full, no overlap, empty"

# --- paragraphFingerprints ---------------------------------------------------

TMPSCRIPT="$(build_helper_test \
  "paragraphFingerprints" \
  '
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
// Single paragraph, single sentence.
const a = paragraphFingerprints("Hello world.");
assert(a.size === 1, "single sentence");
assert(a.has("hello world"), "normalized form");
// Two paragraphs separated by blank line.
const b = paragraphFingerprints("First paragraph.\n\nSecond paragraph.");
assert(b.size === 2, "two paragraphs");
// Sentence boundaries within a paragraph.
const c = paragraphFingerprints("First sentence. Second sentence.");
assert(c.size === 2, "sentence boundaries");
// Empty string.
const d = paragraphFingerprints("");
assert(d.size === 0, "empty");
// Truncation: FINGERPRINT_LEN is 60; long strings get truncated.
const long = "a".repeat(200);
const e = paragraphFingerprints(long);
assert(e.size === 1, "single long paragraph");
for (const f of e) {
  assert(f.length <= 60, "truncated to FINGERPRINT_LEN");
}
console.log("ok");
' \
  "paragraphFingerprints")"
run_test "$TMPSCRIPT" "paragraphFingerprints: paragraphs, sentences, empty, truncation"

# --- detectToolSequence ------------------------------------------------------

TMPSCRIPT="$(build_helper_test \
  "detectToolSequence" \
  '
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
// No repetition: all different keys.
const a = detectToolSequence(["x", "y", "z"], 2, 3);
assert(a === null, "no repeat");
// Repetition: same key repeated 2 times with window=2 (threshold lowered to match count).
const b = detectToolSequence(["x", "x", "x", "x"], 2, 2);
assert(b !== null, "detected");
assert(b.count === 2, "count is 2");
// Not enough calls.
const c = detectToolSequence(["x", "x"], 3, 3);
assert(c === null, "too few calls");
// Window size 1: single call repeats 3 times.
const d = detectToolSequence(["a", "a", "a"], 1, 3);
assert(d !== null, "window=1 detected");
assert(d.count === 3, "count=3");
// Mixed: one different key before the repeats (no full sequence loop).
const e = detectToolSequence(["x", "y", "x", "x", "x"], 2, 3);
assert(e === null, "mixed no repeat");
console.log("ok");
' \
  "detectToolSequence")"
run_test "$TMPSCRIPT" "detectToolSequence: no repeat, repeat, too few, window=1, mixed"

# --- trackFileRead -----------------------------------------------------------

TMPSCRIPT="$(build_helper_test \
  "trackFileRead" \
  '
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
const map = new Map();
// First read.
const n1 = trackFileRead(map, "/tmp/foo.txt", "/tmp");
assert(n1 === 1, "first read is 1");
// Same path, second read.
const n2 = trackFileRead(map, "/tmp/foo.txt", "/tmp");
assert(n2 === 2, "second read is 2");
// Different path.
const n3 = trackFileRead(map, "/tmp/bar.txt", "/tmp");
assert(n3 === 1, "different path is 1");
// Relative path normalization (same absolute path as prior reads).
const n4 = trackFileRead(map, "foo.txt", "/tmp");
assert(n4 === 3, "relative path normalized and counted as 3");
// Empty path.
const n5 = trackFileRead(map, "", "/tmp");
assert(n5 === 0, "empty path returns 0");
console.log("ok");
' \
  "trackFileRead")"
run_test "$TMPSCRIPT" "trackFileRead: cumulative count, normalization, empty"

# --- trackSearch -------------------------------------------------------------

TMPSCRIPT="$(build_helper_test \
  "trackSearch" \
  '
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
const map = new Map();
// First search.
const n1 = trackSearch(map, "foo", "/tmp/a.txt");
assert(n1 === 1, "first search is 1");
// Same pattern, different location.
const n2 = trackSearch(map, "foo", "/tmp/b.txt");
assert(n2 === 2, "second location is 2");
// Same pattern, same location (no new distinct).
const n3 = trackSearch(map, "foo", "/tmp/a.txt");
assert(n3 === 2, "same location no increment");
// Different pattern.
const n4 = trackSearch(map, "bar", "/tmp/c.txt");
assert(n4 === 1, "different pattern is 1");
console.log("ok");
' \
  "trackSearch")"
run_test "$TMPSCRIPT" "trackSearch: distinct locations, dedup, different pattern"

# --- Summary ---------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0