# PIC-SURE All-in-One

The Patient-centered Information Commons: Standard Unification of Research Elements (PIC-SURE) platform integrates different layers of clinical and genomic data from diverse data sources, providing a multifaceted approach to biomedical research. The PIC-SURE platform was built on i2b2 (Informatics for Integrating Biology & the Bedside, a data model created for EHR data), with an Apache 2.0 license (open source). PIC-SURE has been deployed in both FISMA Moderate ATO and HI-TRUST environments.

The PIC-SURE platform provides both an intuitive graphical user interface (UI) and an application programming interface (API) to meet different use cases and levels of experience with data manipulation. The PIC-SURE UI allows for an investigator to search for variables of interest and to conduct feasibility queries. In this way, cohorts are built in real-time and results can be retrieved for analysis.

Deploy the PIC-SURE platform with Docker Compose.

## Quick Start

### Guided setup (recommended)

Install the `pic-sure` CLI, then let the built-in wizard collect credentials
and run the first-time setup for you:

```bash
curl -fsSL https://raw.githubusercontent.com/hms-dbmi/pic-sure-all-in-one/main/cli/install.sh | bash
# or build from source: make -C cli build

git clone https://github.com/hms-dbmi/pic-sure-all-in-one
cd pic-sure-all-in-one
pic-sure          # opens the TUI; choose "Set up PIC-SURE" to run the wizard
```

The wizard collects Auth0 credentials, admin email, and other options, then
streams `init.sh` in-terminal. On success press enter to land in the
dashboard. See [cli/README.md](cli/README.md) for the full CLI/TUI reference.

### Manual setup

```bash
git clone https://github.com/hms-dbmi/pic-sure-all-in-one
cd pic-sure-all-in-one

cp .env.example .env
# Edit AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET, ADMIN_EMAIL.

./preflight.sh
./init.sh

# Optional demo data
./load-demo-data.sh
```

Browse to **https://localhost** and log in with the configured admin Google
account. If `HTTPS_PORT` in `.env` is not 443 — because another stack or a host
process such as Tailscale already holds the port — use
`https://localhost:$HTTPS_PORT` instead, and add that origin to the Auth0
tenant's allowed callback and logout URLs or login will fail. `./init.sh` and
`./load-demo-data.sh` both print the correct URL when they finish.

## Architecture

`httpd` is the only container published to the host. It terminates TLS, serves
the SvelteKit frontend, and reverse-proxies two paths:

- `/picsure/(.*)` → `gateway:8080` — every API call
- `/psama/(.*)` → `psama:8090/auth/` — authentication, straight to PSAMA

The gateway (Spring Cloud Gateway) is the single API front door. It runs the
PSAMA introspection auth chain, then routes `/operations`, `/hpds`,
`/dictionary`, `/visualization`, and `/logging` to the services behind it. Its
own liveness is `/actuator/health/liveness`; deep cross-service health is the
gateway's `/system/status`, surfaced by `./status.sh --deep-health`.

| Service | Role |
|---|---|
| `httpd` | TLS, frontend, reverse proxy — the only public container |
| `gateway` | API front door, auth chain, `/system/status` |
| `psama` | Authentication and authorization; owns the `auth` schema |
| `pic-sure-operations-service` | Queries, datasets, configuration; the only owner of the `picsure` schema |
| `pic-sure-hpds-query-service` | The only query path to `hpds` |
| `hpds` | Phenotype and genomic data store |
| `visualization` | Chart/histogram service |
| `dictionary-api`, `dictionary-dump` | Variable search API and remote-dictionary transfer |
| `pic-sure-logging` | Audit event collector |
| `picsure-db` | MySQL 8 — `picsure` and `auth` schemas |
| `dictionary-db` | PostgreSQL 16 — dictionary schema |
| `flyway-init`, `flyway-dictionary-init` | One-shot migration containers; run once and exit |

Four Docker networks enforce the boundaries: `public` (httpd only), `app`,
internal `data` (the dictionary tier), and internal `query`. HPDS sits on
`query`, so the query service is its query path — visualization, dictionary,
and PSAMA cannot resolve it.

### Source repositories

`./clone-repos.sh` clones four repos into `repos/`; `build-images.sh` calls it
automatically.

| Repo | Provides |
|---|---|
| `pic-sure` | Service monorepo — gateway, operations service, query service, PSAMA, HPDS, visualization, logging, dictionary |
| `PIC-SURE-Frontend` | SvelteKit frontend, baked into the `httpd` image |
| `PIC-SURE-Migrations` | Project-specific Flyway migrations (`Baseline` by default) |
| `picsure-dictionary-etl` | Dictionary ETL loader used by `etl.sh` and `load-demo-data.sh` |

`./build-images.sh` builds every Java service in a single Maven reactor pass
(`maven:3-amazoncorretto-25`, Java 25) over the `pic-sure` checkout, then builds
each service image from that shared reactor output — so all services ship the
same jars. The frontend image builds separately and is rebuilt only when its
baked-in `VITE_*` config or theme changes.

## Requirements

- Docker Engine 20.10+ with Compose V2
- Git
- `jq` recommended; if absent, release-control parsing can use Docker
- 8 GB RAM minimum; 32 GB recommended
- 100 GB disk, plus space for loaded data

**Note**: We run PIC-SURE on AlmaLinux 8.x internally, but we aim to support more operating systems than that. If you have a *nix operating system with docker installed on it, we should be able to help you get PIC-SURE running. You might see some breakages in the bash scripts that run the initial configurations, but once you get things correctly configured, docker should provide enough environment normalization to keep you running.

## Common Commands

The bash scripts are always usable directly. The `pic-sure` CLI wraps each one
and adds checkout-root discovery, TTY safety, and `--json` / `--yes` pass-through.

| Script | `pic-sure` equivalent | What it does |
|---|---|---|
| `./preflight.sh` | `pic-sure preflight` | Check host tools, config shape, Compose validity, and pinned refs |
| `./status.sh` | `pic-sure status` | Print read-only stack, release-control, repo, DB, and migration readiness |
| `./status.sh --deep-health` | `pic-sure status --deep-health` | The above, plus the gateway's `/system/status` cross-service probe |
| `./update.sh --dry-run` | `pic-sure update --dry-run` | Resolve release-control and preview an update |
| `./update.sh` | `pic-sure update` | Apply release-control refs, rebuild/pull images, run migrations, rotate introspection token, restart services |
| `./run-migrations.sh --check` | `pic-sure migrate --check` | Validate migration inputs without touching the database |
| `./etl.sh --help` | `pic-sure etl --help` | Compose replacements for Jenkins data-loading jobs |
| `./uninstall.sh` / `./uninstall.sh --yes` | `pic-sure uninstall` / `pic-sure uninstall --yes` | Preview or perform local Compose and generated-state cleanup |

## Key Docs

- [Operations runbook](docs/operations.md)
- [Upgrade and release-control behavior](docs/upgrade-release-control.md)
- [ETL commands](docs/etl.md)
- [Data dictionary](docs/dictionary.md)
- [Database CLI access](docs/db-access.md)
- [pic-sure CLI & TUI — install, command reference, agent automation rules](cli/README.md)

## Project Layout

```text
docker-compose.yml              # Main Compose stack
docker-compose.dev*.yml         # Build-from-source overlays (all services, or one at a time)
docker-compose.remote-db.yml    # Remote MySQL/RDS overlay
.env.example                    # Configuration template
init.sh                         # First install
clone-repos.sh                  # Clone the four source repos into repos/
preflight.sh                    # Non-mutating host/config checks
status.sh                       # Read-only stack and release status
uninstall.sh                    # Local stack removal
update.sh                       # Safe update path
release-control.sh              # Build-spec ref resolution
build-images.sh                 # Local image builds
bootstrap-remote-db.sh          # Remote DB bootstrap/check
run-migrations.sh               # Flyway migrate/check/repair
seed-db.sh                      # DB seed step
load-demo-data.sh               # Demo data loader
etl.sh                          # Compose ETL operations
cli/                            # pic-sure CLI & TUI (Go binary, installer, release assets)
scripts/                        # Internal helpers used by the bash scripts above
config/                         # Runtime config and service assets
docs/                           # Operator docs
fixtures/                       # Smoke-test fixtures
repos/                          # Cloned service source repos, gitignored
```
