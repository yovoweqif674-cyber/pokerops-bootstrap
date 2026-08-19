# PokerOps Tournament Ingestion bootstrap

## One-command production deployment

`deploy.sh` downloads byte-exact runtime and frontend helpers pinned to one
immutable bootstrap commit, verifies both SHA-256 fingerprints, deploys the
fixed application Release, and then publishes the matching Tournament Catalog
frontend. The wrapper accepts no arguments and contains no secrets.

```bash
curl -fsSL https://raw.githubusercontent.com/yovoweqif674-cyber/pokerops-bootstrap/FULL_WRAPPER_COMMIT/deploy.sh | sudo bash
```

## Tournament catalog frontend

`frontend-deploy.sh` publishes the read-only Tournament Catalog preview at
`https://forprofit.pro/preview/v4/manager/tournaments`. The helper downloads an
immutable frontend ZIP from the pinned payload commit, verifies its manifest and
SHA-256, backs up `/var/www/pokerops` and the active Nginx site, installs a
same-origin read-only proxy to the worker on `127.0.0.1:8787`, and performs a
public smoke test. Internal/write endpoints are blocked at Nginx. Any failure
after activation automatically restores both the frontend and Nginx backup.

Run the helper from a raw URL pinned to the full helper commit supplied in the
deployment handoff:

```bash
curl -fsSL https://raw.githubusercontent.com/yovoweqif674-cyber/pokerops-bootstrap/FULL_HELPER_COMMIT/frontend-deploy.sh | sudo bash
```

The public ZIP contains only browser assets that are served by the production
site. It contains no runtime env, database URL, worker token, room credential,
or migration credential.

## Runtime-only break-glass deployment

`runtime-only-deploy.sh` deploys one exact application commit using the existing
restricted worker runtime configuration already installed on the VPS. It never
requests an administrative database URL, does not run migrations, and does not
execute SQL or DDL. The script verifies the private GitHub commit, builds the
exact Docker image, stops the previous permanent scheduler, runs exactly one
isolated `--once` catalog/info/state live smoke, and only then starts the
permanent worker. It requires fresh scheduler, job-worker, and catalog
heartbeats, completed startup reconciliation, zero stuck runs, expired leases,
and unclassified failures, sanitized catalog/detail/timeline contracts, scoped
facets, restart and queue recovery, and an unchanged `/var/www/pokerops` before
activation. Known terminal failures are reported explicitly and are the only
permitted degraded operational state.

If the shared runtime env is missing, the helper generates a one-time age key,
dispatches the runtime-only sealed-config workflow from `deployment-control`,
and atomically installs the verified decrypted file as `root:root` mode `0600`.
The ephemeral key and downloaded artifact are removed before deployment.

Run it as root with a full 40-character commit SHA. Use a raw URL pinned to the
exact bootstrap commit supplied with the deployment handoff.

This public repository contains the secret-free bootstrap entrypoint for PokerOps Tournament Ingestion.
It installs missing Ubuntu/Debian dependencies, authenticates the root GitHub CLI session when needed,
requests a short-lived age-encrypted configuration artifact, verifies an immutable application Release,
deploys one Docker worker, and runs independent post-deploy and rollback gates.

Production configuration is never stored here or in application Release assets. GitHub Environment
secrets are encrypted to a fresh age X25519 recipient generated on the VPS for each run.

## Production command

Always pin the raw wrapper URL to the full bootstrap commit. The wrapper itself
pins the exact application Release, runtime helper, frontend helper, payload,
and every SHA-256:

```bash
curl -fsSL https://raw.githubusercontent.com/yovoweqif674-cyber/pokerops-bootstrap/FULL_WRAPPER_COMMIT/deploy.sh | sudo bash
```

The legacy `tournament-ingestion.sh` remains available only through the
preserved `deploy-v3` rollback line. The new runtime-only path neither accepts
nor requests a migration URL and never executes `migrate.mjs`, SQL, or DDL.

No VPS deployment is performed by publishing or testing this repository.
