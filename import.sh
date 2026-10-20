#!/usr/bin/env bash
#
# import.sh — Replay an export produced by export.sh into a TARGET Harness account.
#
# Default target is app.harness.io (prod). Discovers which scope directories
# the export actually contains — "account", "org-scope__<org>" (org-only —
# see below), or "<org>__<project>" — recreates each project, then upserts
# every entity into its scope. By default the target scope mirrors the
# source identifiers exactly; set TGT_ORG/TGT_PROJECT to redirect a
# single-project export into a differently-named target project. Account-
# scope entries stay at the TARGET account's account scope (not remapped);
# org-scope entries move to org "org:$TGT_ORG" (the project's own target org).
#
# Dependency order: orgs(exist) -> projects -> templates -> connectors ->
# service accounts -> user groups -> services -> environments ->
# infrastructures -> pipelines -> triggers. Every entity is UPSERTed
# (create; on "already exists" fall back to update).
#
# NOT imported (by design):
#   - secrets       : values can't be exported; see harness-export/secrets-manifest.md
#   - file store    : source entries are Harness auto-seeded sample manifests
#   - role bindings : principals (users) don't exist identically in the target
#   - Harness-native "repository" objects (e.g. IACM's Terraform module repos)
#     and resources outside these entity types (e.g. Monitored Services) —
#     out of scope; a handful of IACM workspaces/pipelines may still need
#     manual follow-up if they depend on these.
#   Note on GitX webhooks: a webhook that appears ONLY as a side effect of a
#   pipeline/template's Git link (no independent create call — confirmed via
#   a HAR capture) reappears on its own once that entity's git-import
#   succeeds against the target's connector; re-importing it here is
#   harmless (falls back to update) but not required. A manually-created
#   GitX webhook (Project Settings -> Webhooks) IS a real, independently-
#   creatable resource and IS imported (see the webhooks/ loop below). A
#   LIVE export.sh run reads spec.connector_ref straight from the API, so
#   this ambiguity never matters for normal project/account migration —
#   it's restore-from-audit.sh specifically that can't tell the two kinds
#   apart from the audit trail alone (no connectorRef in a delete event's
#   YAML), so that path asks you to supply ConnectorRef by hand instead.
#
# Failure handling — the retry loop:
#   This script does NOT exit on failures. After each pass it writes
#   <IN_DIR>/summary-run<N>.csv listing every entity with its status and the
#   FULL error, then waits:
#
#     [Enter]     re-read the CSV, write the operator's corrected Branch /
#                 GitFilePath / ConnectorRef back into the files the import
#                 actually reads, and re-attempt ONLY the rows still marked
#                 `failed`. Writes summary-run<N+1>.csv and asks again.
#     [FORCE]     emit force-inline-review.csv listing the still-failing
#                 git-linked pipelines/templates; the operator marks
#                 ConvertToInline=Yes per row, and those are rebuilt as inline
#                 entities from the content captured at delete time. They stop
#                 being git-backed — hence opt-in, per row, on paper.
#     [terminate] stop; the latest CSV is the record.
#
#   Why the write-back exists: a git-linked pipeline is represented on disk by
#   <id>.remote.json holding {connectorRef, repoName, filePath, branch, yaml}.
#   The import reads the branch from THAT file, never from the review CSV — so
#   before this loop existed, correcting a branch in the CSV had no effect on
#   anything. Rows marked NOT RETRYABLE (e.g. a pipeline whose org-level
#   template is missing) can't be fixed by editing any of those fields; they
#   are kept in every round's CSV for the record but never re-attempted.
#
#   Full, untruncated API response bodies for every non-2xx go to
#   <IN_DIR>/import-errors.log. The console line is a flattened one-liner;
#   some Harness errors ("Error occurred while creating webhook") carry nothing
#   useful in .message at all and only the raw body explains them.
#
# Usage:
#   HARNESS_TOKEN=<target-token> TGT_ACCOUNT_ID=<acct> ./import.sh            # apply
#   HARNESS_TOKEN=<target-token> TGT_ACCOUNT_ID=<acct> DRY_RUN=1 ./import.sh  # preview
#
#   # project mode: import a single-project export (produced by
#   # `export.sh` with SRC_ORG/SRC_PROJECT set) into a specific target
#   # org/project — which may use a different identifier than the source:
#   HARNESS_TOKEN=<target-token> TGT_ACCOUNT_ID=<acct> \
#     TGT_ORG=default TGT_PROJECT=AliceCopy [TGT_PROJECT_NAME="Alice Copy"] \
#     ./import.sh
#
set -uo pipefail

TOKEN="${HARNESS_TOKEN:?set HARNESS_TOKEN to a TARGET account bearer token / x-api-key}"
ACC="${TGT_ACCOUNT_ID:?set TGT_ACCOUNT_ID to the target account identifier}"
BASE="${TGT_BASE_URL:-https://machine-pulse.harness.io}"
IN="${IN_DIR:-./harness-export}"
DRY="${DRY_RUN:-0}"
TGT_ORG="${TGT_ORG:-}"
TGT_PROJECT="${TGT_PROJECT:-}"
TGT_PROJECT_NAME="${TGT_PROJECT_NAME:-}"

if [[ -n "$TGT_ORG" && -z "$TGT_PROJECT" ]] || [[ -z "$TGT_ORG" && -n "$TGT_PROJECT" ]]; then
  echo "set both TGT_ORG and TGT_PROJECT for a project-scoped import, or leave both unset to mirror the export's own org/project identifiers" >&2
  exit 1
fi
PROJECT_MODE=0
[[ -n "$TGT_ORG" && -n "$TGT_PROJECT" ]] && PROJECT_MODE=1

# Auth header: a real API key uses x-api-key; a UI JWT uses Authorization: Bearer.
# Token starting with "pat." or "sat." => API key; else treat as bearer.
if [[ "$TOKEN" == pat.* || "$TOKEN" == sat.* ]]; then
  AUTH=(-H "x-api-key: $TOKEN")
else
  AUTH=(-H "authorization: Bearer $TOKEN")
fi
H=("${AUTH[@]}" -H 'content-type: application/json' -H 'accept: */*')
HY=("${AUTH[@]}" -H 'content-type: application/yaml' -H 'accept: */*')

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq required (brew install yq)" >&2; exit 1; }
[[ -d "$IN" ]] || { echo "export dir '$IN' not found — run export.sh first" >&2; exit 1; }

# Harness built-in connectors that exist in every account — never replicate.
BUILTIN_CONNECTORS="harnessSecretManager harnessImage"
is_builtin() { case " $BUILTIN_CONNECTORS " in *" $1 "*) return 0;; *) return 1;; esac; }

PASS=0; FAIL=0; SKIP=0
declare -a FAILED

# ---- run artifacts (retry loop) --------------------------------------------
# RESULTS is a JSONL scratch file holding one record per entity attempted in
# the CURRENT round. It exists because the per-entity outcome has to survive
# subshells: the projects loop below is `jq ... | while read`, whose body runs
# in a subshell, so `PASS=$((PASS+1))` inside it is silently discarded by the
# parent (this is why a run that printed 100 OK lines reported "99 ok"). A
# file sidesteps the whole class of problem, and doubles as the source the
# summary CSV is built from.
#
# ERRLOG gets the FULL raw response body for every non-2xx — not the trimmed
# one-line `.message` the console shows. Needed because some Harness errors
# ("Error occurred while creating webhook") carry nothing useful in .message
# at all, and the real cause only ever appears in the rest of the body.
RESULTS="$(mktemp)"
ERRLOG="$IN/import-errors.log"
RUN_ROUND=1
# Allowlist of "TYPE<TAB>ID" lines to re-attempt. EMPTY FILE IS NOT "ALLOW
# NOTHING" — RETRY_ONLY is only consulted when RETRY_ACTIVE=1, so round 1
# attempts everything. Keeping these as two separate flags (rather than
# treating an empty allowlist as "first round") means a retry round that
# legitimately resolves to zero entities can't silently turn into a full
# re-import of all 344.
RETRY_ONLY="$(mktemp)"
RETRY_ACTIVE=0
# Fully-formatted CSV rows for entities NOT attempted in the current round —
# anything already succeeded, or classified NOT RETRYABLE. Re-emitted into
# every subsequent summary so the file stays a complete record of the restore
# rather than a shrinking view of only what's still being retried.
CARRY_FORWARD="$(mktemp)"
trap 'rm -f "$RESULTS" "$RETRY_ONLY" "$CARRY_FORWARD"' EXIT

# parse_label LABEL -> sets LBL_TYPE / LBL_ID / LBL_VARIANT
#   Labels passed to req() are already structured as "<type>/<id>" with an
#   optional " (variant)" suffix — e.g. "pipeline/foo (git-import)",
#   "template/bar/v1 (update)", "infra/prod/eks". Splitting here rather than
#   threading type/id through ~20 call sites keeps req()'s signature stable.
#   IDs legitimately contain slashes (template/<id>/<ver>, infra/<env>/<id>),
#   so only the FIRST slash is treated as the type separator.
LBL_TYPE=""; LBL_ID=""; LBL_VARIANT=""
parse_label() {
  local l="$1" base=""
  LBL_VARIANT=""
  case "$l" in
    *" ("*")") LBL_VARIANT="${l##*\(}"; LBL_VARIANT="${LBL_VARIANT%\)}"; base="${l%% (*}" ;;
    *)         base="$l" ;;
  esac
  LBL_TYPE="${base%%/*}"
  if [[ "$base" == */* ]]; then LBL_ID="${base#*/}"; else LBL_ID=""; fi
}

# record_result LABEL STATUS CODE ERROR
#   STATUS is one of: ok | failed | skipped. Written as JSON so the error text
#   (which routinely contains commas and quotes) can't corrupt the record —
#   CSV escaping happens later, once, at write time.
#
#   Newlines are flattened HERE, at the single choke point every record passes
#   through, rather than only in req(). A multi-line cell is technically valid
#   CSV and a strict parser copes, but the read-back loop below is line-
#   oriented: the continuation lines come back as phantom rows with an empty
#   Status and get silently carried forward into the next round's file. Doing
#   it here means no future caller can reintroduce that.
record_result() {
  parse_label "$1"
  local err; err="$(printf '%s' "$4" | tr '\n\r\t' '   ')"
  jq -cn --arg t "$LBL_TYPE" --arg i "$LBL_ID" --arg v "$LBL_VARIANT" \
         --arg s "$2" --arg c "$3" --arg e "$err" --arg d "${SCDIR:-}" \
    '{type:$t, id:$i, variant:$v, status:$s, code:$c, error:$e, scdir:$d}' >> "$RESULTS"
}

# log_raw_error LABEL CODE BODY -> append the untruncated response to ERRLOG
log_raw_error() {
  { printf '=== round %s | %s | HTTP %s ===\n' "$RUN_ROUND" "$1" "$2"
    printf '%s\n\n' "$3"
  } >> "$ERRLOG"
}

# should_attempt TYPE ID -> 0 if this entity should be tried in this round.
#   Round 1 (RETRY_ACTIVE=0) attempts everything. A retry round attempts only
#   what the operator left marked as failed in the summary CSV.
should_attempt() {
  [[ "$RETRY_ACTIVE" -eq 0 ]] && return 0
  grep -qxF "$1	$2" "$RETRY_ONLY"
}

scope_qs() {
  case "$1" in
    account) echo "accountIdentifier=$ACC" ;;
    org:*)   echo "accountIdentifier=$ACC&orgIdentifier=${1#org:}" ;;
    */*)     echo "accountIdentifier=$ACC&orgIdentifier=${1%%/*}&projectIdentifier=${1##*/}" ;;
  esac
}
scope_of_dir() { # account -> account ; org-scope__X -> org:X ; org__proj -> org/proj
  local d="$1"
  [[ "$d" == account ]] && { echo account; return; }
  case "$d" in org-scope__*) echo "org:${d#org-scope__}"; return ;; esac
  echo "${d%%__*}/${d#*__}"
}
# split_org_proj SCOPE -> echoes "ORG PROJ" (PROJ empty for account/org-only scopes)
split_org_proj() {
  case "$1" in
    account) echo " " ;;
    org:*)   echo "${1#org:} " ;;
    */*)     echo "${1%%/*} ${1#*/}" ;;
    *)       echo " " ;;
  esac
}

# req METHOD URL CONTENTTYPE BODY LABEL
#   Performs the call (unless DRY), prints status, tallies pass/fail.
req() {
  local method="$1" url="$2" ctype="$3" body="$4" label="$5"
  if [[ "$DRY" == "1" ]]; then
    printf '    [dry] %s %s\n' "$method" "$label"; SKIP=$((SKIP+1))
    record_result "$label" skipped "" "dry run"
    return 0
  fi
  local hdr=(); [[ "$ctype" == yaml ]] && hdr=("${HY[@]}") || hdr=("${H[@]}")
  local tmp code; tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X "$method" "$url" "${hdr[@]}" --data-binary "$body")"
  local resp; resp="$(cat "$tmp")"; rm -f "$tmp"
  if [[ "$code" =~ ^2 ]]; then
    printf '    OK   %s (%s)\n' "$label" "$code"; PASS=$((PASS+1))
    record_result "$label" ok "$code" ""
    return 0
  fi
  # Error text for the console/CSV: prefer the structured .message, but fall
  # back to the raw body when there isn't one (some endpoints return a bare
  # string or an unexpected shape). No length cap — the whole point is that a
  # truncated error reads as a different, simpler problem than it actually is.
  # Newlines are collapsed to spaces ONLY here; ERRLOG keeps them verbatim.
  local msg
  msg="$(echo "$resp" | jq -r '.message // .responseMessages[0].message // empty' 2>/dev/null)"
  [[ -z "$msg" ]] && msg="$resp"
  msg="$(printf '%s' "$msg" | tr '\n\r\t' '   ')"
  log_raw_error "$label" "$code" "$resp"
  # Already-exists -> let caller try update by returning special code 9.
  # Print the actual response even here — this used to be silent, which
  # meant a real failure that merely happened to contain a matching phrase
  # (or a genuine conflict for a reason other than "the record exists")
  # was invisible; you'd only ever see the SECOND call's (the update
  # attempt's) error, which can be misleading about the real cause.
  #
  # No record_result here on purpose: a 9 always means the caller is about to
  # issue the update call, and THAT call records the entity's real outcome.
  # Recording both would leave two rows per entity for the CSV to reconcile.
  if echo "$resp" | grep -qiE 'already exists|duplicate|DUPLICATE_FIELD'; then
    printf '    (exists) %s (%s) %s -- trying update\n' "$label" "$code" "$msg"
    return 9
  fi
  printf '    FAIL %s (%s) %s\n' "$label" "$code" "$msg" >&2
  FAIL=$((FAIL+1)); FAILED+=("$label ($code)")
  record_result "$label" failed "$code" "$msg"
  return 1
}

# upsert_json BASEPATH SCOPE WRAPKEY FILE LABEL
#   POST to create; if it already exists, PUT to update. Body is the file's JSON,
#   optionally wrapped as {WRAPKEY: <json>}, with scope identifiers injected.
upsert_json() {
  local path="$1" sc="$2" wrap="$3" file="$4" label="$5"
  local qs; qs="$(scope_qs "$sc")"
  local org="" proj=""; read -r org proj <<< "$(split_org_proj "$sc")"
  local inner; inner="$(jq --arg a "$ACC" --arg o "$org" --arg p "$proj" \
    '. + {accountIdentifier:$a} + (if $o=="" then {} else {orgIdentifier:$o} + (if $p=="" then {} else {projectIdentifier:$p} end) end)' "$file")"
  local payload; if [[ -n "$wrap" ]]; then payload="$(jq -n --argjson v "$inner" "{\"$wrap\":\$v}")"; else payload="$inner"; fi

  req POST "$BASE/$path?$qs&routingId=$ACC" json "$payload" "$label"
  if [[ $? -eq 9 ]]; then req PUT "$BASE/$path?$qs&routingId=$ACC" json "$payload" "$label (update)"; fi
}

# upsert_json_pathid BASEPATH SCOPE WRAPKEY FILE LABEL IDENTIFIER
#   Like upsert_json, but the update (PUT) targets BASEPATH/IDENTIFIER — required
#   by endpoints such as service accounts that 500 on a base-path PUT.
upsert_json_pathid() {
  local path="$1" sc="$2" wrap="$3" file="$4" label="$5" id="$6"
  local qs; qs="$(scope_qs "$sc")"
  local org="" proj=""; read -r org proj <<< "$(split_org_proj "$sc")"
  local inner; inner="$(jq --arg a "$ACC" --arg o "$org" --arg p "$proj" \
    '. + {accountIdentifier:$a} + (if $o=="" then {} else {orgIdentifier:$o} + (if $p=="" then {} else {projectIdentifier:$p} end) end)' "$file")"
  local payload; if [[ -n "$wrap" ]]; then payload="$(jq -n --argjson v "$inner" "{\"$wrap\":\$v}")"; else payload="$inner"; fi

  req POST "$BASE/$path?$qs&routingId=$ACC" json "$payload" "$label"
  if [[ $? -eq 9 ]]; then req PUT "$BASE/$path/$id?$qs&routingId=$ACC" json "$payload" "$label (update)"; fi
}

# yaml_get FILE JSONPATH  -> extract a scalar from the entity YAML via yq
yaml_get() { yq -r "$2" "$1" 2>/dev/null; }

# rewrite_scope_yaml FILE ROOTKEY ORG PROJ
#   The exported YAML bodies for services/environments/infrastructures/pipelines
#   all embed their OWN top-level orgIdentifier/projectIdentifier fields. In
#   project mode (target org/project != source), that embedded value still
#   says the SOURCE scope even though the DTO wrapper / URL now say target —
#   and environmentsV2/infrastructures/pipelines all reject that mismatch with
#   a 400. Rewrite the embedded fields to the target scope before sending.
#
#   For pipelines specifically, also rewrite cross-pipeline "chained pipeline"
#   stage references: a `type: Pipeline` stage's spec is {org, project,
#   pipeline, inputs, ...} naming another pipeline by org/project/identifier.
#   That's validated at create time too, and turned out to be the actual
#   cause of "Invalid scope parameters" 400s (not the top-level fields alone)
#   — every pipeline that has one of these stages failed, every pipeline
#   without one imported fine even before this fix. The `has("pipeline") and
#   has("org") and has("project")` guard targets only that specific stage
#   shape so unrelated fields (e.g. a step's own "project"/"org"-named input)
#   are left untouched — verified against this export's real pipelines.
#
#   ORG=="" means account scope (nothing to rewrite); yq failure falls back to
#   the original file untouched rather than silently dropping content.
rewrite_scope_yaml() {
  local file="$1" root="$2" org="$3" proj="$4" out expr
  if [[ -z "$org" ]]; then cat "$file"; return; fi
  expr=".${root}.orgIdentifier = strenv(TARGET_ORG)"
  [[ -n "$proj" ]] && expr="$expr | .${root}.projectIdentifier = strenv(TARGET_PROJ)"
  if [[ "$root" == "pipeline" ]]; then
    expr="$expr | (.. | select(tag == \"!!map\" and has(\"pipeline\") and has(\"org\") and has(\"project\"))) |= (.org = strenv(TARGET_ORG) | .project = strenv(TARGET_PROJ))"
  fi
  out="$(TARGET_ORG="$org" TARGET_PROJ="$proj" yq "$expr" "$file" 2>/dev/null)"
  if [[ -z "$out" ]]; then cat "$file"; else printf '%s\n' "$out"; fi
}

# upsert_dto BASEPATH SCOPE ROOTKEY FILE LABEL [EXTRA_QS]
#   services/environments/infrastructures take a JSON DTO (application/json):
#   top-level identifier/name/scope fields + the full entity YAML as a string
#   `yaml` field. ROOTKEY is the YAML's top object (service|environment|
#   infrastructureDefinition). Environment additionally needs `type`.
upsert_dto() {
  local path="$1" sc="$2" root="$3" file="$4" label="$5" extra="${6:-}"
  local qs; qs="$(scope_qs "$sc")"
  local org="" proj=""; read -r org proj <<< "$(split_org_proj "$sc")"

  local id name etype yaml
  id="$(yaml_get "$file" ".${root}.identifier")"
  name="$(yaml_get "$file" ".${root}.name")"
  etype="$(yaml_get "$file" ".${root}.type")"   # only environments use this; null otherwise
  yaml="$(rewrite_scope_yaml "$file" "$root" "$org" "$proj")"

  # Build DTO. environmentsV2 wants `type`; services/infra ignore a null one.
  local dto
  dto="$(jq -n \
    --arg id "$id" --arg name "$name" --arg acct "$ACC" \
    --arg org "$org" --arg proj "$proj" --arg etype "$etype" \
    --arg yaml "$yaml" --arg root "$root" '
      {identifier:$id, name:$name, accountIdentifier:$acct, yaml:$yaml}
      + (if $org=="" then {} else {orgIdentifier:$org} + (if $proj=="" then {} else {projectIdentifier:$proj} end) end)
      + (if $root=="environment" and $etype!="null" and $etype!="" then {type:$etype} else {} end)
    ')"

  req POST "$BASE/$path?$qs$extra&routingId=$ACC" json "$dto" "$label"
  if [[ $? -eq 9 ]]; then req PUT "$BASE/$path?$qs$extra&routingId=$ACC" json "$dto" "$label (update)"; fi
}

# IACM headers (IACM routes need harness-account; reuse the same auth scheme).
HI=("${AUTH[@]}" -H "harness-account: $ACC" -H 'content-type: application/json' -H 'accept: */*')

# upsert_iacm_workspace ORG PROJ FILE
#   IACM workspaces are project-scoped, path-based, and need harness-account.
#   Strip server-managed/read-only fields, then POST (create) or PUT to /{id}.
upsert_iacm_workspace() {
  local org="$1" proj="$2" file="$3"
  local id label base body
  id="$(jq -r '.identifier' "$file")"
  label="iacm-workspace/$proj/$id"
  base="$BASE/iacm/api/orgs/$org/projects/$proj/workspaces"
  # Keep only writable config fields; account/org/project come from the path.
  # terraform_variables and environment_variables are REQUIRED by the create API
  # (must be present even when empty), so default them to {} rather than dropping.
  body="$(jq '({
      identifier, name, description, provisioner, provisioner_version,
      provider_connector, repository, repository_branch, repository_commit,
      repository_connector, repository_path, repository_submodules,
      cost_estimation_enabled, prune_sensitive_data, tags,
      terraform_variable_files, variable_sets, default_pipelines
    } | with_entries(select(.value != null)))
    + {terraform_variables: (.terraform_variables // {}),
       environment_variables: (.environment_variables // {})}' "$file")"

  if [[ "$DRY" == "1" ]]; then
    printf '    [dry] POST %s\n' "$label"; SKIP=$((SKIP+1))
    record_result "$label" skipped "" "dry run"; return 0
  fi
  local tmp code resp msg; tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$base?routingId=$ACC" "${HI[@]}" --data-binary "$body")"
  resp="$(cat "$tmp")"; rm -f "$tmp"
  if [[ "$code" =~ ^2 ]]; then
    printf '    OK   %s (%s)\n' "$label" "$code"; PASS=$((PASS+1))
    record_result "$label" ok "$code" ""; return 0
  fi
  log_raw_error "$label" "$code" "$resp"
  if echo "$resp" | grep -qiE 'already exists|duplicate|exists'; then
    msg="$(echo "$resp" | jq -r '.message // empty' 2>/dev/null)"; [[ -z "$msg" ]] && msg="$resp"
    printf '    (exists) %s (%s) %s -- trying update\n' "$label" "$code" "$(printf '%s' "$msg" | tr '\n\r\t' '   ')"
    tmp="$(mktemp)"
    code="$(curl -s -o "$tmp" -w '%{http_code}' -X PUT "$base/$id?routingId=$ACC" "${HI[@]}" --data-binary "$body")"
    resp="$(cat "$tmp")"; rm -f "$tmp"
    if [[ "$code" =~ ^2 ]]; then
      printf '    OK   %s (update %s)\n' "$label" "$code"; PASS=$((PASS+1))
      record_result "$label" ok "$code" ""; return 0
    fi
    log_raw_error "$label (update)" "$code" "$resp"
  fi
  msg="$(echo "$resp" | jq -r '.message // empty' 2>/dev/null)"; [[ -z "$msg" ]] && msg="$resp"
  msg="$(printf '%s' "$msg" | tr '\n\r\t' '   ')"
  printf '    FAIL %s (%s) %s\n' "$label" "$code" "$msg" >&2
  FAIL=$((FAIL+1)); FAILED+=("$label ($code)")
  record_result "$label" failed "$code" "$msg"
  return 1
}

# ---- summary CSV / retry plumbing ------------------------------------------
# csv_escape FIELD — same contract as restore-from-audit.sh's: quote only when
# the field contains a comma or a quote, doubling internal quotes. Error text
# has already had its newlines flattened by req(), so a cell can never span
# lines — which matters because the reader below is line-oriented and ONE
# multi-line cell would silently corrupt every row after it.
csv_escape() {
  local f="$1"
  if [[ "$f" == *,* || "$f" == *'"'* ]]; then
    f="${f//\"/\"\"}"
    printf '"%s"' "$f"
  else
    printf '%s' "$f"
  fi
}
csv_unquote() {
  local f="$1"
  if [[ "$f" == \"*\" && "$f" == *\" ]]; then
    f="${f#\"}"; f="${f%\"}"; f="${f//\"\"/\"}"
  fi
  printf '%s' "$f"
}
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# entity_remote_file TYPE ID SCDIR -> path to the entity's git "address card"
#   (.remote.json), or empty if it isn't a git-linked pipeline/template.
#   Templates are keyed identifier+versionLabel, and req() labels them
#   "template/<id>/<ver>", so the ID arriving here is "<id>/<ver>" and the
#   file on disk is "<id>__<ver>.remote.json".
entity_remote_file() {
  local t="$1" i="$2" d="$3" f=""
  case "$t" in
    pipeline) f="$IN/$d/pipelines/$i.remote.json" ;;
    template) f="$IN/$d/templates/${i%/*}__${i##*/}.remote.json" ;;
    *) return ;;
  esac
  [[ -e "$f" ]] && printf '%s' "$f"
}

# entity_webhook_file ID SCDIR -> path to the webhook's JSON, or empty
entity_webhook_file() {
  local f="$IN/$2/webhooks/$1.json"
  [[ -e "$f" ]] && printf '%s' "$f"
}

# classify_failure ERROR -> "<retryable:0|1>|<reason>"
#   Decides whether an operator editing Branch/GitFilePath/ConnectorRef could
#   plausibly fix this row. Anything we can't positively identify is treated
#   as RETRYABLE — a pointless retry round costs the operator one keypress,
#   whereas wrongly branding something NOT RETRYABLE hides a fixable problem.
classify_failure() {
  case "$1" in
    *"Unable to retrieve template with identifier"*)
      printf '0|NOT RETRYABLE - MISSING TEMPLATE DEPENDENCY' ;;
    *"requested file path"*|*"exists on the branch"*)
      printf '1|FILE NOT FOUND IN GIT - FIX Branch OR GitFilePath' ;;
    *"Error occurred while creating webhook"*)
      printf '1|WEBHOOK REJECTED - CHECK ConnectorRef RESOLVES AT THIS SCOPE' ;;
    *)
      printf '1|SEE Error COLUMN' ;;
  esac
}

SUMMARY_CSV=""

# write_summary_csv ROUND
#   Collapses RESULTS to the LAST record per type+id (a create that 400s then
#   succeeds on update is one entity with one final outcome, not two), then
#   emits the operator-facing CSV with failures sorted to the top.
#
#   CARRY_FORWARD holds rows from earlier rounds that are no longer attempted
#   — successes and NOT RETRYABLE alike. They are re-emitted verbatim every
#   round so the CSV stays a complete record of the whole restore: a row that
#   can never be fixed by editing must not quietly disappear from the file the
#   operator is treating as the source of truth.
write_summary_csv() {
  # NOTE: `local a="$1" b="...$a..."` does NOT work — bash expands every
  # argument of `local` before assigning any of them, so $a is still unset
  # (and fatal under `set -u`). Keep the dependent assignment on its own line.
  local round="$1"
  local out="$IN/summary-run${round}.csv"
  local rec t i v s c e d
  local remote wh branch gitpath connref repo localf reason retryable status
  SUMMARY_CSV="$out"
  {
    echo "Type,Identifier,Status,Reason,Branch,GitFilePath,ConnectorRef,Repo,LocalFile,Error"
    # failures first, then everything else — both groups stable-sorted by type+id
    jq -s -r '
      group_by(.type + "/" + .id) | map(.[-1])
      | sort_by(.type, .id)
      | (map(select(.status=="failed")) + map(select(.status!="failed")))
      | .[] | @base64' "$RESULTS" 2>/dev/null | while IFS= read -r rec; do
      [[ -z "$rec" ]] && continue
      rec="$(printf '%s' "$rec" | base64 --decode)"
      t="$(printf '%s' "$rec" | jq -r '.type')"
      i="$(printf '%s' "$rec" | jq -r '.id')"
      s="$(printf '%s' "$rec" | jq -r '.status')"
      e="$(printf '%s' "$rec" | jq -r '.error')"
      d="$(printf '%s' "$rec" | jq -r '.scdir')"
      branch=""; gitpath=""; connref=""; repo=""; localf=""; reason=""
      remote="$(entity_remote_file "$t" "$i" "$d")"
      if [[ -n "$remote" ]]; then
        branch="$(jq -r '.branch // ""' "$remote")"
        gitpath="$(jq -r '.filePath // ""' "$remote")"
        connref="$(jq -r '.connectorRef // ""' "$remote")"
        repo="$(jq -r '.repoName // ""' "$remote")"
        localf="${remote#"$IN"/}"
      elif [[ "$t" == webhook ]]; then
        wh="$(entity_webhook_file "$i" "$d")"
        if [[ -n "$wh" ]]; then
          connref="$(jq -r '.spec.connector_ref // ""' "$wh")"
          repo="$(jq -r '.spec.repo_name // ""' "$wh")"
          localf="${wh#"$IN"/}"
        fi
      fi
      case "$s" in
        ok)      status="yes"; reason="" ;;
        skipped) status="skipped"; reason="$e"; e="" ;;
        *)
          IFS='|' read -r retryable reason <<< "$(classify_failure "$e")"
          if [[ "$retryable" == "0" ]]; then status="NOT RETRYABLE"; else status="failed"; fi
          ;;
      esac
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$t")" "$(csv_escape "$i")" "$(csv_escape "$status")" \
        "$(csv_escape "$reason")" "$(csv_escape "$branch")" "$(csv_escape "$gitpath")" \
        "$(csv_escape "$connref")" "$(csv_escape "$repo")" "$(csv_escape "$localf")" \
        "$(csv_escape "$e")"
    done
    [[ -s "$CARRY_FORWARD" ]] && cat "$CARRY_FORWARD"
  } > "$out"
}

# json_set_field FILE [jq args...] EXPR -> rewrite FILE in place via a temp
#   (jq can't safely read and write the same file). Leaves the original
#   untouched if jq fails or produces nothing, rather than truncating it.
json_set_field() {
  local f="$1"; shift
  local tmp; tmp="$(mktemp)"
  if jq "$@" "$f" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    cat "$tmp" > "$f"
  fi
  rm -f "$tmp"
}

# read_summary_csv CSVFILE
#   Reads the operator's edits back and does three things per row:
#     1. rows still marked `failed` -> added to the retry allowlist
#     2. their Branch / GitFilePath / ConnectorRef -> written into the backing
#        address-card / webhook file, which is what import actually reads
#     3. everything else (yes / NOT RETRYABLE / skipped) -> copied verbatim
#        into CARRY_FORWARD so the next round's CSV still lists it
#   Sets PATCHED and RETRY_COUNT. Returns 1 if the file is unreadable.
PATCHED=0; RETRY_COUNT=0
read_summary_csv() {
  local csv="$1" row=0 c1 c2 c3 c4 c5 c6 c7 c8 c9 _rest
  local t i status branch gitpath connref localf f
  [[ -r "$csv" ]] || { echo "  can't read $csv" >&2; return 1; }
  : > "$RETRY_ONLY"; : > "$CARRY_FORWARD"
  PATCHED=0; RETRY_COUNT=0
  # Same trailing-newline guard as restore-from-audit.sh: `read` returns
  # non-zero on a final unterminated line, which would drop the last row.
  while IFS=, read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 _rest; do
    row=$((row+1))
    [[ "$row" -eq 1 ]] && continue
    [[ -z "$c1" && -z "$c2" ]] && continue
    t="$(csv_unquote "$c1")"; i="$(csv_unquote "$c2")"
    status="$(printf '%s' "$(trim "$(csv_unquote "$c3")")" | tr '[:upper:]' '[:lower:]')"
    if [[ "$status" != "failed" ]]; then
      # Not being retried — preserve the row exactly as it stands.
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$_rest" >> "$CARRY_FORWARD"
      continue
    fi
    branch="$(trim "$(csv_unquote "$c5")")"; gitpath="$(trim "$(csv_unquote "$c6")")"
    connref="$(trim "$(csv_unquote "$c7")")"; localf="$(trim "$(csv_unquote "$c9")")"
    printf '%s\t%s\n' "$t" "$i" >> "$RETRY_ONLY"
    RETRY_COUNT=$((RETRY_COUNT+1))
    # Write the operator's values into the file import actually reads. Without
    # this the whole loop is theatre: import re-reads the address card, not
    # the CSV, so a corrected branch would never reach the API call.
    [[ -z "$localf" ]] && continue
    f="$IN/$localf"
    [[ -e "$f" ]] || { echo "    WARN $t/$i: LocalFile '$localf' not found — edits to this row can't be applied" >&2; continue; }
    case "$f" in
      *.remote.json)
        [[ -n "$branch" ]]  && json_set_field "$f" --arg v "$branch"  '.branch   = $v'
        [[ -n "$gitpath" ]] && json_set_field "$f" --arg v "$gitpath" '.filePath = $v'
        [[ -n "$connref" ]] && json_set_field "$f" --arg v "$connref" '.connectorRef = $v'
        PATCHED=$((PATCHED+1))
        ;;
      */webhooks/*.json)
        [[ -n "$connref" ]] && { json_set_field "$f" --arg v "$connref" '.spec.connector_ref = $v'; PATCHED=$((PATCHED+1)); }
        ;;
    esac
  done < <(cat "$csv"; echo)
  return 0
}

# ---- FORCE: convert unreachable git-linked entities to inline --------------
# A git-linked pipeline/template whose file can't be found in git can still be
# recreated from the content the restore captured at delete time: every
# address card carries a `yaml` field with that last-known content, which the
# git-import path never uses (it tells Harness to read the file from the repo
# instead). Converting means writing that YAML out as a normal inline entity
# and retiring the address card.
#
# This is a REAL CHANGE to how the entity is managed — it stops being
# git-backed — which is why it's opt-in per row and recorded in a CSV the
# operator keeps. Two things make a row unconvertible, and both are reported
# rather than silently skipped:
#   - no recovered content (the delete event carried no oldYaml)
#   - the content references a template that failed to import this run, so an
#     inline create would just fail again with the same template error
FORCE_CSV=""

# missing_template_ids -> template identifiers that failed this round with
#   "Unable to retrieve template with identifier [X]". Used to pre-flag rows
#   whose recovered YAML would hit the same wall.
missing_template_ids() {
  jq -r 'select(.status=="failed") | .error' "$RESULTS" 2>/dev/null \
    | grep -oE 'Unable to retrieve template with identifier \[[^]]*' \
    | sed -E 's/.*\[//' | sort -u
}

# write_force_csv -> builds force-inline-review.csv from the still-failing,
#   git-linked rows. Returns 1 if there's nothing eligible.
write_force_csv() {
  local out="$IN/force-inline-review.csv" rec t i d remote ylen reason n=0
  local missing; missing="$(missing_template_ids)"
  FORCE_CSV="$out"
  {
    echo "Type,Identifier,ConvertToInline,Reason,Repo,Branch,GitFilePath,LocalFile"
    while IFS= read -r rec; do
      [[ -z "$rec" ]] && continue
      rec="$(printf '%s' "$rec" | base64 --decode)"
      t="$(printf '%s' "$rec" | jq -r '.type')"
      i="$(printf '%s' "$rec" | jq -r '.id')"
      d="$(printf '%s' "$rec" | jq -r '.scdir')"
      remote="$(entity_remote_file "$t" "$i" "$d")"
      [[ -z "$remote" ]] && continue     # not git-linked; inline conversion is meaningless
      ylen="$(jq -r '(.yaml // "") | length' "$remote" 2>/dev/null)"
      reason="FILE NOT FOUND IN GIT"
      if [[ "${ylen:-0}" -eq 0 ]]; then
        reason="CANNOT CONVERT - NO RECOVERED CONTENT"
      elif [[ -n "$missing" ]]; then
        while IFS= read -r mt; do
          [[ -z "$mt" ]] && continue
          if jq -r '.yaml // ""' "$remote" 2>/dev/null | grep -qF "$mt"; then
            reason="CANNOT CONVERT - REFERENCES MISSING TEMPLATE $mt"; break
          fi
        done <<< "$missing"
      fi
      n=$((n+1))
      printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$t")" "$(csv_escape "$i")" "" "$(csv_escape "$reason")" \
        "$(csv_escape "$(jq -r '.repoName // ""' "$remote")")" \
        "$(csv_escape "$(jq -r '.branch // ""' "$remote")")" \
        "$(csv_escape "$(jq -r '.filePath // ""' "$remote")")" \
        "$(csv_escape "${remote#"$IN"/}")"
    done < <(jq -s -r 'group_by(.type + "/" + .id) | map(.[-1])
                       | map(select(.status=="failed")) | sort_by(.type, .id) | .[] | @base64' "$RESULTS" 2>/dev/null)
  } > "$out"
  [[ "$n" -gt 0 ]] || { rm -f "$out"; return 1; }
  FORCE_ELIGIBLE="$n"
  return 0
}

# apply_force_csv -> reads the marked CSV, converts approved rows to inline,
#   and loads RETRY_ONLY with exactly those rows so the next round imports
#   them. Sets FORCE_DONE / FORCE_BLOCKED.
FORCE_ELIGIBLE=0; FORCE_DONE=0; FORCE_BLOCKED=0
apply_force_csv() {
  local row=0 c1 c2 c3 c4 c5 c6 c7 c8 _rest t i mark localf f yaml target mt blocker
  local missing; missing="$(missing_template_ids)"
  FORCE_DONE=0; FORCE_BLOCKED=0
  : > "$RETRY_ONLY"
  while IFS=, read -r c1 c2 c3 c4 c5 c6 c7 c8 _rest; do
    row=$((row+1))
    [[ "$row" -eq 1 ]] && continue
    [[ -z "$c1" && -z "$c2" ]] && continue
    mark="$(printf '%s' "$(trim "$(csv_unquote "$c3")")" | tr '[:upper:]' '[:lower:]')"
    case "$mark" in yes|y) : ;; *) continue ;; esac
    t="$(csv_unquote "$c1")"; i="$(csv_unquote "$c2")"; localf="$(trim "$(csv_unquote "$c8")")"
    f="$IN/$localf"
    if [[ -z "$localf" || ! -e "$f" ]]; then
      echo "    SKIP $t/$i (force) — address card '$localf' not found"; FORCE_BLOCKED=$((FORCE_BLOCKED+1)); continue
    fi
    yaml="$(jq -r '.yaml // ""' "$f" 2>/dev/null)"
    if [[ -z "$yaml" ]]; then
      echo "    SKIP $t/$i (force) — no recovered content to build an inline entity from"; FORCE_BLOCKED=$((FORCE_BLOCKED+1)); continue
    fi
    # Re-derive the blocking conditions here instead of trusting the CSV's
    # Reason column: that column is script-written and advisory, and an
    # operator who marks every row Yes (or edits/clears Reason) must still not
    # be able to force through a conversion that is certain to fail. Writing
    # an inline entity that references a template which just failed to import
    # would only swap "file not found in git" for the identical template
    # error on the very next round — a silent no-progress loop.
    blocker=""
    if [[ -n "$missing" ]]; then
      while IFS= read -r mt; do
        [[ -z "$mt" ]] && continue
        if printf '%s' "$yaml" | grep -qF "$mt"; then blocker="$mt"; break; fi
      done <<< "$missing"
    fi
    if [[ -n "$blocker" ]]; then
      echo "    SKIP $t/$i (force) — recovered content references template '$blocker', which failed to import this run."
      echo "         Restore that template first; converting now would fail again with the same error."
      FORCE_BLOCKED=$((FORCE_BLOCKED+1)); continue
    fi
    # Inline filename mirrors what a normal (non-git) restore would have
    # written, so the existing import loops pick it up with no special casing:
    # pipelines/<id>.yaml, templates/<id>__<ver>.yaml.
    target="${f%.remote.json}.yaml"
    printf '%s\n' "$yaml" > "$target"
    rm -f "$f"
    printf '%s\t%s\n' "$t" "$i" >> "$RETRY_ONLY"
    echo "    FORCED $t/$i -> inline (${target#"$IN"/}), git link retired"
    FORCE_DONE=$((FORCE_DONE+1))
  done < <(cat "$FORCE_CSV"; echo)
}

echo "=== Importing $IN -> account $ACC @ $BASE  (DRY_RUN=$DRY) ==="

# ---- 0. discover which scope directories this export actually produced -----
# (dynamic — works for any org/project names, not just the original migration's)
# Three possible shapes: "account", "org-scope__<org>" (org-only — holds
# account-/org-scoped dependencies a project-mode export pulled in because the
# project's own resources referenced them), and "<org>__<project>".
SCDIRS=()
[[ -d "$IN/account" ]] && SCDIRS+=(account)
while IFS= read -r d; do
  SCDIRS+=("$(basename "$d")")
done < <(find "$IN" -mindepth 1 -maxdepth 1 -type d -name '*__*' | sort)

# Bash 3.2 (the shipped /bin/bash on macOS) throws "unbound variable" under
# `set -u` for "${ARR[@]}" (and "${ARR[*]}") on a genuinely EMPTY array —
# fixed in bash 4.4+, but this repo targets 3.2. Every expansion below is
# guarded by a length check first; don't remove those guards.
if [[ "${#SCDIRS[@]}" -eq 0 ]]; then
  echo "no scope directories found under '$IN' — nothing to import (wrong IN_DIR, or an empty export?)" >&2
  exit 1
fi

if [[ "$PROJECT_MODE" -eq 1 ]]; then
  PROJDIRS=(); OTHERDIRS=()
  for d in "${SCDIRS[@]}"; do
    case "$d" in
      account|org-scope__*) OTHERDIRS+=("$d") ;;
      *) PROJDIRS+=("$d") ;;
    esac
  done
  if [[ "${#PROJDIRS[@]}" -ne 1 ]]; then
    proj_list="none"; [[ "${#PROJDIRS[@]}" -gt 0 ]] && proj_list="${PROJDIRS[*]}"
    echo "TGT_ORG/TGT_PROJECT set but '$IN' contains ${#PROJDIRS[@]} project scope(s) ($proj_list) — project-mode import expects exactly one (re-export with SRC_ORG/SRC_PROJECT set)" >&2
    exit 1
  fi
  if [[ "${#OTHERDIRS[@]}" -gt 0 ]]; then
    SCDIRS=("${OTHERDIRS[@]}" "${PROJDIRS[@]}")
    echo "project mode: ${PROJDIRS[0]} -> $TGT_ORG/$TGT_PROJECT (plus referenced account-/org-scope dependencies: ${OTHERDIRS[*]})"
  else
    SCDIRS=("${PROJDIRS[@]}")
    echo "project mode: ${PROJDIRS[0]} -> $TGT_ORG/$TGT_PROJECT"
  fi
fi
echo "Scope dirs: ${SCDIRS[*]}"

# ---- one full import pass ---------------------------------------------------
# Wrapped in a function so the retry loop at the bottom can run it again after
# the operator corrects branches/paths/connectors. Deliberately NOT re-indented
# — keeping the body byte-identical to the single-pass version it replaces
# makes the diff reviewable; the only functional additions inside are the
# `should_attempt` guards and the record_result calls on the two SKIP paths
# that bypass req().
run_import_pass() {

# ---- 1. projects (org 'default' assumed to exist) --------------------------
echo "== projects =="
if [[ -f "$IN/scope.json" ]]; then
  jq -c '.projects[]' "$IN/scope.json" | while read -r p; do
    src_pid=$(echo "$p" | jq -r '.identifier'); src_org=$(echo "$p" | jq -r '.orgIdentifier')
    if [[ "$PROJECT_MODE" -eq 1 ]]; then
      org="$TGT_ORG"; pid="$TGT_PROJECT"
      name="${TGT_PROJECT_NAME:-$(echo "$p" | jq -r '.name')}"
      payload=$(echo "$p" | jq --arg a "$ACC" --arg org "$org" --arg pid "$pid" --arg name "$name" \
        '(. + {accountIdentifier:$a, orgIdentifier:$org, identifier:$pid, name:$name}) | {project: .}')
    else
      org="$src_org"; pid="$src_pid"
      payload=$(echo "$p" | jq --arg a "$ACC" '{project: (. + {accountIdentifier:$a})}')
    fi
    should_attempt "project" "$org/$pid" || continue
    req POST "$BASE/ng/api/projects?accountIdentifier=$ACC&orgIdentifier=$org&routingId=$ACC" json "$payload" "project/$org/$pid"
    [[ $? -eq 9 ]] && req PUT "$BASE/ng/api/projects/$pid?accountIdentifier=$ACC&orgIdentifier=$org&routingId=$ACC" json "$payload" "project/$org/$pid (update)"
  done
fi

# ---- per-scope entities ----------------------------------------------------
for SCDIR in "${SCDIRS[@]}"; do
  SRC_SC="$(scope_of_dir "$SCDIR")"
  if [[ "$PROJECT_MODE" -eq 1 ]]; then
    case "$SRC_SC" in
      account) SC="account" ;;
      org:*)   SC="org:$TGT_ORG" ;;
      *)       SC="$TGT_ORG/$TGT_PROJECT" ;;
    esac
  else
    SC="$SRC_SC"
  fi
  echo "== scope: $SRC_SC -> $SC =="

  # templates (raw YAML, root key "template") — created before connectors,
  # since a connector (e.g. a template-based CustomSecretManager) can
  # reference one. A template's identity is identifier+versionLabel; the
  # update endpoint can't change versionLabel, so re-running with the same
  # exported version just updates that version's content.
  for f in "$IN/$SCDIR"/templates/*.yaml; do [[ -e "$f" ]] || continue
    torg="" tproj=""; read -r torg tproj <<< "$(split_org_proj "$SC")"
    tqs="$(scope_qs "$SC")"
    tid="$(yaml_get "$f" ".template.identifier")"
    tver="$(yaml_get "$f" ".template.versionLabel")"
    [[ -z "$tid" || "$tid" == "null" ]] && continue
    should_attempt "template" "$tid/$tver" || continue
    tbody="$(rewrite_scope_yaml "$f" "template" "$torg" "$tproj")"
    req POST "$BASE/template/api/templates?$tqs&routingId=$ACC" yaml "$tbody" "template/$tid/$tver"
    [[ $? -eq 9 ]] && req PUT "$BASE/template/api/templates/update/$tid/$tver?$tqs&routingId=$ACC" yaml "$tbody" "template/$tid/$tver (update)"
  done

  # git-linked templates (audit-trail restore only — a sidecar written by
  # restore-from-audit.sh when a deleted template's MOVE_TO_GIT history was
  # found, instead of a normal .yaml file). Mirrors the pipeline case above,
  # which is CONFIRMED via a real HAR capture of Harness's "Import From Git"
  # UI action (a genuinely separate endpoint from create — see the pipeline
  # comment for the full trail of why storeType=REMOTE-on-create was wrong).
  # The template's own import endpoint/body shape is EXTRAPOLATED from that
  # confirmed pipeline shape (same param names, parallel /template/api path)
  # — not independently verified. If this fails, check the response text
  # for the actual expected shape before assuming the pipeline pattern
  # applies exactly.
  for f in "$IN/$SCDIR"/templates/*.remote.json; do [[ -e "$f" ]] || continue
    tqs="$(scope_qs "$SC")"
    base="$(basename "$f" .remote.json)"; tid="${base%__*}"; tver="${base##*__}"
    should_attempt "template" "$tid/$tver" || continue
    connectorRef="$(jq -r '.connectorRef' "$f")"; repoName="$(jq -r '.repoName' "$f")"
    filePath="$(jq -r '.filePath' "$f")"; branch="$(jq -r '.branch // ""' "$f")"
    importqs="connectorRef=$connectorRef&isHarnessCodeRepo=false&repoName=$repoName&branch=$branch&filePath=$filePath"
    req POST "$BASE/template/api/templates/import?$tqs&$importqs&routingId=$ACC" json '{"templateDescription":""}' "template/$tid/$tver (git-import)"
    if [[ $? -eq 9 ]]; then
      echo "    SKIP template/$tid/$tver (git-import) (already exists in target — this script doesn't re-import an already-imported git-linked template; delete it in target first if you need to re-run)"
      SKIP=$((SKIP+1))
      record_result "template/$tid/$tver (git-import)" skipped "" "already imported from git in target"
    fi
  done

  # connectors (JSON, wrap "connector") — skip Harness built-ins
  for f in "$IN/$SCDIR"/connectors/*.json; do [[ -e "$f" ]] || continue
    cid="$(basename "$f" .json)"
    if is_builtin "$cid"; then echo "    skip connector/$cid (Harness built-in)"; SKIP=$((SKIP+1)); continue; fi
    should_attempt "connector" "$cid" || continue
    upsert_json "ng/api/connectors" "$SC" "connector" "$f" "connector/$cid"; done

  # service accounts (JSON, no wrap; update PUTs to /serviceaccount/{id})
  for f in "$IN/$SCDIR"/serviceaccounts/*.json; do [[ -e "$f" ]] || continue
    said="$(basename "$f" .json)"
    should_attempt "serviceaccount" "$said" || continue
    upsert_json_pathid "ng/api/serviceaccount" "$SC" "" "$f" "serviceaccount/$said" "$said"; done

  # user groups (JSON, no wrap) — blank users[] (principals not replicated)
  for f in "$IN/$SCDIR"/usergroups/*.json; do [[ -e "$f" ]] || continue
    should_attempt "usergroup" "$(basename "$f" .json)" || continue
    tmp="$(mktemp)"; jq '.users = []' "$f" > "$tmp"
    upsert_json "ng/api/user-groups" "$SC" "" "$tmp" "usergroup/$(basename "$f" .json)"; rm -f "$tmp"; done

  # services (JSON DTO: identifier/name/scope + yaml string)
  for f in "$IN/$SCDIR"/services/*.yaml; do [[ -e "$f" ]] || continue
    should_attempt "service" "$(basename "$f" .yaml)" || continue
    upsert_dto "ng/api/servicesV2" "$SC" "service" "$f" "service/$(basename "$f" .yaml)"; done

  # environments (JSON DTO: + type)
  for f in "$IN/$SCDIR"/environments/*.yaml; do [[ -e "$f" ]] || continue
    should_attempt "environment" "$(basename "$f" .yaml)" || continue
    upsert_dto "ng/api/environmentsV2" "$SC" "environment" "$f" "environment/$(basename "$f" .yaml)"; done

  # infrastructures (JSON DTO + environmentIdentifier query param from <env>.infra)
  for d in "$IN/$SCDIR"/environments/*.infra; do [[ -d "$d" ]] || continue
    env="$(basename "$d" .infra)"
    for f in "$d"/*.yaml; do [[ -e "$f" ]] || continue
      should_attempt "infra" "$env/$(basename "$f" .yaml)" || continue
      upsert_dto "ng/api/infrastructures" "$SC" "infrastructureDefinition" "$f" "infra/$env/$(basename "$f" .yaml)" "&environmentIdentifier=$env"
    done
  done

  # pipelines (YAML) — v2 create endpoint consumes raw pipeline YAML. Pipeline
  # YAML also embeds its own top-level orgIdentifier/projectIdentifier (same
  # issue as environments/infra above) — rewrite before sending.
  for f in "$IN/$SCDIR"/pipelines/*.yaml; do [[ -e "$f" ]] || continue
    case "$SC" in
      */*) porg="${SC%%/*}"; pproj="${SC#*/}"; qs="$(scope_qs "$SC")" ;;
      *) echo "    SKIP pipeline (account-scope pipelines unsupported)"; SKIP=$((SKIP+1)); continue ;;
    esac
    pid="$(basename "$f" .yaml)"
    should_attempt "pipeline" "$pid" || continue
    body="$(rewrite_scope_yaml "$f" "pipeline" "$porg" "$pproj")"
    req POST "$BASE/pipeline/api/pipelines/v2?$qs&routingId=$ACC" yaml "$body" "pipeline/$pid"
    [[ $? -eq 9 ]] && req PUT "$BASE/pipeline/api/pipelines/v2/$pid?$qs&routingId=$ACC" yaml "$body" "pipeline/$pid (update)"
  done

  # git-linked pipelines (audit-trail restore only — a sidecar written by
  # restore-from-audit.sh when a deleted pipeline's MOVE_TO_GIT history was
  # found, instead of a normal .yaml file). CONFIRMED via a real HAR capture
  # of Harness's own "Import From Git" UI action — this is a genuinely
  # separate endpoint from pipeline creation, not a variant of it (three
  # earlier attempts at storeType=REMOTE on the v2 create endpoint all
  # failed for exactly that reason — see git history/README for the trail).
  # POST /pipeline/api/pipelines/import, body is just {"pipelineDescription":
  # ""} — no YAML, no identifier, no stages. Harness reads the pipeline
  # straight from the file at that path; nothing from the sidecar's "yaml"
  # field (last-known content, kept for reference/debugging) is needed here.
  for f in "$IN/$SCDIR"/pipelines/*.remote.json; do [[ -e "$f" ]] || continue
    case "$SC" in
      */*) qs="$(scope_qs "$SC")" ;;
      *) echo "    SKIP git-linked pipeline (account-scope pipelines unsupported)"; SKIP=$((SKIP+1)); continue ;;
    esac
    pid="$(basename "$f" .remote.json)"
    should_attempt "pipeline" "$pid" || continue
    connectorRef="$(jq -r '.connectorRef' "$f")"; repoName="$(jq -r '.repoName' "$f")"
    filePath="$(jq -r '.filePath' "$f")"; branch="$(jq -r '.branch // ""' "$f")"
    importqs="connectorRef=$connectorRef&isHarnessCodeRepo=false&repoName=$repoName&branch=$branch&filePath=$filePath"
    req POST "$BASE/pipeline/api/pipelines/import?$qs&$importqs&routingId=$ACC" json '{"pipelineDescription":""}' "pipeline/$pid (git-import)"
    if [[ $? -eq 9 ]]; then
      echo "    SKIP pipeline/$pid (git-import) (already exists in target — this script doesn't re-import an already-imported git-linked pipeline; delete it in target first if you need to re-run)"
      SKIP=$((SKIP+1))
      record_result "pipeline/$pid (git-import)" skipped "" "already imported from git in target"
    fi
  done

  # triggers (YAML, root key "trigger") — CONFIRMED via a real HAR capture of
  # Harness's own "New Trigger" UI action: POST /pipeline/api/triggers with
  # accountIdentifier/orgIdentifier/projectIdentifier/targetIdentifier query
  # params (targetIdentifier = the trigger's pipeline) and the raw trigger
  # YAML as an application/yaml body. If the target pipeline is itself
  # git-linked (has a sidecar .remote.json — see the pipeline git-import
  # block above), the same capture showed the create call also carrying
  # branch/connectorRef/repoName/storeType=REMOTE query params, so mirror
  # that when present. No confirmed capture of the trigger UPDATE call
  # exists yet — the PUT /pipeline/api/triggers/{id} path below follows this
  # codebase's usual create-then-update convention, not an independent
  # verification; if it 400s, capture that call before trusting it further.
  for f in "$IN/$SCDIR"/triggers/*.yaml; do [[ -e "$f" ]] || continue
    case "$SC" in
      */*) torg="${SC%%/*}"; tproj="${SC#*/}"; qs="$(scope_qs "$SC")" ;;
      *) echo "    SKIP trigger (account-scope triggers unsupported)"; SKIP=$((SKIP+1)); continue ;;
    esac
    tid="$(basename "$f" .yaml)"
    should_attempt "trigger" "$tid" || continue
    pid="$(yaml_get "$f" ".trigger.pipelineIdentifier")"
    if [[ -z "$pid" || "$pid" == "null" ]]; then
      echo "    SKIP trigger/$tid (couldn't determine target pipelineIdentifier)"; SKIP=$((SKIP+1))
      record_result "trigger/$tid" skipped "" "couldn't determine target pipelineIdentifier"
      continue
    fi
    body="$(rewrite_scope_yaml "$f" "trigger" "$torg" "$tproj")"
    gitqs=""
    remf="$IN/$SCDIR/pipelines/$pid.remote.json"
    if [[ -e "$remf" ]]; then
      gconnectorRef="$(jq -r '.connectorRef' "$remf")"; grepoName="$(jq -r '.repoName' "$remf")"
      gbranch="$(jq -r '.branch // ""' "$remf")"
      gitqs="&branch=$gbranch&connectorRef=$gconnectorRef&repoName=$grepoName&storeType=REMOTE"
    fi
    req POST "$BASE/pipeline/api/triggers?$qs&targetIdentifier=$pid&ignoreError=false$gitqs&routingId=$ACC" yaml "$body" "trigger/$tid"
    [[ $? -eq 9 ]] && req PUT "$BASE/pipeline/api/triggers/$tid?$qs&targetIdentifier=$pid&ignoreError=false$gitqs&routingId=$ACC" yaml "$body" "trigger/$tid (update)"
  done

  # GitX webhooks (JSON, no wrap) — CONFIRMED via a real HAR capture of
  # Harness's own "New Webhook" UI action (Project Settings -> Webhooks):
  # POST /v1/orgs/{org}/projects/{project}/webhooks, body {webhook_identifier,
  # webhook_name, spec:{webhook_type, connector_ref, repo_name,
  # folder_paths}}. This is a genuinely different, listable REST API (GET-
  # style /v1/... paths) from the pipeline/template git-import endpoints
  # above — not the same "system side effect" webhook that gets silently
  # recreated when a pipeline reconnects to git; a manually-created one only
  # comes back if explicitly restored here. The UPDATE call (PUT to this
  # same base path + /{id}) was NOT captured — this follows the codebase's
  # usual create-then-update convention, unverified; if it 400s, capture
  # that call before trusting it further.
  for f in "$IN/$SCDIR"/webhooks/*.json; do [[ -e "$f" ]] || continue
    wid="$(basename "$f" .json)"
    should_attempt "webhook" "$wid" || continue
    case "$SC" in
      */*) worg="${SC%%/*}"; wproj="${SC#*/}" ;;
      *) echo "    SKIP webhook/$wid (account-scope webhooks unsupported)"; SKIP=$((SKIP+1)); continue ;;
    esac
    wbase="$BASE/v1/orgs/$worg/projects/$wproj/webhooks"
    req POST "$wbase?routingId=$ACC" json "$(cat "$f")" "webhook/$wid"
    [[ $? -eq 9 ]] && req PUT "$wbase/$wid?routingId=$ACC" json "$(cat "$f")" "webhook/$wid (update)"
  done

  # IACM workspaces (project scope only; after connectors/pipelines they reference)
  case "$SC" in
    */*) org="${SC%%/*}"; proj="${SC#*/}"
      for f in "$IN/$SCDIR"/iacm-workspaces/*.json; do [[ -e "$f" ]] || continue
        should_attempt "iacm-workspace" "$proj/$(jq -r '.identifier' "$f")" || continue
        upsert_iacm_workspace "$org" "$proj" "$f"; done ;;
  esac
done

}  # end run_import_pass

# ---- import, then loop on failures until resolved or abandoned -------------
# Rather than exiting on failure, each round writes summary-run<N>.csv listing
# every entity with its status and FULL error, then hands control back to the
# operator. They can correct Branch / GitFilePath / ConnectorRef in that same
# file and retry (only the rows still marked `failed` are re-attempted), FORCE
# unreachable git-linked entities to inline, or stop.
while :; do
  : > "$RESULTS"
  if [[ "$RETRY_ACTIVE" -eq 1 ]]; then
    echo
    echo "=== Retry round $RUN_ROUND — re-attempting $RETRY_COUNT entit$([[ "$RETRY_COUNT" == 1 ]] && echo y || echo ies) ==="
  fi
  PASS=0; FAIL=0; SKIP=0; FAILED=()

  run_import_pass

  echo
  echo "=== Summary: $PASS ok, $FAIL failed, $SKIP skipped ==="
  if [[ ${#FAILED[@]} -gt 0 ]]; then printf '  - %s\n' "${FAILED[@]}"; fi

  write_summary_csv "$RUN_ROUND"
  echo "Review file: $SUMMARY_CSV"
  [[ -s "$ERRLOG" ]] && echo "Full untruncated API responses for every failure: $ERRLOG"

  # Nothing left to act on — note that FAIL counts only THIS round, so a
  # carried-forward NOT RETRYABLE row doesn't keep the loop spinning forever.
  if [[ "$FAIL" -eq 0 ]]; then
    echo "No failures in this round — nothing left to retry."
    break
  fi

  echo
  echo "Failed rows are listed first in $SUMMARY_CSV, with the full error in the Error column."
  echo "  - To RETRY: open it, fix Branch / GitFilePath / ConnectorRef on the rows marked 'failed'"
  echo "    (check the repo yourself to confirm which branch actually holds the YAML), save as CSV"
  echo "    at the same path, then press Enter. Only rows still marked 'failed' are re-attempted;"
  echo "    set Status to 'no' on anything you want left alone."
  echo "  - Rows marked NOT RETRYABLE cannot be fixed by editing this file (e.g. a missing org-level"
  echo "    template). They are kept in every round's CSV for the record, but never re-attempted."
  echo "  - To FORCE: type FORCE to convert unreachable git-linked pipelines/templates into inline"
  echo "    entities built from the content captured at delete time. They will STOP being git-backed."
  echo "  - To STOP: type terminate."
  echo

  while :; do
    read -r -p "[Enter] retry · [FORCE] convert to inline · [terminate] stop: " _reply
    case "$(printf '%s' "$_reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
      terminate|abort|quit)
        echo "Stopping at operator request. $SUMMARY_CSV holds the current state."
        break 2
        ;;
      force)
        if ! write_force_csv; then
          echo "  Nothing eligible to force — no failing entity is git-linked." ; continue
        fi
        echo
        echo "  $FORCE_ELIGIBLE git-linked entit$([[ "$FORCE_ELIGIBLE" == 1 ]] && echo y || echo ies) can be offered for inline conversion."
        echo "  Wrote $FORCE_CSV"
        echo "  Mark ConvertToInline=Yes on each row you want converted (blank = leave it alone)."
        echo "  Check the Reason column first — rows reading 'CANNOT CONVERT' will be skipped even if marked Yes."
        echo "  Converted entities STOP being git-backed; re-link them in Harness afterwards if you want them in git again."
        read -r -p "  Press Enter once you've saved $FORCE_CSV (or type cancel): " _freply
        case "$(printf '%s' "$_freply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
          cancel|c) echo "  Force cancelled."; continue ;;
        esac
        apply_force_csv
        if [[ "$FORCE_DONE" -eq 0 ]]; then
          echo "  Nothing converted ($FORCE_BLOCKED row(s) blocked, 0 marked Yes). Back to the prompt."
          continue
        fi
        echo "  Converted $FORCE_DONE to inline; $FORCE_BLOCKED blocked."
        echo "  $FORCE_CSV is your record of what changed — keep it."
        # RETRY_ONLY was loaded by apply_force_csv with exactly the converted
        # rows. Rebuild carry-forward from the current CSV so unconverted and
        # already-succeeded rows still appear in the next summary.
        awk -F, 'NR>1' "$SUMMARY_CSV" > "$CARRY_FORWARD"
        RETRY_COUNT="$FORCE_DONE"; RETRY_ACTIVE=1; RUN_ROUND=$((RUN_ROUND+1))
        break
        ;;
      "")
        if ! read_summary_csv "$SUMMARY_CSV"; then continue; fi
        if [[ "$RETRY_COUNT" -eq 0 ]]; then
          echo "  No rows left marked 'failed' in $SUMMARY_CSV — nothing to retry."
          echo "  Mark a row's Status back to 'failed' to re-attempt it, or type terminate."
          continue
        fi
        echo "  $RETRY_COUNT row(s) to retry; applied edits to $PATCHED backing file(s)."
        RETRY_ACTIVE=1; RUN_ROUND=$((RUN_ROUND+1))
        break
        ;;
      *)
        echo "  Didn't understand that. Press Enter to retry, or type FORCE / terminate."
        ;;
    esac
  done
done

echo
echo "Reminder: recreate secrets first (see $IN/secrets-manifest.md); connectors/pipelines referencing them will fail validation until then."
