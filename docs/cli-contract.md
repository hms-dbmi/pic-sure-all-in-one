# CLI Contract

Machine-readable interfaces between the operational scripts and any frontend
(including the `pic-sure` CLI/TUI). A consumer may depend **only** on what is
documented here.

## Stability guarantee

- Every JSON document carries a top-level `schema_version` (currently `1`).
- **Additive** changes (new fields, new check names) do not bump
  `schema_version`; consumers must ignore unknown fields.
- **Breaking** changes (removing/renaming fields, changing types or enum
  values, changing exit-code semantics) bump `schema_version`.
- JSON is emitted on **stdout only**, as a single line followed by a newline.
  stderr may carry diagnostics in any mode and is not part of the contract.
- Human-readable output (without `--json`) is **not** a contract surface;
  do not parse it.

---

## `status.sh --json`

Read-only summary. **Always exits 0** (in both modes): statuses live in the
document, not the exit code. A non-zero exit means the script itself broke.

| Field | Type | Notes |
|---|---|---|
| `schema_version` | number | `1` |
| `command` | string | `"status"` |
| `env.file_present` | boolean | `.env` exists |
| `env.file_valid` | boolean\|null | `null` when absent; `false` when `.env` fails shell-syntax validation (remaining env-derived fields then show defaults) |
| `env.compose_project_name` | string | default `picsure` |
| `env.db_mode` | string | `local` \| `remote` (unvalidated passthrough) |
| `env.db_host` | string\|null | `null` unless `db_mode=remote` |
| `env.db_port` | string\|null | `null` unless `db_mode=remote` |
| `env.auth_mode` | string | default `required` |
| `env.picsure_image_tag` | string | default `LATEST` |
| `release_control.repo` | string | |
| `release_control.branch` | string | |
| `release_control.commit` | string\|null | `null` when unresolved |
| `release_control.refs` | object | exactly the ten `*_REF` keys, each a string |
| `repos[]` | array | one entry per managed sibling repo (currently 10) |
| `repos[].name` | string | directory name under `repos/` |
| `repos[].present` | boolean | `.git` directory exists |
| `repos[].current` | string\|null | branch, short SHA when detached; `null` when missing |
| `repos[].target` | string | ref from `.env`, default `main` |
| `repos[].state` | string | `clean` \| `dirty` \| `missing` |
| `docker.cli_present` | boolean | |
| `docker.compose_available` | boolean | `docker compose` v2 |
| `docker.daemon_reachable` | boolean | |
| `docker.compose_config_valid` | boolean\|null | `null` when not evaluated (daemon or compose unavailable) |
| `services[]` | array | empty when Docker is unreachable or no services exist — treat `[]` as "unknown", not "stack down" |
| `services[].name` | string | compose service name |
| `services[].state` | string\|null | compose `State` |
| `services[].health` | string\|null | `null` when the service reports no health |
| `services[].exit_code` | number\|null | |
| `database.mode` | string | `local` \| `remote` |
| `database.service` | string\|null | `picsure-db` when local, `null` when remote |
| `database.host` | string\|null | remote only |
| `database.port` | string\|null | remote only |
| `migrations.checked` | boolean | `false` when `.env` missing/invalid |
| `migrations.ready` | boolean\|null | exit status of `run-migrations.sh --check`; `null` when not checked |
| `migrations.message` | string | fixed human summary, not sub-command output |

### Example

```json
{
  "schema_version": 1,
  "command": "status",
  "env": {
    "file_present": true,
    "file_valid": true,
    "compose_project_name": "picsure",
    "db_mode": "local",
    "db_host": null,
    "db_port": null,
    "auth_mode": "required",
    "picsure_image_tag": "LATEST"
  },
  "release_control": {
    "repo": "https://github.com/hms-dbmi/pic-sure-baseline-release-control",
    "branch": "main",
    "commit": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
    "refs": {
      "PICSURE_REF": "main", "HPDS_REF": "main", "PSAMA_REF": "main",
      "FRONTEND_REF": "main", "MIGRATIONS_REF": "main",
      "DICTIONARY_REF": "main", "DICTIONARY_ETL_REF": "main",
      "VISUALIZATION_REF": "main", "LOGGING_REF": "main",
      "LOGGING_CLIENT_REF": "main"
    }
  },
  "repos": [
    { "name": "pic-sure", "present": true, "current": "main", "target": "main", "state": "clean" },
    { "name": "pic-sure-hpds", "present": false, "current": null, "target": "main", "state": "missing" }
  ],
  "docker": {
    "cli_present": true,
    "compose_available": true,
    "daemon_reachable": true,
    "compose_config_valid": true
  },
  "services": [
    { "name": "wildfly", "state": "running", "health": null, "exit_code": 0 },
    { "name": "hpds", "state": "running", "health": "healthy", "exit_code": 0 }
  ],
  "database": { "mode": "local", "service": "picsure-db", "host": null, "port": null },
  "migrations": { "checked": true, "ready": true, "message": "Migration inputs look valid" }
}
```

### Weight contract for the migration check

`migrations.*` is produced by `run-migrations.sh --check`, which is
**local-only**: env-var checks, SQL directory layout, a grep for legacy
tokens, and `docker compose config` (a CLI fork; no daemon, network, git, or
containers — measured ≈0.3 s total). Frontends may poll `status --json` on a
short interval (the TUI uses 15 s) because of this. If the check ever needs
git, network, or container access, that work MUST go behind a new opt-in
flag, not into the default path.

### Parsing inside status.sh

`services[]` is parsed from `docker compose ps --format json` with `run_jq`
(`scripts/lib/common.sh`): host `jq` when available, otherwise a dockerized
jq (`JQ_IMAGE`, default `ghcr.io/jqlang/jq:1.7.1`) which may **pull the image
on first use**. Both compose output shapes (NDJSON and a single JSON array)
are normalized.

---

## `preflight.sh --json`

Non-mutating validation. Exit code (both modes): **1 if any check has
`status: "fail"`, 0 otherwise**. Warnings never fail the run.

| Field | Type | Notes |
|---|---|---|
| `schema_version` | number | `1` |
| `command` | string | `"preflight"` |
| `network_checked` | boolean | `--network` was passed |
| `passed` | boolean | `false` iff any check failed; mirrors the exit code |
| `checks[]` | array | in execution order |
| `checks[].name` | string | stable identifier (catalog below) |
| `checks[].status` | string | `ok` \| `warn` \| `fail` |
| `checks[].message` | string | human text; **not** stable, do not match on it |

A `name` may appear more than once (e.g. `compose.generated` per missing
file). Consumers must treat checks as a list, not a map.

### Check-name catalog (schema_version 1)

| Name | Meaning |
|---|---|
| `args.unknown` | unknown command-line option (always `fail`) |
| `host.git`, `host.docker` | command lookup |
| `host.uuid` | uuidgen or /proc fallback |
| `host.jq` | optional; `warn` when absent (dockerized fallback) |
| `host.compose` | docker compose v2 available |
| `host.daemon` | docker daemon reachable |
| `files.<path>` | required file exists |
| `exec.<path>` | required script is executable |
| `syntax.<path>` | `bash -n` passes |
| `env.present` | `.env` exists (`warn` when missing) |
| `env.parse` | `.env` is valid shell (`fail` when not; per-var checks are then skipped) |
| `env.<VAR>` | required/expected variable is set (`warn` when not) |
| `env.db_mode`, `env.auth_mode` | enum validation (`fail` on bad value) |
| `compose.generated` | a generated file is missing (`warn`, one per file) |
| `compose.config` | `docker compose config` validation (or `warn` when skipped) |
| `release.repo`, `release.branch`, `release.cache` | release-control settings/cache |
| `jwt.repo`, `jwt.ref`, `jwt.jar` | jwt-creator settings/cache |
| `network.release-control`, `network.jwt-creator` | only with `--network` |
| `network.skipped` | `warn` emitted when `--network` not passed |

Additive: new check names may appear without a `schema_version` bump.

### Example

```json
{
  "schema_version": 1,
  "command": "preflight",
  "network_checked": false,
  "passed": false,
  "checks": [
    { "name": "host.git", "status": "ok", "message": "Git found: /usr/bin/git" },
    { "name": "host.daemon", "status": "fail", "message": "Docker daemon is not reachable." },
    { "name": "env.AUTH0_CLIENT_ID", "status": "warn", "message": "AUTH0_CLIENT_ID is not set." }
  ]
}
```

---

## `scripts/env-set.sh`

The single entry point for programmatic `.env` writes.

```
scripts/env-set.sh KEY VALUE              # set/overwrite KEY
scripts/env-set.sh KEY VALUE --no-force   # keep an existing non-empty value
scripts/env-set.sh KEY -- VALUE           # `--` ends options; VALUE may begin with `--`
scripts/env-set.sh KEY --stdin            # read VALUE from stdin
```

`--stdin` exists for secrets: the value never appears in a process argument
list. Trailing newlines are stripped; embedded newlines are rejected as
usual. `--stdin` and a positional VALUE are mutually exclusive (exit 2).

A literal `--` ends option parsing: every token after it is positional, so a
VALUE that begins with `--` (e.g. user-typed wizard input) is written verbatim
instead of being rejected as an unknown option. Programmatic callers that pass
arbitrary user-supplied values should use the `KEY -- VALUE` form.

- If `.env` does not exist it is **created from `.env.example` first**
  (frontends never copy or edit `.env` themselves).
- `KEY` must match `[A-Za-z_][A-Za-z0-9_]*`.
- `VALUE` must be single-line. Values containing characters outside
  `[A-Za-z0-9_.,:/@%+=-]` are written single-quoted (shell- and
  dotenv-compatible); plain values are written bare.
- Exit codes: `0` success; `2` usage error (bad key, missing args, multi-line
  value, missing `.env.example`).

## `scripts/compose.sh`

The single entry point for compose operations with this project's file
selection (adds `docker-compose.remote-db.yml` when `DB_MODE=remote`) and
project-name conventions. Frontends must not invoke `docker compose`
directly — including for read-only operations.

```
scripts/compose.sh up [SERVICE...]        # docker compose up -d ...
scripts/compose.sh down [ARGS...]
scripts/compose.sh restart [SERVICE...]
scripts/compose.sh ps [ARGS...]           # read-only
scripts/compose.sh logs [ARGS...]         # read-only
scripts/compose.sh config [ARGS...]       # read-only

scripts/compose.sh dev list               # read-only: available overlay names
scripts/compose.sh dev up OVERLAY         # base + docker-compose.dev-OVERLAY.yml,
                                          # up -d --no-deps --build <its service>
scripts/compose.sh dev off NAME           # base files only, up -d --no-deps;
                                          # NAME is a service or an overlay name
```

- Extra arguments pass through to docker compose verbatim
  (e.g. `ps --format json`, `logs -f wildfly`).
- Exit code is docker compose's exit code; `1` for usage errors.
- Refuses to run (exit 1, `[env]` message on stderr) when `.env` exists but
  is not valid shell syntax.
- `dev` overlays are one-shot: a later plain `up` or update recreates the
  service from the base files (release images). The overlay→service mapping
  is resolved by the script from the overlay file's `services:` key —
  frontends pass names only. `dev up` with a missing/unknown overlay exits 1
  listing the available names.

### `dev list` output format (stable)

`scripts/compose.sh dev list` prints the available overlay names to stdout,
**one name per line** (no header, no trailing punctuation). Each name `N`
corresponds to a `docker-compose.dev-N.yml` file in the checkout root.
Exit code is `0`; stdout is empty when no overlays exist. Consumers must
parse tolerantly: ignore blank lines and leading/trailing whitespace per line.
This format is a **stable contract surface** — consumers may depend on it.

---

## Exit codes by script

| Script | Semantics |
|---|---|
| `status.sh` | always `0` (informational; both modes) |
| `preflight.sh` | `0` passed, `1` any check failed (both modes) |
| `init.sh` | `0` success, non-zero on failure |
| `update.sh` | `0` success (incl. `--dry-run`), non-zero on failure |
| `reset.sh` | declined prompt → `0` (deliberate cancel); `--yes` skips the prompt; `1` on unknown option; non-zero on failure |
| `uninstall.sh` | without `--yes` prints the plan and exits `0`; `1` on unknown option; non-zero on failure |
| `release-control.sh` | `0` success, non-zero on failure |
| `run-migrations.sh` | `--check`: `0` valid / `1` invalid; otherwise Flyway's exit code passes through |
| `seed-db.sh` | `0` success (idempotent), non-zero on failure |
| `load-demo-data.sh` | `0` success, non-zero on failure |
| `etl.sh` | `0` success, `1` usage/failure |
| `scripts/env-set.sh` | `0` success, `2` usage error |
| `scripts/compose.sh` | docker compose's exit code; `1` usage error |

Non-interactive use: `reset.sh` requires `--yes` (it otherwise prompts on
stdin); `uninstall.sh` requires `--yes` to act at all. No other script
prompts.

## Versioning policy

The schema travels with the scripts: a frontend built for `schema_version` N
must refuse (or degrade gracefully) when it sees a different major version.
Because the CLI lives in this repository (`cli/`), script and consumer
changes land atomically in the same commit; out-of-tree consumers must pin
to a release tag.
