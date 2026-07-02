# Gateway latency baseline (P1-2 / ALS-12239)

Repeatable suite that measures client-observed latency through httpd, so the
gateway hop's cost can be isolated: run it once **before** the cutover
(`wildfly-direct`) and once **after** (`via-gateway`) and compare the
**median-of-runs p95/p99** per endpoint. Requests are sequential on purpose —
this measures per-hop latency, not capacity, and stays reproducible on a laptop.

## Endpoints measured

| endpoint | auth | what it isolates |
|---|---|---|
| `GET /picsure/system/status` | none | pure transport/filter overhead (response is server-side cached ~60s) |
| `GET /picsure/info/resources` | token | the JWTFilter → PSAMA introspection path |
| `POST /picsure/query/sync` (COUNT) | token + resource UUID | the full HPDS data path |

## Procedure

```bash
# 0. one-time: make sure httpd records per-request timing (%D) and check state
../gateway-cutover.sh enable-timing
../gateway-cutover.sh status

# 1. PRE-cutover baseline (state must be wildfly-direct)
TOKEN=<long-term PSAMA token>   # from the UI profile page
RESOURCE_UUID=<HPDS resource uuid>   # optional; enables query/sync
TOKEN=$TOKEN RESOURCE_UUID=$RESOURCE_UUID ./run-baseline.sh

# 2. cut over to the gateway (gateway container must be deployed — Jenkins job
#    "PIC-SURE Gateway Build and Deploy")
../gateway-cutover.sh apply

# 3. POST-cutover baseline — identical invocation; the label auto-flips
TOKEN=$TOKEN RESOURCE_UUID=$RESOURCE_UUID ./run-baseline.sh

# 4. compare the two summary.md files (results/<stamp>-wildfly-direct/ vs
#    results/<stamp>-via-gateway/) and attach both to ALS-12239.

# rollback at any point:
../gateway-cutover.sh revert
```

Knobs: `BASE_URL` (default `https://localhost`), `RUNS`/`N`/`WARMUP` (default 3/100/20),
`LABEL` (override auto-detection), `OUT_ROOT`.

## Broad route coverage + health gate: the adapter suite

`run-adapter-suite.sh` complements the curl suite with the
`pic-sure-python-adapter-hpds` repo (default checkout at
`~/code_workspaces/adapters/pic-sure-python-adapter-hpds`). Two instruments,
two jobs — don't merge them:

| | curl suite (`run-baseline.sh`) | adapter suite (`run-adapter-suite.sh`) |
|---|---|---|
| question | what does the gateway hop cost? | do all routes still work, and how do they perform end-to-end? |
| routes | 3 | ~12 (PSAMA, dictionary proxy, legacy + v3 sync, genomic, export) |
| checks | status codes only | real response content (adapter integration tests) |
| timing | client-observed via curl | adapter transport (`PICSURE_DEV_MODE` events) |

Stage 1 is a **health gate**: the adapter's live integration tests must pass
or the suite stops — this is the "verify the environment before promoting"
check, reusable against any env (`BASE_URL=https://... LABEL=bdc-predev`).
Stage 2 collects per-route p50/p95/p99 (N samples per action, errors excluded
and counted) into `results/<stamp>-adapter-<label>/`.

```bash
TOKEN=<token> CONCEPT_PATH='<path valid on the target dataset>' ./run-adapter-suite.sh
```

Knobs: `ADAPTER_DIR`, `SEARCH_TERM`, `GENE` (adds the genomic action),
`RESOURCE_UUID` (multi-resource envs), `N`/`WARMUP` (default 30/3),
`SKIP_HEALTH=1`, `HEALTH_ONLY=1`. The mkcert CA is exported automatically for
local `https://localhost` runs (httpx doesn't read the macOS keychain).

Run it in the same pre/post pairs as the curl suite. Because it asserts on
response content across legacy *and* v3 routes, a pre/post pair doubles as the
**parity verification** evidence for each strangler phase — same invocation,
different label.

The same suite also runs from Jenkins as the **PIC-SURE Health Check** job
(health gate always, metrics via `collect_metrics=true`, token from a Jenkins
credential) — setup and usage in [`docs/health-check.md`](../docs/health-check.md).

## Notes

- Errors (non-2xx) are **excluded from percentiles and reported separately** — an
  expired token would otherwise fake fast latencies. >10% errors prints a warning.
- Post-cutover runs also snapshot the gateway's `/actuator/prometheus`
  (`http_server_requests` p50/p95/p99 per route) into the results dir — the same
  instrument Phase 2 uses for its before/after auth-filter comparison.
- Keep machine conditions comparable between the pre and post runs (same services
  up, no builds running). Compare median-of-runs, not single runs — macOS Docker
  networking is noisy.
- AIO numbers are **relative** (the hop delta), not production-absolute; repeat the
  same suite in BDC during the rollout phase for absolute numbers.
- httpd's own `%D` field (last field of `access_log`, microseconds) corroborates
  with real-traffic timings in both states once `enable-timing` has run.
