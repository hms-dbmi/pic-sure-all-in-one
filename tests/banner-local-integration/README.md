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

Docker must be available. Set the four read-only source roots and run:

```bash
export BANNER_LOCAL_BACKEND_ROOT=/path/to/pic-sure
export BANNER_LOCAL_FRONTEND_ROOT=/path/to/PIC-SURE-Frontend
export BANNER_LOCAL_MIGRATIONS_ROOT=/path/to/PIC-SURE-Migrations
export BANNER_LOCAL_RELEASE_CONTROL_ROOT=/path/to/baseline-pic-sure-release-control
tests/banner-local-integration/test.sh all
```

Each root must be clean and at the commit recorded in `expected-result.json`.
Use `test.sh contract` for the normal and optimized checked-in contract tests
without starting Docker.

Resources are labeled with `org.pic-sure.banner-local-integration=<run-id>`.
The runner removes its containers, network, locally built images, and temporary
directory on success and failure. Failure diagnostics are captured before that
cleanup and emitted by the failing command.

## Proof composition and result

Ticket 15 remains the migration proof owner. The harness validates its exact
entrypoint and matrix checksums and consumes its checked-in PASS/MATCH cells
before independently applying the production migration files needed here.
Tickets 17 and 18 remain the binary/schema and feed-rollback proof owners. The
harness validates their exact entrypoint and matrix checksums and runs their
normal and optimized contract suites. Ticket 19 remains the cache/rollout proof
owner; its exact Java contract test runs against the exported backend source.
This composes those owner proofs without copying their application-level test
matrices into AIO.

`contract.json` defines the reusable fields, checks, limitations, and
`PASS`/`FAIL`/`NOT_RUN` vocabulary. `expected-result.json` is the stable AIO row.
The runner records runtime-only jar hashes, image IDs, and the synthetic banner
UUID in the observed row, then compares every stable field before reporting
PASS.

## Deliberate limits

This local proof does not claim production TLS, external routing, Jenkins
execution, parity with the deployment image's undeclared embedded Flyway
version, live authorization, or BDC/AIM-AHEAD deployment-local behavior. Those
fields remain `NOT_RUN` for the follow-on deployment proofs.
