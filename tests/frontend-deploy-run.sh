#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
helper="$repository_root/frontend-deploy.sh"
payload="$repository_root/pokerops-tournament-ui.zip"
work_root=$(mktemp -d "${TMPDIR:-/tmp}/pokerops-frontend-helper-tests.XXXXXXXX")
trap 'rm -rf -- "$work_root"' EXIT

export POKEROPS_FRONTEND_DEPLOY_LIBRARY_ONLY=1
# shellcheck source=../frontend-deploy.sh
source "$helper"
trap 'rm -rf -- "$work_root"' EXIT

pass_count=0
fail_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS: %s\n' "$1"
}

fail_test() {
  fail_count=$((fail_count + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

expect_archive_success() {
  local name=$1
  local archive=$2
  local case_root="$work_root/$name"
  mkdir -p "$case_root"
  cp "$archive" "$case_root/$ARCHIVE_NAME"
  if POKEROPS_FRONTEND_DEPLOY_LIBRARY_ONLY=1 bash -c \
    'source "$1"; work_dir="$2"; validate_and_extract_archive' _ "$helper" "$case_root" \
    >"$case_root.out" 2>"$case_root.err"; then
    pass "$name"
  else
    fail_test "$name"
  fi
}

expect_archive_failure() {
  local name=$1
  local archive=$2
  local case_root="$work_root/$name"
  mkdir -p "$case_root"
  cp "$archive" "$case_root/$ARCHIVE_NAME"
  if POKEROPS_FRONTEND_DEPLOY_LIBRARY_ONLY=1 bash -c \
    'source "$1"; work_dir="$2"; validate_and_extract_archive' _ "$helper" "$case_root" \
    >"$case_root.out" 2>"$case_root.err"; then
    fail_test "$name"
  else
    pass "$name"
  fi
}

expected_sha='655bdef3b5ab44a34045c01ade637962dd4ae41f52a970c69034e9992db9f7f9'
actual_sha=$(sha256sum "$payload" | awk '{print $1}')
[[ "$actual_sha" == "$expected_sha" ]] && pass payload-checksum || fail_test payload-checksum

expect_archive_success valid-archive "$payload"

python3 - "$payload" "$work_root/traversal.zip" <<'PY'
import sys
import zipfile

source, target = sys.argv[1:]
with zipfile.ZipFile(source) as input_zip, zipfile.ZipFile(target, 'w') as output_zip:
    for index, info in enumerate(input_zip.infolist()):
        data = input_zip.read(info.filename)
        if index == 0:
            info.filename = '../outside'
        output_zip.writestr(info, data)
PY
expect_archive_failure traversal-rejected "$work_root/traversal.zip"

python3 - "$payload" "$work_root/symlink.zip" <<'PY'
import stat
import sys
import zipfile

source, target = sys.argv[1:]
with zipfile.ZipFile(source) as input_zip, zipfile.ZipFile(target, 'w') as output_zip:
    for index, info in enumerate(input_zip.infolist()):
        data = input_zip.read(info.filename)
        if index == 0:
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            data = b'index.html'
        output_zip.writestr(info, data)
PY
expect_archive_failure symlink-rejected "$work_root/symlink.zip"

python3 - "$payload" "$work_root/secret.zip" <<'PY'
import sys
import zipfile

source, target = sys.argv[1:]
changed = False
with zipfile.ZipFile(source) as input_zip, zipfile.ZipFile(target, 'w') as output_zip:
    for info in input_zip.infolist():
        data = input_zip.read(info.filename)
        if not changed and info.filename.endswith('.js'):
            data += b'\nDATABASE_URL=forbidden\n'
            changed = True
        output_zip.writestr(info, data)
PY
expect_archive_failure secret-material-rejected "$work_root/secret.zip"

if grep -Fq "PAYLOAD_COMMIT='894be971df2b55ca89b18ead5ee7be579f130c2a'" "$helper" \
  && grep -Fq "ARCHIVE_SHA256='$expected_sha'" "$helper"; then
  pass immutable-payload-pin
else
  fail_test immutable-payload-pin
fi

if grep -Fq 'proxy_pass http://127.0.0.1:8787/;' "$helper" \
  && grep -Fq 'if ($request_method !~ ^(GET|HEAD)$)' "$helper" \
  && grep -Fq 'location ^~ /tournament-ingestion-api/internal/' "$helper"; then
  pass read-only-loopback-proxy
else
  fail_test read-only-loopback-proxy
fi

if grep -Fq 'restore_frontend' "$helper" \
  && grep -Fq 'restore_nginx' "$helper" \
  && grep -Fq 'rollback_nginx_restore_status=' "$helper" \
  && grep -Fq 'rollback_frontend_restore_status=' "$helper"; then
  pass rollback-gates
else
  fail_test rollback-gates
fi

if grep -Fq 'local resolve_target="${SITE_HOST}:443:127.0.0.1"' "$helper" \
  && grep -Fq 'curl --resolve "$resolve_target"' "$helper" \
  && grep -Fq 'local Nginx ingestion status response is invalid' "$helper"; then
  pass local-nginx-public-smoke
else
  fail_test local-nginx-public-smoke
fi

if python3 "$repository_root/tests/test_frontend_nginx_patch.py" "$helper" >/dev/null; then
  pass nginx-patch-idempotency
else
  fail_test nginx-patch-idempotency
fi

if grep -Eq 'migrate\.mjs|\.env\.migration|docker[[:space:]]+compose|psql[[:space:]]' "$helper"; then
  fail_test no-migration-or-worker-mutation
else
  pass no-migration-or-worker-mutation
fi

if grep -Eq "postgresql://[^[:space:]\"']+:[^[:space:]@\"']+@|-----BEGIN (RSA|OPENSSH|AGE) PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}" \
  "$helper" "$repository_root/pokerops-tournament-ui.manifest.json"; then
  fail_test repository-secret-scan
else
  pass repository-secret-scan
fi

printf 'frontend helper tests: passed=%s failed=%s\n' "$pass_count" "$fail_count"
((fail_count == 0))

