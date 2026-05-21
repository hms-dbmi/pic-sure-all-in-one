# PIC-SURE All-in-One

Deploy the full PIC-SURE platform with Docker Compose.

## Quick Start

```bash
git clone https://github.com/hms-dbmi/pic-sure-all-in-one
cd pic-sure-all-in-one

# 1. Configure
cp .env.example .env
# Edit .env — set AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET, AUTH0_TENANT, ADMIN_EMAIL
# For evaluation, request demo credentials at: http://avillachlabsupport.hms.harvard.edu

# 2. Initialize once (clones repos, builds images, starts services, seeds database)
./init.sh

# 3. Load demo data (optional — includes HPDS + dictionary + search weights)
./load-demo-data.sh          # NHANES (default)
./load-demo-data.sh synthea  # Synthea 10k

# ETL replacement for Jenkins jobs
./etl.sh --help
```

Browse to **https://localhost** and log in with your configured admin Google account.

## Requirements

- Docker Engine 20.10+ with Compose V2
- Python 3
- 8 GB RAM minimum (32 GB recommended for production)
- 100 GB disk, plus space for your data

## Architecture

```text
Internet -> httpd (reverse proxy + frontend)
              -> wildfly (PIC-SURE API)
                   -> hpds (data query engine)
                   -> dictionary-api
              -> psama (auth)

picsure-db (MySQL) <- wildfly, psama
dictionary-db (PostgreSQL) <- dictionary-api
```

Only **httpd** is exposed to the network through ports 80/443. All other services run on internal Docker networks.

## Configuration

All deployment configuration lives in `.env`. Key settings:

| Setting | Description |
|---|---|
| `AUTH0_CLIENT_ID` | Auth0 application client ID |
| `AUTH0_CLIENT_SECRET` | Auth0 application client secret |
| `AUTH0_TENANT` | Auth0 tenant name, for example `avillachlab` |
| `ADMIN_EMAIL` | Google account for the initial admin user |
| `AUTH_MODE` | `required`, `open`, or `explore` |
| `DB_MODE` | `local` or `remote` for external MySQL/RDS |
| `COMPOSE_PROJECT_NAME` | Compose project/volume prefix; change this to run multiple all-in-ones on one host |

### Auth Modes

| Mode | Behavior |
|---|---|
| `required` | Users must log in to access any page |
| `open` | Discover page accessible without login; export/API requires login |
| `explore` | Full Explore page accessible without login; export prompts login |

### Remote Database

To use an external MySQL instance instead of the bundled container:

```env
DB_MODE=remote
DB_HOST=my-rds-instance.region.rds.amazonaws.com
DB_PORT=3306
DB_ROOT_USER=root
DB_ROOT_PASSWORD=your-rds-root-password
```

For a first install, validate config and run `./init.sh`:

```bash
./run-migrations.sh --check
./init.sh
```

`init.sh` calls `bootstrap-remote-db.sh` when `DB_MODE=remote`. Normal migration runs do not create remote schemas or users; they only wait for the configured DB and run Flyway.

### SSL Certificates

`init.sh` generates a self-signed certificate for development. For production, place Apache-compatible certificate files in `certs/`:

- `certs/server.crt`
- `certs/server.key`
- `certs/server.chain`

Then restart httpd:

```bash
docker compose restart httpd
```

Additional trust certificates for WildFly and PSAMA can be placed under `certs/trust/` as `.crt`, `.cer`, or `.pem` files. `init.sh` and `update.sh` import them into the Java truststores.

## Development

Clone all service repos into `repos/`:

```bash
./clone-repos.sh
```

Release-control refs:

```bash
./release-control.sh --resolve-only
./release-control.sh
```

`init.sh` and `update.sh` use `RELEASE_CONTROL_REPO` and
`RELEASE_CONTROL_BRANCH` from `.env` to read `build-spec.json`, fill component
refs such as `PICSURE_REF` and `HPDS_REF`, and check out clean service repos
before building. The default is
`hms-dbmi/pic-sure-baseline-release-control` on `main`; set
`RELEASE_CONTROL_BRANCH` to choose another build-spec branch. Missing build-spec
entries or failed ref checkouts warn and fall back to `main`.

Build only the frontend from local source:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev-httpd.yml up -d --build --no-deps httpd
```

Build multiple services with overlays:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev-httpd.yml -f docker-compose.dev-psama.yml up -d --build httpd psama
```

Build all supported services from local source:

```bash
./build-images.sh --force
```

Use a custom source directory:

```bash
HPDS_SRC=/path/to/my/fork docker compose -f docker-compose.yml -f docker-compose.dev-hpds.yml up -d --build hpds
```

Frontend with HMR:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev-httpd-hmr.yml up -d --no-deps httpd
# Then browse to http://localhost:3000
```

Debug ports when using `docker-compose.dev.yml`:

| Service | Debug Port |
|---|---|
| psama | 5005 |
| wildfly | 5006 |

Source directory defaults:

| Variable | Default | Service |
|---|---|---|
| `HPDS_SRC` | `./repos/pic-sure-hpds` | hpds |
| `PSAMA_SRC` | `./repos/pic-sure-auth-microapp` | psama |
| `WILDFLY_SRC` | `./repos/pic-sure` | wildfly |
| `FRONTEND_SRC` | `./repos/PIC-SURE-Frontend` | httpd |
| `DICTIONARY_SRC` | `./repos/picsure-dictionary` | dictionary-api, dictionary-dump |

## Operations

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f
docker compose logs -f wildfly

# Restart a single service
docker compose restart hpds

# Check service health
docker compose ps
```

Safe update:

```bash
./update.sh
```

`update.sh` applies release-control refs to clean service repos, calls `build-images.sh --force` by default, runs migrations, syncs the introspection token, and restarts services without deleting data. When published images are available:

```bash
./update.sh --pull-images
```

Validate migration inputs without touching the database:

```bash
./run-migrations.sh --check
```

Repair Flyway metadata after resolving a failed migration:

```bash
./run-migrations.sh --repair
```

More production operation notes are in [docs/operations.md](docs/operations.md).

## Data Loading

Demo data:

```bash
./load-demo-data.sh              # NHANES
./load-demo-data.sh synthea      # Synthea 10k
./load-demo-data.sh 1000genomes  # 1000 Genomes
```

Custom phenotype CSVs use this format:

```csv
"PATIENT_NUM","CONCEPT_PATH","NVAL_NUM","TVAL_CHAR","TIMESTAMP"
```

Data should be sorted by `CONCEPT_PATH, PATIENT_NUM, TIMESTAMP`.

Compose ETL commands replace the old Jenkins ETL jobs:

```bash
./etl.sh load-csv --file /path/allConcepts.csv
./etl.sh load-multiple --input-dir /path/hpds_input
./etl.sh load-rdbms --sql-properties /path/sql.properties --query /path/loadQuery.sql
./etl.sh hydrate-dictionary --include-dataset-facets --clear
./etl.sh load-dictionary-csv --datasets /path/datasets.csv --concepts /path/concepts.zip
./etl.sh load-facets --categories /path/facet_categories.csv --facets /path/facets.csv --concepts /path/facet_concepts.csv
./etl.sh run-weights
./etl.sh load-vcf --partition my_partition --vcf-index /path/vcfIndex.tsv --vcf-dir /path/vcfs
```

See [docs/etl.md](docs/etl.md).

## Multiple Local Stacks

Two all-in-ones can run on the same Docker host if each checkout uses a distinct `.env`:

```env
COMPOSE_PROJECT_NAME=picsure2
HTTP_PORT=8080
HTTPS_PORT=8443
```

Container names must also be project-scoped. Prefer removing fixed `container_name` entries from Compose before running two stacks at once.

## Troubleshooting

### Service will not start

```bash
docker compose logs <service-name>
docker compose ps
```

### HPDS crash-loops

If `HPDS_PROFILE` is set to `bch-dev` but no genomic data is loaded, HPDS will crash-loop. Fix: set `HPDS_PROFILE=` in `.env` and restart.

### Database auth errors

All database passwords are generated by `init.sh` and stored in `.env`. If local bundled DB passwords get out of sync:

```bash
docker compose down
docker volume rm picsure_picsure-db-data  # WARNING: destroys all data
./init.sh --force
docker compose up -d
```

### Cannot log in

- Verify `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET`, and `AUTH0_TENANT` in `.env`.
- Ensure `ADMIN_EMAIL` matches your Google account.
- Check PSAMA logs: `docker compose logs psama`.

## Project Structure

```text
pic-sure-all-in-one/
├── docker-compose.yml          # Main compose file
├── docker-compose.dev.yml      # Dev overrides
├── docker-compose.remote-db.yml # Remote MySQL/RDS overlay
├── .env.example                # Configuration template
├── init.sh                     # One-command setup
├── build-images.sh             # Local source image builds
├── bootstrap-remote-db.sh      # Remote MySQL/RDS schema/user bootstrap
├── update.sh                   # Safe one-command update
├── run-migrations.sh           # Flyway migrate/check/repair
├── seed-db.sh                  # DB seeding
├── load-demo-data.sh           # Demo data loader
├── etl.sh                      # Compose ETL operations
├── config/                     # Runtime config and service assets
├── docs/                       # Focused operator docs
├── fixtures/                   # Smoke-test fixtures
├── repos/                      # Cloned service source repos, gitignored
├── GLOSSARY.md                 # Shared terminology
└── AGENTS.md                   # Agent/project orientation
```

## Legacy Jenkins

Jenkins is legacy for this repository. The supported all-in-one path is Docker Compose. Retired Jenkins-era workflows should not be used for new deployments; current replacements live in `init.sh`, `build-images.sh`, `update.sh`, `run-migrations.sh`, and `etl.sh`.

## Additional Resources

- [PIC-SURE Developer Guide](https://pic-sure.gitbook.io/pic-sure-developer-guide)
- [pic-sure.org](https://pic-sure.org/about)
- [Terminology](GLOSSARY.md)
