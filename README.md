# PokerOps Tournament Ingestion bootstrap

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
execute SQL or DDL. The script verifies the private GitHub commit, builds one
Docker worker, performs two live catalog collections, checks duplicate safety,
tests restart and queue recovery, preserves `/var/www/pokerops`, and activates
the release only after all checks pass.

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

Always pin the raw script URL to the full bootstrap commit and pass the full application Release commit:

```bash
curl -fsSL https://raw.githubusercontent.com/yovoweqif674-cyber/pokerops-bootstrap/FULL_BOOTSTRAP_COMMIT/tournament-ingestion.sh \
  | sudo bash -s -- FULL_APPLICATION_RELEASE_COMMIT
```

The only permitted flags precede the application SHA: `--refresh-config`, `--skip-config-refresh`, and
`--diagnostics-only`. The default safely refreshes shared configuration before deployment.

No VPS deployment is performed by publishing or testing this repository.
