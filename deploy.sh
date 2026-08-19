#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_REPOSITORY='yovoweqif674-cyber/pokerops-bootstrap'
readonly HELPER_COMMIT='0869cf9d67e7b5cdd40c1e14be7479ca5d94d4e1'
readonly APPLICATION_COMMIT='5ac17f1bfd0f635c2eeab9438bc5ac048164247b'
readonly RUNTIME_HELPER_SHA256='3e728bf693ad01985f9523f2ad54ba8f30fe3d8e223699ffd64bb2953012d601'
readonly FRONTEND_HELPER_SHA256='fd3f9fbe73790eac48524537bf90e2932b275686d1ab1f13a0a8752532cef3b1'

[[ $# -eq 0 ]] || { printf 'usage: deploy.sh\n' >&2; exit 2; }
[[ "$(id -u)" == '0' ]] || { printf 'run as root\n' >&2; exit 1; }
command -v curl >/dev/null || { printf 'curl is required\n' >&2; exit 1; }
command -v sha256sum >/dev/null || { printf 'sha256sum is required\n' >&2; exit 1; }

temporary_root="$(mktemp -d /tmp/pokerops-full-deploy.XXXXXX)"
trap 'rm -rf -- "$temporary_root"' EXIT INT TERM
runtime_helper="$temporary_root/runtime-only-deploy.sh"
frontend_helper="$temporary_root/frontend-deploy.sh"
base_url="https://raw.githubusercontent.com/$BOOTSTRAP_REPOSITORY/$HELPER_COMMIT"

curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
  "$base_url/runtime-only-deploy.sh" -o "$runtime_helper"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
  "$base_url/frontend-deploy.sh" -o "$frontend_helper"
printf '%s  %s\n%s  %s\n' \
  "$RUNTIME_HELPER_SHA256" "$runtime_helper" \
  "$FRONTEND_HELPER_SHA256" "$frontend_helper" \
  | sha256sum -c - >/dev/null
chmod 0700 "$runtime_helper" "$frontend_helper"

bash "$runtime_helper" "$APPLICATION_COMMIT"
bash "$frontend_helper"

printf '%s\n' 'FULL STACK DEPLOYMENT SUCCESS'
printf 'application_release=%s\n' "$APPLICATION_COMMIT"
printf '%s\n' 'frontend=https://forprofit.pro/preview/v4/manager/tournaments'
