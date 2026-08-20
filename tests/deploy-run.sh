#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/deploy.sh"

bash -n "$SCRIPT"
grep -Fq "HELPER_COMMIT='bcf9ff0436561c5f139df7086378cd65ec7e9b09'" "$SCRIPT"
grep -Fq "APPLICATION_COMMIT='f2b7d46b49da90c0e964ef9b0e65df1900a533e1'" "$SCRIPT"
grep -Fq "PHASE_A_HELPER_SHA256='d0931cac0526a2e687880e2f05ba238156f4e635bb979f06e89c4d9cae22627e'" "$SCRIPT"
grep -Fq '| sha256sum -c -' "$SCRIPT"
if grep -Fq 'runtime-only-deploy.sh' "$SCRIPT"; then exit 1; fi
if grep -Fq 'frontend-deploy.sh' "$SCRIPT"; then exit 1; fi
if grep -Fq 'tournament-ingestion.sh' "$SCRIPT"; then exit 1; fi

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
  */planner-phase-a-deploy.sh)
    cp "$POKEROPS_WRAPPER_TEST_ROOT/planner-phase-a-deploy.sh" "$output"
    if [[ "${POKEROPS_WRAPPER_TEST_CORRUPT:-}" == phase-a ]]; then
      printf '%s\n' corrupt >>"$output"
    fi
    ;;
  *) exit 1 ;;
esac
SH

cat >"$TEMP/bin/bash" <<'SH'
#!/usr/bin/bash
case "$1" in
  */planner-phase-a-deploy.sh)
    printf 'phase-a:%s\n' "$2" >>"$POKEROPS_WRAPPER_TEST_LOG"
    if [[ "${POKEROPS_WRAPPER_TEST_FAIL:-}" == phase-a ]]; then exit 41; fi
    ;;
  *) exit 1 ;;
esac
SH
chmod 0700 "$TEMP/bin/id" "$TEMP/bin/curl" "$TEMP/bin/bash"

PATH="$TEMP/bin:$PATH" /usr/bin/bash "$SCRIPT" >/dev/null
printf 'phase-a:%s\n' 'f2b7d46b49da90c0e964ef9b0e65df1900a533e1' >"$TEMP/expected.log"
cmp "$TEMP/expected.log" "$TEMP/calls.log"

: >"$TEMP/calls.log"
if POKEROPS_WRAPPER_TEST_CORRUPT=phase-a PATH="$TEMP/bin:$PATH" /usr/bin/bash "$SCRIPT" >/dev/null 2>&1; then
  printf '%s\n' 'checksum corruption was accepted' >&2
  exit 1
fi
[[ ! -s "$TEMP/calls.log" ]]

: >"$TEMP/calls.log"
if POKEROPS_WRAPPER_TEST_FAIL=phase-a PATH="$TEMP/bin:$PATH" /usr/bin/bash "$SCRIPT" >/dev/null 2>&1; then
  printf '%s\n' 'Phase A failure was accepted' >&2
  exit 1
fi
printf 'phase-a:%s\n' 'f2b7d46b49da90c0e964ef9b0e65df1900a533e1' >"$TEMP/expected.log"
cmp "$TEMP/expected.log" "$TEMP/calls.log"

printf '%s\n' 'Planner wrapper tests: PASS'


