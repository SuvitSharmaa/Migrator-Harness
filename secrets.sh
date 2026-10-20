#!/usr/bin/env bash
#
# secrets.sh — Create PLACEHOLDER secrets in a target Harness account so that
# connectors / pipelines / IACM workspaces referencing them validate structurally.
#
# Secret VALUES can never be exported (the API returns value:null), so these are
# created with a dummy value/file. REPLACE THEM with real values afterwards in the
# target UI — placeholders only satisfy reference validation, not actual auth.
#
# Source of truth: harness-export/secrets-manifest.md (produced by export.sh).
# Each entry there carries identifier, type (SecretText|SecretFile), and scope.
#
# SecretText -> POST /ng/api/v2/secrets          (application/json)
# SecretFile -> POST /ng/api/v2/secrets/files     (multipart: spec + file)
# Both stored under the built-in 'harnessSecretManager'.
#
# Usage:
#   HARNESS_TOKEN=<target> TGT_ACCOUNT_ID=<acct> ./secrets.sh            # apply
#   HARNESS_TOKEN=<target> TGT_ACCOUNT_ID=<acct> DRY_RUN=1 ./secrets.sh  # preview
#   PLACEHOLDER_VALUE='changeme' ... ./secrets.sh                        # custom dummy
#   TGT_ORG=default TGT_PROJECT=AliceCopy ... ./secrets.sh               # project-mode:
#     redirect project-scoped manifest entries into this one target project.
#     Entries recorded under "account" or "org:<src-org>" (account-/org-scope
#     dependencies export.sh auto-detected) go to the target account, or to
#     org "org:$TGT_ORG", respectively — not folded into the target project.
#
set -uo pipefail

TOKEN="${HARNESS_TOKEN:?set HARNESS_TOKEN to a TARGET token / x-api-key}"
ACC="${TGT_ACCOUNT_ID:?set TGT_ACCOUNT_ID to the target account identifier}"
BASE="${TGT_BASE_URL:-https://app.harness.io/gateway}"
IN="${IN_DIR:-./harness-export}"
MANIFEST="${MANIFEST:-$IN/secrets-manifest.md}"
DRY="${DRY_RUN:-0}"
PH="${PLACEHOLDER_VALUE:-PLACEHOLDER_REPLACE_ME}"
SM="${SECRET_MANAGER:-harnessSecretManager}"
TGT_ORG="${TGT_ORG:-}"
TGT_PROJECT="${TGT_PROJECT:-}"

if [[ "$TOKEN" == pat.* || "$TOKEN" == sat.* ]]; then AUTH=(-H "x-api-key: $TOKEN")
else AUTH=(-H "authorization: Bearer $TOKEN"); fi

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "manifest '$MANIFEST' not found — run export.sh first" >&2; exit 1; }

if [[ -n "$TGT_ORG" && -z "$TGT_PROJECT" ]] || [[ -z "$TGT_ORG" && -n "$TGT_PROJECT" ]]; then
  echo "set both TGT_ORG and TGT_PROJECT for a project-scoped run, or leave both unset to mirror the manifest's own scopes" >&2
  exit 1
fi

# resolve_scope <scope-from-manifest> -> effective scope to write into.
# In project mode, a project-scoped manifest entry is redirected to the
# target project. But "account" stays "account" (the target account — not
# remapped, that scope is shared/global), and "org:<src-org>" becomes
# "org:<TGT_ORG>" (the project's own target org) rather than being folded
# into the target project — these come from export.sh auto-detecting
# account-/org-scoped dependencies the project's resources reference.
resolve_scope() {
  local s="$1"
  case "$s" in
    account) echo "account" ;;
    org:*)   if [[ -n "$TGT_ORG" ]]; then echo "org:$TGT_ORG"; else echo "$s"; fi ;;
    *)       if [[ -n "$TGT_ORG" && -n "$TGT_PROJECT" ]]; then echo "$TGT_ORG/$TGT_PROJECT"; else echo "$s"; fi ;;
  esac
}

PASS=0; FAIL=0; SKIP=0; declare -a FAILED
PHFILE="$(mktemp)"; printf '%s\n' "$PH" > "$PHFILE"
trap 'rm -f "$PHFILE"' EXIT

# scope_qs account|org:X|org/project  -> query string with the right identifiers
scope_qs() {
  case "$1" in
    account) echo "accountIdentifier=$ACC" ;;
    org:*)   echo "accountIdentifier=$ACC&orgIdentifier=${1#org:}" ;;
    */*)     echo "accountIdentifier=$ACC&orgIdentifier=${1%%/*}&projectIdentifier=${1##*/}" ;;
  esac
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

# create_text SCOPE ID
create_text() {
  local sc="$1" id="$2" qs; qs="$(scope_qs "$sc")"
  local org="" proj=""; read -r org proj <<< "$(split_org_proj "$sc")"
  local body; body="$(jq -n --arg id "$id" --arg sm "$SM" --arg v "$PH" \
    --arg org "$org" --arg proj "$proj" '
    {secret: ({type:"SecretText", name:$id, identifier:$id,
       spec:{secretManagerIdentifier:$sm, valueType:"Inline", value:$v}}
      + (if $org=="" then {} else {orgIdentifier:$org} + (if $proj=="" then {} else {projectIdentifier:$proj} end) end))}')"
  if [[ "$DRY" == "1" ]]; then printf '    [dry] text   %s @ %s\n' "$id" "$sc"; SKIP=$((SKIP+1)); return; fi
  local tmp code resp; tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$BASE/ng/api/v2/secrets?$qs&routingId=$ACC" \
    "${AUTH[@]}" -H 'content-type: application/json' --data-binary "$body")"
  resp="$(cat "$tmp")"; rm -f "$tmp"; tally "$code" "$resp" "text/$id @ $sc"
}

# create_file SCOPE ID  (multipart; placeholder file content)
create_file() {
  local sc="$1" id="$2" qs; qs="$(scope_qs "$sc")"
  local org="" proj=""; read -r org proj <<< "$(split_org_proj "$sc")"
  local spec; spec="$(jq -nc --arg id "$id" --arg sm "$SM" --arg org "$org" --arg proj "$proj" '
    {secret: ({type:"SecretFile", name:$id, identifier:$id,
       spec:{secretManagerIdentifier:$sm}}
      + (if $org=="" then {} else {orgIdentifier:$org} + (if $proj=="" then {} else {projectIdentifier:$proj} end) end))}')"
  if [[ "$DRY" == "1" ]]; then printf '    [dry] file   %s @ %s\n' "$id" "$sc"; SKIP=$((SKIP+1)); return; fi
  local tmp code resp; tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$BASE/ng/api/v2/secrets/files?$qs&routingId=$ACC" \
    "${AUTH[@]}" -F "spec=$spec;type=application/json" -F "file=@$PHFILE")"
  resp="$(cat "$tmp")"; rm -f "$tmp"; tally "$code" "$resp" "file/$id @ $sc"
}

# tally CODE RESP LABEL
tally() {
  local code="$1" resp="$2" label="$3"
  if [[ "$code" =~ ^2 ]]; then printf '    OK   %s (%s)\n' "$label" "$code"; PASS=$((PASS+1)); return; fi
  if echo "$resp" | grep -qiE 'already exists|DUPLICATE'; then
    printf '    SKIP %s (already exists)\n' "$label"; SKIP=$((SKIP+1)); return; fi
  printf '    FAIL %s (%s) %s\n' "$label" "$code" "$(echo "$resp" | jq -r '.message // empty' 2>/dev/null | head -c 140)" >&2
  FAIL=$((FAIL+1)); FAILED+=("$label ($code)")
}

echo "=== Creating placeholder secrets -> account $ACC @ $BASE (DRY_RUN=$DRY) ==="
echo "    placeholder value: '$PH'   secret manager: $SM"

# Parse the manifest: '## Scope: <scope>' headers, then '- [ ] `id`  (type: T, ...)'.
SCOPE=""
while IFS= read -r line; do
  case "$line" in
    '## Scope: '*) SCOPE="${line#"## Scope: "}" ;;
    '- [ ] '*|'- [x] '*)
      id="$(printf '%s' "$line" | sed -n 's/.*`\([^`]*\)`.*/\1/p')"
      type="$(printf '%s' "$line" | sed -n 's/.*type: *\([A-Za-z]*\).*/\1/p')"
      [[ -z "$id" || -z "$SCOPE" ]] && continue
      case "$type" in
        SecretFile) create_file "$(resolve_scope "$SCOPE")" "$id" ;;
        *)          create_text "$(resolve_scope "$SCOPE")" "$id" ;;   # default: SecretText
      esac
      ;;
  esac
done < "$MANIFEST"

echo
echo "=== Summary: $PASS created, $SKIP skipped, $FAIL failed ==="
if [[ ${#FAILED[@]} -gt 0 ]]; then printf '  - %s\n' "${FAILED[@]}"; fi
echo "IMPORTANT: these are PLACEHOLDER values. Replace each with the real secret"
echo "in the target before the connectors/pipelines will actually authenticate."
