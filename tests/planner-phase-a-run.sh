#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/planner-phase-a-deploy.sh"

bash -n "$SCRIPT"
grep -Fq "TOURNAMENT_INGESTION_PROFILE planner" "$SCRIPT"
grep -Fq "PLANNER_MODE maintenance" "$SCRIPT"
grep -Fq "INFO_FETCH_MODE selected_only" "$SCRIPT"
grep -Fq "ENABLE_SCHEDULER false" "$SCRIPT"
grep -Fq "ENABLE_JOB_WORKER false" "$SCRIPT"
grep -Fq "CATALOG_INTERVAL_MS 600000" "$SCRIPT"
grep -Fq "POKEROPS_PLANNER_PHASE_A_APPROVED" "$SCRIPT"
grep -Fq "POKEROPS_PLANNER_PGSERVICE" "$SCRIPT"
grep -Fq "migration service must not use the worker role" "$SCRIPT"
grep -Fq "pg_dump --dbname=" "$SCRIPT"
grep -Fq "pg_restore --list" "$SCRIPT"
grep -Fq "20260820101900_tournament_planner_mode.sql" "$SCRIPT"
grep -Fq "20260820101901_tournament_planner_retention.sql" "$SCRIPT"
grep -Fq -- "--reconcile-only" "$SCRIPT"
grep -Fq '.data.status == "paused"' "$SCRIPT"
grep -Fq 'room_requests_enabled=false' "$SCRIPT"
grep -Fq 'cleanup_applied=false' "$SCRIPT"
grep -Fq 'canary_activated=false' "$SCRIPT"

if grep -Fq -- '--once' "$SCRIPT"; then
  printf '%s\n' 'Phase A must not execute live room smoke' >&2
  exit 1
fi
if grep -Fq 'runtime-only-deploy.sh' "$SCRIPT"; then
  printf '%s\n' 'Phase A must not reuse the legacy runtime activator' >&2
  exit 1
fi
stop_line="$(grep -n "stage='worker-pause'" "$SCRIPT" | cut -d: -f1)"
backup_line="$(grep -n "stage='verified-backup'" "$SCRIPT" | cut -d: -f1)"
migration_line="$(grep -n "stage='forward-migrations'" "$SCRIPT" | cut -d: -f1)"
maintenance_line="$(grep -n "stage='maintenance-api'" "$SCRIPT" | cut -d: -f1)"
[[ "$stop_line" -lt "$backup_line" ]]
[[ "$backup_line" -lt "$migration_line" ]]
[[ "$migration_line" -lt "$maintenance_line" ]]

printf '%s\n' 'planner Phase A contracts: PASS'

