---
name: pic-sure-cli
description: Use when operating a PIC-SURE All-in-One deployment from this repo — changing .env configuration, starting/stopping/restarting services, checking stack health, running setup/update/reset/uninstall/etl/demo-data, dev compose overlays, or automating any deployment task.
---

# Driving the pic-sure CLI

The `pic-sure` binary (build: `make -C cli build` → `cli/bin/pic-sure`) fronts
this repo's bash scripts. Full guide: `cli/README.md`. Machine contract
(JSON schemas, exit codes, per-script behavior): `docs/cli-contract.md` —
**authoritative; check it instead of guessing what a script does.**

## Iron rules

1. **Never edit `.env` directly.** Write keys via
   `pic-sure init --<field> VALUE` or `scripts/env-set.sh KEY VALUE`
   (secrets: `scripts/env-set.sh KEY --stdin`).
2. **Never run `docker compose` directly** — use `pic-sure
   up|down|restart|dev` (file selection + project name live in
   `scripts/compose.sh`).
3. **`restart` does NOT apply config changes.** Docker injects env only at
   container *creation*, and wizard-managed keys (AUTH_MODE, ports, DB
   settings…) are *derived* by init.sh into further variables. After
   changing configuration, re-run `pic-sure init` (idempotent: re-derives,
   rebuilds what changed, recreates) — exactly what the TUI's Reconfigure
   does. Plain `pic-sure up` only covers directly-interpolated keys;
   `restart` covers nothing and is for hung services only.
4. **Parse only `--json` output** (`status`, `preflight`;
   `schema_version: 1`). Human output is not a contract.
5. **Pass `--yes`** for anything that can prompt (reset, uninstall);
   prompts on a non-TTY are refused with an error naming the flag.
6. **Don't invent flags or behavior.** Every subcommand passes args
   byte-verbatim to its script — `<script>.sh --help` is the truth.
   To hand a reserved name (`--root --yes --non-interactive
   --no-animations`) to a script: `pic-sure etl -- --root /data`.

## Quick reference

```sh
pic-sure status --json                     # exit 0 always; inspect document
pic-sure preflight --json                  # exit 1 iff any check failed
pic-sure init --skip-auth --admin-email a@b.c   # non-interactive setup (see cli/README.md for all flags)
pic-sure update [--dry-run]
pic-sure up | down | restart [SERVICE...]
pic-sure --yes reset [--all]               # START OVER: wipe generated state to re-init
                                           #   (DB volume kept unless --all; repos/images kept)
pic-sure --yes uninstall [--keep-env] [--images] [--repos]
                                           # REMOVE the deployment: containers, networks,
                                           #   ALL volumes incl. DB. Those three are its ONLY
                                           #   other flags (there is no --all)
pic-sure dev list | up OVERLAY | off NAME  # run a service from local source (one-shot:
                                           #   any later plain up/update reverts it)
pic-sure migrate | seed-db | demo-data [DATASET|--all] | etl SUB | release-control [--branch B]
```

Health check (cron-safe): `pic-sure preflight --json` exit code, or
`status --json` → `.docker.daemon_reachable`, `.services[]`
(`state`/`health`), `.env.file_valid`, `.migrations.ready`.

Exit codes: `0` success *and* deliberate no-ops (declined prompt,
uninstall without `--yes`); `1` script/check failure; `2` usage;
`130/143` signal deaths.

## Gotchas

| Trap | Reality |
|---|---|
| `restart` after a config change | env not re-read — re-run `pic-sure init` (derived keys) or `up` (plain keys) |
| Editing `.env` with sed/editor | bypasses quoting/validation — env-set.sh |
| Parsing human `status` output | unstable — `--json` only |
| Assuming dev overlays persist | one-shot; plain `up`/update reverts to release images |
| DB auth errors after `reset` + re-init | `reset` keeps the DB volume; a fresh `.env` means new passwords the kept DB rejects. reset ALWAYS leaves a backup — recover with `cp .env.backup.<timestamp> .env && pic-sure init`; never repair grants via raw docker |
| `uninstall --all` | no such flag — uninstall already removes ALL volumes; `--images`/`--repos` extend it |
| `--yes` on commands without prompts | silently ignored (it means "never prompt", not "pass --yes") |
| Running TUI commands in automation | bare `pic-sure`/`dashboard` need a TTY; use subcommands |
