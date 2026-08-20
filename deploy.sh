#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_REPOSITORY='yovoweqif674-cyber/pokerops-bootstrap'
readonly HELPER_COMMIT='0117d6102efc5abbfed053881eb4bb5ab99eff34'
readonly APPLICATION_COMMIT='f2b7d46b49da90c0e964ef9b0e65df1900a533e1'
readonly PHASE_A_HELPER_SHA256='d0931cac0526a2e687880e2f05ba238156f4e635bb979f06e89c4d9cae22627e'

[[ $# -eq 0 ]] || { printf 'usage: deploy.sh\n' >&2; exit 2; }
[[ "$(id -u)" == '0' ]] || { printf 'run as root\n' >&2; exit 1; }
command -v curl >/dev/null || { printf 'curl is required\n' >&2; exit 1; }
command -v sha256sum >/dev/null || { printf 'sha256sum is required\n' >&2; exit 1; }

temporary_root="$(mktemp -d /tmp/pokerops-planner-wrapper.XXXXXX)"
trap 'rm -rf -- "$temporary_root"' EXIT INT TERM
phase_a_helper="$temporary_root/planner-phase-a-deploy.sh"
base_url="https://raw.githubusercontent.com/$BOOTSTRAP_REPOSITORY/$HELPER_COMMIT"

curl -fsSL --retry 3 --connect-timeout 15 --max-time 120   "$base_url/planner-phase-a-deploy.sh" -o "$phase_a_helper"
printf '%s  %s\n' "$PHASE_A_HELPER_SHA256" "$phase_a_helper" | sha256sum -c - >/dev/null
chmod 0700 "$phase_a_helper"

bash "$phase_a_helper" "$APPLICATION_COMMIT"

printf '%s\n'   'TOURNAMENT PLANNER WRAPPER SUCCESS'   "application_release=$APPLICATION_COMMIT"   'phase=planner-maintenance'   'scheduler_enabled=false'   'job_worker_enabled=false'   'frontend_deployed=false'   'cleanup_applied=false'   'canary_activated=false'

