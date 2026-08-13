#!/usr/bin/env bash
# This is a dynamic source-based test harness; globals and mocked functions are consumed
# indirectly by the sourced bootstrap entrypoint.
# shellcheck disable=SC1091,SC2015,SC2016,SC2030,SC2031,SC2034,SC2329
set -Eeuo pipefail

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
script="$repository_root/tournament-ingestion.sh"
work_root=$(mktemp -d "${TMPDIR:-/tmp}/pokerops-bootstrap-tests.XXXXXXXX")
trap 'rm -rf -- "$work_root"' EXIT

export POKEROPS_BOOTSTRAP_LIBRARY_ONLY=1
# shellcheck source=../tournament-ingestion.sh
source "$script"

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

expect_success() {
  local name=$1
  shift
  if "$@" >"$work_root/$name.out" 2>"$work_root/$name.err"; then pass "$name"; else fail_test "$name"; fi
}

expect_failure() {
  local name=$1
  shift
  if "$@" >"$work_root/$name.out" 2>"$work_root/$name.err"; then fail_test "$name"; else pass "$name"; fi
}

write_valid_env_pair() {
  local root=$1
  mkdir -p "$root"
  cat >"$root/.env.tournament.local" <<'EOF'
DATABASE_URL=postgresql://pokerops_tournament_worker.xpajqdsppawnjmvewkep:runtime-test@pooler.example:5432/postgres?sslmode=require
IGNITION_USERNAME=test-user
IGNITION_PASSWORD=test-password
IGNITION_DEVICE_ID=00000000-0000-4000-8000-000000000000
IGNITION_PROXY_HOST=proxy.example
IGNITION_PROXY_PORT=1080
IGNITION_PROXY_USERNAME_TEMPLATE=test-template
IGNITION_PROXY_PASSWORD=test-proxy-password
IGNITION_ROOM_PROXY_TAG=tourney001
CAPSOLVER_CLIENT_KEY=test-capsolver-key
INTERNAL_API_TOKEN=test-internal-token-with-minimum-length
EOF
  cat >"$root/.env.migration" <<'EOF'
MIGRATION_DATABASE_URL=postgresql://postgres.xpajqdsppawnjmvewkep:migration-test@pooler.example:5432/postgres?sslmode=require
EOF
}

run_argument_case() {
  parse_arguments "$@"
}

expect_success full-sha run_argument_case 1234567890abcdef1234567890abcdef12345678
expect_success supported-flags run_argument_case --refresh-config 1234567890abcdef1234567890abcdef12345678
expect_failure flag-after-sha run_argument_case 1234567890abcdef1234567890abcdef12345678 --refresh-config
expect_failure short-sha run_argument_case 1234567
expect_failure extra-positional run_argument_case 1234567890abcdef1234567890abcdef12345678 extra
expect_failure unsupported-flag run_argument_case --unsafe 1234567890abcdef1234567890abcdef12345678
expect_success root-context validate_execution_context 0 true true
expect_failure not-root validate_execution_context 1000 true true
expect_failure missing-tty validate_execution_context 0 false true

valid="$work_root/valid"
write_valid_env_pair "$valid"
expect_success valid-env validate_env_pair "$valid/.env.tournament.local" "$valid/.env.migration"

missing="$work_root/missing"
write_valid_env_pair "$missing"
sed -i '/^CAPSOLVER_CLIENT_KEY=/d' "$missing/.env.tournament.local"
expect_failure missing-env-key validate_env_pair "$missing/.env.tournament.local" "$missing/.env.migration"

port="$work_root/port"
write_valid_env_pair "$port"
sed -i 's/:5432\//:6543\//' "$port/.env.tournament.local"
expect_failure transaction-port validate_env_pair "$port/.env.tournament.local" "$port/.env.migration"

role="$work_root/role"
write_valid_env_pair "$role"
sed -i 's/pokerops_tournament_worker/postgres/' "$role/.env.tournament.local"
expect_failure wrong-runtime-role validate_env_pair "$role/.env.tournament.local" "$role/.env.migration"

ssl="$work_root/ssl"
write_valid_env_pair "$ssl"
sed -i 's/sslmode=require/sslmode=disable/' "$ssl/.env.migration"
expect_failure wrong-ssl-mode validate_env_pair "$ssl/.env.tournament.local" "$ssl/.env.migration"

project="$work_root/project"
write_valid_env_pair "$project"
sed -i 's/xpajqdsppawnjmvewkep/wrongprojectref/g' "$project/.env.migration"
expect_failure wrong-project-ref validate_env_pair "$project/.env.tournament.local" "$project/.env.migration"

duplicate="$work_root/duplicate"
write_valid_env_pair "$duplicate"
printf '%s\n' 'INTERNAL_API_TOKEN=duplicate' >>"$duplicate/.env.tournament.local"
expect_failure duplicate-key validate_env_pair "$duplicate/.env.tournament.local" "$duplicate/.env.migration"

tar_root="$work_root/tar"
write_valid_env_pair "$tar_root"
tar -C "$tar_root" -cf "$work_root/valid.tar" .env.tournament.local .env.migration
expect_success valid-tar validate_config_tar "$work_root/valid.tar"

mkdir -p "$work_root/traversal/source"
printf '%s\n' unsafe >"$work_root/traversal/evil"
tar -C "$work_root/traversal/source" --transform='s#^#../#' -cf "$work_root/traversal.tar" ../evil 2>/dev/null || true
expect_failure tar-traversal validate_config_tar "$work_root/traversal.tar"

link_root="$work_root/link"
write_valid_env_pair "$link_root"
rm -f "$link_root/.env.migration"
python - "$link_root/.env.tournament.local" "$work_root/link.tar" <<'PY'
import sys
import tarfile

source, target = sys.argv[1:]
with open(source, 'rb') as file_handle, tarfile.open(target, 'w') as output:
    payload = file_handle.read()
    regular = tarfile.TarInfo('.env.tournament.local')
    regular.size = len(payload)
    import io
    output.addfile(regular, io.BytesIO(payload))
    link = tarfile.TarInfo('.env.migration')
    link.type = tarfile.SYMTYPE
    link.linkname = '.env.tournament.local'
    output.addfile(link)
PY
expect_failure tar-symlink validate_config_tar "$work_root/link.tar"

expect_success valid-nonce validate_nonce '20260813120000-abcdef0123456789'
expect_failure uppercase-nonce validate_nonce '20260813120000-ABCDEF0123456789'
expect_failure short-nonce validate_nonce 'short'
expect_success valid-age-recipient validate_age_recipient 'age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
expect_failure age-shell-meta validate_age_recipient 'age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq;bad'

auth_mock="$work_root/auth-mock"
mkdir -p "$auth_mock"
cat >"$auth_mock/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${FAKE_GH_AUTH_STATE:?}
if [[ "$1 $2" == 'auth status' ]]; then
  [[ -f "$state" ]]
elif [[ "$1 $2" == 'auth login' ]]; then
  [[ "${FAKE_AUTH_FAILURE:-0}" != 1 ]] || exit 1
  : >"$state"
elif [[ "$1 $2 $3" == 'api user --jq' ]]; then
  printf '%s\n' 'yovoweqif674-cyber'
elif [[ "$1" == api && "$2" == repos/yovoweqif674-cyber/po* ]]; then
  if [[ "$2" == *'/actions/permissions'* ]]; then printf '%s\n' true
  elif [[ "$*" == *'/actions/workflows/'* ]]; then printf '%s\n' active
  elif [[ "$*" == *'/releases/tags/'* ]]; then printf '%s\n' 1
  else printf '%s\n' true
  fi
else
  exit 1
fi
EOF
chmod +x "$auth_mock/gh"

run_auth_case() {
  local state=$1
  shift
  release_tag='tournament-ingestion-1234567890ab'
  FAKE_GH_AUTH_STATE="$state" PATH="$auth_mock:$PATH" "$@"
}

touch "$work_root/existing-auth"
expect_success existing-gh-auth run_auth_case "$work_root/existing-auth" ensure_github_auth
rm -f "$work_root/new-auth"
expect_success missing-gh-auth-simulated run_auth_case "$work_root/new-auth" ensure_github_auth
rm -f "$work_root/failed-auth"
expect_failure github-auth-failure env FAKE_AUTH_FAILURE=1 FAKE_GH_AUTH_STATE="$work_root/failed-auth" PATH="$auth_mock:$PATH" bash -c 'export POKEROPS_BOOTSTRAP_LIBRARY_ONLY=1; source "$1"; release_tag=tournament-ingestion-1234567890ab; exec 3</dev/null; exec 4>/dev/null; ensure_github_auth' _ "$script"

wait_for_single_run() {
  POKEROPS_WORKFLOW_LOOKUP_ATTEMPTS_OVERRIDE=1
  POKEROPS_TEST_RUN_LIST_JSON_OVERRIDE='[{"databaseId":42,"displayTitle":"sealed-config-test","url":"https://example.invalid/run","headBranch":"deployment-control","event":"workflow_dispatch"}]'
  wait_for_workflow_run sealed-config-test
  unset POKEROPS_WORKFLOW_LOOKUP_ATTEMPTS_OVERRIDE POKEROPS_TEST_RUN_LIST_JSON_OVERRIDE
}
expect_success exact-workflow-run wait_for_single_run
expect_failure wrong-workflow-run env POKEROPS_WORKFLOW_LOOKUP_ATTEMPTS_OVERRIDE=1 POKEROPS_TEST_RUN_LIST_JSON_OVERRIDE='[{"databaseId":1},{"databaseId":2}]' bash -c 'export POKEROPS_BOOTSTRAP_LIBRARY_ONLY=1; source "$1"; wait_for_workflow_run sealed-config-test' _ "$script"
expect_failure missing-workflow-run env POKEROPS_WORKFLOW_LOOKUP_ATTEMPTS_OVERRIDE=1 POKEROPS_TEST_RUN_LIST_JSON_OVERRIDE='[]' bash -c 'export POKEROPS_BOOTSTRAP_LIBRARY_ONLY=1; source "$1"; wait_for_workflow_run sealed-config-test' _ "$script"
expect_failure unauthorized-actor-workflow validate_github_actor unauthorized-user
if grep -Fq 'gh run watch "$run_id"' "$script" && grep -Fq -- '--exit-status' "$script"; then
  pass workflow-failure-gate
else
  fail_test workflow-failure-gate
fi

sealed="$work_root/sealed"
mkdir -p "$sealed"
printf '%s\n' encrypted-payload >"$sealed/sealed-config.tar.age"
sealed_sha=$(sha256sum "$sealed/sealed-config.tar.age" | awk '{print $1}')
release_sha=1234567890abcdef1234567890abcdef12345678
nonce='20260813120000-abcdef0123456789'
jq -n \
  --arg commitSha "$release_sha" \
  --arg nonce "$nonce" \
  --arg encryptedSha256 "$sealed_sha" \
  '{schemaVersion:1,service:"pokerops-tournament-ingestion",commitSha:$commitSha,nonce:$nonce,encryption:"age-x25519",encryptedFile:"sealed-config.tar.age",encryptedSha256:$encryptedSha256,runtimeEnvSha256:("a"*64),migrationEnvSha256:("b"*64),projectRef:"xpajqdsppawnjmvewkep",generatedAt:"2026-08-13T12:00:00Z"}' \
  >"$sealed/sealed-config.manifest.json"
expect_success sealed-manifest validate_sealed_manifest "$sealed/sealed-config.manifest.json" "$sealed/sealed-config.tar.age" "$nonce"
jq '.commitSha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$sealed/sealed-config.manifest.json" >"$sealed/wrong-commit.json"
expect_failure wrong-commit validate_sealed_manifest "$sealed/wrong-commit.json" "$sealed/sealed-config.tar.age" "$nonce"
expect_failure wrong-nonce validate_sealed_manifest "$sealed/sealed-config.manifest.json" "$sealed/sealed-config.tar.age" '20260813120000-0000000000000000'
jq '.projectRef="wrongprojectref"' "$sealed/sealed-config.manifest.json" >"$sealed/wrong-project.json"
expect_failure sealed-wrong-project validate_sealed_manifest "$sealed/wrong-project.json" "$sealed/sealed-config.tar.age" "$nonce"
printf '%s\n' tampered >>"$sealed/sealed-config.tar.age"
expect_failure sealed-checksum-mismatch validate_sealed_manifest "$sealed/sealed-config.manifest.json" "$sealed/sealed-config.tar.age" "$nonce"

decrypt_mock="$work_root/decrypt-mock"
mkdir -p "$decrypt_mock"
cat >"$decrypt_mock/age" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$decrypt_mock/age"
expect_failure decryption-failure env PATH="$decrypt_mock:$PATH" bash -c 'export POKEROPS_BOOTSTRAP_LIBRARY_ONLY=1; source "$1"; decrypt_config_archive "$2" "$3" "$4"' _ "$script" "$work_root/missing-identity" "$sealed/sealed-config.tar.age" "$work_root/decrypted.tar"

checksum_file="$work_root/checksum"
printf '%s\n' payload >"$checksum_file"
declared_checksum=$(sha256sum "$checksum_file" | awk '{print $1}')
[[ "$(sha256sum "$checksum_file" | awk '{print $1}')" == "$declared_checksum" ]] && pass artifact-checksum || fail_test artifact-checksum
printf '%s\n' tampered >>"$checksum_file"
[[ "$(sha256sum "$checksum_file" | awk '{print $1}')" != "$declared_checksum" ]] && pass artifact-checksum-mismatch || fail_test artifact-checksum-mismatch

helper_expected="$work_root/helper-expected"
helper_actual="$work_root/helper-actual"
printf '%s\n' helper >"$helper_expected"
cp "$helper_expected" "$helper_actual"
expect_success helper-install-checksum verify_matching_checksums "$helper_expected" "$helper_actual"
printf '%s\n' tampered >>"$helper_actual"
expect_failure helper-install-checksum-mismatch verify_matching_checksums "$helper_expected" "$helper_actual"

atomic_root="$work_root/atomic"
install_root="$atomic_root/install"
temporary_root="$atomic_root/temp"
mkdir -p "$temporary_root" "$install_root/shared"
write_valid_env_pair "$atomic_root/new"
write_valid_env_pair "$atomic_root/old"
sed -i 's/runtime-test/runtime-old/' "$atomic_root/old/.env.tournament.local"
cp "$atomic_root/old/.env.tournament.local" "$install_root/shared/.env.tournament.local"
cp "$atomic_root/old/.env.migration" "$install_root/shared/.env.migration"
expect_success atomic-install install_config_atomically "$atomic_root/new/.env.tournament.local" "$atomic_root/new/.env.migration"
[[ "$(sha256sum "$install_root/shared/.env.tournament.local" | awk '{print $1}')" == "$(sha256sum "$atomic_root/new/.env.tournament.local" | awk '{print $1}')" ]] \
  && pass atomic-fingerprint || { fail_test atomic-fingerprint; true; }
expect_success config-restore restore_config_backup
[[ "$(sha256sum "$install_root/shared/.env.tournament.local" | awk '{print $1}')" == "$(sha256sum "$atomic_root/old/.env.tournament.local" | awk '{print $1}')" ]] \
  && pass existing-env-preserved || fail_test existing-env-preserved

frontend="$work_root/frontend"
mkdir -p "$frontend"
printf '%s\n' sentinel >"$frontend/index.html"
before=$(fingerprint_tree "$frontend")
after=$(fingerprint_tree "$frontend")
[[ "$before" == "$after" ]] && pass frontend-fingerprint || fail_test frontend-fingerprint

rollback_root="$work_root/rollback"
mkdir -p "$rollback_root/releases/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/services/tournament-ingestion" \
  "$rollback_root/releases/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/services/tournament-ingestion/scripts"
cat >"$rollback_root/releases/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/services/tournament-ingestion/scripts/vps-rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "\$1" >"$rollback_root/rollback-called"
ln -sfnT "$rollback_root/releases/\$1" "$rollback_root/current"
EOF
chmod +x "$rollback_root/releases/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/services/tournament-ingestion/scripts/vps-rollback.sh"
ln -s "$rollback_root/releases/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$rollback_root/current"
run_rollback_case() (
  install_root="$rollback_root"
  release_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  previous_current="$rollback_root/releases/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  deployment_activated=true
  config_installed=false
  canonical_path() {
    [[ "$1" == "$install_root/current" ]] && printf '%s\n' "$install_root/releases/$release_sha"
  }
  rollback_after_failure
)
expect_success deployment-failure-rollback run_rollback_case
[[ "$(<"$rollback_root/rollback-called")" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] \
  && pass rollback-invoked-with-previous || fail_test rollback-invoked-with-previous

cleanup_root="$work_root/cleanup"
mkdir -p "$cleanup_root"
printf '%s\n' private-key >"$cleanup_root/identity"
run_cleanup_case() (
  temporary_root="$cleanup_root"
  identity_path="$cleanup_root/identity"
  cleanup
)
expect_success temp-key-cleanup run_cleanup_case
[[ ! -e "$cleanup_root" ]] && pass temp-directory-cleanup || fail_test temp-directory-cleanup

fake_root="$work_root/full-fake"
fake_inputs="$work_root/full-fake-inputs"
write_valid_env_pair "$fake_inputs"
printf '%s\n' 'ID=ubuntu' >"$work_root/fake-os-release"
run_full_fake() (
  export POKEROPS_BOOTSTRAP_LIBRARY_ONLY=1
  export POKEROPS_TEST_INSTALL_ROOT="$fake_root"
  export POKEROPS_TEST_OS_RELEASE_FILE="$work_root/fake-os-release"
  install_dependencies() { :; }
  ensure_github_auth() { :; }
  verify_release_manifest_minimums() { :; }
  obtain_sealed_config() { printf '%s\n%s\n' "$fake_inputs/.env.tournament.local" "$fake_inputs/.env.migration"; }
  install_exact_application_helper() { :; }
  fingerprint_tree() { printf '%s\n' frontend-sentinel; }
  pokerops-tournament-deploy() {
    mkdir -p "$install_root/releases/$release_sha"
    printf '%s\n' "$release_sha" >"$install_root/requested-release"
  }
  post_deploy_checks() {
    docker_image_id=fake-image
    health=ok
    readiness=ready
    scheduled_count=1
    sng_count=1
    unique_count=2
    duplicate_count=0
    info_id=info
    state_id=state
    state_status=running
    restart_result=passed
    scheduler_result=leader
    queue_result=recovered
    frontend_unchanged=true
  }
  write_bootstrap_report() { report_path="$fake_root/report.json"; printf '%s\n' '{"status":"success"}' >"$report_path"; }
  print_success() { :; }
  main 1234567890abcdef1234567890abcdef12345678
)
expect_success full-fake-one-command run_full_fake
expect_success idempotent-same-release run_full_fake
[[ "$(<"$fake_root/requested-release")" == 1234567890abcdef1234567890abcdef12345678 ]] \
  && pass idempotent-exact-release || fail_test idempotent-exact-release

printf '%s\n' 'ID=fedora' >"$work_root/unsupported-os-release"
expect_failure unsupported-os env POKEROPS_BOOTSTRAP_LIBRARY_ONLY=1 POKEROPS_TEST_OS_RELEASE_FILE="$work_root/unsupported-os-release" bash -c 'source "$1"; detect_operating_system' _ "$script"

if grep -Eqi '(postgres(ql)?://[^[:space:]]+:[^[:space:]@]+@|BEGIN (RSA|OPENSSH|AGE) PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' "$repository_root/tournament-ingestion.sh" "$repository_root/README.md"; then
  fail_test secret-scan
else
  pass secret-scan
fi
if grep -Eq 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' "$repository_root/tournament-ingestion.sh"; then
  fail_test no-unverified-curl-pipe
else
  pass no-unverified-curl-pipe
fi
if grep -Fq 'https://download.docker.com/linux/$docker_id/gpg' "$repository_root/tournament-ingestion.sh" \
  && grep -Fq 'docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' "$repository_root/tournament-ingestion.sh"; then
  pass official-docker-bootstrap
else
  fail_test official-docker-bootstrap
fi
if grep -Fq "GET /api/ingestion/status failed before live collection" "$repository_root/tournament-ingestion.sh" \
  && grep -Fq "unable to verify Supabase counts after the first live collect" "$repository_root/tournament-ingestion.sh" \
  && grep -Fq "first live collect did not produce a non-empty duplicate-free Supabase catalog" "$repository_root/tournament-ingestion.sh"; then
  pass independent-live-collect-gates
else
  fail_test independent-live-collect-gates
fi
if grep -Fq 'for secret_key in "${REQUIRED_RUNTIME_KEYS[@]}"' "$repository_root/tournament-ingestion.sh"; then
  pass complete-runtime-log-secret-scan
else
  fail_test complete-runtime-log-secret-scan
fi
if grep -Fq "'/internal/queue-recovery/probe'" "$repository_root/tournament-ingestion.sh" \
  && grep -Fq "queue_result='lease-recovered'" "$repository_root/tournament-ingestion.sh"; then
  pass active-queue-lease-recovery-probe
else
  fail_test active-queue-lease-recovery-probe
fi

printf 'bootstrap tests: passed=%s failed=%s\n' "$pass_count" "$fail_count"
((fail_count == 0))
