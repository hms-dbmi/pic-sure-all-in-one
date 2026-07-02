# PIC-SURE Health Check (Jenkins job)

The **PIC-SURE Health Check** job verifies that a PIC-SURE environment is
actually working — not just that containers are up — by running the live
integration test suite from
[`pic-sure-python-adapter-hpds`](https://github.com/hms-dbmi/pic-sure-python-adapter-hpds)
against it. The suite connects like a real API user and asserts on real
response content across the route surface: PSAMA profile (`/psama/user/me`),
resource listing, dictionary search and facets (via the `/proxy/dictionary-api`
routes), legacy and v3 sync queries, export, and (optionally) genomic
filtering.

**A red build means the environment is not fit to baseline, cut over, or
promote.** That is the job's entire contract: run it after a deploy, before a
gateway cutover step, and before promoting anything toward production.

The job has two stages:

1. **Health gate** (always) — `pytest tests/integration` against the target.
   Any failure fails the build.
2. **Metrics** (only when `collect_metrics=true`) — samples every route N
   times and archives per-route p50/p95/p99 latency as build artifacts
   (`metrics-results/`), for before/after comparisons across gateway phases
   or environments.

---

## One-time setup: the token credential

The suite authenticates with a **long-term PSAMA token**, which the job reads
from a Jenkins *Secret text* credential. Without it the build fails
immediately with a pointer to this document.

### 1. Get a token

Log in to the target PIC-SURE UI and copy the long-term token from the
**User Profile** page. The token must belong to a user with access to the
data on that environment — the tests exercise search and query, not just
login. Note the expiration (typically 30 days): a token that expires later
turns this job red with auth failures, which looks like an outage but isn't
(see [Troubleshooting](#troubleshooting)).

### 2. Add it to Jenkins

1. **Manage Jenkins → Credentials → System → Global credentials (unrestricted)
   → Add Credentials**
2. Fill in exactly:
   - **Kind**: `Secret text`
   - **Secret**: the token
   - **ID**: `picsure-health-check-token` ← must match exactly; the job looks
     this ID up by name
   - **Description**: something future-you will thank you for, e.g.
     `PSAMA long-term token for Health Check job — user X, expires YYYY-MM-DD`
3. Save.

To **rotate** the token (expiry, user change): Manage Jenkins → Credentials →
click the credential → **Update**, paste the new secret. No job changes
needed.

> The `credentials-binding` plugin injects the secret as `PICSURE_TOKEN` into
> the build. It ships in the Jenkins image (pinned in
> `initial-configuration/jenkins/jenkins-docker/plugins.yml`). Jenkins masks
> the value in the build log.

### 3. Load the job

The job definition lives at
`initial-configuration/jenkins/jenkins-docker/jobs/PIC-SURE Health Check/config.xml`.
Load it with:

```bash
./update-jenkins.sh --jobs-only
```

> **Warning — credentials and full updates.** `update-jenkins.sh` *without*
> `--jobs-only` wipes `jenkins_home/*` and restores only jobs and core
> config; stored credentials are backed up to `jenkins_home_bak` but **not
> restored**, so the token credential disappears. After any full update,
> either re-add the credential (step 2 — fastest) or restore both
> `credentials.xml` *and* the `secrets/` directory from `jenkins_home_bak`
> (they must move together; `secrets/` holds the key that decrypts
> `credentials.xml`).

---

## Running the job

**Build with Parameters**:

| parameter | default | meaning |
|---|---|---|
| `git_hash` | `origin/main` | adapter repo revision to run the suite from |
| `target_url` | *(empty)* | **empty = the local all-in-one** (auto-detected, see below). Set to `https://…` to check a remote environment |
| `concept_path` | *(empty)* | a concept path that exists on the target dataset; empty makes the query/export tests **skip** (they don't fail) |
| `search_term` | `age` | dictionary search term; `age` exists on most deployments |
| `gene` | *(empty)* | gene symbol in the target's variant data; empty makes genomic tests skip |
| `resource_uuid` | *(empty)* | only needed when the target exposes more than one resource |
| `collect_metrics` | `false` | also run the latency stage and archive `metrics-results/` |
| `metrics_label` | *(empty)* | empty auto-detects `wildfly-direct` / `via-gateway` from the deployed httpd rules (local targets only) |

Minimal useful run: defaults + nothing else (connect/search/facets coverage).
Full coverage: set `concept_path` (and `gene` on genomic-capable envs).

### Local vs. remote targets

- **Local (empty `target_url`)** — the job reads the stack's FQDN from the
  deployed vhosts (`ServerName` in
  `/usr/local/docker-config/httpd/httpd-vhosts.conf`), maps that FQDN to the
  Docker host inside the test container (`--add-host …:host-gateway`, since
  containers don't inherit the host's `/etc/hosts`), and trusts the deployed
  certificate chain (`httpd/cert/server.chain` via `SSL_CERT_FILE` — Python's
  httpx does not read the OS trust store, so mkcert/self-signed certs need
  this). Everything TLS-related is automatic.
- **Remote (`target_url=https://…`)** — plain connection with normal
  certificate verification; the environment must have a publicly-trusted
  cert. **The stored token must be valid on that environment** — if you check
  multiple environments regularly, add one credential per environment and
  clone the job with a different `credentialsId` (the binding is the last
  block in the job's `config.xml`).

### How it runs (for maintainers)

House-style docker-sibling execution: the Jenkins workspace (the adapter repo
checkout) is mounted by host path into a throwaway
`ghcr.io/astral-sh/uv:python3.10-bookworm-slim` container (3.10 = the
adapter's pinned interpreter — keep in sync with its `.python-version`),
which runs `uv sync --frozen` against the committed lockfile and then pytest
(and, for stage 2, `scripts/collect_env_metrics.py`). Package downloads are
cached in the `uv_cache` volume, mirroring the `maven_m2_cache` convention,
so runs after the first are fast.

---

## Reading the results

- **Green** — every executed test passed. Check the log's pytest summary for
  the skip count: `9 skipped` with an empty `concept_path` is normal, but
  skips you didn't expect mean coverage you didn't get.
- **Red in stage 1** — the log ends with `HEALTH GATE FAILED`. The pytest
  output above it names the failing route family (`test_connect_live` →
  auth/PSAMA, `test_search_live` → dictionary proxy, `test_query_live` →
  query path, …). Treat the environment as unhealthy until green.
- **Metrics artifacts** (stage 2) — the build page's artifacts contain
  `metrics-results/<stamp>-adapter-<label>/` with `summary.md` (per-route
  p50/p95/p99 table; errors are excluded from percentiles and counted
  separately), `summary.json`, and raw `events.csv`. Compare `summary.md`
  across labels/environments; pre/post pairs around a cutover are the parity
  and latency evidence for that phase.

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `ERROR: PICSURE_TOKEN is empty` | credential missing or ID ≠ `picsure-health-check-token` — redo [setup](#one-time-setup-the-token-credential). Also happens after a **full** `update-jenkins.sh` (see the warning in step 3) |
| every auth test fails, env known-good | expired/revoked token — mint a new one, **Update** the credential |
| `could not read ServerName` | non-standard local install — pass `target_url` explicitly |
| TLS `CERTIFICATE_VERIFY_FAILED` (local) | deployed cert chain mismatch — was the cert regenerated? `server.chain` must contain the CA that signed `server.crt` |
| TLS errors (remote) | target has no publicly-trusted cert — the job only auto-trusts the *local* chain |
| query tests all skip | `concept_path` empty or invalid for that dataset — pick a path returned by a dictionary search |

## Relationship to `baseline-metrics/`

This job is the Jenkins wrapper around the same tooling you can run from a
laptop: `baseline-metrics/run-adapter-suite.sh` (health gate + metrics
against any env) and `baseline-metrics/run-baseline.sh` (the tight curl-based
gateway hop-cost instrument). See `baseline-metrics/README.md` for how the
two instruments divide the work during the gateway migration.
