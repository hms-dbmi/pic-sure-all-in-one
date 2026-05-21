# Operations

## Fresh Install

```bash
cp .env.example .env
# Edit AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET, AUTH0_TENANT, ADMIN_EMAIL.
./preflight.sh
./init.sh
```

`init.sh` is for first install. It clones service repos, calls
`release-control.sh`, calls `build-images.sh`, generates secrets and
certificates, runs migrations, seeds the first admin, and starts Compose.

`preflight.sh` is non-mutating. Use `./preflight.sh --network` when you also
want to verify the configured release-control and jwt-creator refs are
reachable.

## Status

```bash
./status.sh
```

`status.sh` is read-only. It reports `.env` mode, release-control refs, service
repo state, Compose status when Docker is reachable, DB mode, and migration
input readiness.

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

Preview the update without changing repos, images, migrations, tokens, or
services:

```bash
./update.sh --dry-run
```

Dry run resolves release-control into a temporary `.env` and temporary
release-control checkout before reporting what would happen. To avoid network
access and inspect only the refs already stored in `.env`, run:

```bash
./update.sh --dry-run --offline
```

When published images are available:

```bash
./update.sh --pull-images
```

Detailed upgrade and release-control behavior is documented in
[upgrade-release-control.md](upgrade-release-control.md).

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
./bootstrap-remote-db.sh --check
./bootstrap-remote-db.sh
```

`--check` is non-mutating. It validates admin connectivity and reports whether
schemas/users already exist. After bootstrap, it also verifies app users can
connect to their schemas.

To exercise the remote DB path without RDS, run:

```bash
./scripts/smoke-remote-db.sh
```

## Day-2 Operations

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f
docker compose logs -f wildfly

# Restart one service
docker compose restart hpds

# Check service health and local repo state
docker compose ps
./status.sh
```

## Data Loading

Demo data:

```bash
./load-demo-data.sh              # NHANES
./load-demo-data.sh synthea      # Synthea 10k
./load-demo-data.sh 1000genomes  # 1000 Genomes
```

Compose ETL commands replace the old Jenkins ETL jobs:

```bash
./etl.sh --help
```

See [etl.md](etl.md).

## Multiple Local Stacks

Two all-in-ones can run on one Docker host when each checkout uses a distinct
Compose project and ports:

```env
COMPOSE_PROJECT_NAME=picsure2
HTTP_PORT=8080
HTTPS_PORT=8443
```

Container names must also be project-scoped. Prefer removing fixed
`container_name` entries from Compose before running two stacks at once.

## Troubleshooting

Service will not start:

```bash
docker compose logs <service-name>
docker compose ps
./status.sh
```

HPDS crash-loops:

If `HPDS_PROFILE` is set to `bch-dev` but no genomic data is loaded, HPDS may
crash-loop. Set `HPDS_PROFILE=` in `.env` and restart.

Database auth errors:

All generated DB passwords live in `.env`. If local bundled DB passwords get
out of sync, the destructive repair is:

```bash
docker compose down
docker volume rm picsure_picsure-db-data
./init.sh --force
docker compose up -d
```

Cannot log in:

- Verify `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET`, and `AUTH0_TENANT`.
- Ensure `ADMIN_EMAIL` matches the admin Google account.
- Check PSAMA logs: `docker compose logs psama`.

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
