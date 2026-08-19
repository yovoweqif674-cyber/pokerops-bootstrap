#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/deploy.sh"

bash -n "$SCRIPT"
grep -Fq "HELPER_COMMIT='8cc596453e649fccbe0f528d934376b3467fd583'" "$SCRIPT"
grep -Fq "APPLICATION_COMMIT='663a4b0b2b6d5e61bd4839a528915eea344853e2'" "$SCRIPT"
grep -Fq "RUNTIME_HELPER_SHA256='0c0d78db374c4c40fe3ff40fa5d4452145159113ced19c9a5c114ac4c38cd03b'" "$SCRIPT"
grep -Fq "FRONTEND_HELPER_SHA256='b345a2418b195459b74e8571691cc2bf8db5a2ca1b1771006a087a07f0a6cc4e'" "$SCRIPT"
grep -Fq '| sha256sum -c -' "$SCRIPT"
! grep -Fq 'MIGRATION_DATABASE_URL' "$SCRIPT"
! grep -Fq '.env.migration' "$SCRIPT"

runtime_line="$(grep -n 'bash "$runtime_helper"' "$SCRIPT" | cut -d: -f1)"
frontend_line="$(grep -n 'bash "$frontend_helper"' "$SCRIPT" | cut -d: -f1)"
[[ "$runtime_line" -lt "$frontend_line" ]]

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir "$TEMP/bin"
export POKEROPS_WRAPPER_TEST_ROOT="$ROOT"
export POKEROPS_WRAPPER_TEST_LOG="$TEMP/calls.log"

cat >"$TEMP/bin/id" <<'SH'
#!/usr/bin/bash
printf '%s\n' 0
SH

cat >"$TEMP/bin/curl" <<'SH'
#!/usr/bin/bash
output=''
url=''
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */runtime-only-deploy.sh) cp "$POKEROPS_WRAPPER_TEST_ROOT/runtime-only-deploy.sh" "$output" ;;
  */frontend-deploy.sh) cp "$POKEROPS_WRAPPER_TEST_ROOT/frontend-deploy.sh" "$output" ;;
  *) exit 1 ;;
esac
SH

cat >"$TEMP/bin/bash" <<'SH'
#!/usr/bin/bash
case "$1" in
  */runtime-only-deploy.sh) printf 'runtime:%s\n' "$2" >>"$POKEROPS_WRAPPER_TEST_LOG" ;;
  */frontend-deploy.sh) printf '%s\n' frontend >>"$POKEROPS_WRAPPER_TEST_LOG" ;;
  *) exit 1 ;;
esac
SH
chmod 0700 "$TEMP/bin/id" "$TEMP/bin/curl" "$TEMP/bin/bash"

PATH="$TEMP/bin:$PATH" /usr/bin/bash "$SCRIPT" >/dev/null
printf '%s\n%s\n' \
  'runtime:663a4b0b2b6d5e61bd4839a528915eea344853e2' \
  'frontend' >"$TEMP/expected.log"
cmp "$TEMP/expected.log" "$TEMP/calls.log"

printf '%s\n' 'full-stack wrapper tests: PASS'
