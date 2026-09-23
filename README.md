# Harness Account Replication Toolkit

Export every replicable resource from one Harness account and recreate it in
another, mirroring the org/project structure exactly. Built and verified for a
`prod5.harness.io` → `app.harness.io` migration.

## What it replicates

| Entity | Notes |
| --- | --- |
| Organizations / projects | Structure mirrored under the same identifiers (or remapped — see project mode below) |
| Connectors | Full spec; Harness built-ins (`harnessSecretManager`, `harnessImage`) skipped |
| Secrets | **Definitions only** — values can't be exported (see caveat below) |
| Templates | Raw YAML, all versions; created before connectors/pipelines that may reference them |
| Service accounts | identifier / name / email / description / tags |
| User groups | Custom groups only; `users[]` is blanked (principals aren't replicated) |
| Services | YAML, sent as a JSON DTO |
| Environments | YAML + `type`, sent as a JSON DTO |
| Infrastructures | YAML, per environment |
| Pipelines | Raw pipeline YAML; cross-pipeline "chained pipeline" stage references are rewritten to the target scope too |
| IACM workspaces | Full config incl. terraform/env variable references |

**Not replicated by design:** role assignments (bind to target-specific user
principals), file store (source entries are Harness auto-seeded sample manifests
the target already has), and the six unused modules (CCM/STO/SEI/Chaos/FME had no
configured resources in the source).

**Known gaps (discovered via real migrations, not yet handled):**
- Harness-native "repository" objects (e.g. IACM's Terraform module repos) —
  a different feature entirely, not exported/imported.
- Resources outside these entity types that a pipeline/workspace can depend on
  (e.g. Service Reliability Management "Monitored Services").
- Cross-pipeline chaining stages that reference a pipeline in a *different*
  project than the one being migrated (same-project chaining is rewritten
  correctly; cross-project chaining would need its own scope mapping).

If you hit one of these, the affected pipeline/workspace/connector will fail
import with a clear error — recreate that specific piece by hand.

## Scripts

| Script | Purpose |
| --- | --- |
| `migrate.sh` | Interactive orchestrator — asks account-vs-project, collects the rest, runs `export.sh` → `secrets.sh` → `import.sh` in order |
| `discover.sh` | Read-only inventory of a source account across all scopes |
| `export.sh` | Dump the source account (or a single project) to `./harness-export/` |
| `secrets.sh` | Create the exported secrets as **placeholders** in the target |
| `import.sh` | Replay the export into the target (idempotent upserts) |
| `connector.sh` | Standalone helper to upsert a few sample connectors (not part of the migration flow) |

## Two migration modes

- **Account mode** — mirrors every org/project under the source account into the
  target account, identifiers unchanged. This is the original behavior.
- **Project mode** — migrates a single project into a project in another
  account. Source and target org/project identifiers can differ (e.g. source
  `default/Alice` → target `default/AliceCopy`), so you can rename the project
  during the move. Only that project's own resources are touched, **except**:
  if the project's connectors/services/pipelines/IACM workspaces reference a
  secret or connector defined one scope up (e.g. `connectorRef: account.foo`,
  `provider_connector: org.bar`), `export.sh` detects that reference and pulls
  in just that specific secret/connector too — into the target account's
  account scope, or into org `TGT_ORG` (org-scoped dependencies always land in
  the same org as the migrated project). Everything else at account/org scope
  (service accounts, user groups, anything not actually referenced) is still
  assumed to already exist in the target and is not touched.
  ⚠️ The target **org** must already exist — only the target **project** is
  auto-created.

The easiest way to run either is the wizard:

```bash
./migrate.sh
```

It asks which mode you want, prompts for anything not already set via
environment variables (so it's safe to pre-export values and skip prompts, or
run it fully non-interactively), prints a plan for confirmation, then runs
`export.sh` → `secrets.sh` → `import.sh` for you. Logs land in
`<OUT_DIR>/_migrate-logs/`.

## Prerequisites

- `bash`, `curl`, `jq`, and `yq` (`brew install jq yq`)
- A token for **each** account:
  - **Source** — a UI session JWT (`Authorization: Bearer …`) or an API key, with read access
  - **Target** — an API key (`pat.…` / `sat.…`); the scripts auto-detect `pat.`/`sat.`
    prefixes and send `x-api-key`, otherwise `Authorization: Bearer`
- The correct cluster base URL per account (e.g. `https://prod5.harness.io/gateway`,
  `https://app.harness.io/gateway`). A token is only valid on its own cluster.

## Run order (manual, without the wizard)

`migrate.sh` just automates the sequence below — you can still run the three
scripts by hand if you want full control.

```bash
# 1. Export from the SOURCE account (whole account)
HARNESS_TOKEN=<source-token> \
  SRC_ACCOUNT_ID=<source-account-id> \
  SRC_BASE_URL=https://prod5.harness.io/gateway \
  ./export.sh

# 1b. ...or export a SINGLE PROJECT instead (project mode)
HARNESS_TOKEN=<source-token> \
  SRC_ACCOUNT_ID=<source-account-id> \
  SRC_BASE_URL=https://prod5.harness.io/gateway \
  SRC_ORG=default SRC_PROJECT=Alice \
  ./export.sh

# 2. Create PLACEHOLDER secrets in the TARGET (must run before import —
#    connectors/pipelines/workspaces fail validation if their secrets are missing)
#    Add TGT_ORG=<org> TGT_PROJECT=<project> here too if this was a project-mode export.
HARNESS_TOKEN=<target-pat> \
  TGT_ACCOUNT_ID=<target-account-id> \
  ./secrets.sh

# 3. Import everything into the TARGET
#    Add TGT_ORG=<org> TGT_PROJECT=<project> [TGT_PROJECT_NAME=<name>] for project mode —
#    the target org/project identifiers may differ from the source's.
HARNESS_TOKEN=<target-pat> \
  TGT_ACCOUNT_ID=<target-account-id> \
  TGT_BASE_URL=https://app.harness.io/gateway \
  ./import.sh
```

Add `DRY_RUN=1` to `secrets.sh` or `import.sh` to preview without writing.
`import.sh` and `secrets.sh` are idempotent — re-running upserts existing entities
and skips already-created secrets, so it's safe to run repeatedly.
`import.sh` discovers which scope directories the export actually produced
rather than assuming fixed org/project names, so this works for any account.

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
| `HARNESS_TOKEN` | export, secrets, import | *(required)* |
| `SRC_ACCOUNT_ID` / `SRC_BASE_URL` | export, discover | — / `https://prod5.harness.io/gateway` |
| `TGT_ACCOUNT_ID` / `TGT_BASE_URL` | secrets, import | *(required)* / `https://app.harness.io/gateway` |
| `SRC_ORG` / `SRC_PROJECT` | export | unset (= full account export) — set both to export one project only |
| `TGT_ORG` / `TGT_PROJECT` | secrets, import | unset (= mirror source scopes) — set both to redirect everything into one target project |
| `TGT_PROJECT_NAME` | import | unset (= keep the source project's name) — only used in project mode |
| `IN_DIR` / `OUT_DIR` | import / export | `./harness-export` |
| `DRY_RUN` | secrets, import | `0` |
| `PLACEHOLDER_VALUE` / `SECRET_MANAGER` | secrets | `PLACEHOLDER_REPLACE_ME` / `harnessSecretManager` |

`migrate.sh` uses the same variable names, plus `MIGRATION_MODE` (`account` or
`project`), `SRC_HARNESS_TOKEN` / `TGT_HARNESS_TOKEN` (it maps these to
`HARNESS_TOKEN` for each underlying script since source and target need
different tokens).

## Dependency order (why import.sh sequences things)

```
secrets → [account scope] → [org scope] → [project scope: templates → connectors →
service accounts → user groups → services → environments → infrastructures →
pipelines → IACM workspaces]
```

IACM workspaces reference connectors (provider/repository), which reference secrets,
so the order matters. This is also why `secrets.sh` must run before `import.sh`.
Templates run first within a scope because a connector (e.g. a template-based
`CustomSecretManager`) or a pipeline can reference one. Account-/org-scope
dependencies (auto-detected in project mode) are created before the project's
own resources, since those resources are what reference them.

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
- **Pagination**: several list endpoints (confirmed: pipelines; likely
  templates and others) silently cap their real page size well below a
  requested `pageSize=1000` and just return page 0 — no error, no `hasMore`
  flag you can trust, just fewer results than actually exist (a project with
  478 real pipelines returned only 25 with a single-page fetch). Every list
  call in `export.sh` now loops until a page contributes nothing new —
  connectors, secrets, services, environments, infrastructures, pipelines,
  templates, service accounts, user groups, file store, and IACM workspaces.
  Two of these needed their own handling rather than the shared
  `paginate_content` helper: service accounts (`.data` is sometimes a raw
  array, sometimes `{content:[...]}` — handled via `paginate_content`'s
  configurable `EXTRACT` param) and IACM workspaces (a `page`/`limit`
  convention with a raw array response, not `pageIndex`/`pageSize` +
  `.data.content` — its own `iacm_list_workspaces` helper). Stopping
  condition is "this page added nothing new" (dedup-checked), not just "page
  came back empty" — that also protects against an endpoint that doesn't
  honor the page parameter at all and just re-returns the same full result
  every call, which would otherwise loop-and-duplicate until a 200-page
  safety valve.
- **Templates**: create is `POST /template/api/templates`; update is
  `PUT /template/api/templates/update/{identifier}/{versionLabel}` — a
  template's identity is identifier **+** versionLabel, and versionLabel can't
  be changed on update (you'd create a new version instead). Re-running with
  the same exported version just updates that version's content.
- **Services/environments/infrastructures/pipelines/templates YAML bodies**
  embed their own top-level `orgIdentifier`/`projectIdentifier` — separate
  from the DTO/URL scope wrapping them. `environmentsV2`/`infrastructures`/
  pipeline-create all 400 if these don't match the DTO scope, so in project
  mode (target scope ≠ source scope) `import.sh` rewrites them before
  sending. Pipeline "chained pipeline" stages (`type: Pipeline`) go further
  and embed `org`/`project` fields naming *another* pipeline by scope — these
  are validated too and get rewritten the same way (matched narrowly: only
  objects with sibling `pipeline`+`org`+`project` keys, so unrelated fields
  aren't touched).
