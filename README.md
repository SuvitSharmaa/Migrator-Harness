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
| `migrate.sh` | Interactive orchestrator — asks account-vs-project-vs-restore, collects the rest, runs the right pipeline in order |
| `discover.sh` | Read-only inventory of a source account across all scopes |
| `export.sh` | Dump the source account (or a single project) to `./harness-export/` |
| `restore-from-audit.sh` | Reconstruct an already-**deleted** project from Harness's Audit Trail; writes a CSV for you to approve per-entity before restoring anything |
| `secrets.sh` | Create the exported secrets as **placeholders** in the target |
| `import.sh` | Replay the export into the target (idempotent upserts) |
| `connector.sh` | Standalone helper to upsert a few sample connectors (not part of the migration flow) |

## Three modes

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
- **Restore mode** — recovers a project that's already been **deleted**, by
  reconstructing it from Harness's Audit Trail instead of a live export
  (deleting a project cascades individual `DELETE` audit events to every
  child resource, each carrying the resource's last YAML in the event's
  `oldYaml` — confirmed against real captures). You'll be asked how many
  days back to search for the deletion *before* anything else, since that's
  specific to this mode. Beyond that, target remapping/secrets-as-
  placeholders/dependency detection are identical to project mode —
  `restore-from-audit.sh` just replaces `export.sh` as the data source;
  `secrets.sh`/`import.sh` run unchanged.

  **Two-phase, with a review gate in the middle** — nothing is restored
  sight-unseen:
  1. `restore-from-audit.sh` discovers what was deleted (deduped to the
     latest delete per identifier, in case something was deleted, restored,
     and deleted again) and writes `<OUT_DIR>/restore-review.csv` — one row
     per entity (every type: pipelines, connectors, secrets, services,
     environments, ...; the project itself is *not* a row — it always
     restores, since everything else needs it to exist first).
  2. The script **blocks**, printing the file path and waiting for Enter.
     Open the CSV in Excel/Numbers/Google Sheets, set `Restore` to `yes` or
     `no` per row (blank = no — nothing restores by accident), fill in
     `Branch` for any git-linked pipeline/template you're restoring (see
     below), save, and press Enter in the terminal.
  3. The script re-reads and validates the file. If anything's wrong (a
     `yes`+remote row with an empty `Branch`, garbage in `Restore`), it
     lists every problem and loops back to the prompt — fix and press
     Enter again, no need to restart. Once clean, it restores only the
     approved rows.

  - **Git-backed pipelines/templates**: a deleted entity's audit record
    shows resolved *content*, not its `storeType`/`connectorRef`/`repo`/
    `filePath` pointer — that only lives in a separate `MOVE_TO_GIT` audit
    event for the same identifier, which can predate the deletion by any
    amount of time. `restore-from-audit.sh` searches for that separately
    (`GIT_LOOKBACK_DAYS`, default 730 days) to pre-fill the CSV's `Branch`
    column as a *suggestion* — you decide the real value by what you put in
    the file. Restoring one goes via `pipeline/api/pipelines/import` —
    Harness's actual "Import From Git" API (confirmed via a real HAR
    capture of that UI action; see the API quirks section below for why
    this took three wrong turns to find).
  - **Not restored**: role assignments/access (regenerated fresh in target
    instead), file store, and anything outside the entity types
    `export.sh` already handles (connectors, secrets, services,
    environments, infrastructures, templates, pipelines, service accounts
    best-effort). Any audit `resource.type` this script doesn't recognize
    is logged, not silently dropped — check the output for "unsupported
    resource type" lines.
  - **Scope is deliberately project-level.** If the restored project
    references a secret/connector one scope up (`account.foo`, `org.bar`),
    the script checks whether it already exists in the source account/org
    (live, not audit history — those scopes were never deleted) and copies
    it over if so. If it *doesn't* exist there either, that's logged — both
    inline as it's found, and again in a "MISSING account-/org-scoped
    dependencies" list right before the final summary — rather than trying
    to auto-create or guess at it. This tool doesn't do account/org-level
    restoration; it flags the gap for you to close by hand.
  - Needs a source token with **Audit Trail read access**, in addition to
    the usual read access.

The easiest way to run any of these is the wizard:

```bash
./migrate.sh
```

It asks which mode you want, prompts for anything not already set via
environment variables (so it's safe to pre-export values and skip prompts, or
run it fully non-interactively), prints a plan for confirmation, then runs
`export.sh` → `secrets.sh` → `import.sh` for you. Logs land in
`<OUT_DIR>/_migrate-logs/`.

Each run defaults to its own timestamped subdirectory —
`./harness-export/<timestamp>__<srcOrg>_<srcProject>__to__<tgtOrg>_<tgtProject>`
(or `..._<timestamp>__account` for account mode) — rather than a shared
`./harness-export/`. `export.sh` only ever adds to whatever's in `OUT_DIR`,
never cleans it, so reusing the same directory across runs leaves prior
projects' exported data sitting there; `import.sh` will refuse to proceed if
it finds more than one project scope in project mode. Press Enter to accept
the generated default, or type your own path if you want a fixed/known
location (e.g. for a repeatable script).

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

### Fixing failures without re-running everything

`import.sh` doesn't exit when entities fail. After each pass it writes
`summary-run<N>.csv` into the export directory — every entity, its status, and
the **full** error — then waits for you:

| Input | What happens |
| --- | --- |
| `Enter` | Re-reads the CSV, applies your corrected `Branch` / `GitFilePath` / `ConnectorRef` to the underlying files, and retries **only** the rows still marked `failed` |
| `FORCE` | Writes `force-inline-review.csv`; mark `ConvertToInline=Yes` per row to rebuild unreachable git-linked pipelines/templates as **inline** entities from the content captured at delete time |
| `terminate` | Stops. The latest CSV is your record |

The common case this exists for: a restored git-backed pipeline whose audit
trail recorded `branch=master`, but the YAML actually lives on a different
branch (or was deleted from the repo). Check the repo yourself, correct the
`Branch` cell, press Enter. Rows marked `NOT RETRYABLE` — e.g. a pipeline whose
org-level template is missing — can't be fixed by editing those fields, so they
are kept in every round's CSV for the record but never re-attempted.

`FORCE` is a real change: a converted entity **stops being git-backed**. It's
opt-in per row, and `force-inline-review.csv` is the paper trail for re-linking
them to Git later. Rows whose recovered content is empty, or which reference a
template that failed this run, are refused — converting them would only fail
again the same way.

Full untruncated API responses for every failure land in `import-errors.log`.

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
| `IN_DIR` / `OUT_DIR` | import / export, restore | `./harness-export` |
| `DRY_RUN` | secrets, import | `0` |
| `PLACEHOLDER_VALUE` / `SECRET_MANAGER` | secrets | `PLACEHOLDER_REPLACE_ME` / `harnessSecretManager` |
| `LOOKBACK_DAYS` | restore | *(required)* — how many days back to search for the deletion |
| `GIT_LOOKBACK_DAYS` | restore | `730` — separate, wider window for finding a git-backed pipeline/template's `MOVE_TO_GIT` history |
| `GIT_RESTORE_BRANCH` | restore | unset — suggested branch to pre-fill in the review file's `Branch` column when nothing was captured; you can still override it per row before saving |

`migrate.sh` uses the same variable names, plus `MIGRATION_MODE` (`account`,
`project`, or `restore`), `SRC_HARNESS_TOKEN` / `TGT_HARNESS_TOKEN` (it maps
these to `HARNESS_TOKEN` for each underlying script since source and target
need different tokens).

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

- **Account-/org-scope dependency detection (`account.foo`/`org.bar`) only
  matches a whole field VALUE exactly** (`^account\.[A-Za-z0-9_-]+$`) — it
  doesn't parse Harness's `<+secrets.getValue("account.foo")>` expression
  syntax, for either inline or git-linked entities equally. It reliably
  catches connector-style bare references (`tokenRef: account.foo`), which
  is the common case, but a reference wrapped in an expression string
  inside a pipeline step is invisible to it either way — a real, known
  limit, not something either restore path handles better than the other.
  Separately: a git-linked pipeline/template's `.remote.json` sidecar
  stores its last-known content as one opaque `yaml` string field — the
  detector re-parses that field as its own YAML document specifically for
  `*.remote.json` files, since without that, even the bare-reference case
  above would be invisible for git-linked entities only (confirmed via a
  direct before/after test — this was a real, silent gap until fixed).
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
- **Audit Trail** (`restore-from-audit.sh`): `POST /audit/api/audits/list`
  takes `{scopes:[{accountIdentifier,orgIdentifier,projectIdentifier}],
  filterType:"Audit", startTime, endTime}` (epoch millis, as strings) and
  returns the same pagination envelope as everything else — confirmed
  needing the same defensive fix (send `pageIndex` both via query string and
  merged into the body). Each event has `auditId`, `resourceScope`,
  `resource:{type,identifier}`, `action`, `module`, `timestamp`. The actual
  YAML is a **separate** call, `GET /audit/api/auditYaml?auditId=X`, which
  returns `{oldYaml, newYaml}` — a delete event populates `oldYaml` with the
  entity's full last-known definition (confirmed: this is complete content,
  not a partial diff). One easy-to-miss gotcha: `oldYaml`/`newYaml` come
  back as `""` (empty string) rather than `null` when absent — jq's `//`
  fallback operator only catches `null`/`false`, so `.oldYaml // .newYaml`
  silently "wins" with the empty string instead of falling through; check
  for blank explicitly instead (see `restore-from-audit.sh`'s `audit_yaml`).
  A `MOVE_TO_GIT` action event's `newYaml` is the git pointer itself
  (`storeType: REMOTE`, `repo`, `connectorRef`, `filePath` — no `branch` seen
  in testing, hence `GIT_RESTORE_BRANCH`).
- **Recreating a git-linked pipeline/template is NOT `storeType=REMOTE` on
  the normal create endpoint** — that took three live-tested wrong guesses
  to rule out, each one informative: (1) a bare identifier-only body failed
  with "Pipeline without stages cannot be saved" → create still validates
  the body as a complete entity, it doesn't skip validation for git-linked
  ones; (2) real content but no `branch` failed with "Branch cannot be
  empty during create file GIT operation" → Harness's own wording confirms
  this is a **create-a-new-file** operation; (3) real content + branch
  still failed, this time as a conflict, because the file already exists
  at that path (deleting the Harness pipeline never touched the repo) —
  and my "already exists → try PUT update" fallback made it worse, since
  nothing was ever created on Harness's side to update. The actual answer,
  confirmed via a real HAR capture of Harness's "Import From Git" UI
  action: a **separate** endpoint, `POST /pipeline/api/pipelines/import`,
  query params `connectorRef`/`isHarnessCodeRepo=false`/`repoName`/
  `branch`/`filePath`, body just `{"pipelineDescription":""}` — no YAML, no
  identifier, no stages. Harness reads the pipeline straight from the git
  file. The template equivalent (`/template/api/templates/import`) is
  extrapolated from this confirmed shape, not independently verified.
- **Bash 3.2** (the shipped `/bin/bash` on macOS, which this repo targets)
  throws `unbound variable` under `set -u` for `"${ARR[@]}"` — and `[*]` —
  on a genuinely **empty** array; fixed in bash 4.4+. Every array expansion
  in this codebase that could realistically end up empty (e.g. `import.sh`'s
  `OTHERDIRS` when a restore/migration has no account-/org-scope
  dependencies to bring along) is guarded with a `${#ARR[@]}` length check
  first — don't remove those guards, and add one before expanding any new
  array that isn't unconditionally non-empty by construction.
