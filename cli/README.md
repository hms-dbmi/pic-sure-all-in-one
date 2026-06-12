# pic-sure — CLI & TUI for PIC-SURE All-in-One

`pic-sure` is a single Go binary that fronts the bash deployment scripts in
this repository. It gives evaluators and developers a guided setup wizard, an
animated terminal UI (landing menu, live dashboard, full-screen action
runner), and a scriptable CLI — without replacing anything:

> **Prime directive:** the bash scripts remain the single source of truth for
> every state mutation. The binary never edits `.env` itself (all writes go
> through `scripts/env-set.sh`), never invokes `docker compose` directly
> (all compose operations go through `scripts/compose.sh`), and every action
> it offers is exactly one script invocation. The scripts stay fully usable
> standalone, forever. The machine-readable contract between the binary and
> the scripts is documented in [`docs/cli-contract.md`](../docs/cli-contract.md).

This document serves two audiences: **humans** operating a deployment, and
**agents/automation** driving the CLI non-interactively. Agent-relevant rules
are gathered in [For agents & automation](#for-agents--automation) but the
command reference applies to both.

---

## Install

**From a release** (assets are named `pic-sure_<os>_<arch>.tar.gz`):

```sh
curl -fsSL https://raw.githubusercontent.com/hms-dbmi/pic-sure-all-in-one/main/cli/install.sh | bash
# or choose the destination:
#   install.sh --bin-dir /usr/local/bin     (default: ~/.local/bin)
```

The installer detects `uname -s`/`-m`, downloads the latest release plus
`checksums.txt`, and verifies the SHA-256 by explicit comparison
(`sha256sum`, falling back to `shasum -a 256`).

**From source** (Go 1.24+; `GOTOOLCHAIN=auto` fetches it if needed):

```sh
make -C cli build          # → cli/bin/pic-sure
pic-sure --version         # version (commit <sha>, built <date>)
```

## Quick start

```sh
cd pic-sure-all-in-one     # or pass --root /path/to/checkout from anywhere
pic-sure                   # opens the TUI landing page
```

On a fresh checkout (no `.env`) the landing menu offers **Set up PIC-SURE**:
an in-TUI wizard collects the required configuration (Auth0 credentials or a
deliberate skip, admin email, ports, auth mode, local/remote database),
shows a confirm summary, writes only the changed keys via
`scripts/env-set.sh`, then streams `init.sh` — clone, build, start, seed —
in the activity screen. On success, press enter to land in the dashboard.

On a configured checkout the menu offers the day-2 operations instead:
Dashboard, Update, Load your data…, Reconfigure, and a Developer options
submenu (Preflight check moves there once the stack is configured — it
matters most before and during the first install).

Everything in the TUI is also a plain CLI command (see
[CLI reference](#cli-reference)); the TUI is presentation, not capability.

---

## The TUI

Launch with bare `pic-sure` (context-aware landing) or `pic-sure dashboard`
(same app, starts on the dashboard screen; `esc` still goes to the landing).
The TUI requires a terminal: a bare invocation on a pipe prints help instead,
and `pic-sure dashboard` on a pipe errors.

### Landing

Animated starfield + PIC-SURE logo with a periodic shine sweep, and a
centered menu.

| Context | Menu |
|---|---|
| No `.env` (fresh) | Set up PIC-SURE · Preflight check · Quit |
| Configured | Dashboard · Update · Load your data… · Reconfigure · Developer options… · Quit |

Keys: `↑/↓` or `k/j` select · `enter` choose · `esc` back (in submenus) ·
`q`/`ctrl+c` quit.

**Load your data…** opens the guided load wizard (see
[Load your data](#load-your-data) for the full walkthrough): a step-by-step
screen that collects a phenotype CSV or a genomic VCF load, shows a confirm
summary, then streams the matching `etl.sh` orchestrator. The parameterless
maintenance/recovery ETL operations (`hydrate-dictionary`, `run-weights`,
`promote-genomic`, `public-1000genomes`) moved under **Developer options →
Maintenance / adv. ETL…**.

Consent model, in increasing friction:

- **Preflight** is read-only and runs immediately.
- **Mutating actions** (Update, Migrate, Seed, release-control apply) show a
  one-keystroke confirm describing exactly what the script does.
- **The load wizard** collects its inputs step by step and ends on a confirm
  summary that *is* the consent (it spells out the replacement / caveats).
- **Pickers** (demo dataset, maintenance ETL, dev overlays): the selection *is*
  the consent; every picker includes Cancel.
- **Destructive actions** (Reset, Uninstall) require typing the action name.

### Developer options submenu

Operations for people developing PIC-SURE itself (esc returns to the main
menu):

| Entry | Runs |
|---|---|
| Preflight check | `preflight.sh` — read-only host/config validation; runs immediately (also on the fresh main menu, where it matters most) |
| Run migrations | `run-migrations.sh` |
| Seed database | `seed-db.sh` |
| Load demo data… | picker over the demo datasets (NHANES, Synthea 10k, 1000 Genomes, or all three); runs `load-demo-data.sh`, **replacing** the phenotype data in the hpds-data volume, then re-hydrates the dictionary |
| Maintenance / adv. ETL… | picker over the parameterless `etl.sh` operations — `hydrate-dictionary`, `run-weights`, `promote-genomic`, `public-1000genomes` (instructions-only; prints the manual genomic-load steps, downloads nothing). Subcommands that take file arguments (`load-csv`, `load-vcf`, …) are CLI-only — see `pic-sure etl -- --help`. To load actual data use **Load your data…** on the main menu |
| Apply dev overlay… | picker over `docker-compose.dev-*.yml`; runs `scripts/compose.sh dev up <overlay>` — the overlay's service is recreated **from local source** (`up -d --no-deps --build`) |
| Revert dev overlay… | `scripts/compose.sh dev off <name>` — recreate from the release image |
| Release control… | nested submenu: Re-apply current branch · Dry run · Switch branch… (one-field input, prefilled with the current branch from `status --json`; expect a ~1s pause while it reads) |
| Reset… | one screen: pick the scope — **Keep the database** (`reset.sh --yes`) or **Full wipe** which also drops the DB volume, PIC-SURE images, and the Maven cache (`reset.sh --all --yes`) — plus an optional **reset sibling repos** toggle (adds `--repos`: git-resets the checkouts to their release refs, discarding uncommitted changes but **keeping** local branches & history), then type `reset` to confirm |
| Uninstall… | typed-word confirm, then `uninstall.sh --yes` |

Dev overlays are **one-shot**: a later plain `up` or update recreates the
service from the base compose files (release images).

### Setup / Reconfigure wizard

Runs embedded in the TUI (no terminal handoff). Two phases: the field form
(identity provider selector — Auth0 or a deliberate skip for alternate IdPs —
then the field groups), and a confirm summary of the final values. Notes:

- `esc` cancels: "setup cancelled — nothing written". On a form you have
  edited it first asks "Discard setup? (y/n)" so a reflexive `esc` does not
  silently throw away entered values; a pristine form closes immediately.
- Only **changed** keys are written, each via `scripts/env-set.sh`; secrets
  go via `KEY --stdin` and never appear in a process argument list.
- Reconfigure seeds from `.env.example` defaults with your current `.env`
  merged over them, so a sparse hand-edited file presents defaults instead
  of empty fields. This includes the release-control repo and branch/tag,
  prefilled with their current values.
- After consent, `init.sh` streams in the activity screen — the summary was
  the consent, there is no second dialog.
- Known upstream (huh) behavior: you cannot `shift+tab` backwards out of a
  field that currently fails validation; fix the value first.
- An invalid select value in a hand-edited `.env` (e.g. `AUTH_MODE=bogus`)
  is normalized to a valid option; the confirm summary shows exactly what
  will be written.

### Activity screen

Full-screen runner for actions launched from menus. Output is sanitized
terminal-style (progress bars collapse to their live state; colors are kept)
and hard-wrapped to the pane.

| State | Keys |
|---|---|
| Running | `esc`/`ctrl+c` → abort confirmation (`y` or a second `ctrl+c` aborts, `n`/`esc` dismisses) · `pgup/pgdn/↑/↓/home/end` scroll |
| Aborting | after a confirmed abort the footer reads "aborting — sent ctrl-c, waiting…"; if the child ignores the interrupt for 10s it escalates to "child ignoring interrupt — `K`: force kill" (`K` SIGKILLs the child's process group) |
| Aborted | footer shows the action's re-run-safety note (e.g. "init.sh is safe to re-run") · `esc`/`q` back to menu |
| Success | `✓ done in <duration>` · `enter` opens the dashboard · `esc`/`q` back to menu · `ctrl+c` quits |
| Failure | `✗ exited <code>`, output stays scrollable · `esc`/`q` back to menu · `ctrl+c` quits |

Aborts deliver ctrl-C through the PTY so the script's whole process group is
interrupted — nothing is killed silently mid-mutation. The 10s force-kill
(`K`) is the last resort for a child that traps or ignores SIGINT. Once a run
has finished, `ctrl+c` is the universal quit.

### Dashboard

Live view of the running stack: services pane (state + health, polled every
2s via `scripts/compose.sh ps`), status summary (every 15s via
`status.sh --json`), and a log follower for the selected service
(`scripts/compose.sh logs -f`).

| Key | Action |
|---|---|
| `↑/↓` `k/j` | select service (log pane follows) |
| `r` | restart selected service (one-keystroke confirm) |
| `u` | update (confirm → embedded runner pane) |
| `p` | preflight — read-only, runs immediately (no confirm) |
| `m` / `s` | migrate / seed-db (one-keystroke confirm) |
| `e` | demo-data dataset picker — the selection is the consent; it dispatches on pick (Cancel row backs out, no second confirm) |
| `R` | reset — the same one-screen dialog as the landing: scope (**Keep the database** `reset.sh --yes` / **Full wipe** `reset.sh --all --yes`) + optional **reset sibling repos** toggle (`--repos`), then type `reset` to confirm |
| `X` | uninstall (typed-word confirm) |
| `pgup/pgdn/home/end` | scroll logs (or action output while running) |
| `esc` | back to the landing menu |
| `q` / `ctrl+c` | quit |

Actions started *inside* the dashboard run in its right-hand pane so you can
watch services and logs react. While a pane action runs, `ctrl+c`/`esc` raise
a one-keystroke abort confirm (`y` aborts, `n` keeps it running) — the same
flow as the activity screen, so a reflexive `ctrl+c` never kills a mutation
silently. A confirmed abort sends ctrl-C; if the child ignores it for 10s the
footer offers `K` (force-kill the process group). After an abort the pane
shows the action's re-run-safety note. On a finished pane `esc`/`q` close it
and `ctrl+c` quits the app. The dashboard state (selection, log tail) resets
each time you enter it.

### Animations & appearance

| Control | Effect |
|---|---|
| `--no-animations` (global flag) | static starfield, no logo shine — layout and colors unchanged |
| `PIC_SURE_NO_ANIMATIONS=1` (or `true`/`yes`) | same as the flag |
| `PIC_SURE_NO_ANIMATIONS=0` (or `false`/`no`) | force animations on (overrides SSH auto-detect) |
| `SSH_CONNECTION` set | animations auto-disable (override with the above) |
| `PIC_SURE_STAR_GLYPHS` | comma-separated single-cell glyphs for near stars (e.g. Nerd Font icons: `set -Ux PIC_SURE_STAR_GLYPHS 󰚄` in fish). Invalid or wide entries are dropped; default is `✦` so unpatched fonts never see tofu |
| `NO_COLOR` | palette only (handled by lipgloss); never affects layout or motion |

Precedence: flag > env > SSH auto-detect > on.

---

## Load your data

The headline day-2 workflow. On a configured stack the main menu offers
**Load your data…**, a guided wizard that walks you through a phenotype CSV
load or a genomic VCF load step by step, ends on a confirm summary, then
streams the matching `etl.sh` orchestrator in the activity screen. Each step
prefills a sensible default; `esc` backs out. Both paths are equally available
headless via `pic-sure etl load-phenotype …` / `pic-sure etl load-genomic …`
(see [`docs/etl.md`](../docs/etl.md) for the full flag reference).

### Phenotype CSV (end to end)

1. **Main menu → Load your data… → Phenotype data (CSV).**
2. **Browse to your `allConcepts.csv`.** A file browser opens; pick the CSV.
   The file is a header row plus one row per fact, with these columns:
   `PATIENT_NUM`, `CONCEPT_PATH`, `NVAL_NUM`, `TVAL_CHAR`, `TIMESTAMP`. A tiny
   non-sensitive example lives at
   [`fixtures/etl/custom/allConcepts.csv`](../fixtures/etl/custom/allConcepts.csv).
3. **JVM heap.** Prefilled `4096` (MB) — the floor for <1M rows; raise to
   `8000`+ for larger CSVs.
4. **Dictionary.** Pick **Auto** — rebuild the dictionary from the loaded data
   (recommended) — or **Custom**, which then asks for `datasets.csv` and
   `concepts.zip` (and optionally the facet trio: `facet_categories.csv`,
   `facets.csv`, `facet_concepts.csv` — all three together or none; examples
   sit alongside the CSV fixture under `fixtures/etl/custom/`).
5. **Confirm.** The summary spells out that this **REPLACES existing HPDS
   phenotype data**; that summary is the consent.

On confirm it streams `etl.sh load-phenotype`, which chains the happy path:
`load-csv` (loads the CSV into HPDS) → the dictionary step (`hydrate-dictionary
--clear` for auto, or `load-dictionary-csv … --clear` + optional `load-facets`
for custom) → `run-weights` (recomputes search weights). When it finishes,
search works against the newly loaded concepts.

Headless equivalent:

```sh
pic-sure etl load-phenotype --file /path/allConcepts.csv          # auto dictionary
pic-sure etl load-phenotype --file /path/allConcepts.csv \
  --dictionary custom --datasets /path/datasets.csv --concepts /path/concepts.zip
```

### Genomic VCF

1. **Main menu → Load your data… → Genomic data (VCF).**
2. **Browse to your `vcfIndex.tsv`.** The VCF index TSV that lists the load.
3. **VCF directory (optional).** Point at a directory of VCF files, or skip it
   if the index already uses absolute paths.
4. **Genomic partition.** A name matching `^[A-Za-z0-9_-]+$`.
5. **JVM heap.** Prefilled `16000` (MB) — genomic loads need more headroom than
   phenotype; raise for large partitions.
6. **Promote this load to live now?** If yes, the staged data is promoted into
   the live genomic volume **with a backup** — the previous genomic data volume
   is kept until you remove it (promote is backup-safe).
7. **Enable the genomic HPDS profile now?** Enabling it sets
   `HPDS_PROFILE=bch-dev` and restarts HPDS so loaded genomic data is
   queryable. **Caveat: enabling the profile before genomic data is present
   crash-loops HPDS** — only enable it once promoted genomic data exists (the
   confirm summary surfaces a prominent warning if you enable the profile
   without promoting this load).
8. **Confirm**, then it streams `etl.sh load-genomic`: stage the VCF
   (`load-vcf`) → optional `promote-genomic --backup-current-data` → optional
   set `HPDS_PROFILE=bch-dev` + restart HPDS.

Headless equivalent:

```sh
pic-sure etl load-genomic --partition my_partition --vcf-index /path/vcfIndex.tsv \
  [--vcf-dir /path/to/vcfs] [--heap 16000] [--promote] [--enable-profile]
```

The orchestrators validate **all** inputs up front, before any HPDS mutation,
and on a step failure tell you the single command to re-run just that step. The
lower-level atomic `etl.sh` subcommands stay available for advanced/recovery
use — see [`docs/etl.md`](../docs/etl.md).

---

## CLI reference

### Global flags

Accepted anywhere on the command line; these names are **reserved**:

| Flag | Meaning |
|---|---|
| `--root DIR` | checkout root. Default: walk up from the working directory looking for `.env.example` + `docker-compose.yml` + `scripts/picsure-compose.sh` |
| `--yes`, `--non-interactive` | "never prompt": translated to the script's own `--yes` where supported (reset, uninstall); suppresses the init wizard (missing required values become an error instead of a prompt); silently ignored by scripts with nothing to confirm |
| `--no-animations` | static TUI (see above) |
| `--` | passthrough barrier: everything after it reaches the script byte-verbatim, even reserved names and `--help` (e.g. `pic-sure etl -- --root /data` hands `--root` to `etl.sh`; `pic-sure etl -- --help` shows `etl.sh`'s own usage). Place it **after** the subcommand — a `--` before any subcommand is ignored |

All other arguments pass through to the backing script **byte-verbatim**
(both `--flag value` and `--flag=value` forms, plus positionals). Each
subcommand's `--help` lists common flags; the script's own `--help` is
authoritative — reach it with the `--` barrier (e.g. `pic-sure etl -- --help`)
or by running the script directly (`./etl.sh --help`).

### Commands

| Command | Script | Common flags / notes |
|---|---|---|
| `init` | `init.sh` | guided setup (below) + passthrough `--force --verbose --log` |
| `update` | `update.sh` | `--dry-run --offline --no-rebuild --pull-images --verbose` |
| `status` | `status.sh` | `--json` (machine-readable, passed through untouched) |
| `preflight` | `preflight.sh` | `--network --json` |
| `etl` | `etl.sh` | `SUBCOMMAND [flags]` — run with no arguments for the list. High-level entry points: **`load-phenotype --file …`** and **`load-genomic --partition … --vcf-index …`** orchestrate the full load (see [Load your data](#load-your-data) and [`docs/etl.md`](../docs/etl.md)); the atomic subcommands (`load-csv`, `load-vcf`, `hydrate-dictionary`, `run-weights`, `promote-genomic`, …) are for advanced/recovery use |
| `reset` | `reset.sh` | `--all --repos --yes`; prompts without `--yes` (refused pre-exec on a non-TTY). `--repos` git-resets the sibling checkouts to their release refs — discards uncommitted changes, **keeps** local branches & history (never deletes `.git`) |
| `uninstall` | `uninstall.sh` | `--yes` required to act (plan-only otherwise) · `--keep-env --images --repos`. **`--repos` here DELETES `repos/` including git history** — use `reset --repos` to reset working trees instead |
| `release-control` | `release-control.sh` | `--dry-run --resolve-only --apply-only --branch BRANCH` |
| `seed-db` | `seed-db.sh` | — |
| `migrate` | `run-migrations.sh` | `--check --repair --no-restart --bootstrap-remote-db` |
| `demo-data` | `load-demo-data.sh` | `[nhanes\|synthea\|1000genomes]` `--all --verbose` |
| `up` / `down` / `restart` | `scripts/compose.sh <verb>` | service positionals / compose flags pass through |
| `dev` | `scripts/compose.sh dev` | `list` · `up OVERLAY` · `off SERVICE_OR_OVERLAY` (dev compose overlays; one-shot) |
| `dashboard` | — | opens the TUI on the dashboard screen |

### `pic-sure init` — guided setup

When `.env` does not exist, init collects the required configuration first —
interactively (the wizard) on a terminal, or from these flags. When `.env`
exists, `init.sh` runs directly; pass `--wizard` (terminal required, not
combinable with `--yes`) to review/update the configuration first. Only
changed keys are written; generated values are never touched. Provided flag
values are validated even against an existing `.env`.

| Flag | `.env` key | Notes |
|---|---|---|
| `--auth0-client-id` | `AUTH0_CLIENT_ID` | required unless `--skip-auth` |
| `--auth0-client-secret` | `AUTH0_CLIENT_SECRET` | required unless `--skip-auth`; secret |
| `--auth0-tenant` | `AUTH0_TENANT` | default `avillachlab` |
| `--admin-email` | `ADMIN_EMAIL` | always required; must be a Google account for the Auth0 path |
| `--http-port` / `--https-port` | `HTTP_PORT` / `HTTPS_PORT` | 1–65535; must differ |
| `--auth-mode` | `AUTH_MODE` | `required` \| `open` \| `explore` |
| `--db-mode` | `DB_MODE` | `local` \| `remote` |
| `--db-host` / `--db-port` | `DB_HOST` / `DB_PORT` | required when `--db-mode remote` |
| `--db-root-user` / `--db-root-password` | `DB_ROOT_USER` / `DB_ROOT_PASSWORD` | remote only; password required & secret |
| `--release-control-repo` | `RELEASE_CONTROL_REPO` | repo holding `build-spec.json`; change only if you fork the release control |
| `--release-control-branch` | `RELEASE_CONTROL_BRANCH` | branch or tag pinning component versions (default `main`); written to `.env` before `init.sh` runs |
| `--skip-auth` | — | create `.env` without Auth0 credentials (deliberate alternate-IdP setup) |
| `--wizard` | — | run the wizard over an existing `.env` |

---

## For agents & automation

### Rules

1. **Never edit `.env` directly.** Write keys with
   `scripts/env-set.sh KEY VALUE` (creates `.env` from `.env.example` when
   missing; shell-quotes special characters) or
   `scripts/env-set.sh KEY --stdin` for secrets.
2. **Never run `docker compose` directly** against this stack — use
   `pic-sure up|down|restart|dev` or `scripts/compose.sh`, which own the
   compose-file selection (remote-db overlay, project name).
3. **Parse only the JSON outputs.** Human output is not a contract and
   changes freely. `status --json` and `preflight --json` are stable
   (`schema_version: 1`); the full schemas, field tables, and the check-name
   catalog live in [`docs/cli-contract.md`](../docs/cli-contract.md).
4. **Pass `--yes`** (or `--non-interactive`) for anything that could prompt.
   Prompts on a non-TTY are refused *before* the script runs, with an error
   naming the flag.
5. The scripts are also directly invocable (`./status.sh --json` etc.) —
   the binary adds root discovery and TTY safety, not capability.

### Machine-readable status

```sh
pic-sure status --json     # always exits 0; inspect the document
pic-sure preflight --json  # exit 1 iff any check failed (mirrors .passed)
```

`status --json` highlights: `.env.file_present` / `.env.file_valid`,
`.release_control.branch/commit/refs`, `.repos[].state`
(`clean|dirty|missing`), `.docker.daemon_reachable`,
`.services[] {name,state,health,exit_code}`, `.migrations.ready`.
`preflight --json`: `.passed` plus `.checks[] {name,status,message}` with
stable check names (`host.*`, `env.*`, `compose.config`, `network.*`, …).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | success — including deliberate no-ops: declined `reset` prompt, `uninstall` without `--yes` (plan-only mode), `status` always |
| `1` | script failure (exit code propagated unchanged), `preflight` check failure |
| `2` | binary usage errors: unknown command or flag, `--root` without a value, non-interactive precondition failure (`reset` without `--yes` on a non-TTY), `env-set.sh` usage errors |
| `130`/`143` | script death by SIGINT/SIGTERM (128+N convention) |

Any other binary-side failure where no script ran — checkout-root discovery
failure, a script that could not be spawned, internal I/O errors — also
exits `2`. Exit `1` always means a script (or `preflight` check) actually
ran and failed.

### Non-interactive recipes

```sh
# Fresh setup with Auth0:
pic-sure init --auth0-client-id "$ID" --auth0-client-secret "$SECRET" \
  --admin-email admin@example.com

# Fresh setup, alternate IdP to be configured manually:
pic-sure init --skip-auth --admin-email admin@example.com

# Remote database:
pic-sure init --skip-auth --admin-email a@b.c --db-mode remote \
  --db-host db.example.com --db-port 3306 --db-root-password "$PW"

# Day 2:
pic-sure update --dry-run            # see what would change
pic-sure update                      # apply
pic-sure --yes reset --all           # wipe including the DB volume, no prompt
pic-sure --yes reset --repos         # also git-reset the sibling checkouts to
                                     #   release refs (keeps branches & history)
pic-sure --yes uninstall             # remove the stack (--yes is what arms it)
pic-sure dev up httpd-hmr            # frontend from local source w/ live reload
pic-sure dev off httpd               # back to the release image
```

Notes for unattended runs: `init` without a TTY (or with `--yes`) fails
fast, listing the missing required flags, rather than prompting. Secrets
passed as flags do appear in your process's argv — when that matters, write
them first via `scripts/env-set.sh KEY --stdin` and then run
`pic-sure init`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `not inside a pic-sure-all-in-one checkout: no directory containing .env.example + docker-compose.yml + scripts/picsure-compose.sh found` | run from inside the checkout or pass `--root DIR` |
| `the dashboard needs a terminal` | TUI commands require a TTY; on a pipe use `status --json` etc. |
| `parsing status JSON: invalid character '='` | the binary is pointed at an **old checkout** whose `status.sh` predates `--json`; update that checkout |
| Landing shows "Set up PIC-SURE" though you configured before | no `.env` in *this* checkout root — status values come from the discovered root; pass `--root DIR` to pin it |
| `.env: INVALID shell syntax` in the dashboard / `env.parse` preflight failure | the `.env` no longer parses as shell; fix it or restore the backup (`.env.bak.*`) |
| Animations off unexpectedly | you're on SSH; `PIC_SURE_NO_ANIMATIONS=0` re-enables |
| Star glyphs render as boxes | your terminal font lacks the configured glyph; unset `PIC_SURE_STAR_GLYPHS` (default `✦` is universal) |
| Dev-overlay service reverted by itself | by design: overlays are one-shot; any plain `up`/update recreates from base files |

## Development

```
cli/
  cmd/pic-sure/        main: version ldflags, exit-code propagation
  internal/commands/   cobra tree; global-flag scan; verbatim passthrough (DisableFlagParsing)
  internal/exec/       script runners: Run (live stdio, process group, signal fwd),
                       RunQuiet/RunQuietWithInput/RunOutput (captured, for TUI hosts)
  internal/project/    checkout-root discovery (marker files)
  internal/contract/   JSON contract types + parsers (the ONLY place schemas are known)
  internal/wizard/     data-driven field table, validation, single form definition
                       (NewForm serves both the CLI runner and the TUI screen), WriteChanged
  internal/actions/    shared action table (Describe + AbortNote per action),
                       PTY runner, PTY-output sanitizer (OutputBuffer)
  internal/tui/        unified app: landing/wizard/activity screens, starfield, logo
  internal/dashboard/  dashboard screen (panes, pollers, log follower)
  smoke/               end-to-end harness (runs in CI; Docker steps degrade gracefully)
```

| Target | Does |
|---|---|
| `make build` | build `bin/pic-sure` with version ldflags |
| `make test` | `go test ./...` (set `PICSURE_PTY_TEST=1` to include the PTY e2e) |
| `make lint` | `golangci-lint run` — version pinned in the Makefile; CI installs exactly that |
| `make smoke` | build + `smoke/run.sh` against this checkout |
| `make check` | test + lint + smoke |
| `make build-release GOOS=… GOARCH=…` | the release build (same ldflags as CI) |

Conventions enforced by tests: every wizard key must exist in `.env.example`
(drift guard); every action must carry an `AbortNote`; contract fixtures must
strict-decode; rendered frames must fit the terminal box; huh selects bind
`.Value()` **before** `.Options()`. Releases are tagged `v*`; CI builds the
`linux/darwin × amd64/arm64` matrix and publishes with checksums.
