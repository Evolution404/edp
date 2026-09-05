#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVE_ROOT="$ROOT/Apps/Drive"

cd "$DRIVE_ROOT"

OUTPUT="$(Tests/run-service-lifecycle.sh)"
printf '%s\n' "$OUTPUT"

for scenario in V01 V02 V03 V04 V05 V06 V07; do
  grep -Fq "SCENARIO=${scenario}_OK" <<<"$OUTPUT"
done
grep -Fq 'RESULT=DRIVE_VIRTUAL_USB_INTEGRATION_LAB_OK' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_VIRTUAL_USB_COMBINED_BINARY_OK' <<<"$OUTPUT"

printf '%s\n' 'RESULT=DRIVE_FULLY_SOFTWARE_VIRTUAL_USB_OK'
