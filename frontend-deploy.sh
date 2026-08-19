#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_REPOSITORY='yovoweqif674-cyber/pokerops-bootstrap'
readonly PAYLOAD_COMMIT='643516471bb531d21e6c82ad670373a9643a68f1'
readonly SOURCE_REPOSITORY='yovoweqif674-cyber/po'
readonly SOURCE_COMMIT='5ac17f1bfd0f635c2eeab9438bc5ac048164247b'
readonly ARCHIVE_NAME='pokerops-tournament-ui.zip'
readonly MANIFEST_NAME='pokerops-tournament-ui.manifest.json'
readonly ARCHIVE_SHA256='6f9bbfcb8116f98c892bec29be988c21cbd9e4d7f48fbf357b6f90e439c4ba96'
readonly INDEX_JS='assets/index-DgdmSeIh.js'
readonly INDEX_CSS='assets/index-B5yM79TK.css'
readonly RAW_ROOT="https://raw.githubusercontent.com/${BOOTSTRAP_REPOSITORY}/${PAYLOAD_COMMIT}"
readonly ARCHIVE_URL="${RAW_ROOT}/${ARCHIVE_NAME}"
readonly MANIFEST_URL="${RAW_ROOT}/${MANIFEST_NAME}"

readonly WEB_ROOT='/var/www/pokerops'
readonly WEB_OWNER='deploy:www-data'
readonly BACKUP_ROOT='/var/www/pokerops-backups'
readonly NGINX_BACKUP_ROOT='/var/backups/pokerops-tournament-ui'
readonly STATE_ROOT='/var/lib/pokerops-frontend-deploy'
readonly SITE_URL='https://forprofit.pro'
readonly UI_ROUTE='/preview/v4/manager/tournaments'
readonly API_PREFIX='/tournament-ingestion-api'
readonly WORKER_URL='http://127.0.0.1:8787'

stage='preflight'
work_dir=''
site_path=''
nginx_backup=''
frontend_backup=''
frontend_changed=false
nginx_changed=false
timestamp=''

safe_error() {
  printf '%s\n' "$*" >&2
}

fail() {
  safe_error "$*"
  return 1
}

reload_nginx() {
  if command -v systemctl >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; then
    return
  fi
  nginx -s reload >/dev/null
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
}

restore_nginx() {
  [[ "$nginx_changed" == true ]] || return 0
  [[ -n "$site_path" && -n "$nginx_backup" && -f "$nginx_backup" ]] || return 1
  install -o root -g root -m 644 "$nginx_backup" "$site_path"
}

on_error() {
  local status="${1:-1}"
  trap - ERR
  set +e

  local rollback='not-required'
  if [[ "$frontend_changed" == true || "$nginx_changed" == true ]]; then
    rollback='failed'
    restore_nginx
    local nginx_restore_status=$?
    restore_frontend
    local frontend_restore_status=$?
    if [[ "$nginx_restore_status" -eq 0 && "$frontend_restore_status" -eq 0 ]]; then
      if nginx -t >/dev/null 2>&1 && reload_nginx; then
        rollback='complete'
      fi
    fi
  fi

  printf '%s\n' \
    'FRONTEND DEPLOYMENT FAILED' \
    "stage=${stage}" \
    "rollback=${rollback}" \
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
    if len(infos) != 66:
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

verify_operational_health_file() {
  local health_path="$1"
  jq -e '
    .data as $health |
    ($health.catalog.fresh == true) and
    ($health.scheduler.fresh == true) and
    ($health.jobWorker.fresh == true) and
    ($health.runs.stuck == 0) and
    ($health.queue.unclassified == 0) and
    ($health.queue.expiredLeases == 0) and
    ($health.queue.failed == $health.queue.terminal) and
    (
      $health.status == "healthy" or
      ($health.status == "degraded" and $health.queue.terminal > 0 and (($health.reasons | sort) == ["failed_jobs_present"]))
    )
  ' "$health_path" >/dev/null || fail 'worker operational health gate failed'
}

assert_sanitized_json_file() {
  local path="$1"
  jq -e '
    [recurse(.[]?; true) | objects | keys[] |
      select(test("^(raw|rawPayload|payload|headers|cookies|authorization|token|password|proxy|captcha|session|html|body|stack|errorMessage)$"; "i"))
    ] | length == 0
  ' "$path" >/dev/null || fail 'public API response exposes a forbidden field'
}

verify_catalog_contract_files() {
  local status_path="$1" catalog_path="$2" filtered_path="$3" detail_path="$4" timeline_path="$5" status_filter="$6"
  jq -e '
    (.data | type == "array" and length == 1) and
    (.data[0].presentInLatestSuccessfulCatalog == true) and
    (.pagination.total >= 1) and
    (.facets.scopeTotal >= .pagination.total) and
    (.facets.canonicalDuplicates == 0)
  ' "$catalog_path" >/dev/null || fail 'catalog list contract validation failed'
  local scope_total
  scope_total="$(jq -r '.facets.scopeTotal' "$catalog_path")"
  jq -e --arg status "$status_filter" --argjson scopeTotal "$scope_total" '
    (.facets.scopeTotal == $scopeTotal) and
    (.pagination.total == .facets.byStatus[$status]) and
    (.pagination.total < .facets.scopeTotal) and
    (.facets.canonicalDuplicates == 0)
  ' "$filtered_path" >/dev/null || fail 'filtered pagination and scoped facets contract validation failed'
  jq -e '
    .data.catalog.canonicalDuplicates == 0 and
    (.data.catalog.uniqueTournaments // 0) > 0 and
    (.data.startupReconciliation.status == "completed") and
    (.data.startupReconciliation.jobsUnclassified == 0)
  ' "$status_path" >/dev/null || fail 'ingestion status contract validation failed'
  jq -e '.data.tournament.presentInLatestSuccessfulCatalog == true' "$detail_path" >/dev/null \
    || fail 'tournament detail membership contract validation failed'
  jq -e '.data | type == "array" and length >= 1' "$timeline_path" >/dev/null \
    || fail 'tournament timeline contract validation failed'
  assert_sanitized_json_file "$status_path"
  assert_sanitized_json_file "$catalog_path"
  assert_sanitized_json_file "$filtered_path"
  assert_sanitized_json_file "$detail_path"
  assert_sanitized_json_file "$timeline_path"
}

verify_worker_preflight() {
  local health_path="$work_dir/worker-health.json"
  local ready_path="$work_dir/worker-ready.json"
  local operational_path="$work_dir/worker-operational.json"
  local status_path="$work_dir/worker-status.json"
  local catalog_path="$work_dir/worker-catalog.json"
  local filtered_path="$work_dir/worker-filtered.json"
  local detail_path="$work_dir/worker-detail.json"
  local timeline_path="$work_dir/worker-timeline.json"
  local tournament_id status_filter

  curl -fsS --max-time 10 -o "$health_path" "$WORKER_URL/health"
  curl -fsS --max-time 10 -o "$ready_path" "$WORKER_URL/ready"
  curl -fsS --max-time 15 -o "$operational_path" "$WORKER_URL/api/ingestion/health"
  curl -fsS --max-time 15 -o "$status_path" "$WORKER_URL/api/ingestion/status"
  curl -fsS --max-time 15 -o "$catalog_path" "$WORKER_URL/api/tournaments?scope=current&limit=1&offset=0"

  tournament_id="$(jq -r '.data[0].externalTournamentId // empty' "$catalog_path")"
  [[ "$tournament_id" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'catalog returned an invalid tournament identifier'
  status_filter="$(jq -r '.facets as $facets | [$facets.byStatus | to_entries[] | select(.value > 0 and .value < $facets.scopeTotal) | .key][0] // empty' "$catalog_path")"
  [[ "$status_filter" =~ ^[a-z]+$ ]] || fail 'catalog data cannot prove filtered and scoped totals'
  curl -fsS --max-time 15 -o "$filtered_path" "$WORKER_URL/api/tournaments?scope=current&status=$status_filter&limit=1&offset=0"
  curl -fsS --max-time 15 -o "$detail_path" "$WORKER_URL/api/tournaments/$tournament_id"
  curl -fsS --max-time 15 -o "$timeline_path" "$WORKER_URL/api/tournaments/$tournament_id/timeline?limit=10"

  jq -e '.status == "ok"' "$health_path" >/dev/null
  jq -e '.status == "ready"' "$ready_path" >/dev/null
  verify_operational_health_file "$operational_path"
  verify_catalog_contract_files "$status_path" "$catalog_path" "$filtered_path" "$detail_path" "$timeline_path" "$status_filter"

  ss -ltn | grep -Eq '127\.0\.0\.1:8787[[:space:]]' || fail 'worker is not bound to 127.0.0.1:8787'
  if ss -ltn | grep -Eq '(0\.0\.0\.0|\[::\]):8787[[:space:]]'; then
    fail 'worker port 8787 is exposed beyond loopback'
  fi
}

find_nginx_site() {
  local candidate
  for candidate in /etc/nginx/sites-available/pokerops /etc/nginx/sites-enabled/pokerops; do
    if [[ -f "$candidate" ]]; then
      readlink -f "$candidate"
      return 0
    fi
  done

  local found
  found="$(grep -RslE 'server_name .*forprofit\.pro|root[[:space:]]+/var/www/pokerops' \
    /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
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
    if web_root in block or ('server_name' in block and 'forprofit.pro' in block and 'root' in block):
        lines = block.splitlines()
        anchor = None
        for index, line in enumerate(lines):
            if re.search(r'^\s*index\s+index\.html\s*;', line):
                anchor = index
                break
        if anchor is None:
            for index, line in enumerate(lines):
                if re.search(r'^\s*root\s+', line):
                    anchor = index
                    break
        if anchor is None:
            raise RuntimeError('Nginx site has no root/index anchor')
        lines[anchor + 1:anchor + 1] = ['', managed]
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
}

verify_public_frontend() {
  local page_path="$work_dir/public-page.html"
  local health_path="$work_dir/public-health.json"
  local ready_path="$work_dir/public-ready.json"
  local operational_path="$work_dir/public-operational.json"
  local status_path="$work_dir/public-status.json"
  local catalog_path="$work_dir/public-catalog.json"
  local filtered_path="$work_dir/public-filtered.json"
  local detail_path="$work_dir/public-detail.json"
  local timeline_path="$work_dir/public-timeline.json"
  local tournament_id status_filter

  curl -fsS --max-time 20 -o "$page_path" "${SITE_URL}${UI_ROUTE}"
  grep -Fq '<title>PokerOps Dashboard</title>' "$page_path" || fail 'production UI route did not return PokerOps shell'

  curl -fsS --max-time 15 -o "$health_path" "${SITE_URL}${API_PREFIX}/health"
  curl -fsS --max-time 15 -o "$ready_path" "${SITE_URL}${API_PREFIX}/ready"
  curl -fsS --max-time 20 -o "$operational_path" "${SITE_URL}${API_PREFIX}/api/ingestion/health"
  curl -fsS --max-time 20 -o "$status_path" "${SITE_URL}${API_PREFIX}/api/ingestion/status"
  curl -fsS --max-time 20 -o "$catalog_path" "${SITE_URL}${API_PREFIX}/api/tournaments?scope=current&limit=1&offset=0"

  tournament_id="$(jq -r '.data[0].externalTournamentId // empty' "$catalog_path")"
  [[ "$tournament_id" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'public catalog returned an invalid tournament identifier'
  status_filter="$(jq -r '.facets as $facets | [$facets.byStatus | to_entries[] | select(.value > 0 and .value < $facets.scopeTotal) | .key][0] // empty' "$catalog_path")"
  [[ "$status_filter" =~ ^[a-z]+$ ]] || fail 'public catalog cannot prove filtered and scoped totals'
  curl -fsS --max-time 20 -o "$filtered_path" "${SITE_URL}${API_PREFIX}/api/tournaments?scope=current&status=$status_filter&limit=1&offset=0"
  curl -fsS --max-time 20 -o "$detail_path" "${SITE_URL}${API_PREFIX}/api/tournaments/$tournament_id"
  curl -fsS --max-time 20 -o "$timeline_path" "${SITE_URL}${API_PREFIX}/api/tournaments/$tournament_id/timeline?limit=10"

  jq -e '.status == "ok"' "$health_path" >/dev/null
  jq -e '.status == "ready"' "$ready_path" >/dev/null
  verify_operational_health_file "$operational_path"
  verify_catalog_contract_files "$status_path" "$catalog_path" "$filtered_path" "$detail_path" "$timeline_path" "$status_filter"

  local write_status
  write_status="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
    -X POST "${SITE_URL}${API_PREFIX}/internal/catalog/collect" || true)"
  [[ "$write_status" == '404' || "$write_status" == '405' ]] || fail 'public proxy did not block internal write endpoint'

  local live_index="$work_dir/live-index.html"
  curl -fsS --max-time 15 -o "$live_index" "${SITE_URL}/index.html"
  grep -Fq "$INDEX_JS" "$live_index" || fail 'public index JS is stale'
  grep -Fq "$INDEX_CSS" "$live_index" || fail 'public index CSS is stale'
}

write_report() {
  local status_path="$work_dir/public-status.json"
  local operational_path="$work_dir/public-operational.json"
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
    --arg operationalStatus "$(jq -r '.data.status' "$operational_path")" \
    --argjson schedulerFresh "$(jq '.data.scheduler.fresh' "$operational_path")" \
    --argjson jobWorkerFresh "$(jq '.data.jobWorker.fresh' "$operational_path")" \
    --argjson catalogFresh "$(jq '.data.catalog.fresh' "$operational_path")" \
    --argjson terminalJobs "$(jq '.data.queue.terminal' "$operational_path")" \
    --argjson unclassifiedJobs "$(jq '.data.queue.unclassified' "$operational_path")" \
    '{schemaVersion: 1, service: "pokerops-tournament-catalog-ui", deployedAt: $deployedAt,
      siteUrl: $siteUrl, mode: "read-only-preview", sourceRepository: $sourceRepository,
      sourceCommit: $sourceCommit, payloadCommit: $payloadCommit, archiveSha256: $archiveSha256,
      indexJs: $indexJs, indexCss: $indexCss, health: "ok", readiness: "ready",
      uniqueCount: $uniqueCount, scheduledCount: $scheduledCount, sngCount: $sngCount,
      duplicateCount: $duplicateCount, operationalStatus: $operationalStatus,
      schedulerFresh: $schedulerFresh, jobWorkerFresh: $jobWorkerFresh, catalogFresh: $catalogFresh,
      terminalJobs: $terminalJobs, unclassifiedJobs: $unclassifiedJobs,
      publicWriteEndpoints: "blocked", workerBinding: "loopback",
      frontendBackup: $frontendBackup, nginxBackup: $nginxBackup}' \
    >"$work_dir/report.json"
  install -o root -g root -m 600 "$work_dir/report.json" "$report_path"

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
    "operational_status=$(jq -r '.data.status' "$operational_path")" \
    "scheduler_fresh=$(jq -r '.data.scheduler.fresh' "$operational_path")" \
    "job_worker_fresh=$(jq -r '.data.jobWorker.fresh' "$operational_path")" \
    "catalog_fresh=$(jq -r '.data.catalog.fresh' "$operational_path")" \
    "terminal_jobs=$(jq -r '.data.queue.terminal' "$operational_path")" \
    "unclassified_jobs=$(jq -r '.data.queue.unclassified' "$operational_path")" \
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
