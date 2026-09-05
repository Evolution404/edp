#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVE_ROOT="$ROOT/Apps/Drive"

cd "$DRIVE_ROOT"

OUTPUT="$(Tests/run-service-lifecycle.sh)"
printf '%s\n' "$OUTPUT"

grep -Fq 'RESULT=DRIVE_DISCOVERY_SEAM_OK' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_VIRTUAL_PHYSICAL_USB_OK' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_CREDENTIAL_POLICY_SERVICE_OK' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_FULLY_SOFTWARE_VIRTUAL_USB_OK' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_SERVICE_LIFECYCLE_OK' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_VIRTUAL_USB_COMBINED_BINARY_OK' <<<"$OUTPUT"

printf '%s\n' 'RESULT=DRIVE_VIRTUAL_USB_OK'
