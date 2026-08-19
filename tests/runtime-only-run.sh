#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/runtime-only-deploy.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

bash -n "$SCRIPT"

if shellcheck --version >/dev/null 2>&1; then
  shellcheck "$SCRIPT"
fi

if grep -q 'MIGRATION_DATABASE_URL' "$SCRIPT"; then exit 1; fi
if grep -q '\.env\.migration' "$SCRIPT"; then exit 1; fi
if grep -q 'migrate\.mjs' "$SCRIPT"; then exit 1; fi
grep -q 'yovoweqif674-cyber/po' "$SCRIPT"
grep -q 'xpajqdsppawnjmvewkep' "$SCRIPT"
grep -q '/var/www/pokerops' "$SCRIPT"
grep -q 'canonicalDuplicates == 0' "$SCRIPT"
if grep -q '/internal/catalog/collect' "$SCRIPT"; then exit 1; fi
if grep -q '\.leader' "$SCRIPT"; then exit 1; fi
grep -q '/internal/queue-recovery/probe' "$SCRIPT"
grep -q '/api/ingestion/health' "$SCRIPT"
grep -q '/api/tournaments?scope=current' "$SCRIPT"
grep -q '/timeline?limit=10' "$SCRIPT"
grep -q 'presentInLatestSuccessfulCatalog == true' "$SCRIPT"
grep -q 'catalog data cannot prove filtered and scoped totals' "$SCRIPT"
grep -q 'public API response exposes a forbidden field' "$SCRIPT"
grep -q 'tournament-ingestion-runtime-sealed-config.yml' "$SCRIPT"
grep -q 'runtime-sealed-config-' "$SCRIPT"
grep -q 'age-keygen -o' "$SCRIPT"
grep -q 'runtime-config.tar.age' "$SCRIPT"
grep -q '"commitSha","configType","encryptedFile"' "$SCRIPT"
grep -q 'mv -fT.*runtime_env' "$SCRIPT"
grep -q 'docker compose restart worker' "$SCRIPT"
grep -q 'mv -Tf.*current' "$SCRIPT"
grep -q "trap 'on_error \$?' ERR" "$SCRIPT"
grep -q 'runtime-deploy-failed-' "$SCRIPT"
grep -q 'write_failure_report.*status' "$SCRIPT"

stop_line="$(grep -n 'stage="existing-worker-stop"' "$SCRIPT" | cut -d: -f1)"
once_line="$(grep -n 'docker compose run --rm --no-deps worker node dist/index.js --once' "$SCRIPT" | cut -d: -f1)"
permanent_line="$(grep -n 'stage="permanent-worker-start"' "$SCRIPT" | cut -d: -f1)"
[[ "$stop_line" -lt "$once_line" && "$once_line" -lt "$permanent_line" ]]
[[ "$(grep -c -- '--once' "$SCRIPT")" == 1 ]]

# Load only function definitions; the executable's final line is intentionally main "$@".
sed '$d' "$SCRIPT" >"$TEMP/library.sh"
# shellcheck disable=SC1091
source "$TEMP/library.sh"

# The following globals are consumed by sourced helper functions.
# shellcheck disable=SC2034
failure_reported=false
# shellcheck disable=SC2034
stage="synthetic-post-start-check"
failure_output="$({
  report_failure "synthetic failure"
  report_failure "duplicate failure"
} 2>&1)"
[[ "$(grep -c '^DEPLOYMENT FAILED$' <<<"$failure_output")" == "1" ]]
grep -q '^stage=synthetic-post-start-check$' <<<"$failure_output"
grep -q '^error=synthetic failure$' <<<"$failure_output"
if grep -q 'duplicate failure' <<<"$failure_output"; then exit 1; fi

healthy_json='{"data":{"status":"healthy","reasons":[],"catalog":{"fresh":true},"scheduler":{"fresh":true},"jobWorker":{"fresh":true},"queue":{"failed":0,"terminal":0,"unclassified":0,"expiredLeases":0},"runs":{"stuck":0}}}'
terminal_json='{"data":{"status":"degraded","reasons":["failed_jobs_present"],"catalog":{"fresh":true},"scheduler":{"fresh":true},"jobWorker":{"fresh":true},"queue":{"failed":2,"terminal":2,"unclassified":0,"expiredLeases":0},"runs":{"stuck":0}}}'
validate_operational_health_json "$healthy_json"
validate_operational_health_json "$terminal_json"

for invalid_health in \
  "$(jq -c '.data.status="unavailable"' <<<"$healthy_json")" \
  "$(jq -c '.data.status="stale"' <<<"$healthy_json")" \
  "$(jq -c '.data.catalog.fresh=false' <<<"$healthy_json")" \
  "$(jq -c '.data.scheduler.fresh=false' <<<"$healthy_json")" \
  "$(jq -c '.data.jobWorker.fresh=false' <<<"$healthy_json")" \
  "$(jq -c '.data.runs.stuck=1' <<<"$healthy_json")" \
  "$(jq -c '.data.queue.unclassified=1' <<<"$healthy_json")" \
  "$(jq -c '.data.queue.expiredLeases=1' <<<"$healthy_json")" \
  "$(jq -c '.data.queue.failed=1' <<<"$healthy_json")" \
  "$(jq -c '.data.status="degraded" | .data.reasons=["due_queue_lagging"]' <<<"$healthy_json")"; do
  if validate_operational_health_json "$invalid_health"; then
    echo "invalid operational health was accepted" >&2
    exit 1
  fi
done

reconciliation_json='{"data":{"startupReconciliation":{"status":"completed","reconciledAt":"2026-08-19T00:00:00.000Z","orphanedRunsClosed":17,"expiredLeasesRecovered":1,"jobsRequeued":3,"jobsCancelled":1,"jobsTerminal":0,"jobsUnclassified":0}}}'
validate_startup_reconciliation_json "$reconciliation_json"
if validate_startup_reconciliation_json '{"data":{}}'; then
  echo "missing startup reconciliation was accepted" >&2
  exit 1
fi
if validate_startup_reconciliation_json "$(jq -c '.data.startupReconciliation.jobsUnclassified=1' <<<"$reconciliation_json")"; then
  echo "unclassified reconciliation result was accepted" >&2
  exit 1
fi

write_env() {
  local path="$1"
  {
    printf 'DATABASE_URL=postgresql://%s.%s:%s@%s:%s/%s?sslmode=%s&application_name=%s\n' \
      pokerops_tournament_worker xpajqdsppawnjmvewkep encoded pooler.example 5432 postgres require pokerops
    printf '%s=%s\n' IGNITION_USERNAME user
    printf '%s=%s\n' IGNITION_PASSWORD password
    printf '%s=%s\n' IGNITION_DEVICE_ID device
    printf '%s=%s\n' IGNITION_PROXY_HOST proxy.example
    printf '%s=%s\n' IGNITION_PROXY_PORT 10000
    printf '%s=%s\n' IGNITION_PROXY_USERNAME_TEMPLATE template
    printf '%s=%s\n' IGNITION_PROXY_PASSWORD proxy-password
    printf '%s=%s\n' IGNITION_ROOM_PROXY_TAG tourney001
    printf '%s=%s\n' CAPSOLVER_CLIENT_KEY key
    printf '%s=%s\n' INTERNAL_API_TOKEN token
  } >"$path"
}

write_env "$TEMP/valid.env"
validate_runtime_env "$TEMP/valid.env"

cp "$TEMP/valid.env" "$TEMP/wrong-port.env"
sed -i 's/:5432\//:6543\//' "$TEMP/wrong-port.env"
if (validate_runtime_env "$TEMP/wrong-port.env") >/dev/null 2>&1; then
  echo "wrong port was accepted" >&2
  exit 1
fi

cp "$TEMP/valid.env" "$TEMP/wrong-role.env"
sed -i 's/pokerops_tournament_worker/postgres/' "$TEMP/wrong-role.env"
if (validate_runtime_env "$TEMP/wrong-role.env") >/dev/null 2>&1; then
  echo "wrong role was accepted" >&2
  exit 1
fi

cp "$TEMP/valid.env" "$TEMP/wrong-tag.env"
sed -i 's/tourney001/wrong/' "$TEMP/wrong-tag.env"
if (validate_runtime_env "$TEMP/wrong-tag.env") >/dev/null 2>&1; then
  echo "wrong proxy tag was accepted" >&2
  exit 1
fi

cp "$TEMP/valid.env" "$TEMP/missing-key.env"
sed -i '/^INTERNAL_API_TOKEN=/d' "$TEMP/missing-key.env"
if (validate_runtime_env "$TEMP/missing-key.env") >/dev/null 2>&1; then
  echo "missing key was accepted" >&2
  exit 1
fi

ln -s "$TEMP/valid.env" "$TEMP/symlink.env"
if [[ -L "$TEMP/symlink.env" ]]; then
  if (validate_runtime_env "$TEMP/symlink.env") >/dev/null 2>&1; then
    echo "symlink env was accepted" >&2
    exit 1
  fi
fi

echo "runtime-only helper tests: PASS"
