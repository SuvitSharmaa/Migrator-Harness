#!/usr/bin/env bash
set -euo pipefail

# Runtime glue for launching MCP servers with GCP Secret Manager-backed values.
# This keeps secret material out of committed local MCP configuration.
#
# Usage in .mcp.json:
#   "command": "bash",
#   "args": ["scripts/mcp-with-secrets.sh", "harness-mcp-v2"],
#   "env": {
#     "GCP_SECRET_NAME": "harness-pat-harness0",
#     "GCP_PROJECT": "my-gcp-project",
#     "HARNESS_BASE_URL": "...",
#     ...
#   }

: "${GCP_SECRET_NAME:?GCP_SECRET_NAME must be set}"
: "${GCP_PROJECT:?GCP_PROJECT must be set}"

MCP_PACKAGE="${1:?Usage: mcp-with-secrets.sh <npm-package> [version]}"
MCP_VERSION="${2:-}"

if ! command -v gcloud &>/dev/null; then
  echo "ERROR: gcloud CLI not found. Install it or add to PATH." >&2
  exit 1
fi

export HARNESS_API_KEY
HARNESS_API_KEY="$(gcloud secrets versions access latest \
  --secret="$GCP_SECRET_NAME" \
  --project="$GCP_PROJECT" 2>/dev/null)" || {
  echo "ERROR: Failed to fetch secret '$GCP_SECRET_NAME' from project '$GCP_PROJECT'" >&2
  exit 1
}

source ~/.nvm/nvm.sh && nvm use default --silent

if [[ -n "$MCP_VERSION" ]]; then
  exec npx -y "${MCP_PACKAGE}@${MCP_VERSION}"
else
  exec npx -y "$MCP_PACKAGE"
fi
