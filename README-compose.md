# PIC-SURE All-in-One

Deploy the full PIC-SURE platform with a single command.

## Quick Start

```bash
git clone https://github.com/hms-dbmi/pic-sure-all-in-one
cd pic-sure-all-in-one

# 1. Configure
cp .env.example .env
# Edit .env — set AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET, AUTH0_TENANT, ADMIN_EMAIL
# For evaluation, request demo credentials at: http://avillachlabsupport.hms.harvard.edu

# 2. Initialize (generates passwords, SSL cert, truststore, config files)
./init.sh

# 3. Build frontend (bakes in auth config)
./build-frontend.sh

# 4. Start
docker compose up -d

# 5. Seed database (roles, admin user, visualization resource)
./seed-db.sh

# 6. Restart services to pick up seed data
docker compose restart wildfly psama

# 7. Load demo data (optional — includes HPDS + dictionary + search weights)
./load-demo-data.sh          # NHANES (default)
./load-demo-data.sh synthea  # or Synthea 10k
```

Browse to **https://localhost** and log in with your configured admin Google account.

## Requirements

- Docker Engine 20.10+ with Compose V2
- 8 GB RAM minimum (32 GB recommended for production)
- 100 GB disk (plus space for your data)

## Architecture

```
Internet → httpd (reverse proxy + frontend)
              ├→ wildfly (PIC-SURE API)
              │     ├→ hpds (data query engine)
              │     └→ dictionary-api
              └→ psama (auth)

picsure-db (MySQL) ← wildfly, psama
dictionary-db (PostgreSQL) ← dictionary-api
```

Only **httpd** is exposed to the network (ports 80/443). All other services run on internal Docker networks.

## Configuration

All configuration lives in `.env`. Key settings:

| Setting | Description |
|---|---|
| `AUTH0_CLIENT_ID` | Auth0 application client ID |
| `AUTH0_CLIENT_SECRET` | Auth0 application client secret |
| `AUTH0_TENANT` | Auth0 tenant name (e.g., `avillachlab`) |
| `ADMIN_EMAIL` | Google account for the initial admin user |
| `AUTH_MODE` | `required` (default), `open`, or `explore` — see below |
| `DB_MODE` | `local` (default) or `remote` for external MySQL |

### Auth Modes

| Mode | Behavior |
|---|---|
| `required` | Users must log in to access any page |
| `open` | Discover page accessible without login; export/API requires login |
| `explore` | Full Explore page accessible without login; export prompts login |

### Remote Database (RDS)

To use an external MySQL instance instead of the bundled container:

```env
DB_MODE=remote
DB_HOST=my-rds-instance.region.rds.amazonaws.com
DB_PORT=3306
DB_ROOT_PASSWORD=your-rds-root-password
```

Run `./init.sh` after setting these values — it will generate application user passwords. You'll need to create the `auth` and `picsure` databases and users on the remote instance (the init script will guide you).

### SSL Certificates

`init.sh` generates a self-signed certificate for development. For production:

1. Place your certificate files in `certs/`:
   - `certs/server.crt` — certificate
   - `certs/server.key` — private key
   - `certs/server.chain` — certificate chain
2. Restart: `docker compose restart httpd`

## Developer Guide

### Building from Source

To develop on PIC-SURE services locally:

```bash
# Clone the repos you need (as siblings to this repo)
git clone https://github.com/hms-dbmi/pic-sure-hpds ../pic-sure-hpds
git clone https://github.com/hms-dbmi/pic-sure-auth-microapp ../pic-sure-auth-microapp
# ... etc

# Start everything, building HPDS from local source
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build hpds

# Build multiple services from source
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build hpds psama wildfly

# Use a custom source directory
HPDS_SRC=/path/to/my/fork docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build hpds
```

Services not specified with `--build` will use pre-built images.

### Debug Ports

When using `docker-compose.dev.yml`, Java debug ports are exposed:

| Service | Debug Port |
|---|---|
| psama | 5005 |
| wildfly | 5006 |

Connect your IDE's remote debugger to `localhost:<port>`.

### Source Directory Defaults

| Variable | Default | Service |
|---|---|---|
| `HPDS_SRC` | `../pic-sure-hpds` | hpds |
| `PSAMA_SRC` | `../pic-sure-auth-microapp` | psama |
| `WILDFLY_SRC` | `../pic-sure` | wildfly |
| `FRONTEND_SRC` | `../PIC-SURE-Frontend` | httpd |
| `DICTIONARY_SRC` | `../picsure-dictionary` | dictionary-api, dictionary-dump |

## Operations

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f                 # All services
docker compose logs -f wildfly         # Single service

# Restart a single service
docker compose restart hpds

# Rebuild and restart after code changes (dev mode)
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build hpds

# Check service health
docker compose ps

# Update to latest images
docker compose pull && docker compose up -d
```

## Data Loading

### Demo Data

```bash
./load-demo-data.sh              # NHANES (1000 patients, clinical data)
./load-demo-data.sh synthea      # Synthea 10k (synthetic clinical data)
./load-demo-data.sh 1000genomes  # 1000 Genomes (genomic data)
```

### Custom Data

Place your data file as `allConcepts.csv` in the expected format:

```csv
"PATIENT_NUM","CONCEPT_PATH","NVAL_NUM","TVAL_CHAR","TIMESTAMP"
```

Data must be sorted by `CONCEPT_PATH, PATIENT_NUM, TIMESTAMP`.

See the [data loading documentation](docs/data-loading.md) for details on CSV format, RDBMS loading, and genomic data.

## Upgrading

```bash
git pull
docker compose pull    # Pull latest pre-built images
docker compose up -d   # Restart with new images (migrations run automatically)
```

## Troubleshooting

### Service won't start

```bash
docker compose logs <service-name>    # Check logs
docker compose ps                      # Check health status
```

### HPDS crash-loops

If `HPDS_PROFILE` is set to `bch-dev` but no genomic data is loaded, HPDS will crash-loop. Fix: set `HPDS_PROFILE=` (empty) in `.env` and restart.

### Database auth errors

All database passwords are generated by `init.sh` and stored in `.env`. If passwords get out of sync:

```bash
docker compose down
docker volume rm picsure_picsure-db-data  # WARNING: destroys all data
./init.sh --force                          # Regenerate all passwords
docker compose up -d                       # Fresh start
```

### Can't log in

- Verify `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET`, and `AUTH0_TENANT` in `.env`
- Ensure the admin email in `ADMIN_EMAIL` matches your Google account
- Check PSAMA logs: `docker compose logs psama`

## Project Structure

```
pic-sure-all-in-one/
├── docker-compose.yml          # Main compose file
├── docker-compose.dev.yml      # Dev overrides (build from source)
├── .env.example                # Configuration template
├── .env                        # Your config (git-ignored)
├── init.sh                     # One-time initialization
├── load-demo-data.sh           # Demo data loader
├── config/
│   ├── wildfly/                # Wildfly/pic-sure-api config
│   │   └── standalone.xml      # App server config (uses env vars)
│   ├── httpd/                  # Apache reverse proxy config
│   ├── dictionary/             # Dictionary service config
│   ├── flyway/                 # Database migration runner
│   ├── db-init/                # MySQL first-run initialization
│   └── hpds/                   # HPDS config and encryption key
├── certs/                      # SSL certificates (git-ignored)
├── PLAN.md                     # Architecture and design decisions
├── GLOSSARY.md                 # Shared terminology
└── AGENTS.md                   # Project orientation
```

## Additional Resources

- [PIC-SURE Developer Guide](https://pic-sure.gitbook.io/pic-sure-developer-guide)
- [pic-sure.org](https://pic-sure.org/about)
- [Architecture & Design Decisions](PLAN.md)
- [Terminology](GLOSSARY.md)

## Legacy Jenkins Installation

The previous Jenkins-based installation is still available in `initial-configuration/`. See the [legacy README](README-legacy.md) for those instructions.
