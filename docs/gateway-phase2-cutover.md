# Phase 2 cutover runbook — gateway takes over auth + audit

Phase 2 moves PSAMA token introspection, the consent body-swap, identity
propagation, and audit logging **from the WildFly WAR into the gateway**,
DB-free. This runbook is the coordinated cutover: it must be done in order,
because for a brief window both sides could authenticate the same request.

## The one thing that will bite you

There are **two services** that must agree on a single flag, `GATEWAY_OWNS_AUTH`:

- **Gateway** — env `GATEWAY_OWNS_AUTH` (in `gateway.env`) → registers/removes
  its auth+audit filter chain.
- **WildFly** — `java:global/gatewayOwnsAuth` (in `standalone.xml`) → makes the
  WAR stop introspecting/auditing gateway-owned routes and instead trust the
  gateway-set `X-User-*` headers.

If the **gateway** authenticates while **WildFly** still does, every request is
introspected twice, audited twice, and — critically — the consent query-swap
runs twice, which can **corrupt the query**. So: WildFly must be told to defer
(flag on) in the same change window the gateway starts owning auth.

Defense-in-depth already in place: the gateway **always** strips inbound client
`X-User-*` headers (even when its auth chain is off), so a client can never
spoof identity to WildFly regardless of flag state. The flag coordination below
is still required to avoid the double-swap.

## Preconditions

- Branch `pic_sure_api_rewrite` pushed for both `pic-sure` and
  `pic-sure-all-in-one` (Jenkins clones from GitHub).
- `gateway.env` populated (see `initial-configuration/config/gateway/gateway.env`
  and the george_development_notes step): PSAMA introspection URL/token,
  open-access URL, `LOGGING_SERVICE_URL`/`LOGGING_API_KEY`, and
  `GATEWAY_OWNS_AUTH=false`.
- WildFly `standalone.xml` carries the two bindings
  `java:global/gatewayOwnsAuth` and `java:global/gatewayOwnsQueryReadAuth`
  (both `false` to start). Apply to your deployed
  `local-all-in-one/wildfly/standalone.xml`.
- A **pre-cutover baseline** captured (curl + adapter suites) for comparison.

## Steps

### 1. Deploy WildFly with the flag bindings, flag OFF
Deploy the Phase-2 WAR (path-aware `GatewayHeaderFilter` + bypass) with
`gatewayOwnsAuth=false`. Behavior is unchanged — WildFly still authenticates
everything. This just gets the flag-aware code in place.
Verify: normal login/query works exactly as before.

### 2. Deploy the auth-capable gateway, flag OFF
Run **"PIC-SURE Gateway Build and Deploy"** on `pic_sure_api_rewrite`. With
`GATEWAY_OWNS_AUTH=false` the gateway registers **zero** auth/audit filters —
it's the same transparent pass-through as Phase 1. Live traffic is unaffected.
Verify: `docker logs gateway` shows startup only; a query still works;
`../baseline-metrics/run-adapter-suite.sh` health gate passes.

### 3. Flip both flags together
In the same window:
- WildFly: set `java:global/gatewayOwnsAuth` → `true`, redeploy/reload.
- Gateway: set `GATEWAY_OWNS_AUTH=true` in `gateway.env`, restart the gateway
  container (`docker restart gateway`, or re-run the deploy job).
Order within the window: WildFly first (starts deferring), then the gateway
(starts owning). The gap should be seconds.

### 4. Verify the handover
- **Auth still works**: log in, run a COUNT and a consent-gated query; confirm
  results are correct (consent filters applied exactly once — not doubled).
- **No double audit**: check the logging service — one audit event per request,
  not two.
- **result/signed-url still WildFly-owned**: a `POST /query/{id}/result` still
  authenticates via WildFly (these defer to Phase 4). Confirm it works.
- **Gateway is the auth boundary**: `docker logs gateway` shows introspection
  activity; a bad/absent token is rejected at the gateway (401) before WildFly.
- Run the adapter suite health gate + a post-cutover metrics capture; compare
  latency to the pre-cutover baseline (expect a modest increase — one
  introspection now at the gateway instead of WildFly, plus the hop).

### 5. Rollback (instant)
Flip both flags back to `false` (gateway env + restart; WildFly binding +
reload). WildFly resumes owning auth; the gateway drops its filters and returns
to pass-through. No redeploy needed.

## After bake-in
Once stable, set `GATEWAY_OWNS_AUTH=true` as the default in the deployed
`gateway.env` and `standalone.xml`, and record the Phase-2 completion evidence
(auth-at-gateway, single audit, correct consent results) on the Jira ticket.
The `result`/`signed-url` paths and `gatewayOwnsQueryReadAuth` remain for
Phase 4 (query service).
