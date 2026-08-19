#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/deploy.sh"

bash -n "$SCRIPT"
grep -Fq "HELPER_COMMIT='0869cf9d67e7b5cdd40c1e14be7479ca5d94d4e1'" "$SCRIPT"
grep -Fq "APPLICATION_COMMIT='5ac17f1bfd0f635c2eeab9438bc5ac048164247b'" "$SCRIPT"
grep -Fq "RUNTIME_HELPER_SHA256='3e728bf693ad01985f9523f2ad54ba8f30fe3d8e223699ffd64bb2953012d601'" "$SCRIPT"
grep -Fq "FRONTEND_HELPER_SHA256='fd3f9fbe73790eac48524537bf90e2932b275686d1ab1f13a0a8752532cef3b1'" "$SCRIPT"
grep -Fq '| sha256sum -c -' "$SCRIPT"
if grep -Fq 'MIGRATION_DATABASE_URL' "$SCRIPT"; then exit 1; fi
if grep -Fq '.env.migration' "$SCRIPT"; then exit 1; fi

# shellcheck disable=SC2016
runtime_line="$(grep -n 'bash "$runtime_helper"' "$SCRIPT" | cut -d: -f1)"
# shellcheck disable=SC2016
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
  */runtime-only-deploy.sh)
    cp "$POKEROPS_WRAPPER_TEST_ROOT/runtime-only-deploy.sh" "$output"
    if [[ "${POKEROPS_WRAPPER_TEST_CORRUPT:-}" == runtime ]]; then
      printf '%s\n' corrupt >>"$output"
    fi
    ;;
  */frontend-deploy.sh) cp "$POKEROPS_WRAPPER_TEST_ROOT/frontend-deploy.sh" "$output" ;;
  *) exit 1 ;;
esac
SH

cat >"$TEMP/bin/bash" <<'SH'
#!/usr/bin/bash
case "$1" in
  */runtime-only-deploy.sh)
    printf 'runtime:%s\n' "$2" >>"$POKEROPS_WRAPPER_TEST_LOG"
    if [[ "${POKEROPS_WRAPPER_TEST_FAIL:-}" == runtime ]]; then exit 41; fi
    ;;
  */frontend-deploy.sh)
    printf '%s\n' frontend >>"$POKEROPS_WRAPPER_TEST_LOG"
    if [[ "${POKEROPS_WRAPPER_TEST_FAIL:-}" == frontend ]]; then exit 42; fi
    ;;
  *) exit 1 ;;
esac
SH
chmod 0700 "$TEMP/bin/id" "$TEMP/bin/curl" "$TEMP/bin/bash"

PATH="$TEMP/bin:$PATH" /usr/bin/bash "$SCRIPT" >/dev/null
printf '%s\n%s\n' \
  'runtime:5ac17f1bfd0f635c2eeab9438bc5ac048164247b' \
  'frontend' >"$TEMP/expected.log"
cmp "$TEMP/expected.log" "$TEMP/calls.log"

: >"$TEMP/calls.log"
if POKEROPS_WRAPPER_TEST_CORRUPT=runtime PATH="$TEMP/bin:$PATH" /usr/bin/bash "$SCRIPT" >/dev/null 2>&1; then
  printf '%s\n' 'checksum corruption was accepted' >&2
  exit 1
fi
[[ ! -s "$TEMP/calls.log" ]]

: >"$TEMP/calls.log"
if POKEROPS_WRAPPER_TEST_FAIL=runtime PATH="$TEMP/bin:$PATH" /usr/bin/bash "$SCRIPT" >/dev/null 2>&1; then
  printf '%s\n' 'runtime failure was accepted' >&2
  exit 1
fi
printf 'runtime:%s\n' '5ac17f1bfd0f635c2eeab9438bc5ac048164247b' >"$TEMP/expected.log"
cmp "$TEMP/expected.log" "$TEMP/calls.log"

: >"$TEMP/calls.log"
if POKEROPS_WRAPPER_TEST_FAIL=frontend PATH="$TEMP/bin:$PATH" /usr/bin/bash "$SCRIPT" >/dev/null 2>&1; then
  printf '%s\n' 'frontend failure was accepted' >&2
  exit 1
fi
printf '%s\n%s\n' \
  'runtime:5ac17f1bfd0f635c2eeab9438bc5ac048164247b' \
  'frontend' >"$TEMP/expected.log"
cmp "$TEMP/expected.log" "$TEMP/calls.log"

grep -Fq 'restore_previous_release' "$ROOT/runtime-only-deploy.sh"
grep -Fq 'restore_frontend' "$ROOT/frontend-deploy.sh"
grep -Fq 'restore_nginx' "$ROOT/frontend-deploy.sh"

printf '%s\n' 'full-stack wrapper tests: PASS'
