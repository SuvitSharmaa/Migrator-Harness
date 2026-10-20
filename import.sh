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
    printf '    [dry] %s %s\n' "$method" "$label"; SKIP=$((SKIP+1)); return 0
  fi
  local hdr=(); [[ "$ctype" == yaml ]] && hdr=("${HY[@]}") || hdr=("${H[@]}")
  local tmp code; tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X "$method" "$url" "${hdr[@]}" --data-binary "$body")"
  local resp; resp="$(cat "$tmp")"; rm -f "$tmp"
  if [[ "$code" =~ ^2 ]]; then
    printf '    OK   %s (%s)\n' "$label" "$code"; PASS=$((PASS+1)); return 0
  fi
  # Already-exists -> let caller try update by returning special code 9.
  # Print the actual response even here — this used to be silent, which
  # meant a real failure that merely happened to contain a matching phrase
  # (or a genuine conflict for a reason other than "the record exists")
  # was invisible; you'd only ever see the SECOND call's (the update
  # attempt's) error, which can be misleading about the real cause.
  if echo "$resp" | grep -qiE 'already exists|duplicate|DUPLICATE_FIELD'; then
    printf '    (exists) %s (%s) %s -- trying update\n' "$label" "$code" "$(echo "$resp" | jq -r '.message // .responseMessages[0].message // empty' 2>/dev/null | head -c 160)"
    return 9
  fi
  printf '    FAIL %s (%s) %s\n' "$label" "$code" "$(echo "$resp" | jq -r '.message // .responseMessages[0].message // empty' 2>/dev/null | head -c 160)" >&2
  FAIL=$((FAIL+1)); FAILED+=("$label ($code)"); return 1
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

  if [[ "$DRY" == "1" ]]; then printf '    [dry] POST %s\n' "$label"; SKIP=$((SKIP+1)); return 0; fi
  local tmp code resp; tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$base?routingId=$ACC" "${HI[@]}" --data-binary "$body")"
  resp="$(cat "$tmp")"; rm -f "$tmp"
  if [[ "$code" =~ ^2 ]]; then printf '    OK   %s (%s)\n' "$label" "$code"; PASS=$((PASS+1)); return 0; fi
  if echo "$resp" | grep -qiE 'already exists|duplicate|exists'; then
    printf '    (exists) %s (%s) %s -- trying update\n' "$label" "$code" "$(echo "$resp" | jq -r '.message // empty' 2>/dev/null | head -c 160)"
    tmp="$(mktemp)"
    code="$(curl -s -o "$tmp" -w '%{http_code}' -X PUT "$base/$id?routingId=$ACC" "${HI[@]}" --data-binary "$body")"
    resp="$(cat "$tmp")"; rm -f "$tmp"
    if [[ "$code" =~ ^2 ]]; then printf '    OK   %s (update %s)\n' "$label" "$code"; PASS=$((PASS+1)); return 0; fi
  fi
  printf '    FAIL %s (%s) %s\n' "$label" "$code" "$(echo "$resp" | jq -r '.message // empty' 2>/dev/null | head -c 160)" >&2
  FAIL=$((FAIL+1)); FAILED+=("$label ($code)"); return 1
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
    connectorRef="$(jq -r '.connectorRef' "$f")"; repoName="$(jq -r '.repoName' "$f")"
    filePath="$(jq -r '.filePath' "$f")"; branch="$(jq -r '.branch // ""' "$f")"
    importqs="connectorRef=$connectorRef&isHarnessCodeRepo=false&repoName=$repoName&branch=$branch&filePath=$filePath"
    req POST "$BASE/template/api/templates/import?$tqs&$importqs&routingId=$ACC" json '{"templateDescription":""}' "template/$tid/$tver (git-import)"
    if [[ $? -eq 9 ]]; then
      echo "    SKIP template/$tid/$tver (git-import) (already exists in target — this script doesn't re-import an already-imported git-linked template; delete it in target first if you need to re-run)"
      SKIP=$((SKIP+1))
    fi
  done

  # connectors (JSON, wrap "connector") — skip Harness built-ins
  for f in "$IN/$SCDIR"/connectors/*.json; do [[ -e "$f" ]] || continue
    cid="$(basename "$f" .json)"
    if is_builtin "$cid"; then echo "    skip connector/$cid (Harness built-in)"; SKIP=$((SKIP+1)); continue; fi
    upsert_json "ng/api/connectors" "$SC" "connector" "$f" "connector/$cid"; done

  # service accounts (JSON, no wrap; update PUTs to /serviceaccount/{id})
  for f in "$IN/$SCDIR"/serviceaccounts/*.json; do [[ -e "$f" ]] || continue
    said="$(basename "$f" .json)"
    upsert_json_pathid "ng/api/serviceaccount" "$SC" "" "$f" "serviceaccount/$said" "$said"; done

  # user groups (JSON, no wrap) — blank users[] (principals not replicated)
  for f in "$IN/$SCDIR"/usergroups/*.json; do [[ -e "$f" ]] || continue
    tmp="$(mktemp)"; jq '.users = []' "$f" > "$tmp"
    upsert_json "ng/api/user-groups" "$SC" "" "$tmp" "usergroup/$(basename "$f" .json)"; rm -f "$tmp"; done

  # services (JSON DTO: identifier/name/scope + yaml string)
  for f in "$IN/$SCDIR"/services/*.yaml; do [[ -e "$f" ]] || continue
    upsert_dto "ng/api/servicesV2" "$SC" "service" "$f" "service/$(basename "$f" .yaml)"; done

  # environments (JSON DTO: + type)
  for f in "$IN/$SCDIR"/environments/*.yaml; do [[ -e "$f" ]] || continue
    upsert_dto "ng/api/environmentsV2" "$SC" "environment" "$f" "environment/$(basename "$f" .yaml)"; done

  # infrastructures (JSON DTO + environmentIdentifier query param from <env>.infra)
  for d in "$IN/$SCDIR"/environments/*.infra; do [[ -d "$d" ]] || continue
    env="$(basename "$d" .infra)"
    for f in "$d"/*.yaml; do [[ -e "$f" ]] || continue
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
    body="$(rewrite_scope_yaml "$f" "pipeline" "$porg" "$pproj")"; pid="$(basename "$f" .yaml)"
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
    connectorRef="$(jq -r '.connectorRef' "$f")"; repoName="$(jq -r '.repoName' "$f")"
    filePath="$(jq -r '.filePath' "$f")"; branch="$(jq -r '.branch // ""' "$f")"
    importqs="connectorRef=$connectorRef&isHarnessCodeRepo=false&repoName=$repoName&branch=$branch&filePath=$filePath"
    req POST "$BASE/pipeline/api/pipelines/import?$qs&$importqs&routingId=$ACC" json '{"pipelineDescription":""}' "pipeline/$pid (git-import)"
    if [[ $? -eq 9 ]]; then
      echo "    SKIP pipeline/$pid (git-import) (already exists in target — this script doesn't re-import an already-imported git-linked pipeline; delete it in target first if you need to re-run)"
      SKIP=$((SKIP+1))
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
    pid="$(yaml_get "$f" ".trigger.pipelineIdentifier")"
    if [[ -z "$pid" || "$pid" == "null" ]]; then
      echo "    SKIP trigger/$tid (couldn't determine target pipelineIdentifier)"; SKIP=$((SKIP+1)); continue
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
        upsert_iacm_workspace "$org" "$proj" "$f"; done ;;
  esac
done

echo
echo "=== Summary: $PASS ok, $FAIL failed, $SKIP skipped ==="
if [[ ${#FAILED[@]} -gt 0 ]]; then printf '  - %s\n' "${FAILED[@]}"; fi
echo "Reminder: recreate secrets first (see $IN/secrets-manifest.md); connectors/pipelines referencing them will fail validation until then."
