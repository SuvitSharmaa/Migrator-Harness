#!/usr/bin/env bash
#
# export.sh — Export all replicable resources from a Harness account to local files.
#
# Source defaults to the prod5 account ZmMyYzk4NDktZmU4Ny00Zm (1 org "default",
# projects KarpoInfra + Alice). Reads are done with a bearer token (UI session
# JWT or a real API key works for GETs).
#
# Output tree (./harness-export/):
#   scope.json                         org + project structure
#   secrets-manifest.md                checklist of secrets to recreate by hand
#   <scope>/connectors/*.json          connector definitions (full spec)
#   <scope>/services/*.yaml            service YAML
#   <scope>/environments/*.yaml        environment YAML
#   <scope>/environments/<env>.infra/*.yaml   infrastructure YAML per env
#   <scope>/pipelines/*.yaml           pipeline YAML
#   <scope>/templates/*.json           template (versioned) definitions
#   <scope>/filestore/...              file-store files + folder manifest
# where <scope> is "account" or "<org>__<project>".
#
# Usage:
#   HARNESS_TOKEN=eyJ... ./export.sh
#
set -uo pipefail

TOKEN="${HARNESS_TOKEN:?set HARNESS_TOKEN to a source bearer token}"
ACC="${SRC_ACCOUNT_ID:-ZmMyYzk4NDktZmU4Ny00Zm}"
BASE="${SRC_BASE_URL:-https://prod5.harness.io/gateway}"
OUT="${OUT_DIR:-./harness-export}"
H=(-H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -H 'accept: */*')

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

# --- scope helpers -----------------------------------------------------------
# A scope is "account" or "<org>/<project>".
scope_qs() {
  case "$1" in
    account) echo "accountIdentifier=$ACC" ;;
    */*)     echo "accountIdentifier=$ACC&orgIdentifier=${1%%/*}&projectIdentifier=${1##*/}" ;;
  esac
}
scope_dir() { case "$1" in account) echo account ;; */*) echo "${1%%/*}__${1##*/}" ;; esac; }

get()  { curl -s "${H[@]}" "$BASE/$1"; }
post() { curl -s "${H[@]}" -X POST "$BASE/$1" --data-raw "$2"; }

# --- discover scope tree -----------------------------------------------------
mkdir -p "$OUT"
echo "Discovering scope tree..."
ORGS_JSON="$(get "ng/api/organizations?accountIdentifier=$ACC&routingId=$ACC&pageSize=200")"
PROJ_JSON="$(get "ng/api/projects?accountIdentifier=$ACC&routingId=$ACC&pageSize=500")"
echo "$ORGS_JSON" | jq '{orgs: [.data.content[].organization|{identifier,name,description,tags}]}' > "$OUT/_orgs.json"
echo "$PROJ_JSON" | jq '{projects: [.data.content[].project|{orgIdentifier,identifier,name,description,color,modules,tags}]}' > "$OUT/_projects.json"
jq -s '{orgs: .[0].orgs, projects: .[1].projects}' "$OUT/_orgs.json" "$OUT/_projects.json" > "$OUT/scope.json"
rm -f "$OUT/_orgs.json" "$OUT/_projects.json"

# Build scope list: account + each project as org/project (bash 3.2 portable).
SCOPES=(account)
while IFS= read -r line; do
  [[ -n "$line" ]] && SCOPES+=("$line")
done < <(echo "$PROJ_JSON" | jq -r '.data.content[].project | "\(.orgIdentifier)/\(.identifier)"')
echo "Scopes: ${SCOPES[*]}"

# Secret manifest header.
SECMAN="$OUT/secrets-manifest.md"
{
  echo "# Secrets manifest"
  echo
  echo "Secret VALUES cannot be exported (the API returns \`value: null\`)."
  echo "Recreate each secret below in the TARGET **before** importing, keeping the"
  echo "same identifier and scope. Connectors/pipelines reference them by identifier."
  echo
} > "$SECMAN"

# --- per-scope export --------------------------------------------------------
for SC in "${SCOPES[@]}"; do
  QS="$(scope_qs "$SC")"
  D="$OUT/$(scope_dir "$SC")"
  echo "=========== exporting scope: $SC -> $D ==========="
  mkdir -p "$D"/{connectors,services,environments,pipelines,templates,filestore,serviceaccounts,usergroups,iacm-workspaces}

  # connectors (full spec returned inline by listV2)
  CONN="$(post "ng/api/connectors/listV2?$QS&routingId=$ACC&pageSize=1000" '{"filterType":"Connector"}')"
  n=$(echo "$CONN" | jq '.data.content|length')
  echo "  connectors: $n"
  echo "$CONN" | jq -c '.data.content[].connector' | while read -r c; do
    id=$(echo "$c" | jq -r '.identifier')
    echo "$c" | jq '.' > "$D/connectors/$id.json"
  done

  # secrets -> manifest only (no values available)
  SEC="$(get "ng/api/v2/secrets?$QS&routingId=$ACC&pageSize=1000")"
  ns=$(echo "$SEC" | jq '.data.content|length')
  echo "  secrets:    $ns (manifest only)"
  if [[ "${ns:-0}" -gt 0 ]]; then
    echo "## Scope: $SC" >> "$SECMAN"
    echo "$SEC" | jq -r '.data.content[].secret | "- [ ] `\(.identifier)`  (type: \(.type), name: \(.name // "-"))"' >> "$SECMAN"
    echo >> "$SECMAN"
  fi

  # services (yaml inline)
  SVC="$(get "ng/api/servicesV2?$QS&routingId=$ACC&pageSize=1000")"
  echo "  services:   $(echo "$SVC" | jq '.data.content|length')"
  echo "$SVC" | jq -r '.data.content[].service | @base64' | while read -r row; do
    s=$(echo "$row" | base64 --decode)
    id=$(echo "$s" | jq -r '.identifier')
    echo "$s" | jq -r '.yaml' > "$D/services/$id.yaml"
  done

  # environments (yaml inline) + their infrastructures
  ENV="$(get "ng/api/environmentsV2?$QS&routingId=$ACC&pageSize=1000")"
  echo "  envs:       $(echo "$ENV" | jq '.data.content|length')"
  echo "$ENV" | jq -r '.data.content[].environment | @base64' | while read -r row; do
    e=$(echo "$row" | base64 --decode)
    eid=$(echo "$e" | jq -r '.identifier')
    echo "$e" | jq -r '.yaml' > "$D/environments/$eid.yaml"
    INF="$(get "ng/api/infrastructures?$QS&environmentIdentifier=$eid&routingId=$ACC&pageSize=1000")"
    icount=$(echo "$INF" | jq '.data.content|length')
    if [[ "${icount:-0}" -gt 0 ]]; then
      mkdir -p "$D/environments/$eid.infra"
      echo "$INF" | jq -r '.data.content[].infrastructure | @base64' | while read -r irow; do
        i=$(echo "$irow" | base64 --decode)
        iid=$(echo "$i" | jq -r '.identifier')
        echo "$i" | jq -r '.yaml' > "$D/environments/$eid.infra/$iid.yaml"
      done
    fi
  done

  # pipelines (list gives ids; per-id GET gives yamlPipeline)
  PIP="$(post "pipeline/api/pipelines/list?$QS&routingId=$ACC&pageSize=1000" '{"filterType":"PipelineSetup"}')"
  echo "  pipelines:  $(echo "$PIP" | jq '.data.content|length')"
  echo "$PIP" | jq -r '.data.content[].identifier' | while read -r pid; do
    [[ -z "$pid" ]] && continue
    get "pipeline/api/pipelines/$pid?$QS&routingId=$ACC" | jq -r '.data.yamlPipeline' > "$D/pipelines/$pid.yaml"
  done

  # templates (versioned)
  TPL="$(post "template/api/templates/list?$QS&routingId=$ACC&templateListType=All&pageSize=1000" '{"filterType":"Template"}')"
  tn=$(echo "$TPL" | jq '(.data.content // []) | length' 2>/dev/null || echo 0)
  echo "  templates:  ${tn:-0}"
  if [[ "${tn:-0}" -gt 0 ]]; then
    echo "$TPL" | jq -c '(.data.content // [])[]' | while read -r t; do
      tid=$(echo "$t" | jq -r '.identifier'); ver=$(echo "$t" | jq -r '.versionLabel')
      echo "$t" | jq -r '.yaml // empty' > "$D/templates/${tid}__${ver}.yaml"
    done
  fi

  # service accounts (recreatable: identifier/name/email/description/tags)
  SA="$(get "ng/api/serviceaccount?$QS&routingId=$ACC&pageSize=1000")"
  san=$(echo "$SA" | jq '(.data | if type=="array" then length else (.content|length) end)' 2>/dev/null || echo 0)
  echo "  svcaccounts:${san:-0}"
  if [[ "${san:-0}" -gt 0 ]]; then
    echo "$SA" | jq -c '(.data | if type=="array" then .[] else .content[] end)' | while read -r sa; do
      sid=$(echo "$sa" | jq -r '.identifier')
      echo "$sa" | jq '{identifier,name,email,description,tags}' > "$D/serviceaccounts/$sid.json"
    done
  fi

  # user groups (custom only; skip harness-managed _all_users etc.)
  UG="$(get "ng/api/user-groups?$QS&routingId=$ACC&pageSize=1000")"
  ugn=$(echo "$UG" | jq '[.data.content[]? | select(.harnessManaged!=true)] | length' 2>/dev/null || echo 0)
  echo "  usergroups: ${ugn:-0} (custom)"
  if [[ "${ugn:-0}" -gt 0 ]]; then
    echo "$UG" | jq -c '.data.content[] | select(.harnessManaged!=true)' | while read -r ug; do
      ugid=$(echo "$ug" | jq -r '.identifier')
      # keep definition; users[] kept for reference but import will blank it (principals not replicated)
      echo "$ug" | jq '{identifier,name,description,tags,notificationConfigs,users}' > "$D/usergroups/$ugid.json"
    done
  fi

  # IACM workspaces (project scope only; path-based route + harness-account header).
  # The list view nulls out repo/variables/connectors, so fetch each by identifier
  # to capture full config.
  case "$SC" in
    */*)
      org="${SC%%/*}"; proj="${SC##*/}"
      WS="$(curl -s -H "authorization: Bearer $TOKEN" -H "harness-account: $ACC" -H 'accept: */*' \
        "$BASE/iacm/api/orgs/$org/projects/$proj/workspaces?page=1&limit=1000")"
      wsn=$(echo "$WS" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
      echo "  iacm ws:    ${wsn:-0}"
      if [[ "${wsn:-0}" -gt 0 ]]; then
        echo "$WS" | jq -r '.[].identifier' | while read -r wid; do
          [[ -z "$wid" ]] && continue
          curl -s -H "authorization: Bearer $TOKEN" -H "harness-account: $ACC" -H 'accept: */*' \
            "$BASE/iacm/api/orgs/$org/projects/$proj/workspaces/$wid" \
            | jq '.' > "$D/iacm-workspaces/$wid.json"
        done
      fi
      ;;
    *) : ;;  # IACM has no account-scope workspaces
  esac

  # file store: manifest only. The content/download endpoint 500s server-side for
  # these entries, and all observed files are Harness-auto-seeded sample K8s
  # manifests (deployment/namespace/service/values.yaml) that every account gets
  # for free — so the target already has them. Capture structure for reference.
  FS="$(get "ng/api/file-store?$QS&routingId=$ACC&pageSize=1000")"
  fcount=$(echo "$FS" | jq '(.data.content // []) | length' 2>/dev/null || echo 0)
  echo "  filestore:  ${fcount:-0} (manifest only; sample files, not replicated)"
  if [[ "${fcount:-0}" -gt 0 ]]; then
    echo "$FS" | jq '[.data.content[]|{identifier,name,type,parentIdentifier,mimeType,fileUsage,description}]' > "$D/filestore/_manifest.json"
  fi
done

echo
echo "Export complete -> $OUT"
echo "Review $SECMAN before importing."
