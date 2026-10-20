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
#   <scope>/templates/<id>__<ver>.yaml template YAML, one file per version
#   <scope>/triggers/*.yaml            trigger YAML, one file per trigger (project scope only)
#   <scope>/webhooks/*.json            GitX webhook config (project scope only)
#   <scope>/filestore/...              file-store files + folder manifest
# where <scope> is "account", "org-scope__<org>" (org-only — see project mode
# below), or "<org>__<project>".
#
# Usage:
#   HARNESS_TOKEN=eyJ... ./export.sh                                    # full account
#   HARNESS_TOKEN=eyJ... SRC_ORG=default SRC_PROJECT=Alice ./export.sh  # single project
#
# Setting SRC_ORG + SRC_PROJECT restricts the export to that one project scope
# only — no "account" scope, no other projects, EXCEPT: account-/org-scoped
# secrets and connectors that the project's own resources actually reference
# by identifier (e.g. connectorRef: account.foo) are detected and pulled in
# too (into "account" / "org-scope__<org>" dirs), since a fresh target won't
# have them yet. Everything else at account/org scope (service accounts,
# user groups, unreferenced connectors/secrets, etc.) is still assumed to
# already exist in the target and is not exported.
#
set -uo pipefail

TOKEN="${HARNESS_TOKEN:?set HARNESS_TOKEN to a source bearer token / x-api-key}"
ACC="${SRC_ACCOUNT_ID:-ZmMyYzk4NDktZmU4Ny00Zm}"
BASE="${SRC_BASE_URL:-https://prod5.harness.io/gateway}"
OUT="${OUT_DIR:-./harness-export}"
SRC_ORG="${SRC_ORG:-}"
SRC_PROJECT="${SRC_PROJECT:-}"

# Auth header: a real API key uses x-api-key; a UI JWT uses Authorization: Bearer.
# Token starting with "pat." or "sat." => API key; else treat as bearer.
# (Must match import.sh/secrets.sh — sending a PAT as "Bearer" gets silently
# rejected by Harness and looks like a missing-resource error downstream.)
if [[ "$TOKEN" == pat.* || "$TOKEN" == sat.* ]]; then
  AUTH=(-H "x-api-key: $TOKEN")
else
  AUTH=(-H "authorization: Bearer $TOKEN")
fi
H=("${AUTH[@]}" -H 'content-type: application/json' -H 'accept: */*')

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq required (brew install yq)" >&2; exit 1; }

if [[ -n "$SRC_ORG" && -z "$SRC_PROJECT" ]] || [[ -z "$SRC_ORG" && -n "$SRC_PROJECT" ]]; then
  echo "set both SRC_ORG and SRC_PROJECT for a single-project export, or leave both unset for a full account export" >&2
  exit 1
fi
PROJECT_MODE=0
[[ -n "$SRC_ORG" && -n "$SRC_PROJECT" ]] && PROJECT_MODE=1

# --- scope helpers -----------------------------------------------------------
# A scope is "account" or "<org>/<project>".
scope_qs() {
  case "$1" in
    account) echo "accountIdentifier=$ACC" ;;
    */*)     echo "accountIdentifier=$ACC&orgIdentifier=${1%%/*}&projectIdentifier=${1##*/}" ;;
  esac
}
scope_dir() { case "$1" in account) echo account ;; org:*) echo "org-scope__${1#org:}" ;; */*) echo "${1%%/*}__${1##*/}" ;; esac; }

get()  { curl -s "${H[@]}" "$BASE/$1"; }
post() { curl -s "${H[@]}" -X POST "$BASE/$1" --data-raw "$2"; }

# paginate_content METHOD PATH [BODY] [EXTRACT] -> {"data":{"content":[...]}}
# with every page's items merged into one deduped array. EXTRACT is a jq
# filter picking the item array out of a page's response (default
# ".data.content"; e.g. service accounts sometimes return a raw array under
# `.data` instead — pass '(.data | if type=="array" then . else .content end)').
#
# PATH already carries pageSize=1000 as a *hint*, but several list endpoints
# (confirmed: pipelines; likely others) silently cap their real page size far
# below that and return only page 0 — no error, just a short result. A
# single-page fetch with pageSize=1000 previously returned 25 of a project's
# 478 real pipelines with no indication anything was missing.
#
# Stops when a fetched page contributes ZERO items not already seen — not
# simply "page came back empty". That covers two failure modes: an endpoint
# that properly paginates (ends on a genuinely empty page), AND one that
# doesn't honor pageIndex at all and just re-returns the same full result
# every time (stops after 2 calls once the "next page" adds nothing new,
# instead of re-appending the same items until the safety valve trips).
paginate_content() {
  local method="$1" path="$2" body="${3:-}" extract="${4:-.data.content}"
  local page=0 acc='[]' resp got n merged old_count new_count qs_page body_paged
  while :; do
    # Send both pagination-param naming conventions Harness services use
    # (pageIndex/pageSize vs page/size) in the query string — and, for POST
    # calls, ALSO in the JSON body, since some /list endpoints that take a
    # filter body read pagination from the body and ignore the query string
    # entirely. Cheap and harmless if the server only recognizes one form.
    qs_page="&pageIndex=${page}&page=${page}"
    if [[ "$method" == POST ]]; then
      body_paged="$(echo "$body" | jq -c --argjson pi "$page" \
        '. + {pageIndex: $pi, page: $pi}' 2>/dev/null)"
      [[ -z "$body_paged" ]] && body_paged="$body"
      resp="$(post "${path}${qs_page}" "$body_paged")"
    else
      resp="$(get "${path}${qs_page}")"
    fi
    got="$(echo "$resp" | jq -c "($extract) // []" 2>/dev/null)"
    [[ -z "$got" || "$got" == "null" ]] && got='[]'
    n="$(echo "$got" | jq 'length' 2>/dev/null)"; n="${n:-0}"
    [[ "$n" -eq 0 ]] && break
    old_count="$(echo "$acc" | jq 'length' 2>/dev/null)"; old_count="${old_count:-0}"
    merged="$(jq -cn --argjson a "$acc" --argjson b "$got" '($a + $b) | unique' 2>/dev/null)"
    [[ -z "$merged" ]] && merged="$acc"
    new_count="$(echo "$merged" | jq 'length' 2>/dev/null)"; new_count="${new_count:-$old_count}"
    [[ "$new_count" -eq "$old_count" ]] && break
    acc="$merged"
    page=$((page+1))
    # Safety valve: a real pagination bug elsewhere shouldn't spin forever.
    if [[ "$page" -gt 200 ]]; then
      echo "  WARNING: paginate_content stopped after 200 pages for $path — results may be incomplete" >&2
      break
    fi
  done
  printf '{"data":{"content":%s}}' "$acc"
}

# iacm_list_workspaces ORG PROJ -> JSON array of every workspace (all pages
# merged, deduped by identifier). IACM's list endpoint uses page/limit query
# params (not pageIndex/pageSize) and returns a raw array (no `.data.content`
# wrapper), so it can't go through paginate_content — same "stop when a page
# adds nothing new" safety net, applied directly here instead.
iacm_list_workspaces() {
  local org="$1" proj="$2" page=1 acc='[]' resp n merged old_count new_count
  while :; do
    resp="$(curl -s "${AUTH[@]}" -H "harness-account: $ACC" -H 'accept: */*' \
      "$BASE/iacm/api/orgs/$org/projects/$proj/workspaces?page=$page&limit=1000")"
    if [[ "$(echo "$resp" | jq -e 'type=="array"' 2>/dev/null)" != "true" ]]; then resp='[]'; fi
    n="$(echo "$resp" | jq 'length' 2>/dev/null)"; n="${n:-0}"
    [[ "$n" -eq 0 ]] && break
    old_count="$(echo "$acc" | jq 'length' 2>/dev/null)"; old_count="${old_count:-0}"
    merged="$(jq -cn --argjson a "$acc" --argjson b "$resp" '($a + $b) | unique_by(.identifier)' 2>/dev/null)"
    [[ -z "$merged" ]] && merged="$acc"
    new_count="$(echo "$merged" | jq 'length' 2>/dev/null)"; new_count="${new_count:-$old_count}"
    [[ "$new_count" -eq "$old_count" ]] && break
    acc="$merged"
    page=$((page+1))
    if [[ "$page" -gt 200 ]]; then
      echo "  WARNING: iacm workspace pagination stopped after 200 pages for $org/$proj — results may be incomplete" >&2
      break
    fi
  done
  printf '%s' "$acc"
}

# get_checked <path> <label> -> body on stdout; exits with a clear diagnostic
# on a non-2xx response or an unexpected shape, instead of silently returning
# a body that later cascades into "jq: Cannot iterate over null (null)" and
# misleading "not found" errors further down the script.
get_checked() {
  local path="$1" label="$2" tmp code body
  tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' "${H[@]}" "$BASE/$path")"
  body="$(cat "$tmp")"; rm -f "$tmp"
  if [[ ! "$code" =~ ^2 ]]; then
    echo "ERROR: $label failed (HTTP $code) against $BASE" >&2
    echo "  Check that SRC_BASE_URL points at the right cluster/gateway" >&2
    echo "  (SaaS accounts usually need a /gateway suffix, e.g. https://app.harness.io/gateway)" >&2
    echo "  and that HARNESS_TOKEN is valid, unexpired, and has read access to account $ACC." >&2
    echo "  Response: $(echo "$body" | head -c 300)" >&2
    exit 1
  fi
  if ! echo "$body" | jq -e '.data.content' >/dev/null 2>&1; then
    echo "ERROR: $label returned HTTP 200 but not the expected shape (.data.content missing)." >&2
    echo "  Response: $(echo "$body" | head -c 300)" >&2
    exit 1
  fi
  printf '%s' "$body"
}

# get_single <path> -> body on stdout if HTTP 2xx and .data is non-null;
# returns 1 (no diagnostic) on 404/empty so callers can print their own
# domain-specific "not found" message instead of get_checked's generic one.
get_single() {
  local path="$1" tmp code body
  tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' "${H[@]}" "$BASE/$path")"
  body="$(cat "$tmp")"; rm -f "$tmp"
  [[ "$code" =~ ^2 ]] || return 1
  echo "$body" | jq -e '.data != null' >/dev/null 2>&1 || return 1
  printf '%s' "$body"
}

# get_checked_paginated <path> <label> -> body on stdout, .data.content
# merged across every page (same growth-detection stopping condition as
# paginate_content). Validates the FIRST page's HTTP status/shape with
# get_checked's clear diagnostics before looping further — an account with
# more orgs/projects than fit in one page would otherwise have this script
# report "project not found" even though the project clearly exists, just
# not on page 0.
get_checked_paginated() {
  local path="$1" label="$2" page=0 acc='[]' resp got n merged old_count new_count
  resp="$(get_checked "${path}&pageIndex=${page}&page=${page}" "$label")" || return 1
  while :; do
    got="$(echo "$resp" | jq -c '.data.content // []' 2>/dev/null)"
    [[ -z "$got" || "$got" == "null" ]] && got='[]'
    n="$(echo "$got" | jq 'length' 2>/dev/null)"; n="${n:-0}"
    [[ "$n" -eq 0 ]] && break
    old_count="$(echo "$acc" | jq 'length' 2>/dev/null)"; old_count="${old_count:-0}"
    merged="$(jq -cn --argjson a "$acc" --argjson b "$got" '($a + $b) | unique' 2>/dev/null)"
    [[ -z "$merged" ]] && merged="$acc"
    new_count="$(echo "$merged" | jq 'length' 2>/dev/null)"; new_count="${new_count:-$old_count}"
    [[ "$new_count" -eq "$old_count" ]] && break
    acc="$merged"
    page=$((page+1))
    if [[ "$page" -gt 200 ]]; then
      echo "  WARNING: get_checked_paginated stopped after 200 pages for $label — results may be incomplete" >&2
      break
    fi
    resp="$(get "${path}&pageIndex=${page}&page=${page}")"
  done
  printf '{"data":{"content":%s}}' "$acc"
}

# --- discover scope tree -----------------------------------------------------
mkdir -p "$OUT"
echo "Discovering scope tree..."
# get_checked_paginated (account mode below) runs in a $(...) subshell, so
# its internal `return 1` (from a failed first-page get_checked) only kills
# that subshell — it does NOT stop this script on its own. The exit status
# of a bare `VAR="$(cmd)"` assignment IS cmd's exit status, so `|| exit 1`
# there is what actually propagates the failure up instead of silently
# continuing with an empty ORGS_JSON/PROJ_JSON.
if [[ "$PROJECT_MODE" -eq 1 ]]; then
  # Single-project export: look up the org and project directly by
  # identifier instead of paginating every org/project in the account.
  # Accounts with many thousands of projects can have ties in the list
  # endpoint's default sort (e.g. bulk-seeded rows sharing one
  # lastModifiedAt timestamp) with no secondary sort key — offset-based
  # pagination over such data can skip or repeat pages non-deterministically
  # (get_checked_paginated's growth check then sees "no new items" and stops
  # early), silently missing the one project being exported even though it
  # unambiguously exists. A direct single-resource GET has no such issue.
  ORG_BODY="$(get_single "ng/api/organizations/$SRC_ORG?accountIdentifier=$ACC&routingId=$ACC")" \
    || { echo "org '$SRC_ORG' not found in source account $ACC" >&2; exit 1; }
  PROJ_BODY="$(get_single "ng/api/projects/$SRC_PROJECT?accountIdentifier=$ACC&orgIdentifier=$SRC_ORG&routingId=$ACC")" \
    || { echo "project '$SRC_ORG/$SRC_PROJECT' not found in source account $ACC" >&2; exit 1; }
  echo "$ORG_BODY" | jq '{orgs: [.data.organization|{identifier,name,description,tags}]}' > "$OUT/_orgs.json"
  echo "$PROJ_BODY" | jq '{projects: [.data.project|{orgIdentifier,identifier,name,description,color,modules,tags}]}' > "$OUT/_projects.json"
else
  ORGS_JSON="$(get_checked_paginated "ng/api/organizations?accountIdentifier=$ACC&routingId=$ACC&pageSize=200" "list organizations")" || exit 1
  PROJ_JSON="$(get_checked_paginated "ng/api/projects?accountIdentifier=$ACC&routingId=$ACC&pageSize=500" "list projects")" || exit 1
  echo "$ORGS_JSON" | jq '{orgs: [.data.content[].organization|{identifier,name,description,tags}]}' > "$OUT/_orgs.json"
  echo "$PROJ_JSON" | jq '{projects: [.data.content[].project|{orgIdentifier,identifier,name,description,color,modules,tags}]}' > "$OUT/_projects.json"
fi
jq -s '{orgs: .[0].orgs, projects: .[1].projects}' "$OUT/_orgs.json" "$OUT/_projects.json" > "$OUT/scope.json"
rm -f "$OUT/_orgs.json" "$OUT/_projects.json"

if [[ "$PROJECT_MODE" -eq 1 ]]; then
  found="$(jq '.projects|length' "$OUT/scope.json")"
  [[ "$found" -eq 1 ]] || { echo "project '$SRC_ORG/$SRC_PROJECT' not found in source account $ACC" >&2; exit 1; }
fi

# Build scope list (bash 3.2 portable):
#  - project mode: just the one requested project
#  - account mode: account + every discovered project as org/project
if [[ "$PROJECT_MODE" -eq 1 ]]; then
  SCOPES=("$SRC_ORG/$SRC_PROJECT")
else
  SCOPES=(account)
  while IFS= read -r line; do
    [[ -n "$line" ]] && SCOPES+=("$line")
  done < <(echo "$PROJ_JSON" | jq -r '.data.content[].project | "\(.orgIdentifier)/\(.identifier)"')
fi
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
  mkdir -p "$D"/{connectors,services,environments,pipelines,templates,triggers,webhooks,filestore,serviceaccounts,usergroups,iacm-workspaces}

  # connectors (full spec returned inline by listV2)
  CONN="$(paginate_content POST "ng/api/connectors/listV2?$QS&routingId=$ACC&pageSize=1000" '{"filterType":"Connector"}')"
  n=$(echo "$CONN" | jq '.data.content|length')
  echo "  connectors: $n"
  echo "$CONN" | jq -c '.data.content[].connector' | while read -r c; do
    id=$(echo "$c" | jq -r '.identifier')
    echo "$c" | jq '.' > "$D/connectors/$id.json"
  done

  # secrets -> manifest only (no values available)
  SEC="$(paginate_content GET "ng/api/v2/secrets?$QS&routingId=$ACC&pageSize=1000")"
  ns=$(echo "$SEC" | jq '.data.content|length')
  echo "  secrets:    $ns (manifest only)"
  if [[ "${ns:-0}" -gt 0 ]]; then
    echo "## Scope: $SC" >> "$SECMAN"
    echo "$SEC" | jq -r '.data.content[].secret | "- [ ] `\(.identifier)`  (type: \(.type), name: \(.name // "-"))"' >> "$SECMAN"
    echo >> "$SECMAN"
  fi

  # services (yaml inline)
  SVC="$(paginate_content GET "ng/api/servicesV2?$QS&routingId=$ACC&pageSize=1000")"
  echo "  services:   $(echo "$SVC" | jq '.data.content|length')"
  echo "$SVC" | jq -r '.data.content[].service | @base64' | while read -r row; do
    s=$(echo "$row" | base64 --decode)
    id=$(echo "$s" | jq -r '.identifier')
    echo "$s" | jq -r '.yaml' > "$D/services/$id.yaml"
  done

  # environments (yaml inline) + their infrastructures
  ENV="$(paginate_content GET "ng/api/environmentsV2?$QS&routingId=$ACC&pageSize=1000")"
  echo "  envs:       $(echo "$ENV" | jq '.data.content|length')"
  echo "$ENV" | jq -r '.data.content[].environment | @base64' | while read -r row; do
    e=$(echo "$row" | base64 --decode)
    eid=$(echo "$e" | jq -r '.identifier')
    echo "$e" | jq -r '.yaml' > "$D/environments/$eid.yaml"
    INF="$(paginate_content GET "ng/api/infrastructures?$QS&environmentIdentifier=$eid&routingId=$ACC&pageSize=1000")"
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
  PIP="$(paginate_content POST "pipeline/api/pipelines/list?$QS&routingId=$ACC&pageSize=1000" '{"filterType":"PipelineSetup"}')"
  echo "  pipelines:  $(echo "$PIP" | jq '.data.content|length')"
  echo "$PIP" | jq -r '.data.content[].identifier' | while read -r pid; do
    [[ -z "$pid" ]] && continue
    get "pipeline/api/pipelines/$pid?$QS&routingId=$ACC" | jq -r '.data.yamlPipeline' > "$D/pipelines/$pid.yaml"
  done

  # triggers (one per pipeline; GET .../pipeline/api/triggers?...&targetIdentifier=<pipelineId>
  # returns each trigger's own `yaml` field directly — CONFIRMED via a real
  # HAR capture of the "New Trigger" UI list-refresh call, same endpoint
  # import.sh's create call uses). Account-scope has no pipelines/triggers,
  # so this only ever runs anything for project scope.
  tn_total=0
  case "$SC" in
    */*)
      echo "$PIP" | jq -r '.data.content[].identifier' | while read -r pid; do
        [[ -z "$pid" ]] && continue
        TRG="$(paginate_content GET "pipeline/api/triggers?$QS&targetIdentifier=$pid&size=1000&routingId=$ACC")"
        echo "$TRG" | jq -c '.data.content[]?' | while read -r t; do
          tid="$(echo "$t" | jq -r '.identifier')"
          [[ -z "$tid" || "$tid" == "null" ]] && continue
          echo "$t" | jq -r '.yaml' > "$D/triggers/$tid.yaml"
        done
      done
      ;;
  esac
  tn_total="$(find "$D/triggers" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  triggers:   ${tn_total:-0}"

  # GitX webhooks — CONFIRMED via a real HAR capture of Harness's "New
  # Webhook" UI (Project Settings -> Webhooks): POST /v1/orgs/{org}/
  # projects/{project}/webhooks/list?limit=&page=, no body, response is a
  # bare JSON array (not wrapped in .data.content like the NG APIs above),
  # each entry already carrying spec.connector_ref — unlike audit-trail
  # restore, a LIVE export can see this directly, no manual entry needed.
  # Path-scoped (org/project baked into the URL), so account scope has none.
  wn=0
  case "$SC" in
    */*)
      worg="${SC%%/*}"; wproj="${SC#*/}"
      wbase="v1/orgs/$worg/projects/$wproj/webhooks/list"
      wpage=0 wacc='[]'
      while :; do
        wresp="$(post "${wbase}?limit=1000&page=${wpage}" '')"
        wgot="$(echo "$wresp" | jq -c 'if type=="array" then . else [] end' 2>/dev/null)"
        [[ -z "$wgot" || "$wgot" == "null" ]] && wgot='[]'
        wn_page="$(echo "$wgot" | jq 'length' 2>/dev/null)"; wn_page="${wn_page:-0}"
        [[ "$wn_page" -eq 0 ]] && break
        wold="$(echo "$wacc" | jq 'length' 2>/dev/null)"; wold="${wold:-0}"
        wmerged="$(jq -cn --argjson a "$wacc" --argjson b "$wgot" '($a + $b) | unique_by(.webhook_identifier)' 2>/dev/null)"
        [[ -z "$wmerged" ]] && wmerged="$wacc"
        wnew="$(echo "$wmerged" | jq 'length' 2>/dev/null)"; wnew="${wnew:-$wold}"
        [[ "$wnew" -eq "$wold" ]] && break
        wacc="$wmerged"; wpage=$((wpage+1))
        [[ "$wpage" -gt 200 ]] && { echo "  WARNING: webhook pagination stopped after 200 pages for $SC — results may be incomplete" >&2; break; }
      done
      wn="$(echo "$wacc" | jq 'length' 2>/dev/null)"; wn="${wn:-0}"
      if [[ "${wn:-0}" -gt 0 ]]; then
        echo "$wacc" | jq -c '.[]' | while read -r w; do
          wid="$(echo "$w" | jq -r '.webhook_identifier')"
          [[ -z "$wid" || "$wid" == "null" ]] && continue
          echo "$w" | jq '{webhook_identifier, webhook_name, spec: (.spec | {webhook_type, connector_ref, repo_name, folder_paths: (.folder_paths // [])})}' \
            > "$D/webhooks/$wid.json"
        done
      fi
      ;;
  esac
  echo "  webhooks:   ${wn:-0}"

  # templates (versioned)
  TPL="$(paginate_content POST "template/api/templates/list?$QS&routingId=$ACC&templateListType=All&pageSize=1000" '{"filterType":"Template"}')"
  tn=$(echo "$TPL" | jq '(.data.content // []) | length' 2>/dev/null || echo 0)
  echo "  templates:  ${tn:-0}"
  if [[ "${tn:-0}" -gt 0 ]]; then
    echo "$TPL" | jq -c '(.data.content // [])[]' | while read -r t; do
      tid=$(echo "$t" | jq -r '.identifier'); ver=$(echo "$t" | jq -r '.versionLabel')
      echo "$t" | jq -r '.yaml // empty' > "$D/templates/${tid}__${ver}.yaml"
    done
  fi

  # service accounts (recreatable: identifier/name/email/description/tags).
  # This endpoint's response shape is inconsistent (`.data` is sometimes a
  # raw array, sometimes `{content:[...]}`) — paginate_content's EXTRACT
  # param normalizes either shape into `.data.content` for the rest of this
  # block, same as everywhere else.
  SA="$(paginate_content GET "ng/api/serviceaccount?$QS&routingId=$ACC&pageSize=1000" "" \
    '(.data | if type=="array" then . else .content end)')"
  san=$(echo "$SA" | jq '.data.content|length' 2>/dev/null || echo 0)
  echo "  svcaccounts:${san:-0}"
  if [[ "${san:-0}" -gt 0 ]]; then
    echo "$SA" | jq -c '.data.content[]' | while read -r sa; do
      sid=$(echo "$sa" | jq -r '.identifier')
      echo "$sa" | jq '{identifier,name,email,description,tags}' > "$D/serviceaccounts/$sid.json"
    done
  fi

  # user groups (custom only; skip harness-managed _all_users etc.)
  UG="$(paginate_content GET "ng/api/user-groups?$QS&routingId=$ACC&pageSize=1000")"
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
  # to capture full config. iacm_list_workspaces handles this endpoint's own
  # pagination convention (page/limit, raw array response).
  case "$SC" in
    */*)
      org="${SC%%/*}"; proj="${SC##*/}"
      WS="$(iacm_list_workspaces "$org" "$proj")"
      wsn=$(echo "$WS" | jq 'length' 2>/dev/null || echo 0)
      echo "  iacm ws:    ${wsn:-0}"
      if [[ "${wsn:-0}" -gt 0 ]]; then
        echo "$WS" | jq -r '.[].identifier' | while read -r wid; do
          [[ -z "$wid" ]] && continue
          curl -s "${AUTH[@]}" -H "harness-account: $ACC" -H 'accept: */*' \
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
  FS="$(paginate_content GET "ng/api/file-store?$QS&routingId=$ACC&pageSize=1000")"
  fcount=$(echo "$FS" | jq '(.data.content // []) | length' 2>/dev/null || echo 0)
  echo "  filestore:  ${fcount:-0} (manifest only; sample files, not replicated)"
  if [[ "${fcount:-0}" -gt 0 ]]; then
    echo "$FS" | jq '[.data.content[]|{identifier,name,type,parentIdentifier,mimeType,fileUsage,description}]' > "$D/filestore/_manifest.json"
  fi
done

# --- project mode: pull in account-/org-scoped dependencies -----------------
# The project's own resources can reference secrets/connectors defined one
# scope up (e.g. connectorRef: account.foo, provider_connector: org.bar).
# Project mode otherwise never touches account/org scope, so a fresh target
# won't have these yet and import fails with "No secret/connector exists
# with the id X". Best-effort: scan every exported JSON/YAML file's actual
# string VALUES (not a raw text grep — avoids false positives from a URL or
# path that merely contains "account." or "org." as a substring) for values
# matching exactly "<prefix>.<identifier>", then try each as a secret, then
# a connector, at that scope. Harness built-ins, and anything that resolves
# to neither (e.g. a user-group reference, or a Harness-native
# repository/template reference this tool doesn't migrate), are skipped
# with a note rather than failing the export.
if [[ "$PROJECT_MODE" -eq 1 ]]; then
  echo
  echo "Scanning $SRC_ORG/$SRC_PROJECT's exported resources for account-/org-scoped dependencies..."
  DEPD="$OUT/$(scope_dir "$SRC_ORG/$SRC_PROJECT")"
  DEP_BUILTINS="harnessSecretManager harnessImage"

  # detect_scoped_refs DIR PREFIX -> deduped bare identifiers referenced as
  # "<prefix>.<id>" anywhere inside DIR's JSON/YAML files.
  detect_scoped_refs() {
    local dir="$1" prefix="$2" f
    {
      while IFS= read -r f; do
        jq -r --arg p "$prefix" '[.. | strings | select(test("^" + $p + "\\.[A-Za-z0-9_-]+$"))] | .[]' "$f" 2>/dev/null
      done < <(find "$dir" -name '*.json' 2>/dev/null)
      while IFS= read -r f; do
        yq -o=json "$f" 2>/dev/null | jq -r --arg p "$prefix" '[.. | strings | select(test("^" + $p + "\\.[A-Za-z0-9_-]+$"))] | .[]' 2>/dev/null
      done < <(find "$dir" \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)
    } | sed "s/^${prefix}\.//" | sort -u
  }

  # resolve_dependency PREFIX ID SCOPE_QS OUTDIR HEADER
  #   Try ID as a secret, then as a connector, at the given scope.
  resolve_dependency() {
    local prefix="$1" id="$2" sqs="$3" outdir="$4" header="$5"
    case " $DEP_BUILTINS " in *" $id "*) echo "    skip $prefix.$id (Harness built-in)"; return;; esac
    local sec; sec="$(get "ng/api/v2/secrets/$id?$sqs&routingId=$ACC")"
    if echo "$sec" | jq -e '.data.secret' >/dev/null 2>&1; then
      local stype sname
      stype="$(echo "$sec" | jq -r '.data.secret.type')"
      sname="$(echo "$sec" | jq -r '.data.secret.name // "-"')"
      if ! grep -qF "## Scope: $header" "$SECMAN" 2>/dev/null; then
        { echo "## Scope: $header"; echo; } >> "$SECMAN"
      fi
      echo "- [ ] \`$id\`  (type: $stype, name: $sname)" >> "$SECMAN"
      echo "    dependency $prefix.$id -> secret (added to manifest, scope: $header)"
      return
    fi
    local conn; conn="$(get "ng/api/connectors/$id?$sqs&routingId=$ACC")"
    if echo "$conn" | jq -e '.data.connector' >/dev/null 2>&1; then
      mkdir -p "$outdir/connectors"
      echo "$conn" | jq '.data.connector' > "$outdir/connectors/$id.json"
      echo "    dependency $prefix.$id -> connector (exported to $outdir/connectors/$id.json)"
      return
    fi
    echo "    dependency $prefix.$id -> NOT FOUND as a secret or connector at scope '$header' (skipped — might be a user group, template, or Harness-native repository reference this tool doesn't migrate)"
  }

  ACCT_REFS="$(detect_scoped_refs "$DEPD" account)"
  if [[ -n "$ACCT_REFS" ]]; then
    mkdir -p "$OUT/account"
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      resolve_dependency account "$id" "accountIdentifier=$ACC" "$OUT/account" "account"
    done <<< "$ACCT_REFS"
  fi

  ORG_REFS="$(detect_scoped_refs "$DEPD" org)"
  if [[ -n "$ORG_REFS" ]]; then
    ORGDIR="$OUT/$(scope_dir "org:$SRC_ORG")"
    mkdir -p "$ORGDIR"
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      resolve_dependency org "$id" "accountIdentifier=$ACC&orgIdentifier=$SRC_ORG" "$ORGDIR" "org:$SRC_ORG"
    done <<< "$ORG_REFS"
  fi
fi

echo

# In project mode, warn (don't touch anything) if OUT_DIR contains a
# *different* project's leftover scope dir — export.sh only ever adds to
# what's in OUT_DIR, never cleans it, so a shared/reused OUT_DIR across runs
# leaves prior projects' data sitting there. import.sh will refuse to
# proceed for exactly this reason ("expects exactly one project scope"), but
# only after this whole export has already run — better to know now.
if [[ "$PROJECT_MODE" -eq 1 ]]; then
  MY_DIR="$(scope_dir "$SRC_ORG/$SRC_PROJECT")"
  STALE=()
  while IFS= read -r d; do
    b="$(basename "$d")"
    [[ "$b" == "$MY_DIR" ]] && continue
    STALE+=("$b")
  done < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -name '*__*' 2>/dev/null)
  if [[ "${#STALE[@]}" -gt 0 ]]; then
    echo "WARNING: '$OUT' also contains other project scope dir(s) from a previous run: ${STALE[*]}" >&2
    echo "  import.sh will refuse to proceed with more than one present. Use a fresh OUT_DIR" >&2
    echo "  per run (migrate.sh now defaults to one), or remove the stale dir(s) first." >&2
  fi
fi

echo "Export complete -> $OUT"
echo "Review $SECMAN before importing."
