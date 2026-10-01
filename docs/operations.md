# Operations

## Fresh Install

```bash
cp .env.example .env
# Edit AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET, AUTH0_TENANT, ADMIN_EMAIL.
./preflight.sh
./init.sh
```

`init.sh` is for first install. In order, it clones the four service repos,
generates secrets and certificates, calls `release-control.sh`, calls
`build-images.sh` (one Maven reactor pass over the `pic-sure` monorepo, then a
Docker build per service image), starts the databases, runs migrations, seeds
the first admin, and only then starts the application services.

That ordering is load-bearing: `seed-db.sh` refuses to run until Flyway has
applied migrations to both the `auth` and `picsure` schemas, and the database
consumers (psama, the operations service, and the dictionary services) gate on
their Flyway one-shots via `depends_on: … service_completed_successfully` —
and everything else waits on them transitively — so nothing starts against a
half-migrated schema. See [Migrations and Seeding](#migrations-and-seeding).

To install from a non-default release-control branch:

```bash
./init.sh --release-control-branch my-release-branch
```

`preflight.sh` is non-mutating. Use `./preflight.sh --network` when you also
want to verify the configured release-control and jwt-creator refs are
reachable.

## Status

```bash
./status.sh
./status.sh --deep-health
```

`status.sh` is read-only. It reports `.env` mode, release-control refs, service
repo state, Compose status when Docker is reachable, DB mode, and migration
input readiness.

Compose health only answers "is each container alive". For "does the stack
work", pass `--deep-health`: it execs into the gateway and reads
`/system/status`, the gateway's aggregate over its downstream services. It is
opt-in because it needs a running gateway and costs a round trip to every
service behind it.

Deep status also performs a bounded HPDS COUNT and metadata-health check, and
checks the HTML response's CSP. Data readiness is separate from liveness:
an empty or locked HPDS is not query-ready, even when its container is running.
Unavailable probes remain unknown. The dashboard's `h` key requests these
checks; regular status polling stays lightweight and retains the last explicit
result with its local last-checked date/time. State-changing dashboard actions
invalidate that result; read-only preflight preserves it. Unknown/unchecked
readiness is neutral information. The COUNT probe can emit a `query.sync` audit
event, but status never prints the count. Initialization and explicit data
loading are unchanged.

The introspection diagnostic checks configuration completeness only. It does
not verify the token's signature, expiry, or acceptance by PSAMA.

## Build Images

```bash
./build-images.sh
./build-images.sh --force
```

`build-images.sh` only builds local service images. It does not generate
secrets, run migrations, seed databases, or start services.

Every Java service comes out of one Maven reactor run over the `pic-sure`
monorepo checkout — `mvn clean install` inside `maven:3-amazoncorretto-25`
(Java 25), with `~/.m2` in a named Docker volume so repeat builds reuse the
cache. Each service's Dockerfile then copies its own module's jar out of that
shared reactor output, so a build never mixes new and stale jars. `--force`
re-runs the reactor even when all images already exist.

The frontend (`hms-dbmi/pic-sure-httpd`) builds from `PIC-SURE-Frontend`
separately. It bakes `VITE_*` values and the theme into the image, so it is
rebuilt whenever those build inputs change — tracked as a hash label on the
image, no `--force` needed.

Only explicitly configured `VITE_*` values are baked into the image.
`PICSURE_THEME` supplies `VITE_THEME`; unconfigured fields use the frontend's
application/API defaults, not its example environment. `init.sh` sets
`VITE_CONFIG_MODE=override`, so explicit environment values win over admin
configuration for the same field, including branding.

Use `scripts/compose.sh dev up httpd` for a compiled frontend or
`scripts/compose.sh dev up httpd-hmr` for live reload. Both use the same public
configuration generator. The compiled build restores any developer-owned
frontend `.env` afterward. HMR mounts its generated environment separately,
uses Node from the selected frontend's `.nvmrc`, and pins pnpm to 10.24.0.
Run these through the wrapper or CLI so configuration is generated first.

For a complete source rebuild, use `./build-images.sh --force` followed by
`scripts/compose.sh up`. For a subset, run `scripts/compose.sh dev up <overlay>`
for each selected service (for example, `httpd` and `psama`). The retained
`docker-compose.dev.yml` combines build definitions but is not a complete
frontend setup entry point: direct Compose invocation does not generate the
frontend environment. `dev list` lists the supported per-service overlays.


## Safe Update

```bash
./update.sh
```

The update command is non-destructive. It applies release-control refs to clean
service repos, rebuilds local images through `build-images.sh --force`, runs
`./run-migrations.sh --check` then `./run-migrations.sh`, rotates/syncs the
PIC-SURE introspection token, runs `docker compose up -d`, and then restarts
`psama` and `httpd`. It does not delete volumes.

Before image builds/pulls, migrations, or service changes, `scripts/config-drift.sh`
checks the resolved Compose environment against the selected auth mode and
explicit AIO settings. Known mismatches stop the update with a remedy.
Unrecognized upstream environment keys, image users, and build-context changes
warn for review; they are not proof of an incompatibility. Source checks use the
selected local checkout and print its revision. `--no-rebuild` and `--pull-images`
check configuration only because local sources cannot establish image contents.
This is a targeted compatibility check, not an end-to-end readiness guarantee.

Only those two get an extra `restart`: `psama` to flush its TTL-less
roles/privileges caches, and `httpd` to re-read its bind-mounted vhost and
settings files, which `up -d` does not notice. The gateway is deliberately
absent — the only thing that changes for it is the rotated introspection token,
which `restart` would not re-read anyway; the preceding `up -d` already
recreated it with the new value.

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

To preview release-control resolution only, without changing `.env` or repos:

```bash
./release-control.sh --dry-run
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

## Migrations and Seeding

```bash
./run-migrations.sh            # migrate, then restart psama + dictionary-api
./run-migrations.sh --check    # validate inputs and pending state, touch nothing
./run-migrations.sh --repair   # clear failed history rows (then run migrate again)
./run-migrations.sh --no-restart
./seed-db.sh
```

Two Compose one-shots do the work; both run once and exit.

`flyway-init` handles MySQL in four passes, in this order:

1. `auth` core — `pic-sure/services/pic-sure-auth-microapp/pic-sure-auth-db/db/sql`
2. `picsure` core — `pic-sure/services/pic-sure-operations-service/db/sql`
3. `picsure` project-specific — `PIC-SURE-Migrations/$MIGRATION_NAME/picsure`
4. `auth` project-specific — `PIC-SURE-Migrations/$MIGRATION_NAME/auth`

`MIGRATION_NAME` defaults to `Baseline`. The project-specific passes record
themselves in a separate `flyway_custom_schema_history` table, so they version
independently of the core schema. They are DML against tables the core passes
create, which is why they run second.

`flyway-dictionary-init` handles the dictionary Postgres separately, from
`pic-sure/services/picsure-dictionary/db/flyway`. It is a second one-shot rather
than a fifth pass because the dictionary DB is on the internal `data` network,
uses its own generated `config/dictionary/dictionary.env` credentials, is always
local even under `DB_MODE=remote`, and must not wedge the auth tier when it
fails.

After a successful migrate, `run-migrations.sh` restarts `psama` (access rules
and roles) and `dictionary-api` — the two services that cache migrated data with
no usable flush. Pass `--no-restart` to skip that, as `init.sh` does.

`seed-db.sh` runs strictly after migrations and creates the admin user, the
visualization resource entry, and the introspection token. It refuses to start
unless both `auth` and `picsure` show successful rows in
`flyway_custom_schema_history` — better to fail up front than part-way through
an INSERT. If a migration run failed part-way, recover with
`./run-migrations.sh --repair` followed by `./run-migrations.sh`, not by re-seeding. Seeding is idempotent and
safe to re-run.

## Day-2 Operations

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f
docker compose logs -f gateway

# Restart one service
docker compose restart hpds

# Check service health and local repo state
docker compose ps
./status.sh
```

## Uninstall

```bash
./uninstall.sh
./uninstall.sh --yes
```

`uninstall.sh` removes this checkout's Compose containers, networks, named
volumes, and generated runtime state. This includes the bundled MySQL data
volume, so local database contents are deleted. Remote databases are not
removed. It backs up `.env` before removing it. The source checkout is not
removed. Use `--images` to also remove local PIC-SURE images, `--repos` to
remove cloned service repos, or `--keep-env` to preserve `.env`.

## Data Loading

Demo data:

```bash
./load-demo-data.sh              # NHANES
./load-demo-data.sh synthea      # Synthea 10k
./load-demo-data.sh 1000genomes  # 1000 Genomes
./load-demo-data.sh --all        # all three, merged
```

To share one load between stacks, see [Shared HPDS data](#shared-hpds-data).

Compose ETL commands replace the old Jenkins ETL jobs:

```bash
./etl.sh --help
```

See [etl.md](etl.md).

## Multiple Local Stacks

Two all-in-ones can run on one Docker host when each checkout uses a distinct
Compose project, image tag, and ports:

```env
COMPOSE_PROJECT_NAME=picsure2
PICSURE_IMAGE_TAG=picsure2
HTTP_PORT=8080
HTTPS_PORT=8443
```

Compose names each container `<project>-<service>-N` (for example
`picsure2-picsure-db-1`), so the two stacks' containers, volumes, and networks
stay apart. Reach a container by service through its own checkout's project,
never by a container name:

```bash
docker compose exec picsure-db bash      # run from the checkout, or add -p <project>
docker compose logs -f gateway
```

Inside a stack, services still reach each other by service name (`picsure-db`,
`gateway`, ...). The ETL scripts prefix the containers they start themselves
with the project name, so two stacks can run ETL at the same time.

### Shared HPDS data

Stacks on one host can serve the same HPDS data without each running the HPDS
ETL. Load the data once in one stack, publish it as a named data set, and point
other stacks at it. They never write to it.

```bash
# In the stack that loaded the data (HPDS_DATA_MODE=local):
./load-demo-data.sh --all
scripts/publish-shared-hpds-data.sh picsure-demo-v1
```

Publishing copies the stack's `hpds-data` and `hpds-genomic` volumes into
`picsure-demo-v1_hpds-data` and `picsure-demo-v1_hpds-genomic`. The new
volumes are labelled with their contents and the pic-sure and AIO commits they
came from (`docker volume inspect`). The script won't overwrite an existing
data set unless you pass `--force`, and it won't replace one that a container
still uses. If genomic data is loaded, start HPDS once with `HPDS_PROFILE=bch-dev`
before publishing: HPDS writes each contig's genomic indexes on its first
start, and it can't write them to a read-only mount. The publisher checks
for them and leaves out the `all-bak` backup that `promote-genomic` keeps.

To use a data set, add this to a stack's `.env`, then recreate HPDS and hydrate
that stack's own dictionary:

```env
HPDS_DATA_MODE=shared
HPDS_SHARED_DATA=picsure-demo-v1
```

```bash
scripts/compose.sh up hpds
./load-demo-data.sh        # skips the HPDS load; hydrates the dictionary only
```

HPDS mounts the phenotype volume read-only. It can't do the same with the
genomic volume: it opens every genomic storage file read-write (mode `rwd`),
even though it never writes to them once loaded, and on a read-only mount the
variant store fails to load. In shared mode a one-shot `hpds-genomic-seed`
service therefore copies the shared genomic data into the stack's own
`hpds-genomic-shared-copy` volume, which costs about the genomic data's size on
disk (660 MB for `picsure-demo-v1`). It copies again only when the published
set changes, so later starts skip the copy.

A data set with genomic data needs `HPDS_PROFILE=bch-dev`. The publisher
records that on the volumes, and every shared-mode stack applies it through
the scripts (`scripts/compose.sh`, `init.sh`, `update.sh`, ...) unless its own
`.env` sets `HPDS_PROFILE`. Leave `HPDS_PROFILE=` empty in shared mode;
preflight warns when it overrides the data set's profile.

In shared mode, `etl.sh` refuses commands that write HPDS data (`load-csv`,
`load-phenotype`, `load-vcf`, `promote-genomic`, ...). To change the data,
load it in a local-mode stack and publish a new data set. The shared volumes
are external to every stack, so `docker compose down --volumes`,
`./uninstall.sh`, `./reset.sh` and `ws stack release` leave them in place.
Remove a data set with `docker volume rm <name>_hpds-data <name>_hpds-genomic`
once no stack uses it.

## Troubleshooting

Service will not start:

```bash
docker compose logs <service-name>
docker compose ps
./status.sh
```

API calls fail while every container reports healthy:

Container healthchecks are liveness probes, not end-to-end checks. Ask the
gateway instead:

```bash
./status.sh --deep-health
docker compose logs gateway
```

A downstream service reported DOWN there names the failure; `hpds` reporting DOWN
on a fresh install just means no data is loaded yet.

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
  `certs/server.chain`, then restart `httpd`. The key is bind-mounted into a
  container whose Apache runs as uid/gid 2, so it must be readable by that uid
  (`sudo chgrp 2 certs/server.key && sudo chmod 0640 certs/server.key`) —
  otherwise SSL init fails and `httpd` serves nothing. `./preflight.sh` checks
  this.
- Custom trust certs: place `.crt`, `.cer`, or `.pem` files under
  `certs/trust/`; `init.sh` imports them into the PSAMA truststore at
  `config/psama/application.truststore`.
- TOS: set `TOS_ENABLED=true`; terms content is managed in the frontend admin UI.
- Analytics: set `VITE_GOOGLE_ANALYTICS_ID` or `VITE_GOOGLE_TAG_MANAGER_ID`
  before rebuilding the frontend.
- Auth modes: set `AUTH_MODE=required`, `open`, or `explore`.

After changing auth mode, rerun `init.sh` and rebuild the frontend. Explore
provides exact counts and charts to anonymous visitors, with login required
for export. Discover is the obfuscated mode; expanded Discover deployment and
separate public-data topology remain deferred in this AIO demo implementation.
AIO does not seed user consents, so consent authorization defaults off in both
PSAMA and the query service. Enabling it requires an actual consent workflow.

API documentation defaults on. Set `GATEWAY_DOCS_ENABLED=false` and recreate
gateway and httpd (`scripts/compose.sh up gateway httpd`) to disable gateway
documentation and direct PSAMA documents. In HMR, rerun the dev wrapper to
recreate the frontend container. Current core versions without a docs console
still return 404; the switch does not install documentation support.

The frontend supplies its nonce-based CSP. Apache supplies a restrictive
fallback for responses with no policy. The gateway Swagger viewer has a
separate policy permitting its upstream inline initializer only on that page;
it does not relax application pages or API responses.

HPDS ETL containers explicitly run as `0:0`, matching the service and AIO's
root-owned named volumes. An operator who has prepared compatible permissions
on all data volumes and genomic bind directories can set `ETL_RUN_AS` in `.env`.
Alpine copy helpers and other loaders retain their image defaults. No upstream
Dockerfile is rewritten to handle package pin failures.

## Retired Jenkins Workflows

Jenkins is no longer the target operations surface. GIC/Common Area jobs,
JupyterHub, banner config, SSLOffload, outbound email setup, user-token jobs,
PSAMA config download, Jenkins start/stop, and Jenkins release-control jobs are
retired from the Compose path. Compose still reads the release-control build
spec through `release-control.sh`.
