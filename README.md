# PokerOps Tournament Ingestion bootstrap

## Runtime-only break-glass deployment

`runtime-only-deploy.sh` deploys one exact application commit using the existing
restricted worker runtime configuration already installed on the VPS. It never
requests an administrative database URL, does not run migrations, and does not
execute SQL or DDL. The script verifies the private GitHub commit, builds one
Docker worker, performs two live catalog collections, checks duplicate safety,
tests restart and queue recovery, preserves `/var/www/pokerops`, and activates
the release only after all checks pass.

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
