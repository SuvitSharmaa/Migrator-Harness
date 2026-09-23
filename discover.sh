#!/usr/bin/env bash
# discover.sh — inventory a Harness account's resources across all scopes (read-only).
set -uo pipefail

TOKEN="${HARNESS_TOKEN:?set HARNESS_TOKEN}"
ACC="${ACCOUNT_ID:-ZmMyYzk4NDktZmU4Ny00Zm}"
BASE="${HARNESS_BASE_URL:-https://prod5.harness.io/gateway}"
H=(-H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -H 'accept: */*')

# scopes: "account" then each project as "org/project"
PROJECTS=("default/KarpoInfra" "default/Alice")

# scope_qs <scope> -> echoes the account/org/project query string
scope_qs() {
  case "$1" in
    account) echo "accountIdentifier=$ACC" ;;
    */*)     echo "accountIdentifier=$ACC&orgIdentifier=${1%%/*}&projectIdentifier=${1##*/}" ;;
  esac
}

count_get() { # <label> <path> <scope>
  local n
  n=$(curl -s "${H[@]}" "$BASE/$2?$(scope_qs "$3")&routingId=$ACC&pageIndex=0&pageSize=1" | jq -r '.data.totalItems // .data.totalElements // (.data.content|length) // 0' 2>/dev/null)
  printf '  %-22s %s\n' "$1" "${n:-?}"
}
count_post() { # <label> <path> <scope> <body>
  local n
  n=$(curl -s "${H[@]}" -X POST "$BASE/$2?$(scope_qs "$3")&routingId=$ACC&pageIndex=0&pageSize=1" --data-raw "$4" | jq -r '.data.totalItems // (.data.content|length) // 0' 2>/dev/null)
  printf '  %-22s %s\n' "$1" "${n:-?}"
}

for SC in account "${PROJECTS[@]}"; do
  echo "================ SCOPE: $SC ================"
  count_post "connectors"      "ng/api/connectors/listV2"               "$SC" '{"filterType":"Connector"}'
  count_get  "secrets"         "ng/api/v2/secrets"                      "$SC"
  count_get  "services"        "ng/api/servicesV2"                      "$SC"
  count_get  "environments"    "ng/api/environmentsV2"                  "$SC"
  count_get  "pipelines"       "pipeline/api/pipelines/list"            "$SC"   # POST-only fallback below
  count_post "pipelines(POST)" "pipeline/api/pipelines/list"            "$SC" '{"filterType":"PipelineSetup"}'
  count_get  "templates"       "template/api/templates/list"            "$SC"
  count_post "templates(POST)" "template/api/templates/list"            "$SC" '{"filterType":"Template"}'
  count_get  "files(store)"    "ng/api/file-store"                      "$SC"
  count_get  "variables"       "ng/api/variables"                       "$SC"
  count_get  "infra(env)"      "ng/api/infrastructures"                 "$SC"
done
