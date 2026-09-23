#!/usr/bin/env bash
#
# connector.sh — Upsert account-level Harness connectors via the NG Connectors API.
#
# Endpoints: GET  /ng/api/connectors/{identifier}   (existence check)
#            POST /ng/api/connectors                 (create)
#            PUT  /ng/api/connectors                 (update)
# Docs:      https://apidocs.harness.io/connectors
#
# For each connector the script checks whether one with the same identifier
# already exists at account scope. If it does, it issues a PUT (update); if not,
# a POST (create). Note: Harness keys connectors by *identifier*, not display
# name — identifier is the unique field, so existence is checked against it.
#
# The payload wraps the connector definition under a "connector" object.
# Read-only fields returned by the GET/list API (status, createdAt, lastModifiedAt,
# harnessManaged, gitDetails, entityValidityDetails, governanceMetadata, etc.) are
# NOT sent — only name/identifier/type/spec and scope identifiers.
#
# Account level => orgIdentifier and projectIdentifier are null/omitted.
#
# Usage:
#   ./connector.sh              # upsert all sample connectors below
#   ./connector.sh github       # upsert only the Github connector
#   ./connector.sh docker kms   # upsert a subset by name
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration — replace placeholders before running.
# ----------------------------------------------------------------------------
HARNESS_BASE_URL="${HARNESS_BASE_URL:-https://prod5.harness.io}"  # prod5 cluster
HARNESS_API_KEY="${HARNESS_API_KEY:-<YOUR_API_KEY>}"             # x-api-key (pat.xxx / sat.xxx)
ACCOUNT_ID="${ACCOUNT_ID:-ZmMyYzk4NDktZmU4Ny00Zm}"              # accountIdentifier

# ----------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------
API_PATH="/ng/api/connectors"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but not installed." >&2
  exit 1
fi

if [[ "$HARNESS_API_KEY" == "<YOUR_API_KEY>" ]]; then
  echo "WARNING: HARNESS_API_KEY still holds the placeholder value." >&2
  echo "         Set it via env var or edit this script before running." >&2
  echo "         Example: HARNESS_API_KEY=pat.xxx ./connector.sh" >&2
  echo >&2
fi

# json_field <json> <key>
#   Extract a top-level string field. Uses jq when available, else a grep/sed
#   fallback good enough for the simple identifier/name fields used here.
json_field() {
  local json="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty'
  else
    printf '%s' "$json" \
      | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
  fi
}

# connector_exists <identifier>
#   Returns 0 if a connector with this identifier exists at account scope
#   (HTTP 200), 1 if not found (404), and 2 on any other/error status so the
#   caller can abort rather than blindly create or update.
connector_exists() {
  local identifier="$1"
  local http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X GET "${HARNESS_BASE_URL}${API_PATH}/${identifier}?accountIdentifier=${ACCOUNT_ID}" \
    -H "x-api-key: ${HARNESS_API_KEY}" \
    -H 'Content-Type: application/json')"
  case "$http_code" in
    200) return 0 ;;
    404) return 1 ;;
    *)   echo "    WARNING: existence check returned HTTP ${http_code}" >&2; return 2 ;;
  esac
}

# upsert_connector <label> <connector-json>
#   <connector-json> is the inner "connector" object. The function injects the
#   account identifier, checks existence by identifier, then PUTs (update) if it
#   exists or POSTs (create) if not, and prints the HTTP status + body.
upsert_connector() {
  local label="$1"
  local connector_json="$2"

  # Inject accountIdentifier into the connector object and wrap under "connector".
  local payload
  if command -v jq >/dev/null 2>&1; then
    payload="$(jq -n \
      --arg acct "$ACCOUNT_ID" \
      --argjson conn "$connector_json" \
      '{connector: ($conn + {accountIdentifier: $acct, orgIdentifier: null, projectIdentifier: null})}')"
  else
    # Fallback: assume the connector_json already carries accountIdentifier
    # via the __ACCOUNT_ID__ token, substituted below.
    payload="{\"connector\": ${connector_json}}"
  fi
  payload="${payload//__ACCOUNT_ID__/$ACCOUNT_ID}"

  local identifier
  identifier="$(json_field "$connector_json" identifier)"
  if [[ -z "$identifier" ]]; then
    echo "==> ${label}"
    echo "    SKIPPED: could not determine connector identifier from definition." >&2
    echo
    return
  fi

  echo "==> Upserting connector: ${label} (identifier: ${identifier})"

  # Decide method based on existence.
  local method
  if connector_exists "$identifier"; then
    method="PUT"
    echo "    Exists — updating (PUT)."
  else
    local rc=$?
    if [[ $rc -eq 2 ]]; then
      echo "    Aborting this connector: existence check inconclusive." >&2
      echo
      return
    fi
    method="POST"
    echo "    Not found — creating (POST)."
  fi

  local http_code body tmp
  tmp="$(mktemp)"
  http_code="$(curl -sS -o "$tmp" -w '%{http_code}' \
    -X "$method" "${HARNESS_BASE_URL}${API_PATH}?accountIdentifier=${ACCOUNT_ID}" \
    -H "x-api-key: ${HARNESS_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "$payload")"
  body="$(cat "$tmp")"
  rm -f "$tmp"

  if [[ "$http_code" =~ ^2 ]]; then
    echo "    OK (${method} HTTP ${http_code})"
  else
    echo "    FAILED (${method} HTTP ${http_code})" >&2
  fi
  if command -v jq >/dev/null 2>&1; then
    echo "$body" | jq . 2>/dev/null || echo "$body"
  else
    echo "$body"
  fi
  echo
}

# ----------------------------------------------------------------------------
# Connector definitions (inner "connector" object, read-only fields stripped).
# Derived from the provided list response. Secrets are referenced by secret
# identifier (e.g. account.mp_harness_private_key), never inline.
# ----------------------------------------------------------------------------

# 1) Github connector using GitHub App authentication + API access.
read -r -d '' GITHUB_CONNECTOR <<'JSON' || true
{
  "name": "MP-Harness",
  "identifier": "MPHarness",
  "description": "",
  "tags": { "CreatedManuallyByGuosong": "" },
  "type": "Github",
  "spec": {
    "url": "https://github.com/machinepulse-ai",
    "validationRepo": "karpo-chat-api",
    "authentication": {
      "type": "Http",
      "spec": {
        "type": "GithubApp",
        "spec": {
          "installationId": "117359680",
          "applicationId": "3125495",
          "installationIdRef": null,
          "applicationIdRef": null,
          "privateKeyRef": "account.mp_harness_private_key"
        }
      }
    },
    "apiAccess": {
      "type": "GithubApp",
      "spec": {
        "installationId": "117359680",
        "applicationId": "3125495",
        "installationIdRef": null,
        "applicationIdRef": null,
        "privateKeyRef": "account.mp_harness_private_key"
      }
    },
    "delegateSelectors": [],
    "executeOnDelegate": false,
    "proxy": false,
    "ignoreTestConnection": false,
    "type": "Account"
  }
}
JSON

# 2) Docker Registry connector with anonymous auth (e.g. a public GAR registry).
read -r -d '' DOCKER_CONNECTOR <<'JSON' || true
{
  "name": "Harness GAR Connector",
  "identifier": "harnessImage",
  "description": "Harness internal connector",
  "tags": {},
  "type": "DockerRegistry",
  "spec": {
    "dockerRegistryUrl": "https://us-docker.pkg.dev/gar-prod-setup/harness-public",
    "providerType": "Other",
    "auth": { "type": "Anonymous" },
    "delegateSelectors": [],
    "executeOnDelegate": false,
    "proxy": false,
    "ignoreTestConnection": false
  }
}
JSON

# 3) AWS KMS secret manager connector using an assumed IAM role on the delegate.
read -r -d '' KMS_CONNECTOR <<'JSON' || true
{
  "name": "Harness Secrets Manager AWS KMS",
  "identifier": "harnessSecretManager",
  "description": null,
  "tags": {},
  "type": "AwsKms",
  "spec": {
    "credential": {
      "type": "AssumeIAMRole",
      "spec": { "delegateSelectors": [""] }
    },
    "kmsArn": null,
    "region": "us-west-2",
    "delegateSelectors": [],
    "ignoreTestConnection": false,
    "executeOnDelegate": true,
    "default": false
  }
}
JSON

# ----------------------------------------------------------------------------
# Dispatch — create all, or only the connectors named on the command line.
# ----------------------------------------------------------------------------
selected=("$@")
want() {
  [[ ${#selected[@]} -eq 0 ]] && return 0
  local name="$1"
  for s in "${selected[@]}"; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

want github && upsert_connector "MP-Harness (Github / GithubApp)" "$GITHUB_CONNECTOR"
want docker && upsert_connector "Harness GAR Connector (DockerRegistry / Anonymous)" "$DOCKER_CONNECTOR"
want kms    && upsert_connector "Harness Secrets Manager (AwsKms / AssumeIAMRole)" "$KMS_CONNECTOR"

echo "Done."
