#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_SERVICE='pokerops-tournament-ingestion'
readonly APPLICATION_REPOSITORY='yovoweqif674-cyber/po'
readonly CONFIG_WORKFLOW='tournament-ingestion-sealed-config.yml'
readonly CONFIG_WORKFLOW_REF='deployment-control'
readonly SUPABASE_PROJECT_REF='xpajqdsppawnjmvewkep'
readonly DEFAULT_INSTALL_ROOT='/opt/pokerops-tournament-ingestion'
readonly FRONTEND_ROOT='/var/www/pokerops'
readonly REQUIRED_RUNTIME_KEYS=(
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

stage='bootstrap-preflight'
release_sha=''
release_tag=''
report_path=''
temporary_root=''
identity_path=''
config_backup_dir=''
previous_current=''
deployment_activated=false
config_installed=false
refresh_config=true
diagnostics_only=false

log() {
  printf '[%s] %s\n' "$stage" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

usage() {
  cat >&2 <<'EOF'
usage: tournament-ingestion.sh [--refresh-config|--skip-config-refresh|--diagnostics-only] FULL_RELEASE_COMMIT
EOF
  return 64
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

validate_release_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || { fail 'release commit must be a full lowercase 40-character SHA'; return 1; }
}

validate_nonce() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{15,63}$ && "$1" != *--* && "$1" != *- ]] \
    || fail 'generated workflow nonce is invalid'
}

validate_age_recipient() {
  [[ "$1" =~ ^age1[023456789acdefghjklmnpqrstuvwxyz]{50,90}$ && ${#1} -le 100 ]] \
    || fail 'ephemeral age recipient is invalid'
}

validate_execution_context() {
  local effective_uid=$1
  local tty_readable=$2
  local tty_writable=$3
  [[ "$effective_uid" == 0 ]] || { fail 'production bootstrap must run as root'; return 1; }
  [[ "$tty_readable" == true && "$tty_writable" == true ]] || { fail '/dev/tty is required for safe interactive GitHub authentication'; return 1; }
}

validate_github_actor() {
  [[ "$1" == yovoweqif674-cyber ]] || { fail 'GitHub CLI must be authenticated as the production owner'; return 1; }
}

parse_arguments() {
  local positional=()
  local positional_seen=false
  while (($#)); do
    case "$1" in
      --refresh-config)
        [[ "$positional_seen" == false ]] || { usage; return; }
        refresh_config=true
        ;;
      --skip-config-refresh)
        [[ "$positional_seen" == false ]] || { usage; return; }
        refresh_config=false
        ;;
      --diagnostics-only)
        [[ "$positional_seen" == false ]] || { usage; return; }
        diagnostics_only=true
        refresh_config=false
        ;;
      --*)
        usage
        return
        ;;
      *)
        positional_seen=true
        positional+=("$1")
        ;;
    esac
    shift
  done
  [[ ${#positional[@]} -eq 1 ]] || { usage; return; }
  release_sha=${positional[0],,}
  validate_release_sha "$release_sha" || return
  release_tag="tournament-ingestion-${release_sha:0:12}"
}

canonical_path() {
  if [[ -e "$1" || -L "$1" ]]; then
    readlink -f -- "$1" 2>/dev/null || true
  fi
}

fingerprint_tree() {
  local root=$1
  if [[ ! -e "$root" ]]; then
    printf '%s\n' absent
    return
  fi
  (
    cd "$root"
    find . -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum
    find . -xdev -type l -printf '%p -> %l\n' | sort
  ) | sha256sum | awk '{print $1}'
}

safe_env_value() {
  local key=$1
  local path=$2
  local value
  value=$(awk -v required="$key" '
    index($0, required "=") == 1 {
      count++
      value=substr($0, length(required) + 2)
    }
    END {
      if (count != 1 || value == "") exit 1
      print value
    }
  ' "$path") || { fail "required environment key is missing or duplicated: $key"; return 1; }
  printf '%s\n' "$value"
}

validate_env_syntax() {
  local path=$1
  [[ -f "$path" && ! -L "$path" ]] || { fail "environment input is not a regular file: $(basename -- "$path")"; return 1; }
  awk '
    /^[[:space:]]*($|#)/ { next }
    !/^[A-Za-z_][A-Za-z0-9_]*=.*/ { exit 20 }
    {
      key=$0
      sub(/=.*/, "", key)
      if (seen[key]++) exit 21
    }
  ' "$path" || { fail "environment syntax or duplicate key is invalid: $(basename -- "$path")"; return 1; }
}

validate_env_pair() {
  local runtime_path=$1
  local migration_path=$2
  validate_env_syntax "$runtime_path" || return
  validate_env_syntax "$migration_path" || return
  local key
  for key in "${REQUIRED_RUNTIME_KEYS[@]}"; do
    safe_env_value "$key" "$runtime_path" >/dev/null || return
  done
  local runtime_url
  local migration_url
  runtime_url=$(safe_env_value DATABASE_URL "$runtime_path") || return
  migration_url=$(safe_env_value MIGRATION_DATABASE_URL "$migration_path") || return
  [[ "$runtime_url" != "$migration_url" ]] || { fail 'runtime and migration URLs must differ'; return 1; }
  [[ "$runtime_url" =~ ^postgres(ql)?://pokerops_tournament_worker\.$SUPABASE_PROJECT_REF:[^@[:space:]]+@[^/[:space:]]+:5432/ ]] \
    || { fail 'runtime URL must use the restricted worker role, expected project ref, and port 5432'; return 1; }
  [[ "$migration_url" =~ ^postgres(ql)?://postgres(\.$SUPABASE_PROJECT_REF)?:[^@[:space:]]+@[^/[:space:]]+:5432/ ]] \
    || { fail 'migration URL must use the administrative role, expected project ref, and port 5432'; return 1; }
  [[ "$runtime_url" != *':6543/'* && "$migration_url" != *':6543/'* ]] || { fail 'transaction pooler port 6543 is forbidden'; return 1; }
  [[ "$runtime_url" =~ [\?\&]sslmode=require([\&\#]|$) ]] || { fail 'runtime URL must contain sslmode=require'; return 1; }
  [[ "$migration_url" =~ [\?\&]sslmode=require([\&\#]|$) ]] || { fail 'migration URL must contain sslmode=require'; return 1; }
}

validate_config_tar() {
  local tar_path=$1
  local entries=()
  mapfile -t entries < <(tar -tf "$tar_path") || { fail 'unable to inspect decrypted config tar'; return 1; }
  [[ ${#entries[@]} -eq 2 ]] || { fail 'decrypted config tar must contain exactly two entries'; return 1; }
  local entry
  for entry in "${entries[@]}"; do
    [[ "$entry" != /* && "$entry" != *\\* && ! "/$entry/" =~ /\.\.?/ ]] || { fail 'unsafe config tar path'; return 1; }
  done
  local sorted_entries
  sorted_entries=$(printf '%s\n' "${entries[@]}" | sort)
  [[ "$sorted_entries" == $'.env.migration\n.env.tournament.local' ]] || { fail 'config tar filename allowlist mismatch'; return 1; }
  local unsafe_type
  unsafe_type=$(tar -tvf "$tar_path" | awk 'substr($1, 1, 1) != "-" { print substr($1, 1, 1); exit }')
  if [[ -n "$unsafe_type" ]]; then
    fail 'config tar contains a link, directory, or special file'
    return 1
  fi
}

version_at_least() {
  local actual=${1#v}
  local minimum=${2#v}
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n 1)" == "$minimum" ]]
}

detect_operating_system() {
  local os_release_path='/etc/os-release'
  if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" == 1 && -n "${POKEROPS_TEST_OS_RELEASE_FILE:-}" ]]; then
    os_release_path=$POKEROPS_TEST_OS_RELEASE_FILE
  fi
  [[ -r "$os_release_path" ]] || fail 'only Ubuntu and Debian are supported'
  # shellcheck disable=SC1090
  source "$os_release_path"
  [[ "${ID:-}" == ubuntu || "${ID:-}" == debian ]] || { fail 'only Ubuntu and Debian are supported'; return 1; }
  [[ "${ID_LIKE:-}" != *rhel* ]] || { fail 'only Ubuntu and Debian are supported'; return 1; }
}

install_dependencies() {
  stage='dependencies'
  local required_packages=(ca-certificates curl git gh jq tar gzip util-linux openssh-client postgresql-client age openssl)
  local missing_packages=()
  local package
  for package in "${required_packages[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing_packages+=("$package")
  done
  if ((${#missing_packages[@]})); then
    log "installing ${#missing_packages[@]} missing system dependencies"
    apt-get update -qq
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
  fi

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    log 'installing Docker Engine'
    apt-get update -qq
    if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
      env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io docker-compose-v2
    else
      env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io docker-compose-plugin
    fi
    systemctl enable --now docker
  elif ! docker compose version >/dev/null 2>&1; then
    apt-get update -qq
    if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
      env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-compose-v2
    else
      env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-compose-plugin
    fi
  fi

  for package in curl git gh jq tar gzip flock ssh psql age age-keygen docker; do
    require_command "$package"
  done
  docker info >/dev/null
  docker compose version >/dev/null
  gh --version >/dev/null
  jq --version >/dev/null
  age --version >/dev/null
  psql --version >/dev/null
}

ensure_github_auth() {
  stage='github-auth'
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    log 'GitHub CLI authentication is required; follow the device prompt'
    gh auth login --hostname github.com --git-protocol https --web <&3 >&4 2>&4
  fi
  gh auth status --hostname github.com >/dev/null 2>&1 || fail 'GitHub CLI authentication failed'
  local login
  login=$(gh api user --jq '.login') || fail 'unable to read the authenticated GitHub principal'
  validate_github_actor "$login"
  gh api "repos/$APPLICATION_REPOSITORY" --jq '.permissions.pull' | grep -qx true || fail 'private repository read access is unavailable'
  gh api "repos/$APPLICATION_REPOSITORY/actions/permissions" --jq '.enabled' | grep -qx true || fail 'GitHub Actions are unavailable'
  gh api "repos/$APPLICATION_REPOSITORY/actions/workflows/$CONFIG_WORKFLOW" --jq '.state' | grep -qx active || fail 'sealed-config workflow is unavailable'
  gh api "repos/$APPLICATION_REPOSITORY/releases/tags/$release_tag" --jq '.id' >/dev/null || fail 'application Release read access is unavailable'
}

verify_release_manifest_minimums() {
  stage='release-preflight'
  local manifest_dir=$1
  local short_sha=${release_sha:0:12}
  local archive_name="pokerops-tournament-ingestion-$short_sha.tar.gz"
  local checksum_name="$archive_name.sha256"
  local manifest_name="pokerops-tournament-ingestion-$short_sha.manifest.json"
  local release_json
  release_json=$(gh release view "$release_tag" --repo "$APPLICATION_REPOSITORY" --json 'tagName,targetCommitish,isDraft,isPrerelease,assets') \
    || fail 'application Release does not exist'
  [[ "$(jq -r '.tagName' <<<"$release_json")" == "$release_tag" ]] || fail 'application Release tag mismatch'
  [[ "$(jq -r '.isDraft' <<<"$release_json")" == false ]] || fail 'draft application Release is forbidden'
  [[ "$(jq -r '.isPrerelease' <<<"$release_json")" == false ]] || fail 'prerelease application Release is forbidden'
  local immutable
  immutable=$(gh api -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/$APPLICATION_REPOSITORY/releases/tags/$release_tag" --jq '.immutable') \
    || fail 'unable to verify application Release immutability'
  [[ "$immutable" == true ]] || fail 'application Release is not immutable'
  local target_ref
  local target_sha
  local tag_sha
  target_ref=$(jq -er '.targetCommitish' <<<"$release_json") || fail 'application Release target is missing'
  target_sha=$(gh api "repos/$APPLICATION_REPOSITORY/commits/$target_ref" --jq '.sha') || fail 'unable to resolve application Release target'
  tag_sha=$(gh api "repos/$APPLICATION_REPOSITORY/commits/$release_tag" --jq '.sha') || fail 'unable to resolve application Release tag'
  [[ "${target_sha,,}" == "$release_sha" ]] || fail 'application Release target commit mismatch'
  [[ "${tag_sha,,}" == "$release_sha" ]] || fail 'application Release tag commit mismatch'
  local expected_assets
  local actual_assets
  expected_assets=$(printf '%s\n' "$archive_name" "$checksum_name" "$manifest_name" | sort)
  actual_assets=$(jq -r '.assets[].name' <<<"$release_json" | sort)
  [[ "$actual_assets" == "$expected_assets" ]] || fail 'application Release must contain exactly three expected assets'
  mkdir -m 700 -- "$manifest_dir"
  gh release download "$release_tag" --repo "$APPLICATION_REPOSITORY" --dir "$manifest_dir" --pattern "$manifest_name" \
    || fail 'unable to download the release manifest'
  local manifest="$manifest_dir/$manifest_name"
  [[ -f "$manifest" && ! -L "$manifest" ]] || fail 'release manifest download is invalid'
  [[ "$(jq -er '.commitSha' "$manifest")" == "$release_sha" ]] || fail 'release manifest commit mismatch'
  [[ "$(jq -er '.releaseTag' "$manifest")" == "$release_tag" ]] || fail 'release manifest tag mismatch'
  [[ "$(jq -er '.supabaseProjectRef' "$manifest")" == "$SUPABASE_PROJECT_REF" ]] || fail 'release manifest project ref mismatch'
  [[ "$(jq -er '.transactionPoolerSupported' "$manifest")" == false ]] || fail 'release unexpectedly supports the transaction pooler'
  local minimum_docker
  local minimum_compose
  minimum_docker=$(jq -er '.minimumDockerVersion' "$manifest")
  minimum_compose=$(jq -er '.minimumDockerComposeVersion' "$manifest")
  local docker_version
  local compose_version
  docker_version=$(docker version --format '{{.Server.Version}}')
  compose_version=$(docker compose version --short)
  version_at_least "$docker_version" "$minimum_docker" || fail "Docker $minimum_docker or newer is required"
  version_at_least "$compose_version" "$minimum_compose" || fail "Docker Compose $minimum_compose or newer is required"
}

validate_sealed_manifest() {
  local manifest=$1
  local encrypted=$2
  local expected_nonce=$3
  [[ -f "$manifest" && ! -L "$manifest" && -f "$encrypted" && ! -L "$encrypted" ]] \
    || { fail 'sealed-config artifact files are invalid'; return 1; }
  [[ "$(jq -er '.schemaVersion' "$manifest")" == 1 ]] \
    || { fail 'sealed-config manifest schema is unsupported'; return 1; }
  [[ "$(jq -er '.service' "$manifest")" == "$BOOTSTRAP_SERVICE" ]] \
    || { fail 'sealed-config service mismatch'; return 1; }
  [[ "$(jq -er '.commitSha' "$manifest")" == "$release_sha" ]] \
    || { fail 'sealed-config commit mismatch'; return 1; }
  [[ "$(jq -er '.nonce' "$manifest")" == "$expected_nonce" ]] \
    || { fail 'sealed-config nonce mismatch'; return 1; }
  [[ "$(jq -er '.projectRef' "$manifest")" == "$SUPABASE_PROJECT_REF" ]] \
    || { fail 'sealed-config project ref mismatch'; return 1; }
  [[ "$(jq -er '.encryption' "$manifest")" == age-x25519 ]] \
    || { fail 'sealed-config encryption mismatch'; return 1; }
  [[ "$(jq -er '.encryptedFile' "$manifest")" == sealed-config.tar.age ]] \
    || { fail 'sealed-config encrypted filename mismatch'; return 1; }
  jq -e '.generatedAt | strings | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$manifest" >/dev/null \
    || { fail 'sealed-config generation timestamp is invalid'; return 1; }
  jq -e '.runtimeEnvSha256 | strings | test("^[0-9a-f]{64}$")' "$manifest" >/dev/null \
    || { fail 'sealed-config runtime fingerprint is invalid'; return 1; }
  jq -e '.migrationEnvSha256 | strings | test("^[0-9a-f]{64}$")' "$manifest" >/dev/null \
    || { fail 'sealed-config migration fingerprint is invalid'; return 1; }
  local expected_encrypted_sha
  expected_encrypted_sha=$(jq -er '.encryptedSha256 | select(test("^[0-9a-f]{64}$"))' "$manifest") \
    || { fail 'encrypted fingerprint is invalid'; return 1; }
  [[ "$(sha256sum "$encrypted" | awk '{print $1}')" == "$expected_encrypted_sha" ]] \
    || { fail 'encrypted artifact checksum mismatch'; return 1; }
}

decrypt_config_archive() {
  local identity=$1
  local encrypted=$2
  local decrypted=$3
  age --decrypt --identity "$identity" --output "$decrypted" "$encrypted" \
    || { fail 'sealed-config decryption failed'; return 1; }
  [[ -f "$decrypted" && ! -L "$decrypted" ]] || fail 'sealed-config decryption produced no regular archive'
}

create_ephemeral_age_identity() {
  stage='ephemeral-key'
  local key_dir="$temporary_root/age"
  mkdir -m 700 -- "$key_dir"
  identity_path="$key_dir/identity.txt"
  age-keygen -o "$identity_path" >/dev/null 2>&1
  chmod 600 "$identity_path"
  ephemeral_recipient=$(age-keygen -y "$identity_path")
}

wait_for_workflow_run() {
  local expected_title=$1
  local maximum_attempts=${POKEROPS_WORKFLOW_LOOKUP_ATTEMPTS_OVERRIDE:-60}
  local run_json=''
  local attempts=0
  while ((attempts < maximum_attempts)); do
    if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" == 1 && -n "${POKEROPS_TEST_RUN_LIST_JSON_OVERRIDE:-}" ]]; then
      run_json=$POKEROPS_TEST_RUN_LIST_JSON_OVERRIDE
    else
      run_json=$(gh run list \
        --repo "$APPLICATION_REPOSITORY" \
        --workflow "$CONFIG_WORKFLOW" \
        --branch "$CONFIG_WORKFLOW_REF" \
        --event workflow_dispatch \
        --limit 100 \
        --json databaseId,displayTitle,url,headBranch,event,createdAt \
        --jq "[.[] | select(.displayTitle == \"$expected_title\" and .headBranch == \"$CONFIG_WORKFLOW_REF\" and .event == \"workflow_dispatch\")]" \
      ) || fail 'unable to list sealed-config workflow runs'
    fi
    if [[ "$(jq 'length' <<<"$run_json")" == 1 ]]; then
      jq -c '.[0]' <<<"$run_json"
      return
    fi
    [[ "$(jq 'length' <<<"$run_json")" == 0 ]] || fail 'more than one workflow run matched the unique nonce'
    attempts=$((attempts + 1))
    sleep 2
  done
  fail 'timed out while locating the exact sealed-config workflow run'
}

obtain_sealed_config() {
  stage='sealed-config'
  local ephemeral_recipient=''
  create_ephemeral_age_identity
  local recipient=$ephemeral_recipient
  validate_age_recipient "$recipient"
  local nonce
  nonce="$(date -u +%Y%m%d%H%M%S)-$(openssl rand -hex 12)"
  validate_nonce "$nonce"
  local expected_title="sealed-config-$nonce"

  gh workflow run "$CONFIG_WORKFLOW" \
    --repo "$APPLICATION_REPOSITORY" \
    --ref "$CONFIG_WORKFLOW_REF" \
    -f "commit_sha=$release_sha" \
    -f "age_recipient=$recipient" \
    -f "nonce=$nonce" >&4 2>&4 \
    || fail 'sealed-config workflow dispatch failed'

  local run_json
  run_json=$(wait_for_workflow_run "$expected_title")
  local run_id
  local run_url
  run_id=$(jq -er '.databaseId' <<<"$run_json")
  run_url=$(jq -er '.url' <<<"$run_json")
  if ! gh run watch "$run_id" --repo "$APPLICATION_REPOSITORY" --exit-status >&4 2>&4; then
    printf 'sealed_config_run=%s\n' "$run_url" >&2
    fail 'sealed-config workflow failed'
  fi

  local download_dir="$temporary_root/actions-download"
  mkdir -m 700 -- "$download_dir"
  gh run download "$run_id" \
    --repo "$APPLICATION_REPOSITORY" \
    --name "sealed-config-$nonce" \
    --dir "$download_dir" >&4 2>&4 \
    || fail 'sealed-config artifact download failed'

  mapfile -t artifact_files < <(find "$download_dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
  [[ ${#artifact_files[@]} -eq 2 ]] || fail 'sealed-config artifact must contain exactly two files'
  [[ "${artifact_files[0]}" == 'sealed-config.manifest.json' && "${artifact_files[1]}" == 'sealed-config.tar.age' ]] \
    || fail 'sealed-config artifact filename allowlist mismatch'
  [[ -z "$(find "$download_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] || fail 'sealed-config artifact contains an unsafe entry'

  local manifest="$download_dir/sealed-config.manifest.json"
  local encrypted="$download_dir/sealed-config.tar.age"
  validate_sealed_manifest "$manifest" "$encrypted" "$nonce"

  local decrypted_tar="$temporary_root/sealed-config.tar"
  decrypt_config_archive "$identity_path" "$encrypted" "$decrypted_tar"
  shred -u -- "$identity_path"
  identity_path=''
  validate_config_tar "$decrypted_tar"

  local plaintext_dir="$temporary_root/decrypted"
  mkdir -m 700 -- "$plaintext_dir"
  tar --no-same-owner --no-same-permissions -xf "$decrypted_tar" -C "$plaintext_dir"
  shred -u -- "$decrypted_tar"
  local runtime_path="$plaintext_dir/.env.tournament.local"
  local migration_path="$plaintext_dir/.env.migration"
  validate_env_pair "$runtime_path" "$migration_path"
  local expected_runtime_sha
  local expected_migration_sha
  expected_runtime_sha=$(jq -er '.runtimeEnvSha256 | select(test("^[0-9a-f]{64}$"))' "$manifest")
  expected_migration_sha=$(jq -er '.migrationEnvSha256 | select(test("^[0-9a-f]{64}$"))' "$manifest")
  [[ "$(sha256sum "$runtime_path" | awk '{print $1}')" == "$expected_runtime_sha" ]] || fail 'decrypted runtime fingerprint mismatch'
  [[ "$(sha256sum "$migration_path" | awk '{print $1}')" == "$expected_migration_sha" ]] || fail 'decrypted migration fingerprint mismatch'
  printf '%s\n%s\n' "$runtime_path" "$migration_path"
}

restore_config_backup() {
  [[ "$config_installed" == true ]] || return 0
  local shared_dir="$install_root/shared"
  if [[ -f "$config_backup_dir/.env.tournament.local" ]]; then
    if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" == 1 && "$(id -u)" -ne 0 ]]; then
      cp -- "$config_backup_dir/.env.tournament.local" "$shared_dir/.env.tournament.local.restore"
      chmod 0600 "$shared_dir/.env.tournament.local.restore"
    else
      install -o root -g root -m 0600 "$config_backup_dir/.env.tournament.local" "$shared_dir/.env.tournament.local.restore"
    fi
    mv -fT -- "$shared_dir/.env.tournament.local.restore" "$shared_dir/.env.tournament.local"
  elif [[ -f "$shared_dir/.env.tournament.local" ]]; then
    rm -f -- "$shared_dir/.env.tournament.local"
  fi
  if [[ -f "$config_backup_dir/.env.migration" ]]; then
    if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" == 1 && "$(id -u)" -ne 0 ]]; then
      cp -- "$config_backup_dir/.env.migration" "$shared_dir/.env.migration.restore"
      chmod 0600 "$shared_dir/.env.migration.restore"
    else
      install -o root -g root -m 0600 "$config_backup_dir/.env.migration" "$shared_dir/.env.migration.restore"
    fi
    mv -fT -- "$shared_dir/.env.migration.restore" "$shared_dir/.env.migration"
  elif [[ -f "$shared_dir/.env.migration" ]]; then
    rm -f -- "$shared_dir/.env.migration"
  fi
  sync -f "$shared_dir" 2>/dev/null || sync
}

install_config_atomically() {
  stage='shared-config'
  local runtime_source=$1
  local migration_source=$2
  local shared_dir="$install_root/shared"
  if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" == 1 && "$(id -u)" -ne 0 ]]; then
    mkdir -p -- "$install_root" "$shared_dir"
    chmod 0750 "$install_root" "$shared_dir"
  else
    install -d -o root -g root -m 0750 "$install_root" "$shared_dir"
  fi
  [[ ! -L "$shared_dir" && -d "$shared_dir" ]] || fail 'shared directory must not be a symlink'

  config_backup_dir="$temporary_root/config-backup"
  mkdir -m 700 -- "$config_backup_dir"
  previous_runtime_env_sha='absent'
  previous_migration_env_sha='absent'
  local target
  for target in .env.tournament.local .env.migration; do
    if [[ -e "$shared_dir/$target" || -L "$shared_dir/$target" ]]; then
      [[ -f "$shared_dir/$target" && ! -L "$shared_dir/$target" ]] || fail "existing shared config is unsafe: $target"
      cp --preserve=mode,timestamps -- "$shared_dir/$target" "$config_backup_dir/$target"
      chmod 600 "$config_backup_dir/$target"
      if [[ "$target" == '.env.tournament.local' ]]; then
        previous_runtime_env_sha=$(sha256sum "$shared_dir/$target" | awk '{print $1}')
      else
        previous_migration_env_sha=$(sha256sum "$shared_dir/$target" | awk '{print $1}')
      fi
    fi
  done

  if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" == 1 && "$(id -u)" -ne 0 ]]; then
    cp -- "$runtime_source" "$shared_dir/.env.tournament.local.new"
    cp -- "$migration_source" "$shared_dir/.env.migration.new"
    chmod 0600 "$shared_dir/.env.tournament.local.new" "$shared_dir/.env.migration.new"
  else
    install -o root -g root -m 0600 "$runtime_source" "$shared_dir/.env.tournament.local.new"
    install -o root -g root -m 0600 "$migration_source" "$shared_dir/.env.migration.new"
  fi
  validate_env_pair "$shared_dir/.env.tournament.local.new" "$shared_dir/.env.migration.new"
  sync -f "$shared_dir/.env.tournament.local.new" 2>/dev/null || sync
  sync -f "$shared_dir/.env.migration.new" 2>/dev/null || sync
  mv -fT -- "$shared_dir/.env.tournament.local.new" "$shared_dir/.env.tournament.local"
  mv -fT -- "$shared_dir/.env.migration.new" "$shared_dir/.env.migration"
  sync -f "$shared_dir" 2>/dev/null || sync
  if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" != 1 || "$(id -u)" -eq 0 ]]; then
    chown root:root "$shared_dir" "$shared_dir/.env.tournament.local" "$shared_dir/.env.migration"
  fi
  chmod 0750 "$shared_dir"
  chmod 0600 "$shared_dir/.env.tournament.local" "$shared_dir/.env.migration"
  [[ ! -L "$shared_dir/.env.tournament.local" && ! -L "$shared_dir/.env.migration" ]] || fail 'installed config must not be a symlink'
  if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" != 1 || "$(id -u)" -eq 0 ]]; then
    [[ "$(stat -c '%U:%G:%a' "$shared_dir")" == root:root:750 ]] || fail 'shared directory owner or mode is invalid'
    [[ "$(stat -c '%U:%G:%a' "$shared_dir/.env.tournament.local")" == root:root:600 ]] || fail 'runtime env owner or mode is invalid'
    [[ "$(stat -c '%U:%G:%a' "$shared_dir/.env.migration")" == root:root:600 ]] || fail 'migration env owner or mode is invalid'
  fi
  config_installed=true
}

install_exact_application_helper() {
  stage='deploy-helper'
  local checkout_dir="$temporary_root/application"
  gh repo clone "$APPLICATION_REPOSITORY" "$checkout_dir" -- --no-checkout --filter=blob:none \
    || fail 'unable to clone the private application repository'
  git -C "$checkout_dir" checkout --detach "$release_sha" >/dev/null 2>&1 || fail 'unable to checkout the exact application commit'
  [[ "$(git -C "$checkout_dir" rev-parse HEAD)" == "$release_sha" ]] || fail 'application checkout commit mismatch'
  local source_helper="$checkout_dir/services/tournament-ingestion/scripts/vps-deploy-from-github.sh"
  local installer="$checkout_dir/services/tournament-ingestion/scripts/install-vps-deployer.sh"
  [[ -f "$source_helper" && ! -L "$source_helper" && -x "$installer" && ! -L "$installer" ]] || fail 'verified application checkout has no deploy installer'
  POKEROPS_AUTOMATED_BOOTSTRAP=1 "$installer"
  local installed_helper='/usr/local/sbin/pokerops-tournament-deploy'
  [[ -f "$installed_helper" && ! -L "$installed_helper" ]] || fail 'deploy helper installation failed'
  [[ "$(stat -c '%U:%G:%a' "$installed_helper")" == root:root:750 ]] || fail 'deploy helper owner or mode is invalid'
  verify_matching_checksums "$source_helper" "$installed_helper" \
    || fail 'installed deploy helper checksum does not match the exact application commit'
}

verify_matching_checksums() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" && ! -L "$expected" && -f "$actual" && ! -L "$actual" ]] || return 1
  [[ "$(sha256sum "$expected" | awk '{print $1}')" == "$(sha256sum "$actual" | awk '{print $1}')" ]]
}

wait_for_service() {
  local api_port=$1
  local attempts=0
  while ((attempts < 60)); do
    if curl --fail --silent --show-error "http://127.0.0.1:$api_port/health" >/dev/null 2>&1 \
      && curl --fail --silent --show-error "http://127.0.0.1:$api_port/ready" >/dev/null 2>&1; then
      return
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  fail 'service health/readiness timed out'
}

authenticated_post() {
  local api_port=$1
  local path=$2
  local token_file=$3
  local token
  token=$(safe_env_value INTERNAL_API_TOKEN "$token_file")
  curl --fail --silent --show-error -X POST -H "Authorization: Bearer $token" "http://127.0.0.1:$api_port$path"
}

post_deploy_checks() {
  stage='post-deploy-verification'
  local service_dir="$install_root/releases/$release_sha/services/tournament-ingestion"
  local runtime_env="$install_root/shared/.env.tournament.local"
  local migration_env="$install_root/shared/.env.migration"
  local api_port
  api_port=$(awk -F= '$1 == "TOURNAMENT_HOST_PORT" { value=$2; count++ } END { if (count <= 1) print value }' "$runtime_env")
  api_port=${api_port:-8787}
  [[ "$api_port" =~ ^[0-9]{1,5}$ && "$api_port" -ge 1 && "$api_port" -le 65535 ]] || fail 'configured API port is invalid'
  wait_for_service "$api_port"
  health='ok'
  readiness='ready'
  [[ "$(cd "$service_dir" && docker compose config --services)" == worker ]] || fail 'Compose must contain exactly one worker service'

  local migration_path="$install_root/releases/$release_sha/supabase/migrations/20260812120127_create_tournament_ingestion.sql"
  migration_result=$(docker run --rm \
    --env-file "$migration_env" \
    -e MIGRATION_PATH=/migration.sql \
    -v "$migration_path:/migration.sql:ro" \
    "$BOOTSTRAP_SERVICE:$release_sha" \
    node scripts/migrate.mjs) || fail 'exact migration readback failed'
  [[ "$migration_result" == *'status=already_applied'* ]] || fail 'migration was not confirmed as an exact no-op after deployment'

  local first_collect
  local second_collect
  first_collect=$(authenticated_post "$api_port" '/internal/live-smoke' "$runtime_env") || fail 'first live catalog collect failed'
  [[ "$(jq -er '.data.scheduledCount' <<<"$first_collect")" =~ ^[0-9]+$ ]] || fail 'first live collect response is invalid'
  second_collect=$(authenticated_post "$api_port" '/internal/live-smoke' "$runtime_env") || fail 'second live catalog collect failed'
  info_id=$(jq -er '.data.infoId' <<<"$second_collect") || fail 'live /info target is missing'
  state_id=$(jq -er '.data.stateId' <<<"$second_collect") || fail 'live /state target is missing'
  state_status=$(jq -er '.data.stateStatus' <<<"$second_collect") || fail 'live /state status is missing'

  local status_json
  status_json=$(curl --fail --silent --show-error "http://127.0.0.1:$api_port/api/ingestion/status") || fail 'ingestion status failed after the second collect'
  scheduled_count=$(jq -er '.data.catalog.scheduled' <<<"$status_json")
  sng_count=$(jq -er '.data.catalog.sng' <<<"$status_json")
  unique_count=$(jq -er '.data.catalog.uniqueTournaments' <<<"$status_json")
  duplicate_count=$(jq -er '.data.catalog.canonicalDuplicates' <<<"$status_json")
  [[ "$duplicate_count" == 0 ]] || fail 'canonical duplicates exist after two live collects'

  worker_id=$(cd "$service_dir" && docker compose ps -q worker)
  [[ -n "$worker_id" ]] || fail 'worker container is missing'
  [[ "$(cd "$service_dir" && docker compose ps -q --all worker | wc -l | tr -d ' ')" == 1 ]] || fail 'more than one worker container exists'
  docker_image_id=$(docker image inspect --format '{{.Id}}' "$BOOTSTRAP_SERVICE:$release_sha")
  local port_bindings
  port_bindings=$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$worker_id")
  [[ "$(jq -r 'to_entries | length' <<<"$port_bindings")" == 1 ]] || fail 'worker exposes an unexpected port set'
  [[ "$(jq -r 'to_entries[0].value | length' <<<"$port_bindings")" == 1 ]] || fail 'worker has an unexpected number of port bindings'
  [[ "$(jq -r 'to_entries[0].value[0].HostIp' <<<"$port_bindings")" == 127.0.0.1 ]] || fail 'worker port is not bound only to 127.0.0.1'

  restart_started_epoch=$(date -u +%s)
  (cd "$service_dir" && docker compose restart worker >/dev/null) || fail 'controlled worker restart failed'
  wait_for_service "$api_port"
  restart_result='healthy'

  local diagnostic_attempts=0
  while ((diagnostic_attempts < 30)); do
    status_json=$(curl --fail --silent --show-error "http://127.0.0.1:$api_port/api/ingestion/status") || true
    scheduler_updated_at=$(jq -r '.data.workers.scheduler.updatedAt // empty' <<<"$status_json" 2>/dev/null)
    queue_updated_at=$(jq -r '.data.workers.job_worker.updatedAt // empty' <<<"$status_json" 2>/dev/null)
    scheduler_updated_epoch=$(date -u -d "$scheduler_updated_at" +%s 2>/dev/null || printf 0)
    queue_updated_epoch=$(date -u -d "$queue_updated_at" +%s 2>/dev/null || printf 0)
    if [[ "$(jq -r '.data.workers.scheduler.leader // false' <<<"$status_json" 2>/dev/null)" == true \
      && "$scheduler_updated_epoch" -ge "$restart_started_epoch" \
      && "$queue_updated_epoch" -ge "$restart_started_epoch" ]]; then
      break
    fi
    diagnostic_attempts=$((diagnostic_attempts + 1))
    sleep 2
  done
  [[ "$(jq -r '.data.workers.scheduler.leader // false' <<<"$status_json")" == true ]] || fail 'scheduler leadership did not recover after restart'
  [[ "$scheduler_updated_epoch" -ge "$restart_started_epoch" ]] || fail 'scheduler status was not refreshed after restart'
  [[ "$queue_updated_epoch" -ge "$restart_started_epoch" ]] || fail 'queue worker did not scan for recoverable leases after restart'
  [[ "$(jq -r '.data.jobs.expiredLeases // -1' <<<"$status_json")" == 0 ]] || fail 'expired queue leases remain after restart'
  scheduler_result='leader'
  queue_result='recovered'

  local logs_file="$temporary_root/worker.log"
  (cd "$service_dir" && docker compose logs --no-color --since=30m worker >"$logs_file")
  chmod 600 "$logs_file"
  local secret_key
  local secret_value
  for secret_key in DATABASE_URL IGNITION_USERNAME IGNITION_PASSWORD IGNITION_PROXY_PASSWORD CAPSOLVER_CLIENT_KEY INTERNAL_API_TOKEN; do
    secret_value=$(safe_env_value "$secret_key" "$runtime_env")
    if [[ ${#secret_value} -ge 4 ]] && grep -Fq -- "$secret_value" "$logs_file"; then
      fail 'worker logs contain protected environment material'
    fi
  done
  if grep -Eqi '(authorization:[[:space:]]*bearer|postgres(ql)?://[^[:space:]]+:[^[:space:]@]+@|sessionid[=:][^[:space:]]+)' "$logs_file"; then
    fail 'worker logs contain a credential-shaped value'
  fi
  shred -u -- "$logs_file"

  [[ "$(fingerprint_tree "$FRONTEND_ROOT")" == "$frontend_before" ]] || fail '/var/www/pokerops changed during bootstrap deployment'
  frontend_unchanged=true
}

write_bootstrap_report() {
  local status=$1
  local message=$2
  local history_dir="$install_root/deployment-history"
  install -d -o root -g root -m 0750 "$history_dir" 2>/dev/null || return 0
  report_path="$history_dir/$(date -u +%Y%m%dT%H%M%SZ)-$release_sha-bootstrap-$status.json"
  jq -n \
    --arg service "$BOOTSTRAP_SERVICE" \
    --arg status "$status" \
    --arg stage "$stage" \
    --arg message "$message" \
    --arg commitSha "$release_sha" \
    --arg releaseTag "$release_tag" \
    --arg projectRef "$SUPABASE_PROJECT_REF" \
    --arg previousCurrent "$previous_current" \
    --arg previousRuntimeEnvSha256 "${previous_runtime_env_sha:-not-refreshed}" \
    --arg previousMigrationEnvSha256 "${previous_migration_env_sha:-not-refreshed}" \
    --arg current "$(canonical_path "$install_root/current")" \
    --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{service:$service,status:$status,stage:$stage,message:$message,commitSha:$commitSha,releaseTag:$releaseTag,projectRef:$projectRef,previousCurrent:$previousCurrent,previousRuntimeEnvSha256:$previousRuntimeEnvSha256,previousMigrationEnvSha256:$previousMigrationEnvSha256,current:$current,completedAt:$completedAt}' \
    >"$report_path" 2>/dev/null || return 0
  chown root:root "$report_path" 2>/dev/null || true
  chmod 0600 "$report_path" 2>/dev/null || true
}

rollback_after_failure() {
  [[ "$deployment_activated" == true ]] || return 0
  local current_now
  current_now=$(canonical_path "$install_root/current")
  [[ "$current_now" == "$install_root/releases/$release_sha" ]] || return 0
  if [[ -n "$previous_current" && -d "$previous_current/services/tournament-ingestion" ]]; then
    local previous_sha
    previous_sha=$(basename -- "$previous_current")
    if validate_release_sha "$previous_sha" >/dev/null 2>&1; then
      restore_config_backup || true
      config_installed=false
      "$install_root/releases/$release_sha/services/tournament-ingestion/scripts/vps-rollback.sh" "$previous_sha" || true
      return
    fi
  fi
  local service_dir="$install_root/releases/$release_sha/services/tournament-ingestion"
  [[ -d "$service_dir" ]] && (cd "$service_dir" && docker compose stop worker >/dev/null 2>&1) || true
  [[ -L "$install_root/current" ]] && rm -f -- "$install_root/current"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if ((rc != 0)); then
    rollback_after_failure || true
    restore_config_backup || true
    write_bootstrap_report failed "bootstrap command failed with exit code $rc"
    printf '\nDEPLOYMENT FAILED\n'
    printf 'stage: %s\n' "$stage"
    printf 'safe error: bootstrap stopped at a fail-closed gate\n'
    printf 'current release: preserved or rolled back when activation had started\n'
    printf 'report path: %s\n' "${report_path:-unavailable}"
    printf 'next automated retry command: re-run the same pinned bootstrap command\n'
  fi
  if [[ -n "$identity_path" && -f "$identity_path" ]]; then
    shred -u -- "$identity_path" 2>/dev/null || rm -f -- "$identity_path"
  fi
  if [[ -n "$temporary_root" && -d "$temporary_root" ]]; then
    find "$temporary_root" -type f -exec shred -u -- {} + 2>/dev/null || true
    rm -rf -- "$temporary_root"
  fi
  exit "$rc"
}

print_success() {
  printf '\nDEPLOYMENT SUCCESS\n'
  printf 'release SHA: %s\n' "$release_sha"
  printf 'release tag: %s\n' "$release_tag"
  printf 'Docker image ID: %s\n' "$docker_image_id"
  printf 'Supabase project ref: %s\n' "$SUPABASE_PROJECT_REF"
  printf 'health: %s\n' "$health"
  printf 'readiness: %s\n' "$readiness"
  printf 'scheduled count: %s\n' "$scheduled_count"
  printf 'SNG count: %s\n' "$sng_count"
  printf 'unique count: %s\n' "$unique_count"
  printf 'duplicate count: %s\n' "$duplicate_count"
  printf 'info ID: %s\n' "$info_id"
  printf 'state ID/status: %s/%s\n' "$state_id" "$state_status"
  printf 'restart result: %s\n' "$restart_result"
  printf 'scheduler result: %s\n' "$scheduler_result"
  printf 'queue result: %s\n' "$queue_result"
  printf 'frontend unchanged: %s\n' "$frontend_unchanged"
  printf 'deployment report path: %s\n' "$report_path"
  if [[ -n "$previous_current" ]]; then
    printf 'rollback command: sudo %s/services/tournament-ingestion/scripts/vps-rollback.sh %s\n' "$install_root/current" "$(basename -- "$previous_current")"
  else
    printf 'rollback command: no previous compatible release is installed\n'
  fi
}

main() {
  parse_arguments "$@"
  if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" == 1 ]]; then
    validate_execution_context 0 true true
    exec 3</dev/null
    exec 4>/dev/null
  else
    local tty_readable=false
    local tty_writable=false
    [[ -r /dev/tty ]] && tty_readable=true
    [[ -w /dev/tty ]] && tty_writable=true
    validate_execution_context "${EUID:-$(id -u)}" "$tty_readable" "$tty_writable"
    exec 3</dev/tty
    exec 4>/dev/tty
  fi
  detect_operating_system
  if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" == 1 && -n "${POKEROPS_TEST_INSTALL_ROOT:-}" ]]; then
    install_root=$POKEROPS_TEST_INSTALL_ROOT
  else
    install_root=$DEFAULT_INSTALL_ROOT
  fi
  frontend_before=$(fingerprint_tree "$FRONTEND_ROOT")
  temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/pokerops-tournament-bootstrap.XXXXXXXX")
  chmod 0700 "$temporary_root"
  trap cleanup EXIT INT TERM

  install_dependencies
  ensure_github_auth
  verify_release_manifest_minimums "$temporary_root/release-manifest"
  previous_current=$(canonical_path "$install_root/current")

  if [[ "$diagnostics_only" == true ]]; then
    [[ "$(canonical_path "$install_root/current")" == "$install_root/releases/$release_sha" ]] || fail 'diagnostics-only requires the requested release to be current'
    post_deploy_checks
  else
    if [[ "$refresh_config" == true ]]; then
      obtain_sealed_config >"$temporary_root/config-paths"
      mapfile -t config_paths <"$temporary_root/config-paths"
      [[ ${#config_paths[@]} -eq 2 ]] || fail 'sealed-config function returned an invalid result'
      install_config_atomically "${config_paths[0]}" "${config_paths[1]}"
    else
      validate_env_pair "$install_root/shared/.env.tournament.local" "$install_root/shared/.env.migration"
    fi
    install_exact_application_helper
    stage='application-deploy'
    pokerops-tournament-deploy "$release_sha"
    deployment_activated=true
    post_deploy_checks
  fi

  stage='complete'
  [[ "$(fingerprint_tree "$FRONTEND_ROOT")" == "$frontend_before" ]] || fail '/var/www/pokerops changed during final verification'
  write_bootstrap_report success 'sealed config, immutable release deployment, and independent post-deploy gates passed'
  config_installed=false
  print_success
}

if [[ "${POKEROPS_BOOTSTRAP_LIBRARY_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
