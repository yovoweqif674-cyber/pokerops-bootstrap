#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_REPOSITORY='yovoweqif674-cyber/pokerops-bootstrap'
readonly HELPER_COMMIT='8cc596453e649fccbe0f528d934376b3467fd583'
readonly APPLICATION_COMMIT='663a4b0b2b6d5e61bd4839a528915eea344853e2'
readonly RUNTIME_HELPER_SHA256='0c0d78db374c4c40fe3ff40fa5d4452145159113ced19c9a5c114ac4c38cd03b'
readonly FRONTEND_HELPER_SHA256='b345a2418b195459b74e8571691cc2bf8db5a2ca1b1771006a087a07f0a6cc4e'

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
