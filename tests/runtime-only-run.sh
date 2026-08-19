#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/runtime-only-deploy.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

bash -n "$SCRIPT"

if shellcheck --version >/dev/null 2>&1; then
  shellcheck "$SCRIPT"
fi

! grep -q 'MIGRATION_DATABASE_URL' "$SCRIPT"
! grep -q '\.env\.migration' "$SCRIPT"
! grep -q 'migrate\.mjs' "$SCRIPT"
grep -q 'yovoweqif674-cyber/po' "$SCRIPT"
grep -q 'xpajqdsppawnjmvewkep' "$SCRIPT"
grep -q '/var/www/pokerops' "$SCRIPT"
grep -q 'canonicalDuplicates == 0' "$SCRIPT"
grep -q '/internal/catalog/collect' "$SCRIPT"
grep -q '/internal/queue-recovery/probe' "$SCRIPT"
grep -q 'docker compose restart worker' "$SCRIPT"
grep -q 'mv -Tf.*current' "$SCRIPT"

# Load only function definitions; the executable's final line is intentionally main "$@".
sed '$d' "$SCRIPT" >"$TEMP/library.sh"
# shellcheck disable=SC1090
source "$TEMP/library.sh"

write_env() {
  local path="$1"
  {
    printf 'DATABASE_URL=postgresql://%s.%s:%s@%s:%s/%s?sslmode=%s&application_name=%s\n' \
      pokerops_tournament_worker xpajqdsppawnjmvewkep encoded pooler.example 5432 postgres require pokerops
    printf '%s=%s\n' IGNITION_USERNAME user
    printf '%s=%s\n' IGNITION_PASSWORD password
    printf '%s=%s\n' IGNITION_DEVICE_ID device
    printf '%s=%s\n' IGNITION_PROXY_HOST proxy.example
    printf '%s=%s\n' IGNITION_PROXY_PORT 10000
    printf '%s=%s\n' IGNITION_PROXY_USERNAME_TEMPLATE template
    printf '%s=%s\n' IGNITION_PROXY_PASSWORD proxy-password
    printf '%s=%s\n' IGNITION_ROOM_PROXY_TAG tourney001
    printf '%s=%s\n' CAPSOLVER_CLIENT_KEY key
    printf '%s=%s\n' INTERNAL_API_TOKEN token
  } >"$path"
}

write_env "$TEMP/valid.env"
validate_runtime_env "$TEMP/valid.env"

cp "$TEMP/valid.env" "$TEMP/wrong-port.env"
sed -i 's/:5432\//:6543\//' "$TEMP/wrong-port.env"
if (validate_runtime_env "$TEMP/wrong-port.env") >/dev/null 2>&1; then
  echo "wrong port was accepted" >&2
  exit 1
fi

cp "$TEMP/valid.env" "$TEMP/wrong-role.env"
sed -i 's/pokerops_tournament_worker/postgres/' "$TEMP/wrong-role.env"
if (validate_runtime_env "$TEMP/wrong-role.env") >/dev/null 2>&1; then
  echo "wrong role was accepted" >&2
  exit 1
fi

cp "$TEMP/valid.env" "$TEMP/wrong-tag.env"
sed -i 's/tourney001/wrong/' "$TEMP/wrong-tag.env"
if (validate_runtime_env "$TEMP/wrong-tag.env") >/dev/null 2>&1; then
  echo "wrong proxy tag was accepted" >&2
  exit 1
fi

cp "$TEMP/valid.env" "$TEMP/missing-key.env"
sed -i '/^INTERNAL_API_TOKEN=/d' "$TEMP/missing-key.env"
if (validate_runtime_env "$TEMP/missing-key.env") >/dev/null 2>&1; then
  echo "missing key was accepted" >&2
  exit 1
fi

ln -s "$TEMP/valid.env" "$TEMP/symlink.env"
if [[ -L "$TEMP/symlink.env" ]]; then
  if (validate_runtime_env "$TEMP/symlink.env") >/dev/null 2>&1; then
    echo "symlink env was accepted" >&2
    exit 1
  fi
fi

echo "runtime-only helper tests: PASS"
