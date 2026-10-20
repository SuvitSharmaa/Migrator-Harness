#!/usr/bin/env bash
#
# input-sets-from-audit.sh — Recover DELETED input sets' YAML from Harness's
# Audit Trail and hand the customer a CSV they can work through by hand.
#
# Why this exists, and why it's separate: restore-from-audit.sh reconstructs a
# deleted project into export.sh's on-disk layout so import.sh can replay it
# automatically. Input sets are NOT part of that flow — they fall into its
# "unsupported resource type" bucket and are only logged, never restored. This
# script fills that gap deliberately at a lower ambition level: it is READ-ONLY
# against the source account (no target token, nothing is created anywhere) and
# its only output is a CSV + sidecar YAML files that a human recreates in the
# target UI themselves.
#
# Nothing here writes into export.sh's layout and nothing here is called by
# migrate.sh — run it on its own, before or after a migration, whenever.
#
# What it does:
#   1. Lists DELETE audit events for SRC_ORG/SRC_PROJECT in the last
#      LOOKBACK_DAYS (same endpoint + pagination approach as
#      restore-from-audit.sh: POST /audit/api/audits/list).
#   2. Keeps the input-set ones, newest DELETE per identifier (an identifier
#      can be deleted, recreated, and deleted again inside one window —
#      reporting the superseded delete would hand over stale YAML).
#   3. Pulls each one's last-known YAML from GET /audit/api/auditYaml.
#   4. Writes every input set to its own .yaml file AND inlines the same YAML
#      in the CSV's last column, so the customer can use whichever is easier
#      (open the file and copy, or read straight from the spreadsheet).
#
# Both kinds are included and labeled. Harness records regular and overlay
# input sets under the same audit resource type, so they're told apart by the
# recovered YAML's root key instead: `inputSet:` -> INPUT_SET,
# `overlayInputSet:` -> OVERLAY_INPUT_SET. Overlays only reference other input
# sets by identifier (inputSetReferences), so restore the INPUT_SET rows
# first — an overlay whose references don't exist yet won't save.
#
# Output (OUT_DIR, default a fresh timestamped dir under ./input-set-recovery):
#   input-sets.csv              the handover file
#   yaml/<identifier>.yaml          one per regular input set
#   yaml/<identifier>.overlay.yaml  one per overlay input set
#
# CSV columns:
#   Restored    deliberately blank — the customer's own progress checkbox
#   Org         where to restore into (from the audit event's scope)
#   Project
#   Pipeline    the input set's parent pipeline IDENTIFIER (not display name —
#               the pipeline is deleted too, so there's nothing live to read a
#               name from, and the identifier is what you navigate by anyway)
#   InputSetId
#   Name        display name
#   Type        INPUT_SET | OVERLAY_INPUT_SET
#   DeletedAt   ISO-8601 UTC, from the DELETE event's timestamp
#   YamlFile    relative path to the sidecar file
#   Yaml        the full YAML, inline
#
# Usage — just run it, it asks for what it needs:
#
#   ./input-sets-from-audit.sh
#
# Hybrid prompting, same contract as migrate.sh: any variable already set in
# the environment is used as-is and never prompted for, so the exact same
# script still runs fully non-interactively, e.g.:
#
#   SRC_HARNESS_TOKEN=... SRC_ACCOUNT_ID=... SRC_BASE_URL=https://prod5.harness.io/gateway \
#   SRC_ORG=default SRC_PROJECT=p1 LOOKBACK_DAYS=30 ASSUME_YES=1 \
#     ./input-sets-from-audit.sh
#
# SRC_ORG/SRC_PROJECT must be the identifiers as they were BEFORE deletion.
# LOOKBACK_DAYS has to cover the day the deletion happened — if you get zero
# rows, widen it before concluding there were no input sets.
#
set -uo pipefail

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq required (brew install yq)" >&2; exit 1; }

# ask VAR "prompt" [default] [secret(0/1)]
#   Prompts only if $VAR isn't already set — lets every value be pre-supplied
#   via env vars for non-interactive / scripted runs. Lifted verbatim from
#   migrate.sh so both scripts prompt identically.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __secret="${4:-0}"
  local __current
  eval "__current=\"\${$__var:-}\""
  if [[ -n "$__current" ]]; then return; fi
  local __suffix=""
  [[ -n "$__default" ]] && __suffix=" [$__default]"
  local __value
  if [[ "$__secret" == "1" ]]; then
    read -r -s -p "$__prompt$__suffix: " __value; echo
  else
    read -r -p "$__prompt$__suffix: " __value
  fi
  [[ -z "$__value" ]] && __value="$__default"
  printf -v "$__var" '%s' "$__value"
  export "$__var"
}

# ask_required VAR "prompt" [default] [secret]
#   Same as ask, but keeps re-asking on an empty answer instead of carrying a
#   blank into the API call and failing with something cryptic several steps
#   later. The tty guard matters: with stdin closed (piped/CI), `read` returns
#   empty immediately, so without it a missing value would spin forever.
ask_required() {
  local __var="$1" __v
  while :; do
    ask "$@"
    eval "__v=\"\${$__var:-}\""
    [[ -n "$__v" ]] && return 0
    if [[ ! -t 0 ]]; then
      echo "ERROR: $__var is required, and stdin isn't a terminal to prompt on." >&2
      echo "  Set it via environment variable for non-interactive runs." >&2
      exit 1
    fi
    echo "  $__var is required." >&2
  done
}

confirm() { # <prompt> -> 0 (proceed) on y/Y, 1 otherwise
  local reply
  read -r -p "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

mask() {
  local v="$1"
  [[ -z "$v" ]] && { echo "(none)"; return; }
  [[ "${#v}" -le 4 ]] && echo '****' || echo "${v:0:4}...(${#v} chars)"
}

echo "=== Recover deleted input sets from the audit trail ==="
echo "Read-only: this reads the SOURCE account's audit trail and writes local files."
echo "It never creates, modifies, or deletes anything in any Harness account."
echo

# restore-from-audit.sh and export.sh take the source token as HARNESS_TOKEN,
# while migrate.sh calls it SRC_HARNESS_TOKEN. Accept either so a token already
# exported for one of those is picked up instead of being prompted for again.
: "${SRC_HARNESS_TOKEN:=${HARNESS_TOKEN:-}}"

ask_required SRC_ACCOUNT_ID    "Source account ID"
ask          SRC_BASE_URL      "Source base URL (SaaS usually needs the /gateway suffix, e.g. https://app.harness.io/gateway)" "https://prod5.harness.io/gateway"
ask_required SRC_HARNESS_TOKEN "Source token (needs audit-trail read access)" "" 1
ask_required SRC_ORG           "Source org identifier (as it was BEFORE deletion)"
ask_required SRC_PROJECT       "Source project identifier (as it was BEFORE deletion)"

# Validated in a loop rather than trusted: a non-numeric value here would blow
# up inside the START_MS arithmetic below with an unhelpful bash error.
while :; do
  ask_required LOOKBACK_DAYS "How many days back should I search the audit trail for the deletion?" "30"
  [[ "$LOOKBACK_DAYS" =~ ^[1-9][0-9]*$ ]] && break
  if [[ ! -t 0 ]]; then
    echo "ERROR: LOOKBACK_DAYS must be a whole number of days greater than 0 (got: $LOOKBACK_DAYS)" >&2
    exit 1
  fi
  echo "  Please enter a whole number of days greater than 0 (got: $LOOKBACK_DAYS)." >&2
  LOOKBACK_DAYS=""
done

# Fresh per-run directory by default, for the same reason migrate.sh does it:
# a shared output dir would leave the PREVIOUS run's yaml/ sidecars sitting
# next to this run's CSV (the CSV is overwritten, the sidecars are not), so a
# handover could silently include input sets from a different project. Only a
# default — `ask` skips this entirely if OUT_DIR is already set.
RUN_STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
ask OUT_DIR "Local output directory" "./input-set-recovery/${RUN_STAMP}__${SRC_ORG}_${SRC_PROJECT}"

echo
echo "=== Plan ==="
echo "  Source account:  $SRC_ACCOUNT_ID @ $SRC_BASE_URL (token: $(mask "$SRC_HARNESS_TOKEN"))"
echo "  Source project:  $SRC_ORG/$SRC_PROJECT"
echo "  Lookback:        $LOOKBACK_DAYS days"
echo "  Output dir:      $OUT_DIR"
echo
if [[ -z "${ASSUME_YES:-}" ]]; then
  confirm "Search the audit trail for deleted input sets?" || { echo "Aborted."; exit 1; }
  echo
fi

TOKEN="$SRC_HARNESS_TOKEN"
ACC="$SRC_ACCOUNT_ID"
BASE="$SRC_BASE_URL"
OUT="$OUT_DIR"

if [[ "$TOKEN" == pat.* || "$TOKEN" == sat.* ]]; then
  AUTH=(-H "x-api-key: $TOKEN")
else
  AUTH=(-H "authorization: Bearer $TOKEN")
fi
H=("${AUTH[@]}" -H 'content-type: application/json' -H 'accept: */*')

NOW_MS=$(( $(date +%s) * 1000 ))
START_MS=$(( NOW_MS - LOOKBACK_DAYS*86400*1000 ))

YAML_DIR="$OUT/yaml"
CSV="$OUT/input-sets.csv"
mkdir -p "$YAML_DIR" || { echo "ERROR: couldn't create $YAML_DIR" >&2; exit 1; }

echo "=== Recovering deleted input sets from $SRC_ORG/$SRC_PROJECT (last $LOOKBACK_DAYS days) -> $OUT ==="

# paginate_audits BODY_JSON -> {"data":{"content":[...]}} merged across every
# page, deduped by auditId. Same defensive approach as restore-from-audit.sh:
# pageIndex is sent both via query string AND merged into the body, since we
# have no direct evidence which convention this endpoint honors (captures only
# ever showed page 0). Stops when a page adds nothing new, so it terminates
# even if pageIndex is silently ignored and every page is identical.
paginate_audits() {
  local base_body="$1" label="$2" page=0 acc='[]' resp got n merged old_count new_count body_paged code tmp
  while :; do
    body_paged="$(echo "$base_body" | jq -c --argjson pi "$page" '. + {pageIndex: $pi}')"
    tmp="$(mktemp)"
    code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST \
      "$BASE/audit/api/audits/list?accountIdentifier=$ACC&routingId=$ACC&pageSize=100&pageIndex=$page" \
      "${H[@]}" --data-raw "$body_paged")"
    resp="$(cat "$tmp")"; rm -f "$tmp"
    if [[ "$page" -eq 0 && ! "$code" =~ ^2 ]]; then
      echo "ERROR: $label failed (HTTP $code) against $BASE" >&2
      echo "  Check SRC_BASE_URL/HARNESS_TOKEN, and that this token has audit-trail read access." >&2
      # Untruncated on purpose — see export.sh's paginate_content for why.
      echo "  Response: $resp" >&2
      return 1
    fi
    got="$(echo "$resp" | jq -c '.data.content // []' 2>/dev/null)"
    [[ -z "$got" || "$got" == "null" ]] && got='[]'
    n="$(echo "$got" | jq 'length' 2>/dev/null)"; n="${n:-0}"
    [[ "$n" -eq 0 ]] && break
    old_count="$(echo "$acc" | jq 'length' 2>/dev/null)"; old_count="${old_count:-0}"
    merged="$(jq -cn --argjson a "$acc" --argjson b "$got" '($a + $b) | unique_by(.auditId)' 2>/dev/null)"
    [[ -z "$merged" ]] && merged="$acc"
    new_count="$(echo "$merged" | jq 'length' 2>/dev/null)"; new_count="${new_count:-$old_count}"
    [[ "$new_count" -eq "$old_count" ]] && break
    acc="$merged"
    page=$((page+1))
    if [[ "$page" -gt 500 ]]; then
      echo "  WARNING: $label pagination stopped after 500 pages — results may be incomplete" >&2
      break
    fi
  done
  printf '{"data":{"content":%s}}' "$acc"
}

# audit_yaml AUDIT_ID -> the entity's last-known YAML. A DELETE event carries
# it in oldYaml; newYaml is the fallback only because jq's `//` won't help here
# (oldYaml comes back as an empty STRING, not null, in some events — a naive
# `a // b` would "win" with "" instead of falling through), so blankness is
# checked explicitly.
audit_yaml() {
  local aid="$1" resp
  resp="$(curl -s "${H[@]}" "$BASE/audit/api/auditYaml?accountIdentifier=$ACC&routingId=$ACC&auditId=$aid")"
  echo "$resp" | jq -r '
    (.data.oldYaml // "") as $o |
    if ($o | length) > 0 then $o else (.data.newYaml // "") end
  ' 2>/dev/null
}

# RFC-4180 quoting. Broader than restore-from-audit.sh's version on purpose:
# that one only ever escaped short identifier-ish fields, whereas the Yaml
# column here contains real NEWLINES, which must also force quoting or the
# row silently splits across lines and the file is garbage.
csv_escape() {
  local f="$1"
  if [[ "$f" == *,* || "$f" == *'"'* || "$f" == *$'\n'* || "$f" == *$'\r'* ]]; then
    f="${f//\"/\"\"}"
    printf '"%s"' "$f"
  else
    printf '%s' "$f"
  fi
}

echo "Querying deleted entities in $SRC_ORG/$SRC_PROJECT..."
DELETE_BODY="$(jq -cn --arg acc "$ACC" --arg org "$SRC_ORG" --arg proj "$SRC_PROJECT" \
  --arg st "$START_MS" --arg et "$NOW_MS" \
  '{scopes:[{accountIdentifier:$acc, orgIdentifier:$org, projectIdentifier:$proj}], filterType:"Audit", actions:["DELETE"], startTime:$st, endTime:$et}')"
DELETES_RAW="$(paginate_audits "$DELETE_BODY" "list deleted entities")" || exit 1

# Re-filter client-side (scope + action) in case the server ignores either
# filter, then narrow to input sets. The resource.type list is deliberately
# wider than the one value we expect: Harness records both regular and overlay
# input sets as INPUT_SET, but accepting the plausible variants costs nothing
# and avoids silently reporting zero if that ever differs by version.
EVENTS="$(echo "$DELETES_RAW" | jq -c --arg org "$SRC_ORG" --arg proj "$SRC_PROJECT" '
  [.data.content[]
   | select(.action=="DELETE"
            and .resourceScope.orgIdentifier==$org
            and .resourceScope.projectIdentifier==$proj)
   | select(.resource.type as $t
            | ["INPUT_SET","INPUT_SETS","OVERLAY_INPUT_SET","INPUT_SET_OVERLAY"] | index($t))]
  | group_by(.resource.type + "/" + .resource.identifier) | map(max_by(.timestamp))')"

n_found="$(echo "$EVENTS" | jq 'length')"
echo "Found $n_found deleted input set$([[ "$n_found" == 1 ]] && echo "" || echo s)."

# Write the header unconditionally, so a zero-row run still produces a valid,
# obviously-empty handover file rather than no file at all.
printf 'Restored,Org,Project,Pipeline,InputSetId,Name,Type,DeletedAt,YamlFile,Yaml\n' > "$CSV"

if [[ "$n_found" -eq 0 ]]; then
  echo
  echo "No deleted input sets matched. Before concluding there were none:" >&2
  echo "  - widen LOOKBACK_DAYS so it covers the day the deletion happened" >&2
  echo "  - confirm SRC_ORG/SRC_PROJECT are the identifiers from BEFORE deletion" >&2
  echo "  - confirm the token can read the audit trail for this scope" >&2
  echo
  echo "Wrote $CSV (header only)."
  exit 0
fi

n_rows=0; n_noyaml=0; n_nopipeline=0
declare -a NO_YAML=()
declare -a NO_PIPELINE=()

echo "Recovering YAML..."
while IFS= read -r ev; do
  [[ -z "$ev" ]] && continue
  rid="$(echo "$ev" | jq -r '.resource.identifier')"
  aid="$(echo "$ev" | jq -r '.auditId')"
  org="$(echo "$ev" | jq -r '.resourceScope.orgIdentifier // ""')"
  proj="$(echo "$ev" | jq -r '.resourceScope.projectIdentifier // ""')"
  # jq does the epoch-ms -> ISO-8601 conversion rather than date(1), whose
  # flags differ between BSD (macOS) and GNU (Linux).
  deleted_at="$(echo "$ev" | jq -r '(.timestamp // 0) as $t | if $t > 0 then (($t/1000) | todate) else "" end' 2>/dev/null)"
  label_name="$(echo "$ev" | jq -r '.resource.labels.resourceName // ""')"
  label_pipeline="$(echo "$ev" | jq -r '.resource.labels.pipelineIdentifier // ""')"

  yaml="$(audit_yaml "$aid")"

  if [[ -z "$yaml" ]]; then
    # Still emit a row. A silently dropped input set reads as "this one didn't
    # exist", which is worse than a row saying plainly that its YAML is gone.
    echo "    WARNING $rid — no YAML in the audit record; row written with empty Yaml/YamlFile" >&2
    NO_YAML+=("$rid")
    n_noyaml=$((n_noyaml+1))
    {
      printf '%s,' ""
      printf '%s,' "$(csv_escape "$org")"
      printf '%s,' "$(csv_escape "$proj")"
      printf '%s,' "$(csv_escape "${label_pipeline:-UNKNOWN}")"
      printf '%s,' "$(csv_escape "$rid")"
      printf '%s,' "$(csv_escape "${label_name:-$rid}")"
      printf '%s,' "UNKNOWN"
      printf '%s,' "$(csv_escape "$deleted_at")"
      printf '%s,' ""
      printf '%s\n' ""
    } >> "$CSV"
    n_rows=$((n_rows+1))
    continue
  fi

  # Convert once and read every field with jq. yq (mikefarah v4) is used
  # elsewhere in this repo only for path lookups and -o=json conversion
  # because it has no jq-style `if/then/else` — attempting that there fails
  # the whole expression, so the branching below deliberately happens in jq.
  # An unparseable document yields empty JSON and every field falls back to
  # the audit event's labels rather than aborting the row.
  yjson="$(printf '%s' "$yaml" | yq -o=json '.' 2>/dev/null)"
  if ! echo "$yjson" | jq -e . >/dev/null 2>&1; then
    echo "    WARNING $rid — YAML didn't parse; row written from audit labels only" >&2
    yjson='{}'
  fi

  # Regular vs overlay is decided by the document's root key, not the audit
  # resource type, because Harness files both under the same type.
  kind="$(echo "$yjson" | jq -r '
    if has("overlayInputSet") then "OVERLAY_INPUT_SET"
    elif has("inputSet") then "INPUT_SET"
    else "UNKNOWN" end' 2>/dev/null)"
  [[ -z "$kind" || "$kind" == "null" ]] && kind="UNKNOWN"

  name="$(echo "$yjson" | jq -r '.inputSet.name // .overlayInputSet.name // ""' 2>/dev/null)"
  [[ -z "$name" || "$name" == "null" ]] && name="${label_name:-$rid}"

  # Parent pipeline. Regular input sets nest the pipeline they apply to;
  # overlays name it flat. Field placement has varied across versions, so each
  # known spelling is tried before falling back to the audit event's label.
  pipeline="$(echo "$yjson" | jq -r '
    .inputSet.pipeline.identifier
    // .inputSet.pipelineIdentifier
    // .overlayInputSet.pipelineIdentifier
    // .overlayInputSet.pipeline.identifier
    // ""' 2>/dev/null)"
  [[ -z "$pipeline" || "$pipeline" == "null" ]] && pipeline="$label_pipeline"
  if [[ -z "$pipeline" ]]; then
    pipeline="UNKNOWN"
    NO_PIPELINE+=("$rid")
    n_nopipeline=$((n_nopipeline+1))
  fi

  # Identifiers are alphanumeric+underscore by Harness's own validation, but
  # this writes to the filesystem from remote data — sanitize rather than
  # trust it.
  safe="${rid//[^A-Za-z0-9._-]/_}"
  [[ -z "$safe" ]] && safe="unnamed"
  if [[ "$kind" == "OVERLAY_INPUT_SET" ]]; then
    fname="${safe}.overlay.yaml"
  else
    fname="${safe}.yaml"
  fi
  printf '%s' "$yaml" > "$YAML_DIR/$fname"

  {
    printf '%s,' ""
    printf '%s,' "$(csv_escape "$org")"
    printf '%s,' "$(csv_escape "$proj")"
    printf '%s,' "$(csv_escape "$pipeline")"
    printf '%s,' "$(csv_escape "$rid")"
    printf '%s,' "$(csv_escape "$name")"
    printf '%s,' "$(csv_escape "$kind")"
    printf '%s,' "$(csv_escape "$deleted_at")"
    printf '%s,' "$(csv_escape "yaml/$fname")"
    printf '%s\n' "$(csv_escape "$yaml")"
  } >> "$CSV"

  n_rows=$((n_rows+1))
  echo "    $kind/$rid -> yaml/$fname (pipeline: $pipeline)"
done < <(echo "$EVENTS" | jq -c '.[]')

echo
echo "=== Done ==="
echo "  $CSV  ($n_rows row$([[ "$n_rows" == 1 ]] && echo "" || echo s))"
echo "  $YAML_DIR/  (one file per recovered input set)"
if [[ "$n_noyaml" -gt 0 ]]; then
  echo
  echo "  $n_noyaml input set(s) had NO YAML in the audit record — their rows are present" >&2
  echo "  but Yaml/YamlFile are empty, and they cannot be recovered from the audit trail:" >&2
  printf '    %s\n' "${NO_YAML[@]}" >&2
fi
if [[ "$n_nopipeline" -gt 0 ]]; then
  echo
  echo "  $n_nopipeline input set(s) have Pipeline=UNKNOWN — the parent pipeline wasn't in the" >&2
  echo "  recovered YAML or the audit labels. Open the YAML to work out where they belong:" >&2
  printf '    %s\n' "${NO_PIPELINE[@]}" >&2
fi
echo
echo "Hand $CSV to the customer. To restore, for each row: open the target project's"
echo "pipeline named in the Pipeline column -> Input Sets -> New Input Set -> switch to the"
echo "YAML editor -> paste the Yaml column (or the YamlFile contents) -> Save, then tick"
echo "the Restored column. Do every INPUT_SET row BEFORE any OVERLAY_INPUT_SET row —"
echo "overlays reference other input sets by identifier and won't save until those exist."
