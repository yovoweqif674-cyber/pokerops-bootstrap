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

printf '%s\n' 'full-stack wrapper tests: PASS'
