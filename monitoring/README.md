# PIC-SURE Monitoring Stack

This directory holds the opt-in Prometheus + Grafana observability stack for the
all-in-one (AIO) deployment: Prometheus v3.4.1, Grafana 11.6.0 (bound to
`127.0.0.1:3001` only), node-exporter (host/container metrics), cadvisor
(container metrics), and an apache-exporter reading httpd's `mod_status`
endpoint. It scrapes Prometheus itself, the gateway's `/actuator/prometheus`
(token-gated), node-exporter, cadvisor, and apache-exporter today; further
per-service jobs are pre-written but commented out until those services expose
metrics (see "M2 activation" below). Design rationale, architecture, and the
full rollout plan live in the pic-sure repo at
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

## Known issues

- **macOS / Docker Desktop:** node-exporter's `/:/host:ro,rslave` mount fails
  to start due to VirtioFS mount-propagation limits in Docker Desktop (error:
  `path /host_mnt is mounted on /host_mnt but it is not a shared or slave
  mount`). This is expected on macOS; the rest of the stack works normally,
  and the `node` Prometheus target simply shows as down. Node metrics work
  correctly on Linux hosts (e.g., EC2 all-in-one deployments).

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
   `$DOCKER_CONFIG_DIR/monitoring/` (never touching your `monitoring.env` or
   secrets) and re-runs `docker compose up -d`.
3. Restart the Grafana container so it reloads the provisioned dashboards:
   `docker restart grafana`.

## M2 activation

`monitoring/prometheus/prometheus-aio.yml` has one scrape job commented out
per service (hpds, dictionary, psama, visualization, logging, query-ops).
As each service gains a `/actuator/prometheus` (or equivalent) endpoint,
uncomment its job block, redeploy with `start-monitoring.sh`, and confirm it
shows up as `up` in Prometheus targets.

## BDC / FISMA notes

`monitoring/prometheus/prometheus-bdc.yml` in this repo is a template with
`__REGION__` / `__ENVIRONMENT_NAME__` placeholders; it is not deployed
directly from here. It gets rendered (placeholders substituted) by
`deploy-monitoring.sh` in the `pic-sure-bdc-infrastructure` repo, which also
provisions the EC2-SD-based Prometheus/Grafana instance in AWS. Grafana there
is not publicly reachable — access it via an SSM port-forward, e.g.:

```bash
aws ssm start-session --target <monitoring-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3001"]}'
```

then browse `http://127.0.0.1:3001` as usual.

## Explicitly deferred (do not re-litigate; see spec §10)

- Alerting: Grafana-native, starter rules (target down, error-rate spike, heap pressure, disk fill), notification channel — after baselines exist.
- Custom domain metrics (HPDS query timers, cache hit rates, queue depths).
- FISMA `/grafana/` httpd route — pending security review.
- Tracing (OTel/Micrometer Tracing) — separate spec if wanted.
- Legacy WildFly — never (retires with rewrite).
- AIM-AHEAD monitoring parity — M3/M4 patterns apply; scheduled with the consolidation's dual-environment Phase 3 work.
