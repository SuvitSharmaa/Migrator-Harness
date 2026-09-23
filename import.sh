#!/usr/bin/env bash
#
# import.sh — Replay an export produced by export.sh into a TARGET Harness account.
#
# Default target is app.harness.io (prod). Mirrors the source structure exactly:
# recreates projects under org "default", then upserts every entity into its
# original scope (account / default/KarpoInfra / default/Alice).
#
# Dependency order: orgs(exist) -> projects -> connectors -> service accounts ->
# user groups -> services -> environments -> infrastructures -> pipelines.
# Every entity is UPSERTed (create; on "already exists" fall back to update).
#
# NOT imported (by design):
#   - secrets       : values can't be exported; see harness-export/secrets-manifest.md
#   - file store    : source entries are Harness auto-seeded sample manifests
#   - role bindings : principals (users) don't exist identically in the target
#
# Usage:
#   HARNESS_TOKEN=<target-token> TGT_ACCOUNT_ID=<acct> ./import.sh            # apply
#   HARNESS_TOKEN=<target-token> TGT_ACCOUNT_ID=<acct> DRY_RUN=1 ./import.sh  # preview
#
set -uo pipefail

TOKEN="${HARNESS_TOKEN:?set HARNESS_TOKEN to a TARGET account bearer token / x-api-key}"
ACC="${TGT_ACCOUNT_ID:?set TGT_ACCOUNT_ID to the target account identifier}"
BASE="${TGT_BASE_URL:-https://machine-pulse.harness.io}"
IN="${IN_DIR:-./harness-export}"
DRY="${DRY_RUN:-0}"

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
    */*)     echo "accountIdentifier=$ACC&orgIdentifier=${1%%/*}&projectIdentifier=${1##*/}" ;;
  esac
}
scope_of_dir() { # account__ -> account ; org__proj -> org/proj
  local d="$1"
  [[ "$d" == account ]] && { echo account; return; }
  echo "${d%%__*}/${d#*__}"
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
  if echo "$resp" | grep -qiE 'already exists|duplicate|DUPLICATE_FIELD'; then
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
  local org="" proj=""
  case "$sc" in */*) org="${sc%%/*}"; proj="${sc#*/}";; esac
  local inner; inner="$(jq --arg a "$ACC" --arg o "$org" --arg p "$proj" \
    '. + {accountIdentifier:$a} + (if $o=="" then {} else {orgIdentifier:$o,projectIdentifier:$p} end)' "$file")"
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
  local org="" proj=""; case "$sc" in */*) org="${sc%%/*}"; proj="${sc#*/}";; esac
  local inner; inner="$(jq --arg a "$ACC" --arg o "$org" --arg p "$proj" \
    '. + {accountIdentifier:$a} + (if $o=="" then {} else {orgIdentifier:$o,projectIdentifier:$p} end)' "$file")"
  local payload; if [[ -n "$wrap" ]]; then payload="$(jq -n --argjson v "$inner" "{\"$wrap\":\$v}")"; else payload="$inner"; fi

  req POST "$BASE/$path?$qs&routingId=$ACC" json "$payload" "$label"
  if [[ $? -eq 9 ]]; then req PUT "$BASE/$path/$id?$qs&routingId=$ACC" json "$payload" "$label (update)"; fi
}

# yaml_get FILE JSONPATH  -> extract a scalar from the entity YAML via yq
yaml_get() { yq -r "$2" "$1" 2>/dev/null; }

# upsert_dto BASEPATH SCOPE ROOTKEY FILE LABEL [EXTRA_QS]
#   services/environments/infrastructures take a JSON DTO (application/json):
#   top-level identifier/name/scope fields + the full entity YAML as a string
#   `yaml` field. ROOTKEY is the YAML's top object (service|environment|
#   infrastructureDefinition). Environment additionally needs `type`.
upsert_dto() {
  local path="$1" sc="$2" root="$3" file="$4" label="$5" extra="${6:-}"
  local qs; qs="$(scope_qs "$sc")"
  local org="" proj=""; case "$sc" in */*) org="${sc%%/*}"; proj="${sc#*/}";; esac

  local id name etype yaml
  id="$(yaml_get "$file" ".${root}.identifier")"
  name="$(yaml_get "$file" ".${root}.name")"
  etype="$(yaml_get "$file" ".${root}.type")"   # only environments use this; null otherwise
  yaml="$(cat "$file")"

  # Build DTO. environmentsV2 wants `type`; services/infra ignore a null one.
  local dto
  dto="$(jq -n \
    --arg id "$id" --arg name "$name" --arg acct "$ACC" \
    --arg org "$org" --arg proj "$proj" --arg etype "$etype" \
    --arg yaml "$yaml" --arg root "$root" '
      {identifier:$id, name:$name, accountIdentifier:$acct, yaml:$yaml}
      + (if $org!="" then {orgIdentifier:$org, projectIdentifier:$proj} else {} end)
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
    tmp="$(mktemp)"
    code="$(curl -s -o "$tmp" -w '%{http_code}' -X PUT "$base/$id?routingId=$ACC" "${HI[@]}" --data-binary "$body")"
    resp="$(cat "$tmp")"; rm -f "$tmp"
    if [[ "$code" =~ ^2 ]]; then printf '    OK   %s (update %s)\n' "$label" "$code"; PASS=$((PASS+1)); return 0; fi
  fi
  printf '    FAIL %s (%s) %s\n' "$label" "$code" "$(echo "$resp" | jq -r '.message // empty' 2>/dev/null | head -c 160)" >&2
  FAIL=$((FAIL+1)); FAILED+=("$label ($code)"); return 1
}

echo "=== Importing $IN -> account $ACC @ $BASE  (DRY_RUN=$DRY) ==="

# ---- 1. projects (org 'default' assumed to exist) --------------------------
echo "== projects =="
if [[ -f "$IN/scope.json" ]]; then
  jq -c '.projects[]' "$IN/scope.json" | while read -r p; do
    pid=$(echo "$p" | jq -r '.identifier'); org=$(echo "$p" | jq -r '.orgIdentifier')
    payload=$(echo "$p" | jq --arg a "$ACC" '{project: (. + {accountIdentifier:$a})}')
    req POST "$BASE/ng/api/projects?accountIdentifier=$ACC&orgIdentifier=$org&routingId=$ACC" json "$payload" "project/$org/$pid"
    [[ $? -eq 9 ]] && req PUT "$BASE/ng/api/projects/$pid?accountIdentifier=$ACC&orgIdentifier=$org&routingId=$ACC" json "$payload" "project/$org/$pid (update)"
  done
fi

# ---- per-scope entities ----------------------------------------------------
for SCDIR in account default__KarpoInfra default__Alice; do
  [[ -d "$IN/$SCDIR" ]] || continue
  SC="$(scope_of_dir "$SCDIR")"
  echo "== scope: $SC =="

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

  # pipelines (YAML) — v2 create endpoint consumes raw pipeline YAML
  for f in "$IN/$SCDIR"/pipelines/*.yaml; do [[ -e "$f" ]] || continue
    case "$SC" in */*) qs="$(scope_qs "$SC")";; *) echo "    SKIP pipeline (account-scope pipelines unsupported)"; SKIP=$((SKIP+1)); continue;; esac
    body="$(cat "$f")"; pid="$(basename "$f" .yaml)"
    req POST "$BASE/pipeline/api/pipelines/v2?$qs&routingId=$ACC" yaml "$body" "pipeline/$pid"
    [[ $? -eq 9 ]] && req PUT "$BASE/pipeline/api/pipelines/v2/$pid?$qs&routingId=$ACC" yaml "$body" "pipeline/$pid (update)"
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
