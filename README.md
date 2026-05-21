# PIC-SURE All-in-One

The Patient-centered Information Commons: Standard Unification of Research Elements (PIC-SURE) platform integrates different layers of clinical and genomic data from diverse data sources, providing a multifaceted approach to biomedical research. The PIC-SURE platform was built on i2b2 (Informatics for Integrating Biology & the Bedside, a data model created for EHR data), with an Apache 2.0 license (open source). PIC-SURE has been deployed in both FISMA Moderate ATO and HI-TRUST environments.

The PIC-SURE platform provides both an intuitive graphical user interface (UI) and an application programming interface (API) to meet different use cases and levels of experience with data manipulation. The PIC-SURE UI allows for an investigator to search for variables of interest and to conduct feasibility queries. In this way, cohorts are built in real-time and results can be retrieved for analysis.

Deploy the PIC-SURE platform with Docker Compose.

## Quick Start

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
account.

## Requirements

- Docker Engine 20.10+ with Compose V2
- Git
- `jq` recommended; if absent, release-control parsing can use Docker
- 8 GB RAM minimum; 32 GB recommended
- 100 GB disk, plus space for loaded data

**Note**: We run PIC-SURE on AlmaLinux 8.x internally, but we aim to support more operating systems than that. If you have a *nix operating system with docker installed on it, we should be able to help you get PIC-SURE running. You might see some breakages in the bash scripts that run the initial configurations, but once you get things correctly configured, docker should provide enough environment normalization to keep you running.

## Common Commands

- `./preflight.sh` checks host tools, config shape, Compose validity, and pinned
  refs before setup.
- `./status.sh` prints read-only stack, release-control, repo, DB, and migration
  readiness.
- `./update.sh --dry-run` resolves release-control into temporary state and
  previews an update.
- `./update.sh` applies release-control refs, rebuilds/pulls images, runs
  migrations, syncs tokens, and restarts services.
- `./run-migrations.sh --check` validates migration inputs without touching the
  database.
- `./etl.sh --help` shows Compose replacements for Jenkins data-loading jobs.

## Key Docs

- [Operations runbook](docs/operations.md)
- [Upgrade and release-control behavior](docs/upgrade-release-control.md)
- [ETL commands](docs/etl.md)

## Project Layout

```text
docker-compose.yml              # Main Compose stack
docker-compose.remote-db.yml    # Remote MySQL/RDS overlay
.env.example                    # Configuration template
init.sh                         # First install
preflight.sh                    # Non-mutating host/config checks
status.sh                       # Read-only stack and release status
update.sh                       # Safe update path
release-control.sh              # Build-spec ref resolution
build-images.sh                 # Local image builds
bootstrap-remote-db.sh          # Remote DB bootstrap/check
run-migrations.sh               # Flyway migrate/check/repair
seed-db.sh                      # DB seed step
load-demo-data.sh               # Demo data loader
etl.sh                          # Compose ETL operations
config/                         # Runtime config and service assets
docs/                           # Operator docs
fixtures/                       # Smoke-test fixtures
repos/                          # Cloned service source repos, gitignored
```
