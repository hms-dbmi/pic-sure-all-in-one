# PIC-SURE Monitoring Stack

This directory holds the opt-in Prometheus + Grafana observability stack for the
all-in-one (AIO) deployment: Prometheus v3.4.1, Grafana 11.6.0 (bound to
`127.0.0.1:3001` only), node-exporter (host/container metrics), cadvisor
(container metrics), an apache-exporter reading httpd's `mod_status`
endpoint, and a blackbox-exporter for synthetic HTTP probes + TLS certificate
expiry. It scrapes Prometheus itself, the gateway's `/actuator/prometheus`
(token-gated), node-exporter, cadvisor, apache-exporter, and blackbox today;
further per-service jobs are pre-written but commented out until those
services expose metrics (see "M2 activation" below). Two DB exporters
(postgres-exporter, mysqld-exporter) are also available but opt-in — see
"DB exporters" below. Design rationale, architecture, and the full rollout
plan live in the pic-sure repo at
`docs/superpowers/specs/2026-07-06-monitoring-stack-design.md`.

## Setup (opt-in)

The stack is off by default. `start-picsure.sh` / `stop-picsure.sh` only start
or stop it if `$DOCKER_CONFIG_DIR/monitoring/` exists. To opt in:

```bash
mkdir "$DOCKER_CONFIG_DIR/monitoring"
cp monitoring/monitoring.env.example "$DOCKER_CONFIG_DIR/monitoring/monitoring.env"
```

Edit `$DOCKER_CONFIG_DIR/monitoring/monitoring.env` and fill in both values:

- `PICSURE_APPLICATION_TOKEN` — must match the value already set in
  `$DOCKER_CONFIG_DIR/gateway/gateway.env`. This is the same
  `X-Application-Token` the gateway's actuator endpoint requires; Prometheus
  writes it to a secrets file (`$DOCKER_CONFIG_DIR/monitoring/secrets/app-token`)
  and sends it as a request header when scraping.
- `GF_SECURITY_ADMIN_PASSWORD` — the Grafana admin password (see Access below).

Once `monitoring.env` exists, the next `start-picsure.sh` run brings the
monitoring stack up automatically (and `stop-picsure.sh` tears it down). You
can also manage it directly with `bash monitoring/start-monitoring.sh` /
`bash monitoring/stop-monitoring.sh`.

### Existing deployments (upgrading)

The mod_status block that apache-exporter scrapes (the `# --- monitoring:`
block at the end of this repo's `initial-configuration/config/httpd/httpd-vhosts.conf`)
is only copied into `$DOCKER_CONFIG_DIR/httpd/httpd-vhosts.conf` at install
time. On a deployment that was installed before this block existed, re-sync
that block into `$DOCKER_CONFIG_DIR/httpd/httpd-vhosts.conf` yourself and run
`docker restart httpd` — otherwise the `apache` Prometheus target stays down.

## Jenkins

Two dedicated jobs — `Start Monitoring` and `Stop Monitoring`
(`initial-configuration/jenkins/jenkins-docker/jobs/`) run
`monitoring/start-monitoring.sh` / `monitoring/stop-monitoring.sh` directly,
mirroring the existing `Start PIC-SURE` / `Stop PIC-SURE` job conventions.
Load them into a running Jenkins instance with:

```bash
./update-jenkins.sh --jobs-only
```

The existing `Start PIC-SURE` / `Stop PIC-SURE` jobs already start and stop
the monitoring stack implicitly via the same `$DOCKER_CONFIG_DIR/monitoring/`
opt-in check described above — the dedicated jobs exist for monitoring-only
cycling (e.g. redeploying a dashboard change) without restarting the rest of
the platform.

## Known issues

- **macOS / Docker Desktop:** node-exporter's `/:/host:ro,rslave` mount fails
  to start due to VirtioFS mount-propagation limits in Docker Desktop (error:
  `path /host_mnt is mounted on /host_mnt but it is not a shared or slave
  mount`). This is expected on macOS; the rest of the stack works normally,
  and the `node` Prometheus target simply shows as down. Node metrics work
  correctly on Linux hosts (e.g., EC2 all-in-one deployments).
  `start-monitoring.sh` tolerates this automatically — it brings up the other
  services strictly and only warns if node-exporter fails — so
  `start-picsure.sh` / `start-monitoring.sh` still exit 0 on macOS.

## Access

Grafana is reachable only at `http://127.0.0.1:3001` (never published on a
wide interface). Log in as user `admin` with the password you set as
`GF_SECURITY_ADMIN_PASSWORD`. Prometheus has no published host port; it's
reachable only from other containers on the `monitoring` network at
`prometheus:9090`.

## Editing dashboards

Dashboards are provisioned from JSON files in `monitoring/grafana/dashboards/`
in this repo (not from Grafana's UI-saved state). The loop is:

1. Edit a dashboard JSON file in this repo.
2. Run `bash monitoring/start-monitoring.sh` — it re-syncs the repo's
   `docker-compose.monitoring.yml`, `prometheus/`, and `grafana/` assets into
   `$DOCKER_CONFIG_DIR/monitoring/` (it regenerates the Prometheus app-token
   secret from `monitoring.env` each run, but never edits `monitoring.env`
   itself), re-runs `docker compose up -d`, and restarts the Prometheus
   container automatically so any config/rule changes take effect.
3. Restart the Grafana container so it reloads the provisioned dashboards:
   `docker restart grafana`.

## M2 activation

`monitoring/prometheus/prometheus-aio.yml` has one scrape job commented out
per service (hpds, dictionary, psama, visualization, logging, query-ops).
As each service gains a `/actuator/prometheus` (or equivalent) endpoint,
uncomment its job block, redeploy with `start-monitoring.sh` (which restarts
Prometheus automatically so the new scrape config takes effect), and confirm
it shows up as `up` in Prometheus targets.

## M5: Synthetic probes & TLS certificate expiry

blackbox-exporter (v0.26.0) probes a small set of HTTP(S) endpoints and
exposes the results (up/down, latency, HTTP status, TLS certificate expiry)
to Prometheus. In AIO it probes `https://httpd/picsure/health` and
`https://httpd/` using the `http_2xx_insecure` module
(`monitoring/blackbox/blackbox.yml`): httpd's cert is issued for the
publicly-resolvable name, not the docker-internal `httpd` hostname, so
strict TLS verification would always fail there even though the site is
healthy — `insecure_skip_verify` is used only to avoid that false negative;
`probe_ssl_earliest_cert_expiry` is still collected normally, so expiry
alerts remain meaningful. Publicly-resolvable targets (FISMA ALB, staging —
see BDC notes below) use the strict `http_2xx` module instead.

The `PIC-SURE / Synthetics & Certificates` Grafana dashboard
(`monitoring/grafana/dashboards/synthetics-certificates.json`) shows probe
success, probe duration, HTTP status code, and days-to-certificate-expiry
per target (red below 14 days, yellow below 30).

## M5: DB exporters (opt-in)

postgres-exporter (v0.16.0) and mysqld-exporter (v0.17.2) are defined in
`docker-compose.monitoring.yml` under the `db-exporters` compose profile, so
a plain `docker compose up -d` never starts them — they only come up when
`start-monitoring.sh` finds matching credentials in `monitoring.env`.

To opt in:

1. Create a **read-only** monitoring user on each database you want metrics
   from. MySQL (`picsure-db`):

   ```sql
   CREATE USER 'monitoring'@'%' IDENTIFIED BY '...';
   GRANT PROCESS, REPLICATION CLIENT, SELECT ON performance_schema.* TO 'monitoring'@'%';
   ```

   PostgreSQL (`dictionary-db`, database `dictionary`):

   ```sql
   CREATE ROLE monitoring LOGIN PASSWORD '...';
   GRANT pg_monitor TO monitoring;
   ```

2. Set the corresponding keys in `$DOCKER_CONFIG_DIR/monitoring/monitoring.env`
   (see `monitoring.env.example`): `MONITORING_MYSQL_USER` /
   `MONITORING_MYSQL_PASSWORD` for mysqld-exporter, `MONITORING_PG_USER` /
   `MONITORING_PG_PASSWORD` for postgres-exporter. Leave a pair empty to skip
   that exporter.
3. Rerun `bash monitoring/start-monitoring.sh`. It writes
   `$DOCKER_CONFIG_DIR/monitoring/secrets/db-exporters.env` (chmod 600) from
   those keys and starts each exporter only if both of its keys are present;
   otherwise it prints a one-line "skipping <exporter> (no MONITORING_*
   credentials in monitoring.env)" and moves on.

Once running, `postgres-exporter:9187` and `mysqld-exporter:9104` are scraped
by the `postgres` / `mysql` Prometheus jobs (they show `down` until the
profile is enabled) and surfaced on the `PIC-SURE / Databases` dashboard
(`monitoring/grafana/dashboards/databases.json`), alongside the existing
Micrometer JDBC pool metrics from the app side.

## BDC / FISMA notes

`monitoring/prometheus/prometheus-bdc.yml` in this repo is a template with
`__REGION__` / `__ENVIRONMENT_NAME__` / `__PUBLIC_DNS__` / `__STAGING_DNS__`
placeholders; it is not deployed directly from here. It gets rendered
(placeholders substituted) by `deploy-monitoring.sh` in the
`pic-sure-bdc-infrastructure` repo, which also provisions the EC2-SD-based
Prometheus/Grafana instance in AWS. Grafana there is not publicly
reachable — access it via an SSM port-forward, e.g.:

```bash
aws ssm start-session --target <monitoring-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3001"]}'
```

then browse `http://127.0.0.1:3001` as usual.

`monitoring/grafana/provisioning-bdc/` and `monitoring/grafana/dashboards-bdc/`
are **FISMA-only** assets (a CloudWatch datasource and an AWS Edge dashboard
for ALB/RDS/EBS metrics) — they are installed by `deploy-monitoring.sh` in
the BDC repo, not by this repo's `start-monitoring.sh`, which only ever
syncs `grafana/provisioning` and `grafana/dashboards`. The `prometheus-bdc.yml`
mysql job scrapes `mysqld-exporter:9104` directly (no compose profile there —
BDC's podman-based deploy wires it unconditionally); there is intentionally
no `postgres` job in that file yet — see the stub comment in
`prometheus-bdc.yml` for why.

## Explicitly deferred (do not re-litigate; see spec §10)

- Alerting: Grafana-native, starter rules (target down, error-rate spike, heap pressure, disk fill), notification channel — after baselines exist.
- Custom domain metrics (HPDS query timers, cache hit rates, queue depths).
- FISMA `/grafana/` httpd route — pending security review.
- Tracing (OTel/Micrometer Tracing) — separate spec if wanted.
- Legacy WildFly — never (retires with rewrite).
- AIM-AHEAD monitoring parity — M3/M4 patterns apply; scheduled with the consolidation's dual-environment Phase 3 work.
