#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_REPOSITORY='yovoweqif674-cyber/pokerops-bootstrap'
readonly PAYLOAD_COMMIT='894be971df2b55ca89b18ead5ee7be579f130c2a'
readonly SOURCE_REPOSITORY='yovoweqif674-cyber/po'
readonly SOURCE_COMMIT='2a9e20c4804f7b5196a1e43356cb2503f5773c97'
readonly ARCHIVE_NAME='pokerops-tournament-ui.zip'
readonly MANIFEST_NAME='pokerops-tournament-ui.manifest.json'
readonly ARCHIVE_SHA256='655bdef3b5ab44a34045c01ade637962dd4ae41f52a970c69034e9992db9f7f9'
readonly INDEX_JS='assets/index-MCSD7vkL.js'
readonly INDEX_CSS='assets/index-B5yM79TK.css'
readonly RAW_ROOT="https://raw.githubusercontent.com/${BOOTSTRAP_REPOSITORY}/${PAYLOAD_COMMIT}"
readonly ARCHIVE_URL="${RAW_ROOT}/${ARCHIVE_NAME}"
readonly MANIFEST_URL="${RAW_ROOT}/${MANIFEST_NAME}"

readonly WEB_ROOT='/var/www/pokerops'
readonly WEB_OWNER='deploy:www-data'
readonly BACKUP_ROOT='/var/www/pokerops-backups'
readonly NGINX_BACKUP_ROOT='/var/backups/pokerops-tournament-ui'
readonly STATE_ROOT='/var/lib/pokerops-frontend-deploy'
readonly SITE_HOST='forprofit.pro'
readonly SITE_URL='https://forprofit.pro'
readonly UI_ROUTE='/preview/v4/manager/tournaments'
readonly API_PREFIX='/tournament-ingestion-api'
readonly WORKER_URL='http://127.0.0.1:8787'

stage='preflight'
work_dir=''
site_path=''
nginx_backup=''
frontend_backup=''
nginx_before_sha=''
frontend_index_before_sha=''
frontend_changed=false
nginx_changed=false
deployment_succeeded=false
timestamp=''

safe_error() {
  printf '%s\n' "$*" >&2
}

fail() {
  safe_error "$*"
  return 1
}

reload_nginx() {
  local attempt
  for attempt in $(seq 1 10); do
    if command -v systemctl >/dev/null 2>&1 \
      && systemctl reload nginx >/dev/null 2>&1; then
      return
    fi
    if nginx -s reload >/dev/null 2>&1; then
      return
    fi
    if [[ -r /run/nginx.pid ]] \
      && kill -HUP "$(cat /run/nginx.pid)" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  return 1
}

restore_frontend() {
  [[ "$frontend_changed" == true ]] || return 0
  [[ -n "$frontend_backup" && -f "$frontend_backup" ]] || return 1
  [[ "$WEB_ROOT" == '/var/www/pokerops' ]] || return 1

  find "$WEB_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  tar -xzf "$frontend_backup" -C "$WEB_ROOT"
  chown -R "$WEB_OWNER" "$WEB_ROOT"
  find "$WEB_ROOT" -type d -exec chmod 755 {} +
  find "$WEB_ROOT" -type f -exec chmod 644 {} +
  [[ -z "$frontend_index_before_sha" \
    || "$(sha256sum "$WEB_ROOT/index.html" | awk '{print $1}')" == "$frontend_index_before_sha" ]]
}

restore_nginx() {
  [[ "$nginx_changed" == true ]] || return 0
  [[ -n "$site_path" && -n "$nginx_backup" && -f "$nginx_backup" ]] || return 1
  install -o root -g root -m 644 "$nginx_backup" "$site_path"
  [[ -z "$nginx_before_sha" \
    || "$(sha256sum "$site_path" | awk '{print $1}')" == "$nginx_before_sha" ]]
}

on_error() {
  local status="${1:-1}"
  trap - ERR
  set +e

  local rollback='not-required'
  local nginx_restore_status=0
  local frontend_restore_status=0
  local nginx_config_status=0
  local nginx_reload_status=0
  if [[ "$frontend_changed" == true || "$nginx_changed" == true ]]; then
    rollback='failed'
    restore_nginx || nginx_restore_status=$?
    restore_frontend || frontend_restore_status=$?
    if [[ "$nginx_restore_status" -eq 0 && "$frontend_restore_status" -eq 0 ]]; then
      if nginx -t >/dev/null 2>&1; then
        if reload_nginx; then
          rollback='complete'
        else
          nginx_reload_status=$?
        fi
      else
        nginx_config_status=$?
      fi
    fi
  fi

  printf '%s\n' \
    'FRONTEND DEPLOYMENT FAILED' \
    "stage=${stage}" \
    "rollback=${rollback}" \
    "rollback_nginx_restore_status=${nginx_restore_status}" \
    "rollback_frontend_restore_status=${frontend_restore_status}" \
    "rollback_nginx_config_status=${nginx_config_status}" \
    "rollback_nginx_reload_status=${nginx_reload_status}" \
    'retry=rerun-the-same-pinned-command'
  exit "$status"
}

cleanup() {
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
}

trap 'on_error $?' ERR
trap cleanup EXIT

require_root_and_os() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail 'run as root (use sudo bash)'
  [[ -r /etc/os-release ]] || fail 'unsupported operating system'

  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|ubuntu:*|*:debian*) ;;
    *) fail 'only Ubuntu/Debian is supported' ;;
  esac
}

install_dependencies() {
  local missing=()
  local command_name
  for command_name in curl unzip python3 jq sha256sum tar nginx ss flock; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=('ca-certificates')
  [[ "${#missing[@]}" -eq 0 ]] && return 0

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl unzip python3 jq coreutils tar nginx iproute2 util-linux
}

acquire_lock_and_workspace() {
  exec 9>/var/lock/pokerops-frontend-deploy.lock
  flock -n 9 || fail 'another frontend deployment is already running'

  umask 077
  work_dir="$(mktemp -d /tmp/pokerops-frontend-deploy.XXXXXX)"
  chmod 700 "$work_dir"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
}

download_and_verify_payload() {
  local archive_path="$work_dir/$ARCHIVE_NAME"
  local manifest_path="$work_dir/$MANIFEST_NAME"

  curl -fsSL --retry 4 --retry-delay 2 --proto '=https' --tlsv1.2 \
    -o "$archive_path" "$ARCHIVE_URL"
  curl -fsSL --retry 4 --retry-delay 2 --proto '=https' --tlsv1.2 \
    -o "$manifest_path" "$MANIFEST_URL"

  printf '%s  %s\n' "$ARCHIVE_SHA256" "$archive_path" | sha256sum -c - >/dev/null

  jq -e \
    --arg archive "$ARCHIVE_NAME" \
    --arg sha "$ARCHIVE_SHA256" \
    --arg sourceRepository "$SOURCE_REPOSITORY" \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg route "$UI_ROUTE" \
    --arg apiBase "$API_PREFIX" \
    --arg indexJs "$INDEX_JS" \
    --arg indexCss "$INDEX_CSS" \
    '.schemaVersion == 1
      and .service == "pokerops-tournament-catalog-ui"
      and .mode == "read-only-preview"
      and .archive == $archive
      and .archiveSha256 == $sha
      and .sourceRepository == $sourceRepository
      and .sourceCommit == $sourceCommit
      and .route == $route
      and .apiBase == $apiBase
      and .indexJs == $indexJs
      and .indexCss == $indexCss' \
    "$manifest_path" >/dev/null
}

validate_and_extract_archive() {
  local archive_path="$work_dir/$ARCHIVE_NAME"
  local extract_root="$work_dir/extract"
  mkdir -p "$extract_root"

  if ! ARCHIVE_PATH_VALUE="$archive_path" EXTRACT_ROOT_VALUE="$extract_root" python3 <<'PY'
import os
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(os.environ['ARCHIVE_PATH_VALUE'])
extract_root = pathlib.Path(os.environ['EXTRACT_ROOT_VALUE'])

with zipfile.ZipFile(archive) as bundle:
    infos = bundle.infolist()
    if len(infos) != 67:
        raise SystemExit('unexpected archive entry count')

    seen = set()
    total_size = 0
    for info in infos:
        name = info.filename
        if not name or name in seen:
            raise SystemExit('duplicate or empty archive entry')
        seen.add(name)
        if '\\' in name or name.startswith(('/', '\\')):
            raise SystemExit('unsafe archive path')
        parts = pathlib.PurePosixPath(name).parts
        if any(part in ('', '.', '..') for part in parts):
            raise SystemExit('unsafe archive component')
        mode = (info.external_attr >> 16) & 0xFFFF
        if stat.S_ISLNK(mode):
            raise SystemExit('archive symlink is forbidden')
        if mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise SystemExit('archive special file is forbidden')
        if any(part.startswith('.env') for part in parts):
            raise SystemExit('environment file is forbidden')
        total_size += info.file_size
        if total_size > 100 * 1024 * 1024:
            raise SystemExit('archive is too large')

    required = {'index.html', '_redirects'}
    if not required.issubset(seen) or not any(name.startswith('assets/') for name in seen):
        raise SystemExit('archive layout is invalid')
    if any(name.startswith('dist/') for name in seen):
        raise SystemExit('nested dist directory is forbidden')

    bundle.extractall(extract_root)
PY
  then
    fail 'archive safety validation failed'
  fi

  [[ -f "$extract_root/index.html" ]] || fail 'index.html is missing'
  [[ -f "$extract_root/$INDEX_JS" ]] || fail 'expected index JS is missing'
  [[ -f "$extract_root/$INDEX_CSS" ]] || fail 'expected index CSS is missing'
  grep -Fq "$INDEX_JS" "$extract_root/index.html" || fail 'index.html has unexpected JS'
  grep -Fq "$INDEX_CSS" "$extract_root/index.html" || fail 'index.html has unexpected CSS'
  grep -RIlE \
    'postgresql://|MIGRATION_DATABASE_URL|DATABASE_URL=|INTERNAL_API_TOKEN=|IGNITION_PASSWORD=|CAPSOLVER_CLIENT_KEY=|TOURNAMENT_RUNTIME_ENV_B64|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY' \
    "$extract_root" >/dev/null && fail 'forbidden secret material detected in frontend payload'
  return 0
}

verify_worker_preflight() {
  local health_path="$work_dir/worker-health.json"
  local ready_path="$work_dir/worker-ready.json"
  local status_path="$work_dir/worker-status.json"
  local catalog_path="$work_dir/worker-catalog.json"

  curl -fsS --max-time 10 -o "$health_path" "$WORKER_URL/health"
  curl -fsS --max-time 10 -o "$ready_path" "$WORKER_URL/ready"
  curl -fsS --max-time 15 -o "$status_path" "$WORKER_URL/api/ingestion/status"
  curl -fsS --max-time 15 -o "$catalog_path" "$WORKER_URL/api/tournaments?limit=1&offset=0"

  jq -e '.status == "ok"' "$health_path" >/dev/null
  jq -e '.status == "ready"' "$ready_path" >/dev/null
  jq -e '.data.catalog.canonicalDuplicates == 0 and (.data.catalog.uniqueTournaments // 0) > 0' "$status_path" >/dev/null
  jq -e '.data | type == "array" and length > 0' "$catalog_path" >/dev/null

  ss -ltn | grep -Eq '127\.0\.0\.1:8787[[:space:]]' || fail 'worker is not bound to 127.0.0.1:8787'
  if ss -ltn | grep -Eq '(0\.0\.0\.0|\[::\]):8787[[:space:]]'; then
    fail 'worker port 8787 is exposed beyond loopback'
  fi
}

find_nginx_site() {
  local effective_path="$work_dir/nginx-effective-preflight.conf"
  local active_files_path="$work_dir/nginx-active-files.txt"
  nginx -T >"$effective_path" 2>&1
  sed -nE 's/^# configuration file (.*):$/\1/p' "$effective_path" >"$active_files_path"

  local candidate canonical
  while IFS= read -r candidate; do
    [[ -f "$candidate" ]] || continue
    canonical="$(readlink -f "$candidate")"
    [[ -n "$canonical" && "$canonical" == /etc/nginx/* && -f "$canonical" ]] || continue
    if grep -Eq 'server_name[^;]*\bforprofit\.pro\b|root[[:space:]]+/var/www/pokerops' "$candidate"; then
      printf '%s\n' "$canonical"
      return 0
    fi
  done <"$active_files_path"

  for candidate in /etc/nginx/sites-enabled/pokerops /etc/nginx/conf.d/pokerops.conf /etc/nginx/sites-available/pokerops; do
    if [[ -f "$candidate" ]]; then
      readlink -f "$candidate"
      return 0
    fi
  done

  local found
  found="$(grep -RslE 'server_name .*forprofit\.pro|root[[:space:]]+/var/www/pokerops' \
    /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/nginx/sites-available 2>/dev/null \
    | head -n 1 || true)"
  [[ -n "$found" ]] || fail 'PokerOps Nginx site was not found'
  readlink -f "$found"
}

prepare_nginx_patch() {
  site_path="$(find_nginx_site)"
  [[ -f "$site_path" && ! -L "$site_path" ]] || fail 'resolved Nginx site is not a regular file'

  install -d -o root -g root -m 700 "$NGINX_BACKUP_ROOT"
  nginx_backup="$NGINX_BACKUP_ROOT/pokerops-nginx-$timestamp.conf"
  cp -a "$site_path" "$nginx_backup"
  chmod 600 "$nginx_backup"
  nginx_before_sha="$(sha256sum "$site_path" | awk '{print $1}')"
  cp "$site_path" "$work_dir/nginx-site-original.conf"

  if ! NGINX_SOURCE_VALUE="$work_dir/nginx-site-original.conf" \
    NGINX_PATCHED_VALUE="$work_dir/nginx-site-patched.conf" \
    WEB_ROOT_VALUE="$WEB_ROOT" \
    python3 <<'PY'
import os
import re

source = os.environ['NGINX_SOURCE_VALUE']
patched = os.environ['NGINX_PATCHED_VALUE']
web_root = os.environ['WEB_ROOT_VALUE']

with open(source, 'r', encoding='utf-8') as handle:
    text = handle.read()

managed = r'''    # BEGIN POKEROPS TOURNAMENT INGESTION
    location = /tournament-ingestion-api/internal {
        return 404;
    }

    location ^~ /tournament-ingestion-api/internal/ {
        return 404;
    }

    location = /tournament-ingestion-api/metrics {
        return 404;
    }

    location ^~ /tournament-ingestion-api/metrics/ {
        return 404;
    }

    location ^~ /tournament-ingestion-api/ {
        if ($request_method !~ ^(GET|HEAD)$) {
            return 405;
        }
        proxy_pass http://127.0.0.1:8787/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 3s;
        proxy_send_timeout 15s;
        proxy_read_timeout 30s;
        add_header Cache-Control "no-store" always;
    }
    # END POKEROPS TOURNAMENT INGESTION'''

def matching_brace(value: str, opening: int) -> int:
    depth = 0
    quote = None
    escaped = False
    for index in range(opening, len(value)):
        char = value[index]
        if quote:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in ('"', "'"):
            quote = char
        elif char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return index
    return -1

marker = re.compile(
    r'\n\s*# BEGIN POKEROPS TOURNAMENT INGESTION.*?# END POKEROPS TOURNAMENT INGESTION\s*',
    re.S,
)

pieces = []
position = 0
patched_count = 0
while True:
    match = re.search(r'\bserver\s*\{', text[position:])
    if not match:
        pieces.append(text[position:])
        break
    start = position + match.start()
    opening = text.find('{', start)
    end = matching_brace(text, opening)
    if end < 0:
        raise RuntimeError('cannot parse Nginx server block')

    pieces.append(text[position:start])
    block = text[start:end + 1]
    block = marker.sub('\n', block)
    is_forprofit_server = re.search(
        r'^\s*server_name\s+[^;]*\bforprofit\.pro\b[^;]*;', block, re.M
    ) is not None
    if web_root in block or is_forprofit_server:
        lines = block.splitlines()
        if not lines or '{' not in lines[0]:
            raise RuntimeError('invalid Nginx server block')
        # Insert directly under `server {` so the managed locations can never
        # be nested accidentally inside an existing location block.
        lines[1:1] = ['', managed]
        block = '\n'.join(lines)
        patched_count += 1

    pieces.append(block)
    position = end + 1

if patched_count == 0:
    raise RuntimeError('no PokerOps Nginx server block was patched')

result = ''.join(pieces)
if result.count('# BEGIN POKEROPS TOURNAMENT INGESTION') != patched_count:
    raise RuntimeError('managed Nginx block count mismatch')

with open(patched, 'w', encoding='utf-8') as handle:
    handle.write(result)
PY
  then
    fail 'Nginx proxy patch generation failed'
  fi
}

create_frontend_backup() {
  [[ -d "$WEB_ROOT" && -f "$WEB_ROOT/index.html" ]] || fail 'existing PokerOps frontend is missing'
  id deploy >/dev/null 2>&1 || fail 'deploy user is missing'
  getent group www-data >/dev/null 2>&1 || fail 'www-data group is missing'

  install -d -o root -g root -m 750 "$BACKUP_ROOT"
  frontend_backup="$BACKUP_ROOT/pokerops-before-tournament-ui-$timestamp.tar.gz"
  frontend_index_before_sha="$(sha256sum "$WEB_ROOT/index.html" | awk '{print $1}')"
  tar -czf "$frontend_backup" -C "$WEB_ROOT" .
  chmod 600 "$frontend_backup"
  tar -tzf "$frontend_backup" >/dev/null
}

deploy_frontend_and_nginx() {
  frontend_changed=true
  unzip -oq "$work_dir/$ARCHIVE_NAME" -d "$WEB_ROOT"
  chown -R "$WEB_OWNER" "$WEB_ROOT"
  find "$WEB_ROOT" -type d -exec chmod 755 {} +
  find "$WEB_ROOT" -type f -exec chmod 644 {} +

  grep -Fq "$INDEX_JS" "$WEB_ROOT/index.html" || fail 'deployed index JS does not match payload'
  grep -Fq "$INDEX_CSS" "$WEB_ROOT/index.html" || fail 'deployed index CSS does not match payload'

  nginx_changed=true
  install -o root -g root -m 644 "$work_dir/nginx-site-patched.conf" "$site_path"
  nginx -t
  reload_nginx
  nginx -T >"$work_dir/nginx-effective.conf" 2>&1
  if ! EFFECTIVE_NGINX_VALUE="$work_dir/nginx-effective.conf" SITE_HOST_VALUE="$SITE_HOST" \
    python3 <<'PY'
import os
import re

path = os.environ['EFFECTIVE_NGINX_VALUE']
site_host = os.environ['SITE_HOST_VALUE']
with open(path, 'r', encoding='utf-8', errors='replace') as handle:
    text = handle.read()

def matching_brace(value: str, opening: int) -> int:
    depth = 0
    quote = None
    escaped = False
    for index in range(opening, len(value)):
        char = value[index]
        if quote:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in ('"', "'"):
            quote = char
        elif char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return index
    return -1

tls_targets = []
position = 0
while True:
    match = re.search(r'\bserver\s*\{', text[position:])
    if not match:
        break
    start = position + match.start()
    opening = text.find('{', start)
    end = matching_brace(text, opening)
    if end < 0:
        raise SystemExit('effective Nginx server block is malformed')
    block = text[start:end + 1]
    has_host = re.search(
        rf'^\s*server_name\s+[^;]*\b{re.escape(site_host)}\b[^;]*;', block, re.M
    ) is not None
    has_tls = re.search(r'^\s*listen\s+[^;]*\b443\b[^;]*;', block, re.M) is not None
    if has_host and has_tls:
        tls_targets.append(block)
    position = end + 1

if len(tls_targets) != 1:
    raise SystemExit('expected exactly one active TLS server for production host')

target = tls_targets[0]
required_patterns = (
    r'^\s*location\s+\^~\s+/tournament-ingestion-api/\s*\{',
    r'^\s*location\s+\^~\s+/tournament-ingestion-api/internal/\s*\{',
    r'^\s*location\s+\^~\s+/tournament-ingestion-api/metrics/\s*\{',
    r'^\s*proxy_pass\s+http://127\.0\.0\.1:8787/\s*;',
)
if any(len(re.findall(pattern, target, re.M)) != 1 for pattern in required_patterns):
    raise SystemExit('effective production TLS server has an invalid managed proxy block')
PY
  then
    fail 'managed Nginx proxy is not active in the production TLS server'
  fi
}

classify_safe_response() {
  local response_path=$1
  if [[ ! -s "$response_path" ]]; then
    printf 'empty'
  elif jq -e . "$response_path" >/dev/null 2>&1; then
    printf 'json-unexpected'
  elif grep -Eiq '<!doctype|<html|<head|<title|<body' "$response_path"; then
    printf 'html'
  else
    printf 'non-json'
  fi
}

wait_for_local_json() {
  local url=$1
  local output_path=$2
  local jq_filter=$3
  local label=$4
  local candidate_path="${output_path}.candidate"
  local attempt

  for attempt in $(seq 1 45); do
    if curl --noproxy '*' --resolve "${SITE_HOST}:443:127.0.0.1" \
      -fsS --max-time 10 -o "$candidate_path" "$url" \
      && jq -e "$jq_filter" "$candidate_path" >/dev/null 2>&1; then
      mv -f "$candidate_path" "$output_path"
      return 0
    fi
    sleep 1
  done

  local response_kind
  response_kind="$(classify_safe_response "$candidate_path")"
  rm -f -- "$candidate_path"
  fail "local Nginx ${label} did not become ready (response=${response_kind})"
}

verify_public_frontend() {
  local page_path="$work_dir/public-page.html"
  local health_path="$work_dir/public-health.json"
  local ready_path="$work_dir/public-ready.json"
  local status_path="$work_dir/public-status.json"
  local catalog_path="$work_dir/public-catalog.json"

  local resolve_target="${SITE_HOST}:443:127.0.0.1"

  wait_for_local_json "${SITE_URL}${API_PREFIX}/health" "$health_path" \
    '.status == "ok"' 'health'
  wait_for_local_json "${SITE_URL}${API_PREFIX}/ready" "$ready_path" \
    '.status == "ready"' 'readiness'
  wait_for_local_json "${SITE_URL}${API_PREFIX}/api/ingestion/status" "$status_path" \
    '.data.catalog.canonicalDuplicates == 0 and (.data.catalog.uniqueTournaments // 0) > 0' \
    'ingestion status'
  wait_for_local_json "${SITE_URL}${API_PREFIX}/api/tournaments?limit=1&offset=0" "$catalog_path" \
    '.data | type == "array" and length > 0' 'tournament catalog'

  # Verify the exact production Nginx vhost locally. A VPS resolving its own
  # public hostname through an external proxy/CDN can receive an unrelated
  # HTML error even when the local vhost is healthy.
  curl --noproxy '*' --resolve "$resolve_target" -fsS --max-time 20 \
    -o "$page_path" "${SITE_URL}${UI_ROUTE}"
  grep -Fq '<title>PokerOps Dashboard</title>' "$page_path" || fail 'production UI route did not return PokerOps shell'

  local write_status
  write_status="$(curl --noproxy '*' --resolve "$resolve_target" -sS --max-time 15 -o /dev/null -w '%{http_code}' \
    -X POST "${SITE_URL}${API_PREFIX}/internal/catalog/collect" || true)"
  [[ "$write_status" == '404' || "$write_status" == '405' ]] || fail 'public proxy did not block internal write endpoint'

  local live_index="$work_dir/live-index.html"
  curl --noproxy '*' --resolve "$resolve_target" -fsS --max-time 15 \
    -o "$live_index" "${SITE_URL}/index.html"
  grep -Fq "$INDEX_JS" "$live_index" || fail 'public index JS is stale'
  grep -Fq "$INDEX_CSS" "$live_index" || fail 'public index CSS is stale'
}

write_report() {
  local status_path="$work_dir/public-status.json"
  local unique_count scheduled_count sng_count duplicate_count
  unique_count="$(jq -r '.data.catalog.uniqueTournaments' "$status_path")"
  scheduled_count="$(jq -r '.data.catalog.scheduled' "$status_path")"
  sng_count="$(jq -r '.data.catalog.sng' "$status_path")"
  duplicate_count="$(jq -r '.data.catalog.canonicalDuplicates' "$status_path")"

  install -d -o root -g root -m 750 "$STATE_ROOT/history"
  local report_path="$STATE_ROOT/history/frontend-deploy-$timestamp.json"
  jq -n \
    --arg deployedAt "$timestamp" \
    --arg siteUrl "${SITE_URL}${UI_ROUTE}" \
    --arg sourceRepository "$SOURCE_REPOSITORY" \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg payloadCommit "$PAYLOAD_COMMIT" \
    --arg archiveSha256 "$ARCHIVE_SHA256" \
    --arg indexJs "$INDEX_JS" \
    --arg indexCss "$INDEX_CSS" \
    --arg frontendBackup "$frontend_backup" \
    --arg nginxBackup "$nginx_backup" \
    --argjson uniqueCount "$unique_count" \
    --argjson scheduledCount "$scheduled_count" \
    --argjson sngCount "$sng_count" \
    --argjson duplicateCount "$duplicate_count" \
    '{schemaVersion: 1, service: "pokerops-tournament-catalog-ui", deployedAt: $deployedAt,
      siteUrl: $siteUrl, mode: "read-only-preview", sourceRepository: $sourceRepository,
      sourceCommit: $sourceCommit, payloadCommit: $payloadCommit, archiveSha256: $archiveSha256,
      indexJs: $indexJs, indexCss: $indexCss, health: "ok", readiness: "ready",
      uniqueCount: $uniqueCount, scheduledCount: $scheduledCount, sngCount: $sngCount,
      duplicateCount: $duplicateCount, publicWriteEndpoints: "blocked", workerBinding: "loopback",
      frontendBackup: $frontendBackup, nginxBackup: $nginxBackup}' \
    >"$work_dir/report.json"
  install -o root -g root -m 600 "$work_dir/report.json" "$report_path"

  deployment_succeeded=true
  frontend_changed=false
  nginx_changed=false

  printf '%s\n' \
    'FRONTEND DEPLOYMENT SUCCESS' \
    "url=${SITE_URL}${UI_ROUTE}" \
    "source_commit=${SOURCE_COMMIT}" \
    "payload_commit=${PAYLOAD_COMMIT}" \
    "archive_sha256=${ARCHIVE_SHA256}" \
    "index_js=${INDEX_JS}" \
    "index_css=${INDEX_CSS}" \
    'health=ok' \
    'readiness=ready' \
    "scheduled_count=${scheduled_count}" \
    "sng_count=${sng_count}" \
    "unique_count=${unique_count}" \
    "duplicate_count=${duplicate_count}" \
    'public_writes=blocked' \
    'worker_binding=127.0.0.1:8787' \
    "frontend_backup=${frontend_backup}" \
    "nginx_backup=${nginx_backup}" \
    "report=${report_path}"
}

main() {
  [[ "$#" -eq 0 ]] || fail 'this helper accepts no arguments'

  stage='os-preflight'
  require_root_and_os

  stage='dependency-bootstrap'
  install_dependencies
  acquire_lock_and_workspace

  stage='payload-download'
  download_and_verify_payload

  stage='archive-validation'
  validate_and_extract_archive

  stage='worker-preflight'
  verify_worker_preflight

  stage='nginx-preparation'
  prepare_nginx_patch

  stage='frontend-backup'
  create_frontend_backup

  stage='frontend-activation'
  deploy_frontend_and_nginx

  stage='public-smoke'
  verify_public_frontend

  stage='report'
  write_report
}

if [[ "${POKEROPS_FRONTEND_DEPLOY_LIBRARY_ONLY:-0}" != '1' ]]; then
  main "$@"
fi
