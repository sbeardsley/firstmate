#!/usr/bin/env bash
# Resolve one already-matched crew-dispatch rule to a concrete profile.
# Usage:
#   fm-dispatch-select.sh [--select <strategy>] [--quota-json <file>] [<rule-or-use-json>]
#   fm-dispatch-select.sh --quota-vendor-facts [<config-or-rule-json>]
#
# Input may be a full rule object with `use` and optional `select`, a single
# profile object, or an ordered array of profile objects.
# Output is one compact JSON profile object on stdout.
#
# quota-balanced is deterministic, and this header is the single owner of its
# contract:
#   - It runs quota-axi --json (or the --quota-json fixture).
#   - It resolves each candidate's quota vendor from the candidate profile, not
#     from the worker tool alone.
#     An explicit profile vendor string wins when present and remains optional
#     for backward compatibility.
#     Otherwise Claude and Codex harnesses map to their same-named quota
#     vendors, and Pi models ending in -cloud map to the Ollama quota vendor.
#     There is intentionally no generic Pi quota vendor.
#     Only vendors whose general-window ids are verified against real quota-axi
#     output are mapped here; a harness whose windows are unverified stays
#     unmapped on purpose, because a wrong window id silently excludes every
#     candidate for that vendor instead of failing loudly. Grok is deferred for
#     exactly this reason - its provider reports auth_required with zero windows
#     locally, so its general-window ids are unconfirmed.
#   - An explicit vendor value is EITHER a bare quota provider ("ollama") OR a
#     provider-qualified upstream model reference ("ollama:glm-5.2:cloud").
#     Only the FIRST colon separates; the prefix is the quota provider and the
#     entire remainder is one opaque upstream model reference that this selector
#     never interprets. An empty prefix (":x") or empty remainder ("ollama:") is
#     malformed. The provider prefix must be one of the mapped vendors above -
#     an explicit vendor selects among mapped providers, it cannot introduce an
#     unmapped one, because a provider with no verified window ids has nothing to
#     compare. Malformed values, unknown providers, and unmapped candidates are
#     all reported rather than silently dropped.
#     Ollama quota is account-level today, so only the provider prefix selects
#     windows; the opaque remainder is preserved in config and echoed in
#     diagnostics for future model-scoped support, never treated as a quota key.
#   - Per candidate quota vendor it takes the minimum percentRemaining across
#     that vendor's GENERAL windows only - Claude five_hour and seven_day, and
#     Codex five_hour and weekly - ignoring model-scoped windows such as
#     model:fable and model:codex_bengalfox:*.
#   - The Ollama mapping is STAGED AHEAD OF ITS PROVIDER. As of quota-axi's
#     current provider set (claude, codex, cursor, copilot, grok) there is no
#     ollama provider, so a Pi -cloud candidate resolves to vendor "ollama",
#     finds no matching provider, and is excluded from quota comparison with an
#     "absent from quota output" stderr line - dispatch still proceeds via the
#     other candidates or the mapped fallback. The mapping only starts changing
#     selection once quota-axi reports an ollama provider carrying five_hour and
#     weekly general windows; that provider shape is the contract this selector
#     assumes, and both sides of it are fixture-tested in
#     tests/fm-dispatch-select.test.sh.
#   - The vendor with the higher minimum remaining quota wins; an exact tie
#     between equally trusted candidates uses the first array element.
#   - Stale-but-cached general-window numbers are usable, but a fresh candidate
#     wins unless the stale candidate's minimum is at least the stale-clear
#     margin higher (default 20 points - the definition of "clearly less
#     constrained").
#   - A vendor absent from quota output, or with no usable general windows, is
#     unavailable; selection happens among available candidates, and excluded or
#     unmapped quota-balanced candidates are logged to stderr.
#   - If quota-axi is missing, exits non-zero, returns unparseable JSON, or no
#     candidate is usable, the reason is logged to stderr and the first profile
#     with a known quota vendor is printed, falling back to the first array
#     element only when none is mapped - quota trouble never blocks dispatch.
#
# quota-balanced uses quota-axi --json unless --quota-json supplies a fixture.
# --quota-vendor-facts prints non-actionable BOOTSTRAP_INFO facts for
# quota-balanced config candidates whose quota vendor is absent, malformed, or
# an unknown provider, then exits.
# These describe a static config, so bootstrap emits them only under
# FM_BOOTSTRAP_VERBOSE_FACTS; the per-dispatch exclusion lines above are the
# actionable runtime signal and are always logged to stderr.
# FM_DISPATCH_QUOTA_AXI overrides the quota command.
# FM_DISPATCH_STALE_CLEAR_MARGIN overrides the default 20 point stale margin.
set -u

STALE_CLEAR_MARGIN=${FM_DISPATCH_STALE_CLEAR_MARGIN:-20}
SELECT_OVERRIDE=
QUOTA_JSON_FILE=
QUOTA_VENDOR_FACTS=0
ARGS=()
# shellcheck disable=SC2016 # This is jq source; jq variables must not expand in the shell.
JQ_VENDOR_LIB='
  def clean($p):
    {harness: $p.harness}
    + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
    + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
  def profile_label($p):
    ($p.harness // "unknown" | tostring)
    + (if ($p.model? | type) == "string" then "/" + $p.model else "" end);
  def known_vendors: ["claude", "codex", "ollama"];
  def explicit_vendor($p):
    if ($p.vendor? | type) == "string" and ($p.vendor | length) > 0 then $p.vendor else null end;
  def inferred_vendor($p):
    ($p.harness // "") as $h
    | (if ($p.model? | type) == "string" then $p.model else "" end) as $m
    | if $h == "claude" then "claude"
      elif $h == "codex" then "codex"
      elif $h == "pi" and ($m | test("-cloud$")) then "ollama"
      else null
      end;
  def vendor_spec($p):
    (explicit_vendor($p) // inferred_vendor($p)) as $v
    | if $v == null then null
      else
        ($v | split(":")) as $parts
        | if ($parts | length) == 1 then {raw: $v, provider: $v, ref: null, malformed: false}
          else
            ($parts[0]) as $prefix
            | ($parts[1:] | join(":")) as $suffix
            | {
                raw: $v,
                provider: $prefix,
                ref: (if ($suffix | length) > 0 then $suffix else null end),
                malformed: (($prefix | length) == 0 or ($suffix | length) == 0)
              }
          end
      end;
  def vendor_display($s):
    ($s.raw | @json)
    + (if $s.ref == null then ""
       else " (quota provider " + ($s.provider | @json)
            + ", upstream model reference " + ($s.ref | @json) + ")"
       end);
  def vendor_provider_known($s): (known_vendors | index($s.provider)) != null;
  def quota_vendor($p):
    (vendor_spec($p)) as $s
    | if $s != null and ($s.malformed | not) and vendor_provider_known($s) then $s.provider
      else null
      end;
  def general_ids($v):
    if $v == "claude" then ["five_hour", "seven_day"]
    elif $v == "codex" then ["five_hour", "weekly"]
    elif $v == "ollama" then ["five_hour", "weekly"]
    else []
    end;
'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

log() {
  printf 'fm-dispatch-select: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quota-vendor-facts)
      QUOTA_VENDOR_FACTS=1
      shift
      ;;
    --select)
      [ "$#" -gt 1 ] || { echo "error: --select requires a value" >&2; exit 2; }
      SELECT_OVERRIDE=$2
      shift 2
      ;;
    --select=*)
      SELECT_OVERRIDE=${1#--select=}
      shift
      ;;
    --quota-json)
      [ "$#" -gt 1 ] || { echo "error: --quota-json requires a file" >&2; exit 2; }
      QUOTA_JSON_FILE=$2
      shift 2
      ;;
    --quota-json=*)
      QUOTA_JSON_FILE=${1#--quota-json=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option $1" >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

[ "${#ARGS[@]}" -le 1 ] || { echo "error: expected at most one JSON argument" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

if [ "${#ARGS[@]}" -eq 1 ]; then
  SPEC_JSON=${ARGS[0]}
else
  SPEC_JSON=$(cat)
fi

if [ "$QUOTA_VENDOR_FACTS" = 1 ]; then
  printf '%s\n' "$SPEC_JSON" | jq -r "$JQ_VENDOR_LIB"'
    def use_profiles($u):
      if ($u | type) == "array" then $u
      elif ($u | type) == "object" then [$u]
      else []
      end;
    def quota_rules:
      if type == "object" and (.rules? | type) == "array" then
        .rules[]? | select((.select? // "") == "quota-balanced")
      elif type == "object" and (.select? // "") == "quota-balanced" then
        .
      else
        empty
      end;
    quota_rules
    | use_profiles(.use?)[]?
    | . as $p
    | (vendor_spec($p)) as $s
    | if $s == null then
        "BOOTSTRAP_INFO: quota-balanced candidate " + profile_label($p) + " has no known quota vendor; selector excludes it from quota comparison"
      elif $s.malformed then
        "BOOTSTRAP_INFO: quota-balanced candidate " + profile_label($p) + " declares malformed quota vendor " + ($s.raw | @json) + "; expected \"<provider>\" or \"<provider>:<upstream model reference>\"; selector excludes it from quota comparison"
      elif (vendor_provider_known($s) | not) then
        "BOOTSTRAP_INFO: quota-balanced candidate " + profile_label($p) + " declares unknown quota vendor " + vendor_display($s) + "; selector excludes it from quota comparison"
      else empty
      end
  ' 2>/dev/null || true
  exit 0
fi

profiles_json=$(printf '%s\n' "$SPEC_JSON" | jq -ec '
  (if type == "object" and has("use") then .use else . end)
  | if type == "array" then .
    elif type == "object" then [.]
    else empty
    end
' 2>/dev/null) || { echo "error: dispatch input must be a rule, profile, or profile array" >&2; exit 2; }

profile_count=$(printf '%s\n' "$profiles_json" | jq 'length')
[ "$profile_count" -gt 0 ] || { echo "error: dispatch profile array must not be empty" >&2; exit 2; }

first_profile() {
  printf '%s\n' "$profiles_json" | jq -c '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    clean(.[0])
  '
}

fallback_profile() {
  printf '%s\n' "$profiles_json" | jq -c "$JQ_VENDOR_LIB"'
    clean((map(select(quota_vendor(.) != null))[0]) // .[0])
  '
}

fallback_target_label() {
  printf '%s\n' "$profiles_json" | jq -r "$JQ_VENDOR_LIB"'
    if (quota_vendor(.[0]) != null) then "first profile"
    elif (map(select(quota_vendor(.) != null)) | length) > 0 then "first quota-mapped profile"
    else "first profile"
    end
  '
}

quota_fallback() {
  local reason target
  reason=$1
  target=$(fallback_target_label)
  log "$reason; using $target"
  fallback_profile
  exit 0
}

select_strategy=$SELECT_OVERRIDE
if [ -z "$select_strategy" ]; then
  select_strategy=$(printf '%s\n' "$SPEC_JSON" | jq -r '
    if type == "object" and has("use") and (.select? | type) == "string" then .select else "" end
  ' 2>/dev/null || true)
fi

if [ "$select_strategy" != quota-balanced ]; then
  if [ -n "$select_strategy" ]; then
    log "unknown select strategy '$select_strategy'; using first profile"
  fi
  first_profile
  exit 0
fi

if [ -n "$QUOTA_JSON_FILE" ]; then
  if ! quota_json=$(cat "$QUOTA_JSON_FILE" 2>/dev/null); then
    quota_fallback "cannot read quota JSON"
  fi
else
  quota_cmd=${FM_DISPATCH_QUOTA_AXI:-quota-axi}
  if ! command -v "$quota_cmd" >/dev/null 2>&1; then
    quota_fallback "quota-axi missing"
  fi
  quota_json=$("$quota_cmd" --json 2>/dev/null)
  quota_status=$?
  if [ "$quota_status" -ne 0 ]; then
    quota_fallback "quota-axi exited $quota_status"
  fi
fi

if ! printf '%s\n' "$quota_json" | jq -e 'type == "object" and (.providers | type) == "array"' >/dev/null 2>&1; then
  quota_fallback "quota-axi returned unparseable JSON"
fi

selection=$(printf '%s\n' "$quota_json" | jq -ec \
  --argjson profiles "$profiles_json" \
  --argjson margin "$STALE_CLEAR_MARGIN" "$JQ_VENDOR_LIB"'
  def provider_for($v): [.providers[]? | select(.provider == $v)][0];
  def excluded($i; $p; $message):
    {index: $i, profile: clean($p), excluded: true, message: $message};
  def candidate_metric($p; $i):
    . as $root
    | (vendor_spec($p)) as $s
    | if $s == null then
        excluded($i; $p; "candidate \($i) (" + profile_label($p) + ") has no known quota vendor; excluded from quota comparison")
      elif $s.malformed then
        excluded($i; $p; "candidate \($i) (" + profile_label($p) + ") declares malformed quota vendor " + ($s.raw | @json) + "; expected \"<provider>\" or \"<provider>:<upstream model reference>\"; excluded from quota comparison")
      elif (vendor_provider_known($s) | not) then
        excluded($i; $p; "candidate \($i) (" + profile_label($p) + ") declares unknown quota vendor " + vendor_display($s) + "; excluded from quota comparison")
      else
        ($s.provider) as $vendor
        | ($root | provider_for($vendor)) as $provider
        | if $provider == null then
            excluded($i; $p; "candidate \($i) (" + profile_label($p) + ") quota vendor " + vendor_display($s) + " absent from quota output; excluded from quota comparison")
          else {
            index: $i,
            profile: clean($p),
            vendor: $vendor,
            provider: $provider
          } as $base
          | (($provider.windows // [])
            | map(. as $window
              | select(((general_ids($vendor) | index($window.id)) != null)
                and (($window.kind? // "") != "model")
                and (($window.percentRemaining? | type) == "number")))) as $windows
          | if ($windows | length) == 0 then
              excluded($i; $p; "candidate \($i) (" + profile_label($p) + ") quota vendor " + vendor_display($s) + " has no usable general windows; excluded from quota comparison")
            else
              $base
              + {
                min: ($windows | map(.percentRemaining) | min),
                fresh: (($provider.state.status? // "") == "fresh")
              }
            end
          end
      end;
  def better($a; $b):
    if $a == null then $b
    elif $b == null then $a
    elif ($b.min > $a.min) then $b
    elif ($b.min == $a.min and $b.index < $a.index) then $b
    else $a
    end;
  def best_by_min($xs): reduce $xs[] as $x (null; better(.; $x));
  . as $quota_root
  | ([$profiles | to_entries[] | . as $entry | ($quota_root | candidate_metric($entry.value; $entry.key))]) as $states
  | ($states | map(select(.excluded? != true))) as $candidates
  | ($states | map(select(.excluded? == true) | .message)) as $excluded
  | if ($candidates | length) == 0 then {
      fallback: true,
      reason: "no usable quota windows for candidate vendors",
      excluded: $excluded,
      profile: clean((($profiles | map(select(quota_vendor(.) != null))[0]) // $profiles[0]))
    }
    else
      (best_by_min($candidates | map(select(.fresh)))) as $fresh_best
      | (best_by_min($candidates | map(select(.fresh | not)))) as $stale_best
      | (if $fresh_best != null and $stale_best != null then
          if $stale_best.min >= ($fresh_best.min + $margin) then $stale_best else $fresh_best end
        elif $fresh_best != null then $fresh_best
        else $stale_best
        end) as $chosen
      | {fallback: false, excluded: $excluded, profile: $chosen.profile}
    end
' 2>/dev/null) || {
  quota_fallback "quota-axi data could not be evaluated"
}

printf '%s\n' "$selection" | jq -r '.excluded[]?' | while IFS= read -r exclusion; do
  [ -n "$exclusion" ] && log "$exclusion"
done

if [ "$(printf '%s\n' "$selection" | jq -r '.fallback')" = true ]; then
  log "$(printf '%s\n' "$selection" | jq -r '.reason'); using $(fallback_target_label)"
fi
printf '%s\n' "$selection" | jq -c '.profile'
