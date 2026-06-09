# Upgrade and Release Control

This repository uses Docker Compose for update operations, but it still reads a
release-control build spec to choose service refs.

## Build Spec

`init.sh` and `update.sh` use:

```env
RELEASE_CONTROL_REPO=https://github.com/hms-dbmi/pic-sure-baseline-release-control
RELEASE_CONTROL_BRANCH=main
```

`release-control.sh` reads `build-spec.json`, fills component refs in `.env`,
and applies those refs to clean service repos. Missing build-spec entries fall
back to `main` with a warning.

To choose a different release-control branch:

```env
RELEASE_CONTROL_BRANCH=my-release-branch
```

For first install, you can also pass it directly:

```bash
./init.sh --release-control-branch my-release-branch
```

`init.sh` writes that branch into `.env` before resolving release-control refs.

## Dry Run

Preview release-control resolution only, without changing `.env`, the
release-control cache, or service repo checkouts:

```bash
./release-control.sh --dry-run
./release-control.sh --dry-run --branch my-release-branch
```

Preview an update without changing real state:

```bash
./update.sh --dry-run
```

The dry run resolves release-control into a temporary `.env` and temporary
checkout, then reports:

- release-control repo, branch, and commit
- resolved component refs
- local repo current refs and dirty/clean state
- image action
- migration actions
- token and service restart actions

For no-network checks, inspect the refs already stored in `.env`:

```bash
./update.sh --dry-run --offline
```

## Update

```bash
./update.sh
```

The update path:

1. Clones missing service repos.
2. Resolves release-control refs into `.env`.
3. Checks out clean service repos to the resolved refs.
4. Skips dirty service repos with a warning.
5. Rebuilds local images by default.
6. Runs migration check and migrations.
7. Rotates/syncs the PIC-SURE introspection token.
8. Starts/restarts affected Compose services.

When published images are available:

```bash
./update.sh --pull-images
```

To skip image rebuilding:

```bash
./update.sh --no-rebuild
```

## Supporting Checks

```bash
./status.sh
./preflight.sh --network
./scripts/test-release-control.sh
```

`scripts/test-release-control.sh` uses local temporary Git repos. It does not
require GitHub and does not touch real service repos.
