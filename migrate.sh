#!/usr/bin/env bash
#
# migrate.sh — interactive orchestrator for the Harness migration toolkit.
#
# Wires export.sh -> secrets.sh -> import.sh together in the right order and
# with the right environment variables. Asks whether you want to migrate an
# entire account (mirrors every org/project, as before) or a single project
# into a (possibly differently-named) project in another account.
#
# Hybrid prompting: any variable already set in the environment is used as-is
# and never prompted for, so this also works fully non-interactively, e.g.:
#
#   MIGRATION_MODE=project \
#   SRC_ACCOUNT_ID=... SRC_BASE_URL=https://prod5.harness.io/gateway SRC_HARNESS_TOKEN=... \
#   SRC_ORG=default SRC_PROJECT=Alice \
#   TGT_ACCOUNT_ID=... TGT_BASE_URL=https://app.harness.io/gateway TGT_HARNESS_TOKEN=... \
#   TGT_ORG=default TGT_PROJECT=AliceCopy \
#   DRY_RUN=1 ./migrate.sh
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq required (brew install yq)" >&2; exit 1; }

# ask VAR "prompt" [default] [secret(0/1)]
#   Prompts only if $VAR isn't already set — lets every value be pre-supplied
#   via env vars for non-interactive / scripted runs.
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

run_step() { # <label> <log-file> <cmd...>
  local label="$1" log="$2"; shift 2
  echo "=== $label ==="
  if "$@" 2>&1 | tee "$log"; then
    echo
    return 0
  fi
  echo "!! $label failed — see $log" >&2
  return 1
}

echo "=== Harness Migration Toolkit ==="
echo

# ---- 1. mode ---------------------------------------------------------------
MIGRATION_MODE="${MIGRATION_MODE:-}"
while [[ "$MIGRATION_MODE" != "account" && "$MIGRATION_MODE" != "project" ]]; do
  read -r -p "Migrate an entire (a)ccount or a single (p)roject? [a/p]: " choice
  case "$choice" in
    a|A|account) MIGRATION_MODE="account" ;;
    p|P|project) MIGRATION_MODE="project" ;;
    *) echo "Please enter 'a' or 'p'." ;;
  esac
done
export MIGRATION_MODE
echo "Mode: $MIGRATION_MODE"
echo

# ---- 2. source --------------------------------------------------------------
echo "-- Source account --"
ask SRC_ACCOUNT_ID    "Source account ID"
ask SRC_BASE_URL      "Source base URL (SaaS usually needs the /gateway suffix, e.g. https://app.harness.io/gateway)" "https://prod5.harness.io/gateway"
ask SRC_HARNESS_TOKEN "Source token (UI session JWT or API key, read access)" "" 1
echo

if [[ "$MIGRATION_MODE" == "project" ]]; then
  echo "-- Source project --"
  ask SRC_ORG     "Source org identifier"
  ask SRC_PROJECT "Source project identifier"
  echo
fi

# ---- 3. target --------------------------------------------------------------
echo "-- Target account --"
ask TGT_ACCOUNT_ID    "Target account ID"
ask TGT_BASE_URL      "Target base URL (SaaS usually needs the /gateway suffix, e.g. https://app.harness.io/gateway)" "https://app.harness.io/gateway"
ask TGT_HARNESS_TOKEN "Target token (API key pat./sat. recommended)" "" 1
echo

if [[ "$MIGRATION_MODE" == "project" ]]; then
  echo "-- Target project (press Enter to mirror the source identifiers) --"
  ask TGT_ORG          "Target org identifier" "$SRC_ORG"
  ask TGT_PROJECT      "Target project identifier" "$SRC_PROJECT"
  ask TGT_PROJECT_NAME "Target project display name (blank = keep source project's name)" ""
  echo
fi

# ---- 4. misc ----------------------------------------------------------------
ask OUT_DIR "Local export directory" "./harness-export"
if [[ -z "${DRY_RUN:-}" ]]; then
  if confirm "Dry-run secrets/import first (preview only, no writes to the target)?"; then
    DRY_RUN=1
  else
    DRY_RUN=0
  fi
fi
export DRY_RUN

# ---- 5. summary + confirm ---------------------------------------------------
echo "=== Plan ==="
echo "  Mode:            $MIGRATION_MODE"
echo "  Source account:  $SRC_ACCOUNT_ID @ $SRC_BASE_URL (token: $(mask "$SRC_HARNESS_TOKEN"))"
[[ "$MIGRATION_MODE" == "project" ]] && echo "  Source project:  $SRC_ORG/$SRC_PROJECT"
echo "  Target account:  $TGT_ACCOUNT_ID @ $TGT_BASE_URL (token: $(mask "$TGT_HARNESS_TOKEN"))"
if [[ "$MIGRATION_MODE" == "project" ]]; then
  echo "  Target project:  $TGT_ORG/$TGT_PROJECT${TGT_PROJECT_NAME:+ (name: $TGT_PROJECT_NAME)}"
fi
echo "  Export dir:      $OUT_DIR"
echo "  Dry run:         $DRY_RUN"
echo
confirm "Proceed with export -> secrets -> import?" || { echo "Aborted."; exit 1; }
echo

LOG_DIR="$OUT_DIR/_migrate-logs"
mkdir -p "$LOG_DIR"

# ---- 6. export ---------------------------------------------------------------
EXPORT_ENV=(HARNESS_TOKEN="$SRC_HARNESS_TOKEN" SRC_ACCOUNT_ID="$SRC_ACCOUNT_ID" SRC_BASE_URL="$SRC_BASE_URL" OUT_DIR="$OUT_DIR")
[[ "$MIGRATION_MODE" == "project" ]] && EXPORT_ENV+=(SRC_ORG="$SRC_ORG" SRC_PROJECT="$SRC_PROJECT")
run_step "1/3 export.sh (source -> $OUT_DIR)" "$LOG_DIR/export.log" \
  env "${EXPORT_ENV[@]}" "$SCRIPT_DIR/export.sh" || exit 1

# ---- 7. secrets ---------------------------------------------------------------
SECRETS_ENV=(HARNESS_TOKEN="$TGT_HARNESS_TOKEN" TGT_ACCOUNT_ID="$TGT_ACCOUNT_ID" TGT_BASE_URL="$TGT_BASE_URL" IN_DIR="$OUT_DIR" DRY_RUN="$DRY_RUN")
[[ "$MIGRATION_MODE" == "project" ]] && SECRETS_ENV+=(TGT_ORG="$TGT_ORG" TGT_PROJECT="$TGT_PROJECT")
run_step "2/3 secrets.sh (placeholder secrets -> target)" "$LOG_DIR/secrets.log" \
  env "${SECRETS_ENV[@]}" "$SCRIPT_DIR/secrets.sh" || exit 1

# ---- 8. import ---------------------------------------------------------------
IMPORT_ENV=(HARNESS_TOKEN="$TGT_HARNESS_TOKEN" TGT_ACCOUNT_ID="$TGT_ACCOUNT_ID" TGT_BASE_URL="$TGT_BASE_URL" IN_DIR="$OUT_DIR" DRY_RUN="$DRY_RUN")
[[ "$MIGRATION_MODE" == "project" ]] && IMPORT_ENV+=(TGT_ORG="$TGT_ORG" TGT_PROJECT="$TGT_PROJECT" TGT_PROJECT_NAME="$TGT_PROJECT_NAME")
run_step "3/3 import.sh ($OUT_DIR -> target)" "$LOG_DIR/import.log" \
  env "${IMPORT_ENV[@]}" "$SCRIPT_DIR/import.sh" || exit 1

# ---- 9. wrap-up ---------------------------------------------------------------
echo "=== Done ==="
ISSUES="$(grep -h '^    FAIL ' "$LOG_DIR"/*.log 2>/dev/null || true)"
if [[ -n "$ISSUES" ]]; then
  echo "Some entities failed — review:"
  echo "$ISSUES"
else
  echo "No failures reported."
fi
[[ "$DRY_RUN" == "1" ]] && echo "(this was a DRY RUN — nothing was written to the target; re-run with DRY_RUN=0 to apply)"
echo "Logs: $LOG_DIR"
echo "Reminder: replace placeholder secret values in the target UI (see $OUT_DIR/secrets-manifest.md)."
