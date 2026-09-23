# Harness Account Replication Toolkit

Export every replicable resource from one Harness account and recreate it in
another, mirroring the org/project structure exactly. Built and verified for a
`prod5.harness.io` → `app.harness.io` migration.

## What it replicates

| Entity | Notes |
| --- | --- |
| Organizations / projects | Structure mirrored under the same identifiers |
| Connectors | Full spec; Harness built-ins (`harnessSecretManager`, `harnessImage`) skipped |
| Secrets | **Definitions only** — values can't be exported (see caveat below) |
| Service accounts | identifier / name / email / description / tags |
| User groups | Custom groups only; `users[]` is blanked (principals aren't replicated) |
| Services | YAML, sent as a JSON DTO |
| Environments | YAML + `type`, sent as a JSON DTO |
| Infrastructures | YAML, per environment |
| Pipelines | Raw pipeline YAML |
| IACM workspaces | Full config incl. terraform/env variable references |

**Not replicated by design:** role assignments (bind to target-specific user
principals), file store (source entries are Harness auto-seeded sample manifests
the target already has), and the six unused modules (CCM/STO/SEI/Chaos/FME had no
configured resources in the source).

## Scripts

| Script | Purpose |
| --- | --- |
| `discover.sh` | Read-only inventory of a source account across all scopes |
| `export.sh` | Dump the source account to `./harness-export/` |
| `secrets.sh` | Create the exported secrets as **placeholders** in the target |
| `import.sh` | Replay the export into the target (idempotent upserts) |
| `connector.sh` | Standalone helper to upsert a few sample connectors (not part of the migration flow) |

## Prerequisites

- `bash`, `curl`, `jq`, and `yq` (`brew install jq yq`)
- A token for **each** account:
  - **Source** — a UI session JWT (`Authorization: Bearer …`) or an API key, with read access
  - **Target** — an API key (`pat.…` / `sat.…`); the scripts auto-detect `pat.`/`sat.`
    prefixes and send `x-api-key`, otherwise `Authorization: Bearer`
- The correct cluster base URL per account (e.g. `https://prod5.harness.io/gateway`,
  `https://app.harness.io/gateway`). A token is only valid on its own cluster.

## Run order (full migration)

```bash
# 1. Export from the SOURCE account
HARNESS_TOKEN=<source-token> \
  SRC_ACCOUNT_ID=<source-account-id> \
  SRC_BASE_URL=https://prod5.harness.io/gateway \
  ./export.sh

# 2. Create PLACEHOLDER secrets in the TARGET (must run before import —
#    connectors/pipelines/workspaces fail validation if their secrets are missing)
HARNESS_TOKEN=<target-pat> \
  TGT_ACCOUNT_ID=<target-account-id> \
  ./secrets.sh

# 3. Import everything into the TARGET
HARNESS_TOKEN=<target-pat> \
  TGT_ACCOUNT_ID=<target-account-id> \
  TGT_BASE_URL=https://app.harness.io/gateway \
  ./import.sh
```

Add `DRY_RUN=1` to `secrets.sh` or `import.sh` to preview without writing.
`import.sh` and `secrets.sh` are idempotent — re-running upserts existing entities
and skips already-created secrets, so it's safe to run repeatedly.

## ⚠️ Secret values are NOT migrated

The Harness API never returns secret material (`value: null` on export). `secrets.sh`
therefore creates every secret with the dummy value **`PLACEHOLDER_REPLACE_ME`**
(override with `PLACEHOLDER_VALUE=…`). This satisfies *reference validation* so the
dependent connectors, pipelines, and IACM workspaces import cleanly — but they will
**not actually authenticate** until you replace each placeholder with the real value
in the target UI.

The full checklist of secrets needing real values is in
`harness-export/secrets-manifest.md`.

## Environment variables

| Variable | Used by | Default |
| --- | --- | --- |
| `HARNESS_TOKEN` | all | *(required)* |
| `SRC_ACCOUNT_ID` / `SRC_BASE_URL` | export, discover | — / `https://prod5.harness.io/gateway` |
| `TGT_ACCOUNT_ID` / `TGT_BASE_URL` | secrets, import | *(required)* / `https://app.harness.io/gateway` |
| `IN_DIR` / `OUT_DIR` | import / export | `./harness-export` |
| `DRY_RUN` | secrets, import | `0` |
| `PLACEHOLDER_VALUE` / `SECRET_MANAGER` | secrets | `PLACEHOLDER_REPLACE_ME` / `harnessSecretManager` |

## Dependency order (why import.sh sequences things)

```
secrets → connectors → service accounts → user groups → services →
environments → infrastructures → pipelines → IACM workspaces
```

IACM workspaces reference connectors (provider/repository), which reference secrets,
so the order matters. This is also why `secrets.sh` must run before `import.sh`.

## API quirks captured here (so you don't rediscover them)

- **Services / environments / infrastructures** reject raw YAML — they need a JSON
  DTO with top-level `identifier`/`name`/(`type`) plus the YAML as a string field.
- **Service accounts** 500 on a base-path `PUT`; updates must target
  `/serviceaccount/{identifier}`.
- **IACM** routes are project-scoped, path-based
  (`/iacm/api/orgs/{org}/projects/{project}/workspaces`), and require the
  `harness-account` header. The list view nulls out repo/variables/connectors, so
  each workspace is fetched individually for full config. `terraform_variables` and
  `environment_variables` must be present on create (empty `{}` is fine).
- **File store** download endpoint returns HTTP 500 server-side; not used here.
