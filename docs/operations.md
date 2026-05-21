# Operations

## Fresh Install

```bash
cp .env.example .env
# Edit AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET, AUTH0_TENANT, ADMIN_EMAIL.
./init.sh
```

`init.sh` is for first install. It clones service repos, calls
`release-control.sh`, calls `build-images.sh`, generates secrets and
certificates, runs migrations, seeds the first admin, and starts Compose.

## Release Control

`init.sh` and `update.sh` read the configured release-control
`build-spec.json`, write component refs into `.env`, and check out clean
service repos to those refs before building.

```env
RELEASE_CONTROL_REPO=https://github.com/hms-dbmi/pic-sure-baseline-release-control
RELEASE_CONTROL_BRANCH=main
```

Set `RELEASE_CONTROL_BRANCH` to choose a different branch of the release-control
repo. If a component is missing from the build spec, or a repo cannot check out
the requested ref, the scripts warn and fall back to `main`.

To resolve refs without changing service repo checkouts:

```bash
./release-control.sh --resolve-only
```

## Build Images

```bash
./build-images.sh
./build-images.sh --force
```

`build-images.sh` only builds local service images. It does not generate
secrets, run migrations, seed databases, or start services.

## Safe Update

```bash
./update.sh
```

The update command is non-destructive. It applies release-control refs to clean
service repos, rebuilds local images through `build-images.sh --force`, runs
migration checks and migrations, rotates/syncs the PIC-SURE introspection token,
and restarts services. It does not delete volumes.

When published images are available:

```bash
./update.sh --pull-images
```

## Remote MySQL/RDS

Set:

```env
DB_MODE=remote
DB_HOST=my-rds-instance.region.rds.amazonaws.com
DB_PORT=3306
DB_ROOT_USER=root
DB_ROOT_PASSWORD=...
```

For a first install, run:

```bash
./run-migrations.sh --check
./init.sh
```

`init.sh` calls `bootstrap-remote-db.sh` when `DB_MODE=remote`.
`bootstrap-remote-db.sh` creates/checks the `auth` and `picsure` schemas and
application users. Normal migration runs do not create remote schemas or users;
they only wait for the configured DB and run Flyway. To bootstrap remote DB
manually without a full install:

```bash
./bootstrap-remote-db.sh
```

To exercise the remote DB path without RDS, run:

```bash
./scripts/smoke-remote-db.sh
```

## Supported Site Configuration

- Auth0: `.env` only.
- First admin: `ADMIN_EMAIL` during bootstrap; additional admins use the UI.
- Custom IDP: configure PSAMA connections in the admin UI and add frontend
  `VITE_AUTH_PROVIDER_MODULE_*` values in `.env`, then rebuild `httpd`.
- SSL: replace `certs/server.crt`, `certs/server.key`, and
  `certs/server.chain`, then restart `httpd`.
- Custom trust certs: place `.crt`, `.cer`, or `.pem` files under
  `certs/trust/`; `init.sh`/`update.sh` imports them into WildFly and PSAMA
  truststores.
- TOS: set `TOS_ENABLED=true`; terms content is managed in the frontend admin UI.
- Analytics: set `VITE_GOOGLE_ANALYTICS_ID` or `VITE_GOOGLE_TAG_MANAGER_ID`
  before rebuilding the frontend.
- Auth modes: set `AUTH_MODE=required`, `open`, or `explore`.

## Retired Jenkins Workflows

Jenkins is no longer the target operations surface. GIC/Common Area jobs,
JupyterHub, banner config, SSLOffload, outbound email setup, user-token jobs,
PSAMA config download, Jenkins start/stop, and Jenkins release-control jobs are
retired from the Compose path. Compose still reads the release-control build
spec through `release-control.sh`.
