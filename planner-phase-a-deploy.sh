#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY='yovoweqif674-cyber/po'
readonly SERVICE='pokerops-tournament-ingestion'
readonly INSTALL_ROOT='/opt/pokerops-tournament-ingestion'
readonly API_BASE='http://127.0.0.1:8787'
readonly PLANNER_MIGRATION='supabase/migrations/20260820101900_tournament_planner_mode.sql'
readonly RETENTION_MIGRATION='supabase/migrations/20260820101901_tournament_planner_retention.sql'

stage='preflight'
temporary_root=''
release_sha=''
service_dir=''
backup_dir=''
runtime_env=''

log() { printf '%s\n' "$*" >&2; }
die() { log 'PHASE A FAILED'; log "stage=$stage"; log "error=$*"; exit 1; }

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$temporary_root" && -d "$temporary_root" ]]; then
    [[ "$temporary_root" == /tmp/pokerops-planner-phase-a.* ]] || exit 1
    rm -rf -- "$temporary_root"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

env_value() {
  local file="$1" key="$2"
  awk -v wanted="$key" '
    index($0, "=") > 0 {
      key = substr($0, 1, index($0, "=") - 1)
      if (key == wanted) {
        value = substr($0, index($0, "=") + 1)
        sub(/\r$/, "", value)
        print value
      }
    }
  ' "$file"
}

require_explicit_env() {
  local file="$1" key="$2" expected="$3" value
  [[ "$(grep -cE "^${key}=" "$file")" == '1' ]] || die "runtime env must contain exactly one explicit ${key}"
  value="$(env_value "$file" "$key")"
  [[ "$value" == "$expected" ]] || die "runtime env ${key} must equal ${expected}"
}

validate_runtime_env() {
  local file="$1" database_url
  [[ -f "$file" && ! -L "$file" ]] || die 'runtime env must be a regular non-symlink file'
  [[ "$(stat -c '%U:%G:%a' "$file")" == 'root:root:600' ]] || die 'runtime env must be root:root mode 0600'
  require_explicit_env "$file" TOURNAMENT_INGESTION_PROFILE planner
  require_explicit_env "$file" PLANNER_MODE maintenance
  require_explicit_env "$file" INFO_FETCH_MODE selected_only
  require_explicit_env "$file" ENABLE_SCHEDULER false
  require_explicit_env "$file" ENABLE_JOB_WORKER false
  require_explicit_env "$file" CATALOG_INTERVAL_MS 600000
  database_url="$(env_value "$file" DATABASE_URL)"
  [[ "$database_url" == postgresql://pokerops_tournament_worker.* ]] || die 'DATABASE_URL must use the restricted worker role'
  [[ "$database_url" =~ ([?&])sslmode=require([&]|$) ]] || die 'DATABASE_URL must require TLS'
}

install_dependencies() {
  local command_name
  for command_name in curl git gh jq sha256sum pg_dump pg_restore psql docker flock; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: ${command_name}"
  done
  docker compose version >/dev/null 2>&1 || die 'Docker Compose plugin is unavailable'
}

stop_all_tournament_workers() {
  local ids
  ids="$(docker ps -q --filter "label=com.docker.compose.project=${SERVICE}" --filter 'label=com.docker.compose.service=worker')"
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker stop $ids >/dev/null
  fi
  [[ -z "$(docker ps -q --filter "label=com.docker.compose.project=${SERVICE}" --filter 'label=com.docker.compose.service=worker')" ]]     || die 'a tournament worker is still running'
}

write_backup_manifest() {
  local dump_path="$1" manifest_path="$2" dump_sha dump_size
  pg_restore --list "$dump_path" >/dev/null || die 'database backup verification failed'
  dump_sha="$(sha256sum "$dump_path" | awk '{print $1}')"
  dump_size="$(stat -c '%s' "$dump_path")"
  jq -n     --arg generatedAt "$(date -u +%FT%TZ)"     --arg applicationCommit "$release_sha"     --arg dumpFile "$(basename "$dump_path")"     --arg dumpSha256 "$dump_sha"     --argjson dumpBytes "$dump_size"     '{schemaVersion:1,phase:"planner-maintenance",generatedAt:$generatedAt,
      applicationCommit:$applicationCommit,dumpFile:$dumpFile,
      dumpSha256:$dumpSha256,dumpBytes:$dumpBytes,verified:true,
      cleanupApproved:false}' >"$manifest_path"
  chmod 0600 "$manifest_path"
}

wait_for_maintenance_health() {
  local health_json=''
  for _ in $(seq 1 60); do
    health_json="$(curl -fsS --max-time 5 "${API_BASE}/api/ingestion/health" 2>/dev/null || true)"
    if jq -e '
      .data.status == "paused"
      and .data.scheduler.status == "paused"
      and .data.jobWorker.status == "paused"
      and .data.storage.status != "hard_stop"
      and .data.storage.status != "degraded"
      and .data.queue.expiredLeases == 0
      and .data.queue.unclassified == 0
    ' >/dev/null 2>&1 <<<"$health_json"; then
      printf '%s' "$health_json" >"$temporary_root/maintenance-health.json"
      return
    fi
    sleep 2
  done
  die 'maintenance health gate failed'
}

write_report() {
  local timestamp report_path health_path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  health_path="$temporary_root/maintenance-health.json"
  report_path="$INSTALL_ROOT/deployment-history/planner-phase-a-${timestamp}.json"
  jq -n     --arg generatedAt "$(date -u +%FT%TZ)"     --arg applicationCommit "$release_sha"     --arg backupManifest "$backup_dir/backup-manifest.json"     --argjson databaseSizeBytes "$(jq '.data.storage.databaseSizeBytes' "$health_path")"     --arg storageStatus "$(jq -r '.data.storage.status' "$health_path")"     '{schemaVersion:1,phase:"planner-maintenance",status:"paused",generatedAt:$generatedAt,
      applicationCommit:$applicationCommit,profile:"planner",plannerMode:"maintenance",
      schedulerEnabled:false,jobWorkerEnabled:false,roomRequestsEnabled:false,
      migrationsApplied:["20260820101900_tournament_planner_mode.sql","20260820101901_tournament_planner_retention.sql"],
      backupManifest:$backupManifest,databaseSizeBytes:$databaseSizeBytes,
      storageStatus:$storageStatus,cleanupApplied:false,canaryActivated:false}' >"$temporary_root/report.json"
  install -o root -g root -m 0600 "$temporary_root/report.json" "$report_path"
  printf '%s\n'     'TOURNAMENT PLANNER PHASE A SUCCESS'     "application_commit=${release_sha}"     'profile=planner'     'planner_mode=maintenance'     'scheduler_enabled=false'     'job_worker_enabled=false'     'room_requests_enabled=false'     "backup_manifest=${backup_dir}/backup-manifest.json"     "storage_status=$(jq -r '.data.storage.status' "$health_path")"     'cleanup_applied=false'     'canary_activated=false'     "report=${report_path}"
}

main() {
  [[ $# -eq 1 ]] || die 'usage: planner-phase-a-deploy.sh <full-40-character-commit>'
  release_sha="$1"
  [[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || die 'release SHA must contain 40 lowercase hexadecimal characters'
  [[ "$(id -u)" == '0' ]] || die 'Phase A must run as root'
  [[ "${POKEROPS_PLANNER_PHASE_A_APPROVED:-}" == 'YES' ]] || die 'POKEROPS_PLANNER_PHASE_A_APPROVED=YES is required'
  [[ "${POKEROPS_PLANNER_PGSERVICE:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die 'POKEROPS_PLANNER_PGSERVICE is required'
  [[ -f /root/.pg_service.conf && ! -L /root/.pg_service.conf ]] || die 'root pg_service file is missing'
  [[ "$(stat -c '%U:%G:%a' /root/.pg_service.conf)" == 'root:root:600' ]] || die 'pg_service file must be root:root mode 0600'

  umask 077
  temporary_root="$(mktemp -d /tmp/pokerops-planner-phase-a.XXXXXX)"
  install -d -o root -g root -m 0750 "$INSTALL_ROOT" "$INSTALL_ROOT/releases" "$INSTALL_ROOT/shared" "$INSTALL_ROOT/backups" "$INSTALL_ROOT/deployment-history"
  exec 9>"$INSTALL_ROOT/.planner-phase-a.lock"
  flock -n 9 || die 'another Tournament Planner maintenance operation is running'

  stage='dependencies'
  install_dependencies

  stage='runtime-env-preflight'
  runtime_env="$INSTALL_ROOT/shared/.env.tournament.local"
  validate_runtime_env "$runtime_env"

  stage='migration-authority-preflight'
  local migration_role migration_database
  migration_role="$(psql "service=${POKEROPS_PLANNER_PGSERVICE}" -X -A -t -v ON_ERROR_STOP=1 -c 'select current_user')"
  migration_database="$(psql "service=${POKEROPS_PLANNER_PGSERVICE}" -X -A -t -v ON_ERROR_STOP=1 -c 'select current_database()')"
  [[ "$migration_role" != pokerops_tournament_worker* ]] || die 'migration service must not use the worker role'
  [[ "$migration_database" == 'postgres' ]] || die 'migration service must target database postgres'

  stage='exact-source'
  gh auth status --hostname github.com >/dev/null 2>&1 || die 'authenticated GitHub CLI access is required'
  [[ "$(gh api "repos/${REPOSITORY}/commits/${release_sha}" --jq '.sha')" == "$release_sha" ]] || die 'GitHub did not resolve the exact application commit'
  gh repo clone "$REPOSITORY" "$temporary_root/repository" -- --filter=blob:none --no-checkout >/dev/null
  git -C "$temporary_root/repository" checkout --detach "$release_sha" >/dev/null 2>&1
  [[ "$(git -C "$temporary_root/repository" rev-parse HEAD)" == "$release_sha" ]] || die 'checked out source does not match the requested commit'

  stage='release-install'
  local release_dir="$INSTALL_ROOT/releases/$release_sha"
  service_dir="$release_dir/services/tournament-ingestion"
  if [[ ! -d "$release_dir" ]]; then
    mkdir "$temporary_root/release"
    git -C "$temporary_root/repository" archive --format=tar "$release_sha"       | tar -xf - -C "$temporary_root/release" --no-same-owner --no-same-permissions
    printf '%s\n' "$release_sha" >"$temporary_root/release/.pokerops-release-sha"
    chown -R root:root "$temporary_root/release"
    mv "$temporary_root/release" "$release_dir"
  fi
  [[ "$(tr -d '\r\n' <"$release_dir/.pokerops-release-sha")" == "$release_sha" ]] || die 'release marker mismatch'
  [[ -f "$service_dir/docker-compose.yml" && -f "$service_dir/Dockerfile" ]] || die 'Tournament Planner service source is incomplete'
  ln -sfn "$runtime_env" "$service_dir/.env.tournament.local"

  stage='image-build'
  (
    cd "$service_dir"
    TOURNAMENT_RELEASE_SHA="$release_sha" TOURNAMENT_IMAGE_TAG="$release_sha" docker compose config --quiet
    TOURNAMENT_RELEASE_SHA="$release_sha" TOURNAMENT_IMAGE_TAG="$release_sha" docker compose build --pull worker
  )

  stage='worker-pause'
  stop_all_tournament_workers

  stage='verified-backup'
  local backup_timestamp dump_path
  backup_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="$INSTALL_ROOT/backups/planner-phase-a-${backup_timestamp}"
  install -d -o root -g root -m 0700 "$backup_dir"
  dump_path="$backup_dir/postgres.dump"
  PGCONNECT_TIMEOUT=15 pg_dump --dbname="service=${POKEROPS_PLANNER_PGSERVICE}" --format=custom --no-owner --no-acl --file="$dump_path"
  chmod 0600 "$dump_path"
  write_backup_manifest "$dump_path" "$backup_dir/backup-manifest.json"

  stage='forward-migrations'
  psql "service=${POKEROPS_PLANNER_PGSERVICE}" -X -v ON_ERROR_STOP=1 -f "$release_dir/$PLANNER_MIGRATION"
  psql "service=${POKEROPS_PLANNER_PGSERVICE}" -X -v ON_ERROR_STOP=1 -f "$release_dir/$RETENTION_MIGRATION"

  stage='reconcile-only'
  (
    cd "$service_dir"
    TOURNAMENT_RELEASE_SHA="$release_sha" TOURNAMENT_IMAGE_TAG="$release_sha"       docker compose run --rm --no-deps worker node dist/index.js --reconcile-only
  )

  stage='maintenance-api'
  (
    cd "$service_dir"
    TOURNAMENT_RELEASE_SHA="$release_sha" TOURNAMENT_IMAGE_TAG="$release_sha" docker compose up -d worker
  )
  ln -sfn "$release_dir" "$INSTALL_ROOT/current"
  wait_for_maintenance_health

  stage='report'
  write_report
}

main "$@"

