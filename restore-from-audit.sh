#!/usr/bin/env bash
#
# restore-from-audit.sh — Reconstruct a DELETED project's resources from
# Harness's Audit Trail, into the same on-disk layout export.sh produces, so
# secrets.sh/import.sh can replay them into a target account exactly like a
# normal project-mode migration.
#
# Why this exists: once a project is deleted, its live NG APIs are gone —
# export.sh can no longer read it. But Harness's Audit Trail records every
# create/update/delete with a YAML snapshot of the affected resource. When a
# PROJECT is deleted, Harness cascades individual DELETE events to every
# child resource (pipelines, connectors, secrets, services, ...) at the same
# timestamp — each one's DELETE event carries the resource's last-known YAML
# in `oldYaml` (confirmed against real captures: GET /audit/api/audits/list
# for the event list, GET /audit/api/auditYaml?auditId=X for the YAML).
#
# Two-phase flow: (1) discover what was deleted, write a CSV listing every
# entity (Type, Identifier, StorageType, blank Restore, blank/pre-filled
# Branch, blank/pre-filled ConnectorRef, Name), then BLOCK — waiting for you
# to open it, mark Restore yes/no per row (and Branch for any remote
# pipeline/template, and ConnectorRef for any GitX webhook, you're
# restoring), save, and press Enter. (2) re-read and validate that file,
# looping back to the prompt if anything's wrong (missing branch/connectorRef
# on a yes row that needs one, garbage in Restore), then restore only what
# was approved. The PROJECT itself always restores — it's not a peer choice,
# everything else needs it to exist first.
#
# Special case — Git-backed (REMOTE) pipelines/templates: a DELETE event's
# oldYaml shows resolved *content*, not the storeType/connectorRef/repo/
# filePath pointer. That pointer only appears in a separate MOVE_TO_GIT
# action event for the same identifier, which can predate the deletion by
# any amount of time (moved to git months ago, deleted today) — so those get
# a second, wider-lookback search specifically for their most recent
# MOVE_TO_GIT event, used to pre-fill (not decide — you can override) the
# review file's Branch column. If found, the pipeline/template is restored
# as a git pointer (see import.sh's *.remote.json handling) instead of
# inline content — the actual file is assumed to still exist in the repo.
#
# Special case — GitX webhooks (resource.type GITX_WEBHOOK): these exist
# either as a SYSTEM-created side effect of a pipeline/template's Git link,
# or as a webhook a user creates directly (Project Settings -> Webhooks;
# confirmed via a real HAR capture of POST /v1/orgs/{org}/projects/{project}/
# webhooks, body {webhook_identifier, webhook_name, spec:{webhook_type,
# connector_ref, repo_name, folder_paths}}). Both kinds produce the exact
# same audit YAML shape (name/identifier/repoName/isEnabled/repoURL/
# webhookType/createdAt/lastUpdatedAt — confirmed against two separate real
# deletions), and critically that YAML NEVER includes connectorRef, even
# though the create API requires one. There is no way to recover it from
# the audit trail, so the review file's ConnectorRef column is REQUIRED for
# every GITX_WEBHOOK row marked Restore=yes — pick whichever connector in
# the target points at the same repo the row's Name/repoName references.
#
# NOT restored (by design, matching migrate.sh project-mode's existing
# scope): role assignments / user & group access, and anything whose
# resource.type this script doesn't recognize (logged, not silently
# dropped — check the "unsupported resource type" lines in the output).
#
# Usage:
#   HARNESS_TOKEN=<source-token> SRC_ACCOUNT_ID=<acct> SRC_BASE_URL=... \
#     SRC_ORG=<org> SRC_PROJECT=<project> LOOKBACK_DAYS=30 \
#     ./restore-from-audit.sh
#
# LOOKBACK_DAYS window is for finding what was DELETED. GIT_LOOKBACK_DAYS
# (default 730) is a separate, wider window for finding a git-backed
# pipeline/template's MOVE_TO_GIT event, which is not bounded by when it was
# deleted. If a pipeline was moved to git longer ago than GIT_LOOKBACK_DAYS,
# its review-file row won't have a pre-filled branch — increase
# GIT_LOOKBACK_DAYS if that matters, or just type the branch in by hand.
#
set -uo pipefail

TOKEN="${HARNESS_TOKEN:?set HARNESS_TOKEN to a source bearer token / x-api-key, with audit-trail read access}"
ACC="${SRC_ACCOUNT_ID:?set SRC_ACCOUNT_ID to the source account identifier}"
BASE="${SRC_BASE_URL:-https://prod5.harness.io/gateway}"
SRC_ORG="${SRC_ORG:?set SRC_ORG to the deleted project's org identifier}"
SRC_PROJECT="${SRC_PROJECT:?set SRC_PROJECT to the deleted project's identifier}"
OUT="${OUT_DIR:-./harness-export}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:?set LOOKBACK_DAYS to how many days back to search for the deletion}"
GIT_LOOKBACK_DAYS="${GIT_LOOKBACK_DAYS:-730}"
# Purely a pre-fill suggestion for the review file's Branch column when
# nothing was captured from MOVE_TO_GIT history — you can still override it
# per row before saving. Not a runtime fallback/skip decision anymore; the
# review file's validated Branch value is what actually gets used.
GIT_RESTORE_BRANCH="${GIT_RESTORE_BRANCH:-}"

if [[ "$TOKEN" == pat.* || "$TOKEN" == sat.* ]]; then
  AUTH=(-H "x-api-key: $TOKEN")
else
  AUTH=(-H "authorization: Bearer $TOKEN")
fi
H=("${AUTH[@]}" -H 'content-type: application/json' -H 'accept: */*')

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq required (brew install yq)" >&2; exit 1; }

NOW_MS=$(( $(date +%s) * 1000 ))
DELETE_START_MS=$(( NOW_MS - LOOKBACK_DAYS*86400*1000 ))
GIT_START_MS=$(( NOW_MS - GIT_LOOKBACK_DAYS*86400*1000 ))

D="$OUT/${SRC_ORG}__${SRC_PROJECT}"
mkdir -p "$OUT" "$D"/{connectors,services,environments,pipelines,templates,filestore,serviceaccounts,usergroups,iacm-workspaces,triggers,webhooks}
SECMAN="$OUT/secrets-manifest.md"
{
  echo "# Secrets manifest"
  echo
  echo "Secret VALUES cannot be exported (the API returns \`value: null\`), same as a live"
  echo "migration. These entries were reconstructed from the audit trail's YAML snapshot,"
  echo "which also never carries the value. Recreate each with its real value in the target."
  echo
} > "$SECMAN"

echo "=== Restoring $SRC_ORG/$SRC_PROJECT from audit trail (last $LOOKBACK_DAYS days) -> $OUT ==="

# paginate_audits BODY_JSON -> {"data":{"content":[...]}} merged across every
# page, deduped by auditId. Same defensive approach as export.sh's pipeline
# fix: pageIndex sent both via query string AND merged into the body, since
# we have no direct evidence which convention this endpoint actually honors
# (our test captures only ever showed page 0). Stops when a page adds
# nothing new — safe even if pageIndex is silently ignored.
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
      echo "  Response: $(echo "$resp" | head -c 300)" >&2
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

# auditYaml AUDIT_ID -> the entity's YAML (oldYaml, falling back to newYaml
# for the rare case oldYaml is empty but newYaml carries content, e.g.
# MOVE_TO_GIT events which only populate newYaml).
audit_yaml() {
  local aid="$1" resp
  resp="$(curl -s "${H[@]}" "$BASE/audit/api/auditYaml?accountIdentifier=$ACC&routingId=$ACC&auditId=$aid")"
  # jq's `//` only falls back on null/false, not "" — oldYaml comes back as
  # an empty STRING (not null) for MOVE_TO_GIT events, so a naive `a // b`
  # would wrongly "win" with the empty string instead of falling through to
  # newYaml. Check for blank explicitly instead.
  echo "$resp" | jq -r '
    (.data.oldYaml // "") as $o |
    if ($o | length) > 0 then $o else (.data.newYaml // "") end
  ' 2>/dev/null
}

echo "Querying deleted entities in $SRC_ORG/$SRC_PROJECT..."
DELETE_BODY="$(jq -cn --arg acc "$ACC" --arg org "$SRC_ORG" --arg proj "$SRC_PROJECT" \
  --arg st "$DELETE_START_MS" --arg et "$NOW_MS" \
  '{scopes:[{accountIdentifier:$acc, orgIdentifier:$org, projectIdentifier:$proj}], filterType:"Audit", actions:["DELETE"], startTime:$st, endTime:$et}')"
DELETES_RAW="$(paginate_audits "$DELETE_BODY" "list deleted entities")" || exit 1

# Defensive: filter client-side too, in case the server ignores our scope
# and/or actions filters (same lesson learned from pipeline pagination).
DELETES="$(echo "$DELETES_RAW" | jq -c --arg org "$SRC_ORG" --arg proj "$SRC_PROJECT" \
  '[.data.content[] | select(.action=="DELETE" and .resourceScope.orgIdentifier==$org and .resourceScope.projectIdentifier==$proj)]')"
# The same identifier can have more than one DELETE in the window (deleted,
# restored, deleted again) — keep only the latest per type+identifier, since
# restoring from a superseded delete would resurrect stale content.
DELETES="$(echo "$DELETES" | jq -c 'group_by(.resource.type + "/" + .resource.identifier) | map(max_by(.timestamp))')"
n_deletes="$(echo "$DELETES" | jq 'length')"
echo "Found $n_deletes deleted entit$([[ "$n_deletes" == 1 ]] && echo y || echo ies) in the last $LOOKBACK_DAYS days."
if [[ "$n_deletes" -eq 0 ]]; then
  echo "Nothing to restore — check LOOKBACK_DAYS covers when the project was deleted, and that" >&2
  echo "SRC_ORG/SRC_PROJECT are correct (this must match identifiers from BEFORE deletion)." >&2
  exit 1
fi

# ---- recover the PROJECT's own metadata (name/color/modules/description) --
PROJECT_EVENT="$(echo "$DELETES" | jq -c '[.[] | select(.resource.type=="PROJECT")] | .[0] // empty')"
if [[ -n "$PROJECT_EVENT" && "$PROJECT_EVENT" != "null" ]]; then
  paid="$(echo "$PROJECT_EVENT" | jq -r '.auditId')"
  pyaml="$(audit_yaml "$paid")"
  if [[ -n "$pyaml" ]]; then
    echo "$pyaml" | yq -o=json '.project' > "$OUT/_project.json"
    jq -n --slurpfile p "$OUT/_project.json" '{orgs: [], projects: $p}' > "$OUT/scope.json"
    rm -f "$OUT/_project.json"
    echo "  recovered project metadata: $(echo "$pyaml" | yq -r '.project.name')"
  fi
else
  echo "  NOTE: no PROJECT-level DELETE event found — recreating project with bare identifier (no recovered name/color/tags)." >&2
  # color can't be an empty string — Harness's project-create validates "may
  # not be empty" if the field is present at all — so fall back to a real
  # (arbitrary) hex color rather than "".
  jq -n --arg org "$SRC_ORG" --arg proj "$SRC_PROJECT" \
    '{orgs: [], projects: [{orgIdentifier:$org, identifier:$proj, name:$proj, description:"", color:"#0063f7", modules:[], tags:{}}]}' > "$OUT/scope.json"
fi

# ---- MOVE_TO_GIT cross-reference for PIPELINE/TEMPLATE -----------------
PIPE_TPL_IDS="$(echo "$DELETES" | jq -c '[.[] | select(.resource.type=="PIPELINE" or .resource.type=="TEMPLATE") | .resource.identifier] | unique')"
n_pt="$(echo "$PIPE_TPL_IDS" | jq 'length')"
GIT_LINKS='{}'
if [[ "$n_pt" -gt 0 ]]; then
  echo "Checking $n_pt pipeline/template identifier(s) for a Git-backed history (up to $GIT_LOOKBACK_DAYS days back)..."
  GIT_BODY="$(jq -cn --arg acc "$ACC" --arg org "$SRC_ORG" --arg proj "$SRC_PROJECT" \
    --arg st "$GIT_START_MS" --arg et "$NOW_MS" \
    '{scopes:[{accountIdentifier:$acc, orgIdentifier:$org, projectIdentifier:$proj}], filterType:"Audit", actions:["MOVE_TO_GIT"], startTime:$st, endTime:$et}')"
  MOVES_RAW="$(paginate_audits "$GIT_BODY" "list MOVE_TO_GIT history")" || MOVES_RAW='{"data":{"content":[]}}'
  # Latest MOVE_TO_GIT per identifier, defensively re-filtered client-side.
  MOVES="$(echo "$MOVES_RAW" | jq -c --arg org "$SRC_ORG" --arg proj "$SRC_PROJECT" '
    [.data.content[] | select(.action=="MOVE_TO_GIT" and .resourceScope.orgIdentifier==$org and .resourceScope.projectIdentifier==$proj)]
    | group_by(.resource.identifier) | map(max_by(.timestamp))')"
  n_moves="$(echo "$MOVES" | jq 'length')"
  echo "  found $n_moves MOVE_TO_GIT record(s)."
  while IFS= read -r mid; do
    [[ -z "$mid" ]] && continue
    mv_event="$(echo "$MOVES" | jq -c --arg id "$mid" '[.[] | select(.resource.identifier==$id)] | .[0] // empty')"
    [[ -z "$mv_event" || "$mv_event" == "null" ]] && continue
    maid="$(echo "$mv_event" | jq -r '.auditId')"
    myaml="$(audit_yaml "$maid")"
    [[ -z "$myaml" ]] && continue
    if echo "$myaml" | grep -q 'storeType:[[:space:]]*REMOTE'; then
      GIT_LINKS="$(jq -cn --argjson g "$GIT_LINKS" --arg id "$mid" --arg y "$myaml" '$g + {($id): $y}')"
      echo "    $mid -> Git-backed (will restore as a pointer, not content)"
    fi
  done < <(echo "$PIPE_TPL_IDS" | jq -r '.[]')
fi

# repoName -> connectorRef map, built from GIT_LINKS' MOVE_TO_GIT records —
# used only as a best-effort ConnectorRef prefill suggestion for GITX_WEBHOOK
# rows below (their audit YAML never carries connectorRef; see the header
# comment). If no pipeline/template in this project was ever git-linked to
# the webhook's repo, this stays empty and the row needs a manual value.
REPO_CONNECTORS='{}'
while IFS= read -r gy; do
  [[ -z "$gy" ]] && continue
  grepo="$(echo "$gy" | yq -r '.repo // ""' 2>/dev/null)"
  gcr="$(echo "$gy" | yq -r '.connectorRef // ""' 2>/dev/null)"
  [[ -z "$grepo" || -z "$gcr" ]] && continue
  REPO_CONNECTORS="$(jq -cn --argjson m "$REPO_CONNECTORS" --arg r "$grepo" --arg c "$gcr" '$m + {($r): $c}')"
done < <(echo "$GIT_LINKS" | jq -r '.[]')

# ---- build a CSV review file and wait for approval before restoring -------
# Every non-PROJECT entity gets a row (PROJECT is always restored — it's the
# container everything else needs, not a peer choice). Restore is left
# blank on purpose: blank/no means "don't restore this", so nothing comes
# back by accident from an unfilled row. Branch is pre-filled with whatever
# was captured from MOVE_TO_GIT (or GIT_RESTORE_BRANCH, if that's unset);
# ConnectorRef (GITX_WEBHOOK rows only) is pre-filled from REPO_CONNECTORS
# when a match is found. Both are suggestions only — you can override them.
#
# Column order matters: Name (freeform, can contain commas — e.g. "Hello,
# World") is LAST on purpose. Type/Identifier/StorageType are system-
# generated and comma-free by construction; Restore/Branch/ConnectorRef are
# user-typed but constrained to simple tokens (yes/no, a git ref, an
# identifier). Reading the file back only ever parses the first 6 fields by
# position and discards whatever's in position 7+ entirely — so a comma
# inside Name can never corrupt the fields that actually drive restore logic.
csv_escape() {
  local f="$1"
  if [[ "$f" == *,* || "$f" == *'"'* ]]; then
    f="${f//\"/\"\"}"
    printf '"%s"' "$f"
  else
    printf '%s' "$f"
  fi
}

REVIEW_CSV="$OUT/restore-review.csv"
echo "Building review file..."
{
  echo "Type,Identifier,StorageType,Restore,Branch,ConnectorRef,Name"
  while IFS= read -r ev; do
    [[ -z "$ev" ]] && continue
    rtype="$(echo "$ev" | jq -r '.resource.type')"
    [[ "$rtype" == "PROJECT" ]] && continue
    rid="$(echo "$ev" | jq -r '.resource.identifier')"
    aid="$(echo "$ev" | jq -r '.auditId')"
    rname="$(echo "$ev" | jq -r '.resource.labels.resourceName // .resource.identifier')"
    storeType="-"
    prefill_branch=""
    prefill_connref=""
    if [[ "$rtype" == "PIPELINE" || "$rtype" == "TEMPLATE" ]]; then
      is_git="$(echo "$GIT_LINKS" | jq -r --arg id "$rid" 'has($id)')"
      if [[ "$is_git" == "true" ]]; then
        storeType="remote"
        gy="$(echo "$GIT_LINKS" | jq -r --arg id "$rid" '.[$id]')"
        prefill_branch="$(echo "$gy" | yq -r '.branch // ""')"
        [[ -z "$prefill_branch" ]] && prefill_branch="$GIT_RESTORE_BRANCH"
      else
        storeType="inline"
      fi
    elif [[ "$rtype" == "GITX_WEBHOOK" ]]; then
      storeType="webhook"
      wyaml="$(audit_yaml "$aid")"
      if [[ -n "$wyaml" ]]; then
        wrepo="$(echo "$wyaml" | yq -r '.gitXWebhook.repoName // ""' 2>/dev/null)"
        [[ -n "$wrepo" ]] && prefill_connref="$(echo "$REPO_CONNECTORS" | jq -r --arg r "$wrepo" '.[$r] // ""')"
      fi
    fi
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "$rtype")" "$(csv_escape "$rid")" "$(csv_escape "$storeType")" \
      "" "$(csv_escape "$prefill_branch")" "$(csv_escape "$prefill_connref")" "$(csv_escape "$rname")"
  done < <(echo "$DELETES" | jq -c '.[]')
} > "$REVIEW_CSV"

n_rows=$(($(wc -l < "$REVIEW_CSV") - 1))
echo
echo "=== Review file ready: $REVIEW_CSV ($n_rows entit$([[ "$n_rows" == 1 ]] && echo y || echo ies), plus the project itself which always restores) ==="
echo "Open it in Excel/Numbers/Google Sheets (keep it saved as CSV — same filename/path), and for each row:"
echo "  - Restore: type yes or no (blank = no, nothing restores by accident)"
echo "  - Branch: REQUIRED if StorageType=remote and Restore=yes. Some rows may already have a"
echo "    suggested branch filled in from the audit trail — double check it's actually right."
echo "  - ConnectorRef: REQUIRED if StorageType=webhook and Restore=yes — the audit trail never"
echo "    records which connector a GitX webhook used, so pick whichever connector in the target"
echo "    points at that webhook's repo (Name/repoName tells you which repo). Some rows may"
echo "    already have a suggested connector filled in (only when a pipeline/template in this"
echo "    project was git-linked to the same repo) — double check it's actually right."
echo "Leave Type/Identifier/StorageType/Name alone; they're not read back."
echo

# csv_unquote FIELD -> strips a wrapping pair of double-quotes and unescapes
# doubled internal quotes, in case the spreadsheet app re-quoted fields on
# save (common even for plain values, depending on the app/export settings).
csv_unquote() {
  local f="$1"
  if [[ "$f" == \"*\" && "$f" == *\" ]]; then
    f="${f#\"}"; f="${f%\"}"
    f="${f//\"\"/\"}"
  fi
  printf '%s' "$f"
}
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Parallel indexed arrays, not an associative array — this codebase targets
# bash 3.2 (macOS's shipped /bin/bash), which doesn't have `declare -A`.
APPROVED_TYPES=()
APPROVED_IDS=()
APPROVED_BRANCHES=()
APPROVED_CONNREFS=()

# is_approved TYPE ID -> 0 and sets $APPROVED_BRANCH_FOR/$APPROVED_CONNREF_FOR
# if approved, else 1. Linear search over a handful-to-low-hundreds of rows —
# fine at this scale.
is_approved() {
  local t="$1" i="$2" idx=0 n=${#APPROVED_TYPES[@]}
  while [[ "$idx" -lt "$n" ]]; do
    if [[ "${APPROVED_TYPES[$idx]}" == "$t" && "${APPROVED_IDS[$idx]}" == "$i" ]]; then
      APPROVED_BRANCH_FOR="${APPROVED_BRANCHES[$idx]}"
      APPROVED_CONNREF_FOR="${APPROVED_CONNREFS[$idx]}"
      return 0
    fi
    idx=$((idx+1))
  done
  return 1
}

while :; do
  read -r -p "Press Enter once you've saved the file to continue (or type 'abort' to stop): " _reply
  if [[ "$_reply" == "abort" ]]; then
    echo "Aborted — nothing was restored. $REVIEW_CSV is still there if you want to resume by hand later." >&2
    exit 1
  fi
  if [[ ! -f "$REVIEW_CSV" ]]; then
    echo "Can't find $REVIEW_CSV — did it get moved or renamed? Put it back at that exact path and try again." >&2
    continue
  fi

  PROBLEMS=()
  APPROVED_TYPES=(); APPROVED_IDS=(); APPROVED_BRANCHES=(); APPROVED_CONNREFS=()
  row_num=0
  # `read` returns non-zero on a final line with no trailing newline, and
  # `while CMD; do BODY; done` only runs BODY when CMD succeeds — so a plain
  # `< "$REVIEW_CSV"` here would silently DROP the last row whenever the
  # spreadsheet app happens to save the file without a trailing newline
  # (confirmed live: a row marked "yes" got silently skipped because it was
  # last in the file). Feeding the loop an extra appended blank line
  # guarantees the true last row always gets its own terminated line; the
  # phantom empty line this adds hits the blank-line skip below and is a
  # no-op.
  while IFS=, read -r c1 c2 c3 c4 c5 c6 _rest; do
    row_num=$((row_num+1))
    [[ "$row_num" -eq 1 ]] && continue
    [[ -z "$c1" && -z "$c2" ]] && continue
    rtype="$(csv_unquote "$c1")"; rid="$(csv_unquote "$c2")"; stype="$(csv_unquote "$c3")"
    restore_val="$(trim "$(csv_unquote "$c4")")"; branch_val="$(trim "$(csv_unquote "$c5")")"
    connref_val="$(trim "$(csv_unquote "$c6")")"
    restore_norm="$(printf '%s' "$restore_val" | tr '[:upper:]' '[:lower:]')"
    case "$restore_norm" in
      ""|no|n) : ;;
      yes|y)
        if [[ "$stype" == "remote" && -z "$branch_val" ]]; then
          PROBLEMS+=("row $row_num ($rtype/$rid): marked yes but StorageType=remote and Branch is empty")
        elif [[ "$stype" == "webhook" && -z "$connref_val" ]]; then
          PROBLEMS+=("row $row_num ($rtype/$rid): marked yes but StorageType=webhook and ConnectorRef is empty")
        else
          APPROVED_TYPES+=("$rtype"); APPROVED_IDS+=("$rid"); APPROVED_BRANCHES+=("$branch_val"); APPROVED_CONNREFS+=("$connref_val")
        fi
        ;;
      *)
        PROBLEMS+=("row $row_num ($rtype/$rid): Restore must be 'yes' or 'no' (or blank) — got '$restore_val'")
        ;;
    esac
  done < <(cat "$REVIEW_CSV"; echo)

  if [[ "${#PROBLEMS[@]}" -gt 0 ]]; then
    echo "Found ${#PROBLEMS[@]} problem(s) in $REVIEW_CSV:" >&2
    printf '  - %s\n' "${PROBLEMS[@]}" >&2
    echo "Fix these, save the file, and press Enter again." >&2
    continue
  fi
  break
done

n_approved=${#APPROVED_IDS[@]}
echo "Restoring $n_approved approved entit$([[ "$n_approved" == 1 ]] && echo y || echo ies) (plus the project itself)."

# ---- reconstruct each deleted entity into export.sh's on-disk layout ------
echo "Reconstructing files..."
UNSUPPORTED=()
while IFS= read -r ev; do
  [[ -z "$ev" ]] && continue
  rtype="$(echo "$ev" | jq -r '.resource.type')"
  rid="$(echo "$ev" | jq -r '.resource.identifier')"
  aid="$(echo "$ev" | jq -r '.auditId')"
  [[ "$rtype" == "PROJECT" ]] && continue   # already handled above
  if ! is_approved "$rtype" "$rid"; then
    echo "    SKIP $rtype/$rid (not selected for restore in $REVIEW_CSV)"
    continue
  fi

  case "$rtype" in
    PIPELINE|TEMPLATE)
      is_git="$(echo "$GIT_LINKS" | jq -r --arg id "$rid" 'has($id)')"
      if [[ "$rtype" == "PIPELINE" ]]; then dir="$D/pipelines"; else dir="$D/templates"; fi
      if [[ "$is_git" == "true" ]]; then
        gy="$(echo "$GIT_LINKS" | jq -r --arg id "$rid" '.[$id]')"
        connectorRef="$(echo "$gy" | yq -r '.connectorRef // ""')"
        repo="$(echo "$gy" | yq -r '.repo // ""')"
        filePath="$(echo "$gy" | yq -r '.filePath // ""')"
        # Branch comes from the reviewed/validated CSV, not re-derived here —
        # is_approved already confirmed this exact row is "yes" and (since
        # StorageType=remote) guaranteed a non-empty Branch during validation.
        is_approved "$rtype" "$rid" >/dev/null
        branch="$APPROVED_BRANCH_FOR"
        # Even with storeType=REMOTE, Harness's create endpoint still
        # validates the request body as a structurally complete
        # pipeline/template (confirmed: "Pipeline without stages cannot be
        # saved" when sent a bare identifier-only shell) — it's not purely
        # "adopt the existing file, ignore the body". So the DELETE event's
        # last-known content (which we already have oldYaml for, same as
        # any inline entity) goes into the sidecar too, and import.sh sends
        # THAT as the body alongside the git pointer query params. It may
        # be stale relative to whatever's actually in git right now, but
        # it's structurally valid, which is what's required to pass create
        # validation at all.
        content_yaml="$(audit_yaml "$aid")"
        if [[ "$rtype" == "TEMPLATE" ]]; then
          ver="$(echo "$content_yaml" | yq -r '.template.versionLabel // "1"' 2>/dev/null)"
          fname="${rid}__${ver}.remote.json"
        else
          fname="${rid}.remote.json"
        fi
        jq -n --arg id "$rid" --arg cr "$connectorRef" --arg repo "$repo" --arg fp "$filePath" --arg br "$branch" --arg yaml "$content_yaml" \
          '{identifier:$id, connectorRef:$cr, repoName:$repo, filePath:$fp, yaml:$yaml} + (if $br=="" then {} else {branch:$br} end)' \
          > "$dir/$fname"
        echo "    $rtype/$rid -> $fname (git pointer, with last-known content as the create body)"
      else
        yaml="$(audit_yaml "$aid")"
        if [[ -z "$yaml" ]]; then echo "    SKIP $rtype/$rid (no YAML in audit record)" >&2; continue; fi
        if [[ "$rtype" == "TEMPLATE" ]]; then
          ver="$(echo "$yaml" | yq -r '.template.versionLabel // "1"' 2>/dev/null)"
          printf '%s' "$yaml" > "$dir/${rid}__${ver}.yaml"
        else
          printf '%s' "$yaml" > "$dir/${rid}.yaml"
        fi
        echo "    $rtype/$rid -> restored (inline)"
      fi
      ;;
    CONNECTOR)
      yaml="$(audit_yaml "$aid")"
      [[ -z "$yaml" ]] && { echo "    SKIP CONNECTOR/$rid (no YAML in audit record)" >&2; continue; }
      echo "$yaml" | yq -o=json '.connector' > "$D/connectors/$rid.json" 2>/dev/null
      echo "    CONNECTOR/$rid -> restored"
      ;;
    SECRET)
      yaml="$(audit_yaml "$aid")"
      [[ -z "$yaml" ]] && { echo "    SKIP SECRET/$rid (no YAML in audit record)" >&2; continue; }
      stype="$(echo "$yaml" | yq -r '.secret.type // "SecretText"' 2>/dev/null)"
      sname="$(echo "$yaml" | yq -r '.secret.name // empty' 2>/dev/null)"
      if ! grep -qF "## Scope: $SRC_ORG/$SRC_PROJECT" "$SECMAN"; then
        { echo "## Scope: $SRC_ORG/$SRC_PROJECT"; echo; } >> "$SECMAN"
      fi
      echo "- [ ] \`$rid\`  (type: $stype, name: ${sname:-$rid})" >> "$SECMAN"
      echo "    SECRET/$rid -> added to manifest (value cannot be recovered, same as a live export)"
      ;;
    SERVICE)
      yaml="$(audit_yaml "$aid")"
      [[ -z "$yaml" ]] && { echo "    SKIP SERVICE/$rid (no YAML in audit record)" >&2; continue; }
      printf '%s' "$yaml" > "$D/services/$rid.yaml"
      echo "    SERVICE/$rid -> restored"
      ;;
    ENVIRONMENT)
      yaml="$(audit_yaml "$aid")"
      [[ -z "$yaml" ]] && { echo "    SKIP ENVIRONMENT/$rid (no YAML in audit record)" >&2; continue; }
      printf '%s' "$yaml" > "$D/environments/$rid.yaml"
      echo "    ENVIRONMENT/$rid -> restored"
      ;;
    INFRASTRUCTURE|INFRASTRUCTURE_DEFINITION)
      yaml="$(audit_yaml "$aid")"
      [[ -z "$yaml" ]] && { echo "    SKIP INFRASTRUCTURE/$rid (no YAML in audit record)" >&2; continue; }
      envref="$(echo "$yaml" | yq -r '.infrastructureDefinition.environmentRef // empty' 2>/dev/null)"
      if [[ -z "$envref" ]]; then echo "    SKIP INFRASTRUCTURE/$rid (couldn't determine parent environment)" >&2; continue; fi
      mkdir -p "$D/environments/$envref.infra"
      printf '%s' "$yaml" > "$D/environments/$envref.infra/$rid.yaml"
      echo "    INFRASTRUCTURE/$rid -> restored (under environment $envref)"
      ;;
    SERVICE_ACCOUNT|SERVICEACCOUNT)
      yaml="$(audit_yaml "$aid")"
      [[ -z "$yaml" ]] && { echo "    SKIP SERVICE_ACCOUNT/$rid (no YAML in audit record)" >&2; continue; }
      echo "$yaml" | yq -o=json '.' > "$D/serviceaccounts/$rid.json" 2>/dev/null
      echo "    SERVICE_ACCOUNT/$rid -> restored (best-effort — verify shape)"
      ;;
    TRIGGER)
      yaml="$(audit_yaml "$aid")"
      [[ -z "$yaml" ]] && { echo "    SKIP TRIGGER/$rid (no YAML in audit record)" >&2; continue; }
      printf '%s' "$yaml" > "$D/triggers/$rid.yaml"
      echo "    TRIGGER/$rid -> restored"
      ;;
    GITX_WEBHOOK)
      yaml="$(audit_yaml "$aid")"
      [[ -z "$yaml" ]] && { echo "    SKIP GITX_WEBHOOK/$rid (no YAML in audit record)" >&2; continue; }
      wname="$(echo "$yaml" | yq -r '.gitXWebhook.name // "'"$rid"'"')"
      wrepo="$(echo "$yaml" | yq -r '.gitXWebhook.repoName // ""')"
      # ConnectorRef comes from the reviewed/validated CSV, not from the
      # audit YAML — it's never present there (see header comment). is_approved
      # already confirmed this exact row is "yes" and (since StorageType=
      # webhook) guaranteed a non-empty ConnectorRef during validation.
      is_approved "$rtype" "$rid" >/dev/null
      connectorRef="$APPROVED_CONNREF_FOR"
      jq -n --arg id "$rid" --arg name "$wname" --arg cr "$connectorRef" --arg repo "$wrepo" \
        '{webhook_identifier:$id, webhook_name:$name, spec:{webhook_type:"GIT", connector_ref:$cr, repo_name:$repo, folder_paths:[""]}}' \
        > "$D/webhooks/$rid.json"
      echo "    GITX_WEBHOOK/$rid -> restored (connectorRef: $connectorRef)"
      ;;
    *)
      UNSUPPORTED+=("$rtype/$rid")
      ;;
  esac
done < <(echo "$DELETES" | jq -c '.[]')

# --- account-/org-scoped dependencies -------------------------------------
# Same logic as export.sh's project mode: the restored project's own
# resources can reference secrets/connectors defined one scope up (e.g.
# connectorRef: account.foo). Those scopes weren't deleted (only the
# project was), so they're looked up LIVE against the source account rather
# than reconstructed from audit history.
get() { curl -s "${H[@]}" "$BASE/$1"; }
scope_dir() { case "$1" in account) echo account ;; org:*) echo "org-scope__${1#org:}" ;; */*) echo "${1%%/*}__${1##*/}" ;; esac; }

echo
echo "Scanning restored $SRC_ORG/$SRC_PROJECT for account-/org-scoped dependencies..."
DEP_BUILTINS="harnessSecretManager harnessImage"
MISSING_DEPS=()

detect_scoped_refs() {
  local dir="$1" prefix="$2" f
  {
    while IFS= read -r f; do
      jq -r --arg p "$prefix" '[.. | strings | select(test("^" + $p + "\\.[A-Za-z0-9_-]+$"))] | .[]' "$f" 2>/dev/null
    done < <(find "$dir" -name '*.json' 2>/dev/null)
    while IFS= read -r f; do
      yq -o=json "$f" 2>/dev/null | jq -r --arg p "$prefix" '[.. | strings | select(test("^" + $p + "\\.[A-Za-z0-9_-]+$"))] | .[]' 2>/dev/null
    done < <(find "$dir" \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)
    # .remote.json sidecars (git-linked pipelines/templates) embed their
    # last-known content as one opaque "yaml" STRING field — the *.json
    # pass above sees that whole multi-line blob as a single non-matching
    # value and never looks inside it. Re-parse just that field as its own
    # YAML document so a reference buried in its steps/stages is still
    # caught (confirmed via a direct test: this was a real, silent gap).
    while IFS= read -r f; do
      jq -r '.yaml // empty' "$f" 2>/dev/null | yq -o=json - 2>/dev/null \
        | jq -r --arg p "$prefix" '[.. | strings | select(test("^" + $p + "\\.[A-Za-z0-9_-]+$"))] | .[]' 2>/dev/null
    done < <(find "$dir" -name '*.remote.json' 2>/dev/null)
  } | sed "s/^${prefix}\.//" | sort -u
}

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
  echo "    dependency $prefix.$id -> NOT FOUND as a secret or connector at scope '$header' (skipped)"
  MISSING_DEPS+=("$prefix.$id (scope: $header) — referenced by the restored project but not found as a secret or connector; recreate it manually if needed")
}

ACCT_REFS="$(detect_scoped_refs "$D" account)"
if [[ -n "$ACCT_REFS" ]]; then
  mkdir -p "$OUT/account"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    resolve_dependency account "$id" "accountIdentifier=$ACC" "$OUT/account" "account"
  done <<< "$ACCT_REFS"
fi

ORG_REFS="$(detect_scoped_refs "$D" org)"
if [[ -n "$ORG_REFS" ]]; then
  ORGDIR="$OUT/$(scope_dir "org:$SRC_ORG")"
  mkdir -p "$ORGDIR"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    resolve_dependency org "$id" "accountIdentifier=$ACC&orgIdentifier=$SRC_ORG" "$ORGDIR" "org:$SRC_ORG"
  done <<< "$ORG_REFS"
fi

echo
echo "=== Restore reconstruction complete -> $OUT ==="
echo "Restored into: $D"
if [[ "${#UNSUPPORTED[@]}" -gt 0 ]]; then
  echo "NOT restored (unrecognized resource type — recreate manually if needed):" >&2
  printf '  - %s\n' "${UNSUPPORTED[@]}" >&2
fi
if [[ "${#MISSING_DEPS[@]}" -gt 0 ]]; then
  echo "MISSING account-/org-scoped dependencies (referenced by the restored project, not found in the source account — recreate manually if needed):" >&2
  printf '  - %s\n' "${MISSING_DEPS[@]}" >&2
fi
echo "Next: run secrets.sh then import.sh against this directory, with TGT_ORG/TGT_PROJECT set,"
echo "same as a normal project-mode migration. Review $SECMAN before importing."
