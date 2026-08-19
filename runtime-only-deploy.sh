#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY="yovoweqif674-cyber/po"
readonly RUNTIME_CONFIG_WORKFLOW="tournament-ingestion-runtime-sealed-config.yml"
readonly SERVICE="pokerops-tournament-ingestion"
readonly SUPABASE_REF="xpajqdsppawnjmvewkep"
readonly INSTALL_ROOT="/opt/pokerops-tournament-ingestion"
readonly FRONTEND_ROOT="/var/www/pokerops"
readonly API_BASE="http://127.0.0.1:8787"

stage="preflight"
temporary_root=""
new_service_dir=""
old_release=""
new_worker_started=false
deployment_succeeded=false
report_path=""

log() { printf '%s\n' "$*" >&2; }
die() { log "DEPLOYMENT FAILED"; log "stage=$stage"; log "error=$*"; exit 1; }

file_fingerprint() {
  sha256sum -- "$1" | awk '{print $1}'
}

tree_fingerprint() {
  local root="$1"
  [[ -d "$root" ]] || die "frontend root is missing"
  find "$root" -xdev -type f -print0 \
    | sort -z \
    | xargs -0 -r sha256sum \
    | sha256sum \
    | awk '{print $1}'
}

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

validate_runtime_env() {
  local file="$1" key value database_url room_tag
  local required=(
    DATABASE_URL
    IGNITION_USERNAME
    IGNITION_PASSWORD
    IGNITION_DEVICE_ID
    IGNITION_PROXY_HOST
    IGNITION_PROXY_PORT
    IGNITION_PROXY_USERNAME_TEMPLATE
    IGNITION_PROXY_PASSWORD
    IGNITION_ROOM_PROXY_TAG
    CAPSOLVER_CLIENT_KEY
    INTERNAL_API_TOKEN
  )

  [[ -e "$file" ]] || die "runtime env is missing"
  [[ ! -L "$file" ]] || die "runtime env must not be a symlink"
  [[ -f "$file" ]] || die "runtime env must be a regular file"

  for key in "${required[@]}"; do
    value="$(env_value "$file" "$key")"
    [[ -n "$value" ]] || die "runtime env key is missing or empty: $key"
    [[ "$(grep -cE "^${key}=" "$file")" == "1" ]] || die "runtime env key must occur exactly once: $key"
  done

  database_url="$(env_value "$file" DATABASE_URL)"
  [[ "$database_url" == postgresql://pokerops_tournament_worker."$SUPABASE_REF":* ]] \
    || die "DATABASE_URL does not use the restricted worker role"
  [[ "$database_url" =~ @[^/]+:5432/postgres([?]|$) ]] \
    || die "DATABASE_URL must use port 5432 and database postgres"
  [[ "$database_url" != *":6543"* ]] || die "transaction pooler port 6543 is forbidden"
  [[ "$database_url" =~ ([?&])sslmode=require([&]|$) ]] || die "DATABASE_URL must require TLS"

  room_tag="$(env_value "$file" IGNITION_ROOM_PROXY_TAG)"
  [[ "$room_tag" == "tourney001" ]] || die "IGNITION_ROOM_PROXY_TAG must be tourney001"
}

install_dependencies() {
  local missing=false package
  for package in curl git gh jq tar gzip sha256sum find xargs diff age age-keygen; do
    command -v "$package" >/dev/null 2>&1 || missing=true
  done
  command -v docker >/dev/null 2>&1 || missing=true
  docker compose version >/dev/null 2>&1 || missing=true

  if [[ "$missing" == true ]]; then
    [[ -r /etc/os-release ]] || die "unsupported operating system"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == ubuntu || "${ID:-}" == debian || "${ID_LIKE:-}" == *debian* ]] \
      || die "only Ubuntu and Debian are supported"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl git gh jq tar gzip coreutils findutils diffutils util-linux age
    if ! command -v docker >/dev/null 2>&1; then
      apt-get install -y -qq docker.io
    fi
    if ! docker compose version >/dev/null 2>&1; then
      apt-get install -y -qq docker-compose-v2 \
        || apt-get install -y -qq docker-compose-plugin
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"
}

ensure_github_auth() {
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    return
  fi
  [[ -r /dev/tty && -w /dev/tty ]] || die "GitHub authentication requires an interactive terminal"
  log "GitHub authentication is required; complete the browser device flow."
  gh auth login --hostname github.com --git-protocol https --web </dev/tty >/dev/tty
  gh auth status --hostname github.com >/dev/null 2>&1 || die "GitHub authentication failed"
}

obtain_runtime_env() {
  local release_sha="$1" runtime_env="$2"
  local key_dir="$temporary_root/age" identity recipient nonce title runs_json run_id run_url
  local download_dir="$temporary_root/runtime-artifact"
  local encrypted_path manifest_path plaintext_tar plaintext_dir decrypted_env
  mkdir -m 0700 -- "$key_dir" "$download_dir"
  identity="$key_dir/identity.txt"
  age-keygen -o "$identity" >/dev/null 2>&1
  chmod 0600 "$identity"
  recipient="$(age-keygen -y "$identity")"
  [[ "$recipient" =~ ^age1[023456789acdefghjklmnpqrstuvwxyz]{50,90}$ ]] \
    || die "ephemeral age recipient is invalid"
  nonce="runtime-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  title="runtime-config-$nonce"

  gh workflow run "$RUNTIME_CONFIG_WORKFLOW" \
    --repo "$REPOSITORY" \
    --ref deployment-control \
    -f "commit_sha=$release_sha" \
    -f "age_recipient=$recipient" \
    -f "nonce=$nonce" >/dev/null

  run_id=""
  for _ in $(seq 1 60); do
    runs_json="$(gh run list \
      --repo "$REPOSITORY" \
      --workflow "$RUNTIME_CONFIG_WORKFLOW" \
      --branch deployment-control \
      --event workflow_dispatch \
      --limit 100 \
      --json databaseId,displayTitle,url 2>/dev/null || true)"
    run_id="$(jq -r --arg title "$title" '[.[] | select(.displayTitle == $title)] | sort_by(.databaseId) | last | .databaseId // empty' <<<"$runs_json" 2>/dev/null || true)"
    run_url="$(jq -r --arg title "$title" '[.[] | select(.displayTitle == $title)] | sort_by(.databaseId) | last | .url // empty' <<<"$runs_json" 2>/dev/null || true)"
    [[ "$run_id" =~ ^[0-9]+$ ]] && break
    sleep 2
  done
  [[ "$run_id" =~ ^[0-9]+$ ]] || die "runtime config workflow run was not found by nonce"

  if ! gh run watch "$run_id" --repo "$REPOSITORY" --exit-status; then
    log "workflow_url=$run_url"
    die "runtime config workflow failed"
  fi
  gh run download "$run_id" \
    --repo "$REPOSITORY" \
    --name "runtime-sealed-config-$nonce" \
    --dir "$download_dir" >/dev/null

  encrypted_path="$download_dir/runtime-config.tar.age"
  manifest_path="$download_dir/runtime-config.manifest.json"
  [[ -f "$encrypted_path" && ! -L "$encrypted_path" ]] || die "encrypted runtime artifact is missing"
  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || die "runtime artifact manifest is missing"
  [[ "$(find "$download_dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" == 2 ]] \
    || die "runtime artifact must contain exactly two files"
  [[ -z "$(find "$download_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] \
    || die "runtime artifact contains a non-regular entry"

  jq -e \
    --arg commit "$release_sha" \
    --arg nonce "$nonce" \
    --arg project "$SUPABASE_REF" \
    '.schemaVersion == 2 and
     .configType == "runtime-only" and
     .service == "pokerops-tournament-ingestion" and
     .commitSha == $commit and
     .nonce == $nonce and
     .encryption == "age-x25519" and
     .encryptedFile == "runtime-config.tar.age" and
     .projectRef == $project and
     (.encryptedSha256 | test("^[0-9a-f]{64}$")) and
     (.runtimeEnvSha256 | test("^[0-9a-f]{64}$")) and
     ((keys | sort) == (["commitSha","configType","encryptedFile","encryptedSha256","encryption","generatedAt","nonce","projectRef","runtimeEnvSha256","schemaVersion","service"] | sort))' \
    "$manifest_path" >/dev/null || die "runtime artifact manifest validation failed"
  [[ "$(file_fingerprint "$encrypted_path")" == "$(jq -r '.encryptedSha256' "$manifest_path")" ]] \
    || die "encrypted runtime artifact checksum mismatch"

  plaintext_tar="$temporary_root/runtime-config.tar"
  plaintext_dir="$temporary_root/runtime-plaintext"
  mkdir -m 0700 -- "$plaintext_dir"
  age --decrypt --identity "$identity" --output "$plaintext_tar" "$encrypted_path" \
    || die "runtime artifact decryption failed"
  chmod 0600 "$plaintext_tar"
  mapfile -t tar_entries < <(tar -tf "$plaintext_tar")
  [[ "${#tar_entries[@]}" -eq 1 && "${tar_entries[0]}" == '.env.tournament.local' ]] \
    || die "runtime tar filename allowlist mismatch"
  tar -tvf "$plaintext_tar" | awk 'NR == 1 { exit(substr($1, 1, 1) == "-" ? 0 : 1) }' \
    || die "runtime tar entry must be a regular file"
  tar -xf "$plaintext_tar" -C "$plaintext_dir" --no-same-owner --no-same-permissions
  decrypted_env="$plaintext_dir/.env.tournament.local"
  [[ -f "$decrypted_env" && ! -L "$decrypted_env" ]] || die "decrypted runtime env is invalid"
  [[ "$(file_fingerprint "$decrypted_env")" == "$(jq -r '.runtimeEnvSha256' "$manifest_path")" ]] \
    || die "decrypted runtime env checksum mismatch"
  validate_runtime_env "$decrypted_env"

  local install_tmp
  install_tmp="$(mktemp "$INSTALL_ROOT/shared/.env.tournament.local.tmp.XXXXXX")"
  install -o root -g root -m 0600 "$decrypted_env" "$install_tmp"
  sync -f "$install_tmp"
  mv -fT "$install_tmp" "$runtime_env"
  sync -f "$INSTALL_ROOT/shared"
  [[ -f "$runtime_env" && ! -L "$runtime_env" ]] || die "atomic runtime env installation failed"
  [[ "$(stat -c '%U:%G:%a' "$runtime_env")" == root:root:600 ]] \
    || die "installed runtime env ownership or mode is invalid"

  shred -u -- "$plaintext_tar" "$decrypted_env" "$identity" 2>/dev/null || true
  rm -rf -- "$download_dir" "$plaintext_dir" "$key_dir"
}

wait_for_health() {
  local container_id="$1" attempt health running
  for attempt in $(seq 1 90); do
    running="$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)"
    if [[ "$running" == true && "$health" == healthy ]]; then
      return
    fi
    sleep 2
  done
  die "worker did not become healthy"
}

wait_for_scheduler() {
  local attempt status_json
  for attempt in $(seq 1 60); do
    status_json="$(curl -fsS "$API_BASE/api/ingestion/status" 2>/dev/null || true)"
    if jq -e '.data.workers.scheduler.leader == true' >/dev/null 2>&1 <<<"$status_json"; then
      return
    fi
    sleep 2
  done
  die "scheduler leadership was not established"
}

internal_post() {
  local path="$1"
  docker compose exec -T worker node -e '
    const path = process.argv[1];
    const token = process.env.INTERNAL_API_TOKEN;
    fetch(`http://127.0.0.1:8787${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}` }
    }).then(async (response) => {
      if (!response.ok) process.exit(1);
      await response.arrayBuffer();
    }).catch(() => process.exit(1));
  ' "$path" >/dev/null
}

restore_previous_release() {
  [[ "$new_worker_started" == true && "$deployment_succeeded" == false ]] || return
  log "Attempting automatic rollback."
  if [[ -n "$old_release" && -d "$old_release/services/tournament-ingestion" ]]; then
    local old_sha old_service
    old_sha="$(basename "$old_release")"
    old_service="$old_release/services/tournament-ingestion"
    ln -sfn "$INSTALL_ROOT/shared/.env.tournament.local" "$old_service/.env.tournament.local"
    (
      cd "$old_service"
      export TOURNAMENT_RELEASE_SHA="$old_sha"
      export TOURNAMENT_IMAGE_TAG="$old_sha"
      docker compose up -d worker >/dev/null
    ) || true
  elif [[ -n "$new_service_dir" && -d "$new_service_dir" ]]; then
    (
      cd "$new_service_dir"
      docker compose down --remove-orphans >/dev/null 2>&1
    ) || true
  fi
}

cleanup() {
  local status=$?
  trap - EXIT ERR INT TERM
  if [[ $status -ne 0 ]]; then
    restore_previous_release
    if [[ -n "$report_path" ]]; then
      log "report=$report_path"
    fi
  fi
  if [[ -n "$temporary_root" && -d "$temporary_root" ]]; then
    [[ "$temporary_root" == /tmp/pokerops-runtime-deploy.* ]] \
      || { log "refusing to clean an unexpected temporary path"; exit 1; }
    rm -rf -- "$temporary_root"
  fi
  exit "$status"
}

main() {
  [[ $# -eq 1 ]] || die "usage: runtime-only-deploy.sh <full-40-character-commit>"
  local release_sha="$1"
  [[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || die "release SHA must contain 40 lowercase hexadecimal characters"
  [[ "$(id -u)" == 0 ]] || die "production deployment must run as root"

  trap cleanup EXIT ERR INT TERM
  umask 077
  temporary_root="$(TMPDIR=/tmp mktemp -d /tmp/pokerops-runtime-deploy.XXXXXX)"

  stage="dependencies"
  install_dependencies

  stage="filesystem-preflight"
  install -d -o root -g root -m 0750 \
    "$INSTALL_ROOT" \
    "$INSTALL_ROOT/shared" \
    "$INSTALL_ROOT/releases" \
    "$INSTALL_ROOT/deployment-history"
  local runtime_env="$INSTALL_ROOT/shared/.env.tournament.local"
  if [[ ! -e "$runtime_env" ]]; then
    stage="github-authentication"
    ensure_github_auth
    stage="runtime-config"
    obtain_runtime_env "$release_sha" "$runtime_env"
  fi
  validate_runtime_env "$runtime_env"
  chown root:root "$runtime_env"
  chmod 0600 "$runtime_env"
  [[ "$(stat -c '%U:%G:%a' "$runtime_env")" == "root:root:600" ]] \
    || die "runtime env ownership or mode is incorrect"
  local runtime_fingerprint frontend_before
  runtime_fingerprint="$(file_fingerprint "$runtime_env")"
  frontend_before="$(tree_fingerprint "$FRONTEND_ROOT")"

  if [[ -L "$INSTALL_ROOT/current" ]]; then
    old_release="$(readlink -f "$INSTALL_ROOT/current")"
    [[ "$old_release" == "$INSTALL_ROOT/releases/"* ]] || die "current symlink escapes the releases directory"
  elif [[ -e "$INSTALL_ROOT/current" ]]; then
    die "current exists but is not a symlink"
  fi

  local existing_workers
  existing_workers="$(docker ps -aq \
    --filter "label=com.docker.compose.project=$SERVICE" \
    --filter 'label=com.docker.compose.service=worker' | wc -l | tr -d ' ')"
  if [[ "$existing_workers" != 0 && -z "$old_release" ]]; then
    die "an existing worker has no rollback-safe current symlink"
  fi

  stage="github-authentication"
  ensure_github_auth
  gh api "repos/$REPOSITORY" --jq '.full_name' 2>/dev/null | grep -Fxq "$REPOSITORY" \
    || die "private repository read access is unavailable"
  local resolved_sha
  resolved_sha="$(gh api "repos/$REPOSITORY/commits/$release_sha" --jq '.sha' 2>/dev/null)"
  [[ "$resolved_sha" == "$release_sha" ]] || die "GitHub did not resolve the exact requested commit"

  stage="exact-source"
  gh repo clone "$REPOSITORY" "$temporary_root/repository" -- --filter=blob:none --no-checkout >/dev/null
  git -C "$temporary_root/repository" checkout --detach "$release_sha" >/dev/null 2>&1
  [[ "$(git -C "$temporary_root/repository" rev-parse HEAD)" == "$release_sha" ]] \
    || die "checked-out source does not match the requested commit"

  local release_dir="$INSTALL_ROOT/releases/$release_sha"
  new_service_dir="$release_dir/services/tournament-ingestion"
  mkdir "$temporary_root/release"
  git -C "$temporary_root/repository" archive --format=tar "$release_sha" \
    | tar -xf - -C "$temporary_root/release" --no-same-owner --no-same-permissions
  printf '%s\n' "$release_sha" >"$temporary_root/release/.pokerops-release-sha"
  if [[ -d "$release_dir" ]]; then
    diff -qr \
      --exclude='.env.tournament.local' \
      --exclude='.pokerops-release-sha' \
      "$temporary_root/release" "$release_dir" >/dev/null \
      || die "existing release directory does not match the exact Git commit"
  else
    chown -R root:root "$temporary_root/release"
    mv "$temporary_root/release" "$release_dir"
  fi
  [[ -f "$release_dir/.pokerops-release-sha" ]] || die "release marker is missing"
  [[ "$(tr -d '\r\n' <"$release_dir/.pokerops-release-sha")" == "$release_sha" ]] \
    || die "release marker does not match the requested commit"
  [[ -f "$new_service_dir/docker-compose.yml" && -f "$new_service_dir/Dockerfile" ]] \
    || die "tournament worker source is incomplete"
  ln -sfn "$runtime_env" "$new_service_dir/.env.tournament.local"
  [[ "$(readlink -f "$new_service_dir/.env.tournament.local")" == "$runtime_env" ]] \
    || die "release runtime env link is invalid"

  stage="docker-build"
  cd "$new_service_dir"
  export TOURNAMENT_RELEASE_SHA="$release_sha"
  export TOURNAMENT_IMAGE_TAG="$release_sha"
  docker compose config --quiet
  docker compose build --pull worker

  stage="worker-start"
  docker compose up -d worker
  new_worker_started=true
  local container_id
  container_id="$(docker compose ps -q worker)"
  [[ -n "$container_id" ]] || die "worker container was not created"
  wait_for_health "$container_id"

  stage="runtime-boundaries"
  [[ "$(docker ps -q \
    --filter "label=com.docker.compose.project=$SERVICE" \
    --filter 'label=com.docker.compose.service=worker' | wc -l | tr -d ' ')" == 1 ]] \
    || die "expected exactly one running worker container"
  docker inspect "$container_id" \
    | jq -e '.[0].NetworkSettings.Ports["8787/tcp"] as $p | ($p | length) == 1 and $p[0].HostIp == "127.0.0.1" and $p[0].HostPort == "8787"' \
      >/dev/null || die "worker API is not bound exclusively to 127.0.0.1:8787"
  ! docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" \
    | grep -q '^MIGRATION_' || die "administrative configuration reached the worker container"
  [[ -f "$runtime_env" && ! -L "$runtime_env" ]] || die "shared runtime env changed type"
  [[ "$(file_fingerprint "$runtime_env")" == "$runtime_fingerprint" ]] || die "shared runtime env changed during deployment"

  stage="health-readiness"
  curl -fsS "$API_BASE/health" | jq -e '.status == "ok"' >/dev/null
  curl -fsS "$API_BASE/ready" | jq -e '.status == "ready"' >/dev/null
  local status_json
  status_json="$(curl -fsS "$API_BASE/api/ingestion/status")"
  jq -e '.data.catalog.canonicalDuplicates == 0' >/dev/null <<<"$status_json"

  stage="first-live-collect"
  internal_post /internal/catalog/collect
  status_json="$(curl -fsS "$API_BASE/api/ingestion/status")"
  jq -e '.data.catalog.uniqueTournaments >= 1 and .data.catalog.canonicalDuplicates == 0' >/dev/null <<<"$status_json"

  stage="second-live-collect"
  internal_post /internal/catalog/collect
  status_json="$(curl -fsS "$API_BASE/api/ingestion/status")"
  jq -e '.data.catalog.uniqueTournaments >= 1 and .data.catalog.canonicalDuplicates == 0' >/dev/null <<<"$status_json"

  stage="controlled-restart"
  docker compose restart worker >/dev/null
  container_id="$(docker compose ps -q worker)"
  wait_for_health "$container_id"
  curl -fsS "$API_BASE/health" | jq -e '.status == "ok"' >/dev/null
  curl -fsS "$API_BASE/ready" | jq -e '.status == "ready"' >/dev/null

  stage="scheduler-queue-recovery"
  wait_for_scheduler
  internal_post /internal/queue-recovery/probe
  local restart_count_before restart_count_after
  restart_count_before="$(docker inspect --format '{{.RestartCount}}' "$container_id")"
  sleep 5
  restart_count_after="$(docker inspect --format '{{.RestartCount}}' "$container_id")"
  [[ "$restart_count_after" == "$restart_count_before" ]] || die "worker entered a restart loop"

  stage="secret-log-scan"
  local secret_patterns="$temporary_root/secret-patterns"
  for key in DATABASE_URL IGNITION_PASSWORD IGNITION_PROXY_PASSWORD CAPSOLVER_CLIENT_KEY INTERNAL_API_TOKEN; do
    env_value "$runtime_env" "$key"
  done >"$secret_patterns"
  chmod 0600 "$secret_patterns"
  docker compose logs --no-color --tail=1000 worker >"$temporary_root/worker.log"
  if grep -F -f "$secret_patterns" "$temporary_root/worker.log" >/dev/null; then
    die "worker logs contain a protected runtime value"
  fi

  stage="frontend-integrity"
  local frontend_after
  frontend_after="$(tree_fingerprint "$FRONTEND_ROOT")"
  [[ "$frontend_after" == "$frontend_before" ]] || die "frontend files changed during worker deployment"

  stage="activation"
  ln -s "$release_dir" "$temporary_root/current"
  mv -Tf "$temporary_root/current" "$INSTALL_ROOT/current"
  [[ "$(readlink -f "$INSTALL_ROOT/current")" == "$release_dir" ]] || die "current release activation failed"

  status_json="$(curl -fsS "$API_BASE/api/ingestion/status")"
  local image_id timestamp report_tmp
  image_id="$(docker inspect --format '{{.Image}}' "$container_id")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  report_path="$INSTALL_ROOT/deployment-history/runtime-deploy-$timestamp.json"
  report_tmp="$temporary_root/report.json"
  jq -n \
    --arg schemaVersion "1" \
    --arg service "$SERVICE" \
    --arg releaseSha "$release_sha" \
    --arg imageId "$image_id" \
    --arg projectRef "$SUPABASE_REF" \
    --arg runtimeEnvSha256 "$runtime_fingerprint" \
    --arg frontendSha256 "$frontend_after" \
    --arg generatedAt "$(date -u +%FT%TZ)" \
    --argjson scheduled "$(jq '.data.catalog.scheduled' <<<"$status_json")" \
    --argjson sng "$(jq '.data.catalog.sng' <<<"$status_json")" \
    --argjson unique "$(jq '.data.catalog.uniqueTournaments' <<<"$status_json")" \
    --argjson duplicates "$(jq '.data.catalog.canonicalDuplicates' <<<"$status_json")" \
    '{schemaVersion:$schemaVersion,service:$service,releaseSha:$releaseSha,imageId:$imageId,projectRef:$projectRef,runtimeEnvSha256:$runtimeEnvSha256,frontendSha256:$frontendSha256,health:"ok",readiness:"ready",scheduledCount:$scheduled,sngCount:$sng,uniqueCount:$unique,duplicateCount:$duplicates,restart:"ok",scheduler:"leader",queueRecovery:"ok",frontendUnchanged:true,generatedAt:$generatedAt}' \
      >"$report_tmp"
  install -o root -g root -m 0600 "$report_tmp" "$report_path"

  deployment_succeeded=true
  stage="complete"
  log "DEPLOYMENT SUCCESS"
  log "release_sha=$release_sha"
  log "docker_image_id=$image_id"
  log "supabase_project_ref=$SUPABASE_REF"
  log "health=ok"
  log "readiness=ready"
  log "scheduled_count=$(jq -r '.data.catalog.scheduled' <<<"$status_json")"
  log "sng_count=$(jq -r '.data.catalog.sng' <<<"$status_json")"
  log "unique_count=$(jq -r '.data.catalog.uniqueTournaments' <<<"$status_json")"
  log "duplicate_count=$(jq -r '.data.catalog.canonicalDuplicates' <<<"$status_json")"
  log "restart=ok"
  log "scheduler=leader"
  log "queue_recovery=ok"
  log "frontend_unchanged=true"
  log "report=$report_path"
  if [[ -n "$old_release" ]]; then
    log "rollback_release_sha=$(basename "$old_release")"
  else
    log "rollback_release_sha=none"
  fi
}

main "$@"
