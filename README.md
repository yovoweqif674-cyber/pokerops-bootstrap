# PokerOps Tournament Planner bootstrap

This branch is the paused Phase A handoff for Tournament Planner Mode. It does
not activate live tournament monitoring, a canary, frontend publication, or
retention cleanup.

## Phase A safety boundary

The pinned wrapper downloads one byte-exact `planner-phase-a-deploy.sh`, checks
its SHA-256, and passes the immutable application commit. Before any migration,
the helper requires:

- explicit `TOURNAMENT_INGESTION_PROFILE=planner`;
- `PLANNER_MODE=maintenance`;
- `INFO_FETCH_MODE=selected_only`;
- `ENABLE_SCHEDULER=false` and `ENABLE_JOB_WORKER=false`;
- a root-owned PostgreSQL service definition and the explicit
  `POKEROPS_PLANNER_PHASE_A_APPROVED=YES` operator gate.

The helper builds the exact source, stops every existing tournament worker,
creates and verifies a full custom-format PostgreSQL backup, applies only the
two forward Planner migrations, runs DB-only `--reconcile-only`, and starts
the API in maintenance mode. Success requires paused scheduler/job-worker
health, no expired or unclassified leases, and storage below the degraded
threshold. The report records `roomRequestsEnabled=false`,
`cleanupApplied=false`, and `canaryActivated=false`.

No production execution is performed by publishing this repository. Phase B
cleanup and Phase C canary require separate approvals and are intentionally not
implemented by the Phase A wrapper.

## Immutable frontend payload

The repository also contains the Planner UI payload for later activation. Phase
A does not publish it.

- source: `yovoweqif674-cyber/po@f2b7d46b49da90c0e964ef9b0e65df1900a533e1`
- archive SHA-256: `f4152b0823c86c99fb68d38d2e6bd38436bba3f1f6bfc5c01e28526c8ccc737e`
- entry JS: `assets/index-BoDsFUEu.js`
- entry CSS: `assets/index-B5yM79TK.css`
- route: `/preview/v4/manager/tournaments`

The Nginx helper remains read-only for the ingestion API; authenticated Planner
commands go directly through Supabase RPC and never through the worker token.


