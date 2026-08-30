# AIO banner deployment-local integration proof

This proof exercises the banner feature through an isolated, production-shaped
AIO path:

```text
Chromium -> frontend/httpd -> Gateway -> PSAMA + Operations -> MySQL
                                      Operations -> logging service
```

The harness exports the exact clean source commits, builds the real application
artifacts, applies the real core and AIO migration histories to disposable
MySQL, and uses synthetic identities and banner content. It does not mock any
service or response in the request path.

## Run

Docker must be available. Set the six read-only source roots and run:

```bash
export BANNER_LOCAL_BACKEND_ROOT=/path/to/pic-sure
export BANNER_LOCAL_FRONTEND_ROOT=/path/to/PIC-SURE-Frontend
export BANNER_LOCAL_MIGRATIONS_ROOT=/path/to/PIC-SURE-Migrations
export BANNER_LOCAL_RELEASE_CONTROL_ROOT=/path/to/baseline-pic-sure-release-control
export BANNER_LOCAL_BDC_ROOT=/path/to/pic-sure-bdc-infrastructure
export BANNER_LOCAL_LEGACY_PSAMA_ROOT=/path/to/pic-sure-auth-microapp
tests/banner-local-integration/test.sh all
```

The current inputs must be clean and at the commits recorded in
`expected-result.json`; the BDC root is pinned by the binary/feed owner contract,
and the clean legacy PSAMA root must contain the exact annotated `v4.2.2` tag.
Use `test.sh contract` for the normal and optimized checked-in contract tests
without starting Docker. `nested-owner-diagnostics.py` drives a failing Ticket
17 subprocess through Ticket 18's real composition and failure paths without
starting Docker, then checks that Ticket 22A retains both owners' diagnostics.

Resources are labeled with `org.pic-sure.banner-local-integration=<run-id>`.
The runner removes its containers, network, locally built images, and temporary
directory on success and failure. Failure diagnostics, including the composed
owner matrices, service logs, and browser results, are captured before that
cleanup under `${BANNER_LOCAL_DIAGNOSTICS_ROOT:-/tmp/banner-local-integration-diagnostics}`.
CI uploads that directory when the job fails.

## Proof composition and result

Ticket 15 remains the migration proof owner. The harness builds its historical
inputs from exact local Git objects and runs its authoritative `test.sh all`.
Tickets 17 and 18 remain the binary/schema and feed-rollback proof owners.
Ticket 18 composes Ticket 17's authoritative `test.sh all` once. The AIO proof
independently validates both observed matrices and Ticket 17's runtime result
before recording either owner PASS. Ticket 19's cache-restart integration and
rollout-contract Java tests run against the exported backend source. Ticket 20's
AIO and release-control owner suites run normally and with Python optimization.
No owner PASS is inferred from a checked-in result or checksum.

`contract.json` is the deployment-neutral JSON Schema consumed unchanged by
AIO, BDC, and AIM-AHEAD. `expected-result.json` is the stable AIO expectation
template; it deliberately omits the executing commit and runtime artifacts.
The runner constructs the observed row independently, records exact source
commits, image and contract digests, application hashes, built image IDs, and
the synthetic banner UUID, then separately compares stable expectations before
reporting PASS.

## Deliberate limits

This local proof does not claim production TLS, external routing, deployment
automation execution, parity with the deployment image's undeclared embedded
migration runtime, live authorization, or peer deployment-local behavior.
Those fields remain `NOT_RUN` for the follow-on deployment proofs.
