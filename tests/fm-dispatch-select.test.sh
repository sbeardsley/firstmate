#!/usr/bin/env bash
# Behavior tests for deterministic crew-dispatch profile selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-dispatch-select-tests)
mkdir -p "$TMP_ROOT"

write_quota() {
  local file=$1 claude_status=$2 claude_five=$3 claude_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "$claude_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_five },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": $claude_week },
        { "id": "model:fable", "kind": "model", "percentRemaining": 100 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week },
        { "id": "model:codex_bengalfox:5h", "kind": "model", "percentRemaining": 100 }
      ]
    }
  ]
}
JSON
}

profiles='[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'

write_ollama_codex_quota() {
  local file=$1 ollama_status=$2 ollama_five=$3 ollama_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "providers": [
    {
      "provider": "ollama",
      "state": { "status": "$ollama_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $ollama_five },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $ollama_week }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week }
      ]
    }
  ]
}
JSON
}

test_higher_min_vendor_wins() {
  local quota out
  quota="$TMP_ROOT/higher.json"
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "higher-min vendor should win, got: $out"
  pass "quota-balanced picks the candidate with the higher general-window minimum"
}

test_exact_tie_uses_first_profile() {
  local quota out
  quota="$TMP_ROOT/tie.json"
  write_quota "$quota" fresh 90 50 fresh 60 50
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "exact tie should pick first profile, got: $out"
  pass "quota-balanced exact tie uses the first ordered profile"
}

test_pi_cloud_uses_ollama_vendor() {
  local quota out profiles_pi
  profiles_pi='[{"harness":"pi","model":"glm-5.2-cloud","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  quota="$TMP_ROOT/pi-ollama.json"
  write_ollama_codex_quota "$quota" fresh 100 100 fresh 5 5

  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles_pi")
  [ "$out" = '{"harness":"pi","model":"glm-5.2-cloud","effort":"high"}' ] \
    || fail "pi cloud profile should use ollama quota and beat constrained codex, got: $out"
  pass "quota-balanced maps pi -cloud models to the ollama quota vendor"
}

test_grok_uses_grok_vendor() {
  local quota out profiles_grok
  profiles_grok='[{"harness":"grok","model":"grok-4","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  quota="$TMP_ROOT/grok.json"
  cat > "$quota" <<'JSON'
{
  "providers": [
    {
      "provider": "grok",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 80 },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": 75 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 10 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 10 }
      ]
    }
  ]
}
JSON

  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles_grok")
  [ "$out" = '{"harness":"grok","model":"grok-4","effort":"high"}' ] \
    || fail "grok profile should use grok quota and beat constrained codex, got: $out"
  pass "quota-balanced maps grok profiles to the grok quota vendor"
}

test_explicit_vendor_override_wins_and_is_not_output() {
  local quota out profiles_override
  profiles_override='[{"harness":"pi","model":"glm-5.2","effort":"high","vendor":"ollama"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  quota="$TMP_ROOT/vendor-override.json"
  write_ollama_codex_quota "$quota" fresh 90 90 fresh 10 10

  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles_override")
  [ "$out" = '{"harness":"pi","model":"glm-5.2","effort":"high"}' ] \
    || fail "explicit vendor override should select pi without leaking vendor, got: $out"
  pass "quota-balanced honors optional explicit vendor override without changing spawn profile output"
}

test_quota_missing_falls_back_to_first() {
  local fakebin out err status
  fakebin=$(fm_fakebin "$TMP_ROOT/missing")
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/missing.err")
  status=$?
  err=$(cat "$TMP_ROOT/missing.err")
  expect_code 0 "$status" "missing quota-axi should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "missing quota-axi should fall back to first, got: $out"
  assert_contains "$err" "quota-axi missing" "missing quota-axi fallback should be logged"
  pass "quota-axi missing falls back to the first profile and logs"
}

test_quota_error_falls_back_to_first() {
  local fakebin out err status
  fakebin=$(fm_fakebin "$TMP_ROOT/error")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/error.err")
  status=$?
  err=$(cat "$TMP_ROOT/error.err")
  expect_code 0 "$status" "quota-axi error should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "quota-axi error should fall back to first, got: $out"
  assert_contains "$err" "quota-axi exited 42" "quota-axi error fallback should be logged"
  pass "quota-axi non-zero exit falls back to the first profile and logs"
}

test_quota_trouble_prefers_first_mapped_profile() {
  local fakebin out err status profiles_unmapped_first
  profiles_unmapped_first='[{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"max"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  fakebin=$(fm_fakebin "$TMP_ROOT/missing-mapped")
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles_unmapped_first" 2>"$TMP_ROOT/missing-mapped.err")
  status=$?
  err=$(cat "$TMP_ROOT/missing-mapped.err")
  expect_code 0 "$status" "missing quota-axi should not fail dispatch"
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "quota trouble should fall back to first quota-mapped profile, got: $out"
  assert_contains "$err" "using first quota-mapped profile" "mapped fallback should be logged"
  pass "quota trouble prefers a known vendor candidate before an unmapped first profile"
}

test_bad_quota_json_falls_back_to_first() {
  local quota out err
  quota="$TMP_ROOT/bad.json"
  printf '%s\n' 'not-json' > "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/bad.err")
  err=$(cat "$TMP_ROOT/bad.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "bad quota JSON should fall back to first, got: $out"
  assert_contains "$err" "unparseable JSON" "bad quota JSON fallback should be logged"
  pass "unparseable quota JSON falls back to the first profile and logs"
}

test_bad_quota_json_prefers_first_mapped_profile() {
  local quota out err profiles_unmapped_first
  profiles_unmapped_first='[{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"max"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  quota="$TMP_ROOT/bad-mapped.json"
  printf '%s\n' 'not-json' > "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles_unmapped_first" 2>"$TMP_ROOT/bad-mapped.err")
  err=$(cat "$TMP_ROOT/bad-mapped.err")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "bad quota JSON should fall back to first quota-mapped profile, got: $out"
  assert_contains "$err" "using first quota-mapped profile" "bad-json mapped fallback should be logged"
  pass "unparseable quota JSON prefers a known vendor candidate before an unmapped first profile"
}

test_stale_with_cache_needs_clear_margin_to_beat_fresh() {
  local quota out
  quota="$TMP_ROOT/stale-margin.json"
  write_quota "$quota" stale 85 70 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "fresh vendor should win when stale lead is below margin, got: $out"

  write_quota "$quota" stale 90 85 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "stale vendor should win when lead clears margin, got: $out"
  pass "stale cached quota is usable only when it clears the documented margin over fresh"
}

test_vendor_absent_or_unusable_falls_back_conservatively() {
  local quota out err
  quota="$TMP_ROOT/absent.json"
  cat > "$quota" <<'JSON'
{
  "providers": [
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 40 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 50 }
      ]
    }
  ]
}
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/absent-first.err")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "available candidate should win over absent vendor, got: $out"

  cat > "$quota" <<'JSON'
{ "providers": [] }
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/none.err")
  err=$(cat "$TMP_ROOT/none.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "no usable vendors should fall back to first, got: $out"
  assert_contains "$err" "no usable quota windows" "no usable vendor fallback should be logged"
  pass "absent or unusable vendors resolve to an available candidate or the first fallback"
}

test_unmapped_and_absent_candidates_are_logged_and_excluded() {
  local quota out err profiles_mixed
  profiles_mixed='[{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"max"},{"harness":"pi","model":"glm-5.2-cloud","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  quota="$TMP_ROOT/exclusions.json"
  cat > "$quota" <<'JSON'
{
  "providers": [
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 40 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 50 }
      ]
    }
  ]
}
JSON

  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles_mixed" 2>"$TMP_ROOT/exclusions.err")
  err=$(cat "$TMP_ROOT/exclusions.err")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "available codex candidate should win after exclusions, got: $out"
  assert_contains "$err" "candidate 0 (pi/openai-codex/gpt-5.6-sol) has no known quota vendor" \
    "unmapped pi candidate should be logged"
  assert_contains "$err" "candidate 1 (pi/glm-5.2-cloud) quota vendor \"ollama\" absent from quota output" \
    "absent ollama provider should be logged"
  pass "quota-balanced logs unmapped and unavailable candidates before selecting an available vendor"
}

test_no_usable_candidates_falls_back_to_first_mapped_profile() {
  local quota out err profiles_unmapped_first
  profiles_unmapped_first='[{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"max"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  quota="$TMP_ROOT/no-usable-mapped.json"
  printf '%s\n' '{ "providers": [] }' > "$quota"

  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles_unmapped_first" 2>"$TMP_ROOT/no-usable-mapped.err")
  err=$(cat "$TMP_ROOT/no-usable-mapped.err")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "no usable candidates should fall back to first quota-mapped profile, got: $out"
  assert_contains "$err" "no usable quota windows" "no usable mapped fallback should be logged"
  assert_contains "$err" "using first quota-mapped profile" "no usable mapped fallback target should be logged"
  pass "no usable quota windows prefers a known vendor candidate before an unmapped first profile"
}

test_quota_vendor_diagnostics() {
  local out config
  config='{"rules":[{"when":"big work","use":[{"harness":"pi","model":"openai-codex/gpt-5.6-sol"},{"harness":"pi","model":"glm-5.2-cloud"},{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","vendor":"mystery"}],"select":"quota-balanced"},{"when":"normal","use":[{"harness":"pi","model":"openai-codex/gpt-5.6-sol"}]}]}'
  out=$("$ROOT/bin/fm-dispatch-select.sh" --quota-vendor-diagnostics "$config")

  assert_contains "$out" "CREW_DISPATCH: quota-balanced candidate pi/openai-codex/gpt-5.6-sol has no known quota vendor" \
    "diagnostics should surface unmapped quota-balanced candidates"
  assert_contains "$out" "CREW_DISPATCH: quota-balanced candidate opencode/anthropic/claude-sonnet-4-5 declares unknown quota vendor \"mystery\"" \
    "diagnostics should surface unknown explicit vendors"
  assert_not_contains "$out" "pi/glm-5.2-cloud" "diagnostics should not warn for mapped pi cloud models"
  pass "quota vendor diagnostics reports only quota-balanced profiles without known vendors"
}

test_backward_compatible_first_selection() {
  local fakebin marker out single array_rule
  fakebin=$(fm_fakebin "$TMP_ROOT/no-call")
  marker="$TMP_ROOT/quota-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"

  single='{"harness":"grok","model":"grok-4","effort":"high"}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$single")
  [ "$out" = '{"harness":"grok","model":"grok-4","effort":"high"}' ] \
    || fail "single-object use should resolve to itself, got: $out"

  array_rule='{"when":"big work","use":[{"harness":"claude","effort":"high"},{"harness":"codex","effort":"high"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$array_rule")
  [ "$out" = '{"harness":"claude","effort":"high"}' ] \
    || fail "array without select should resolve to first, got: $out"
  [ ! -e "$marker" ] || fail "quota-axi should not be called without quota-balanced select"
  pass "single-object use and no-select arrays preserve first-profile selection"
}

test_higher_min_vendor_wins
test_exact_tie_uses_first_profile
test_pi_cloud_uses_ollama_vendor
test_grok_uses_grok_vendor
test_explicit_vendor_override_wins_and_is_not_output
test_quota_missing_falls_back_to_first
test_quota_error_falls_back_to_first
test_quota_trouble_prefers_first_mapped_profile
test_bad_quota_json_falls_back_to_first
test_bad_quota_json_prefers_first_mapped_profile
test_stale_with_cache_needs_clear_margin_to_beat_fresh
test_vendor_absent_or_unusable_falls_back_conservatively
test_unmapped_and_absent_candidates_are_logged_and_excluded
test_no_usable_candidates_falls_back_to_first_mapped_profile
test_quota_vendor_diagnostics
test_backward_compatible_first_selection

echo "# all fm-dispatch-select tests passed"
