#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_ROOT="${TMPDIR:-/tmp}/edp-drive-ui-regression-$$"
BIN="${BUILD_ROOT}/validate-drive-ui"
UI_LOG="${BUILD_ROOT}/ui.log"
HITCH_LOG="${BUILD_ROOT}/hitch.log"
TRACE="${BUILD_ROOT}/sidebar-hitches.trace"
TOC_XML="${BUILD_ROOT}/trace-toc.xml"
HITCH_XML="${BUILD_ROOT}/hitches.xml"
HITCH_EVENT_XML="${BUILD_ROOT}/hitch-events.xml"
UI_BOUNDED="${ROOT}/Apps/Drive/Tests/Storage/RunBounded.py"
UI_XCTRACE_RECORD_TIMEOUT_SECONDS=120
UI_XCTRACE_EXPORT_TIMEOUT_SECONDS=30
mkdir -p "${BUILD_ROOT}"
cleanup() {
  if [[ -n "${HITCH_PID:-}" ]] && kill -0 "${HITCH_PID}" 2>/dev/null; then
    kill -KILL "${HITCH_PID}" 2>/dev/null || true
  fi
  if [[ "${EDP_UI_KEEP_ARTIFACTS:-0}" == "1" ]]; then
    echo "UI_REGRESSION_ARTIFACTS=${BUILD_ROOT}" >&2
  else
    rm -rf "${BUILD_ROOT}"
  fi
}
trap cleanup EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -D EDP_UI_PREVIEW -D EDP_UI_AUTOMATION \
  -framework AppKit -framework FSKit -framework SwiftUI -framework ServiceManagement \
  "${ROOT}/Shared/UI/EDPDesignSystem.swift" \
  "${ROOT}/Apps/Drive/product/EDPXPCProtocol.swift" \
  "${ROOT}/Apps/Drive/Tests/UI/EDPPreviewScenarios.swift" \
  "${ROOT}/Apps/Drive/product/App/EDPUSBVaultApp.swift" \
  "${ROOT}/Apps/Drive/product/App/Service/EDPAppServiceSupport.swift" \
  "${ROOT}/Apps/Drive/product/App/Service/EDPXPCSmokeSupport.swift" \
  "${ROOT}/Apps/Drive/product/App/Model/EDPVaultViewModel.swift" \
  "${ROOT}/Apps/Drive/product/App/Sidebar/EDPSidebarView.swift" \
  "${ROOT}/Apps/Drive/product/App/Shell/EDPMainWindow.swift" \
  "${ROOT}/Apps/Drive/product/App/Pages/EDPOverviewView.swift" \
  "${ROOT}/Apps/Drive/product/App/Pages/EDPDevicesView.swift" \
  "${ROOT}/Apps/Drive/product/App/Pages/EDPActivityView.swift" \
  "${ROOT}/Apps/Drive/product/App/Pages/EDPSettingsView.swift" \
  "${ROOT}/Apps/Drive/product/App/MenuBar/EDPMenuBarView.swift" \
  "${ROOT}/Apps/Drive/Tests/UI/ValidateUIAutomation.swift" \
  -o "${BIN}"

"${BIN}" | tee "${UI_LOG}"
grep -Fq 'RESULT=DRIVE_UI_PREVIEW_SCENARIOS_OK' "${UI_LOG}"
grep -Fq 'RESULT=DRIVE_UI_PAGE_RENDERING_OK' "${UI_LOG}"
grep -Fq 'RESULT=DRIVE_UI_900X680_SIDEBAR_OK' "${UI_LOG}"
grep -Fq 'RESULT=DRIVE_UI_AUTOMATION_OK' "${UI_LOG}"
[[ "$(grep -Fc 'SCENARIO=UI_SIDEBAR_TOGGLE_' "${UI_LOG}")" -eq 20 ]]

APP_SOURCE="${ROOT}/Apps/Drive/product/App/EDPUSBVaultApp.swift"
SHELL_SOURCE="${ROOT}/Apps/Drive/product/App/Shell/EDPMainWindow.swift"
SIDEBAR_SOURCE="${ROOT}/Apps/Drive/product/App/Sidebar/EDPSidebarView.swift"
DEVICES_SOURCE="${ROOT}/Apps/Drive/product/App/Pages/EDPDevicesView.swift"
ACTIVITY_SOURCE="${ROOT}/Apps/Drive/product/App/Pages/EDPActivityView.swift"
MENU_BAR_SOURCE="${ROOT}/Apps/Drive/product/App/MenuBar/EDPMenuBarView.swift"
DESIGN_SOURCE="${ROOT}/Shared/UI/EDPDesignSystem.swift"
grep -Fq 'EDPNativeSplitViewController: NSSplitViewController' "${SHELL_SOURCE}"
grep -Fq 'sidebarItem.canCollapseFromWindowResize = false' "${SHELL_SOURCE}"
grep -Fq 'sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView' "${SHELL_SOURCE}"
grep -Fq 'sidebarHost.sizingOptions = []' "${SHELL_SOURCE}"
grep -Fq 'detailHost.sizingOptions = []' "${SHELL_SOURCE}"
grep -Fq '.focusEffectDisabled()' "${SHELL_SOURCE}"
! grep -Fq 'NavigationSplitView {' "${SHELL_SOURCE}"
grep -Fq '.menuBarExtraStyle(.window)' "${APP_SOURCE}"
grep -Fq '@Environment(\.accessibilityReduceMotion)' "${DEVICES_SOURCE}"
grep -Fq '@Environment(\.accessibilityReduceMotion)' "${MENU_BAR_SOURCE}"
grep -Fq '@Environment(\.accessibilityReduceTransparency)' "${DESIGN_SOURCE}"
grep -Fq '@Environment(\.colorSchemeContrast)' "${DESIGN_SOURCE}"
grep -Fq '.accessibilityLabel("切换设备")' "${DEVICES_SOURCE}"
grep -Fq '.accessibilityLabel("设备页面")' "${DEVICES_SOURCE}"
grep -Fq '.accessibilityLabel("活动筛选")' "${ACTIVITY_SOURCE}"
grep -Fq '.accessibilityLabel("显示或隐藏侧栏")' "${SHELL_SOURCE}"
! grep -Fq '»' "${APP_SOURCE}" "${SHELL_SOURCE}" "${SIDEBAR_SOURCE}" \
  "${DEVICES_SOURCE}" "${ACTIVITY_SOURCE}" "${MENU_BAR_SOURCE}"

echo 'RESULT=DRIVE_UI_ACCESSIBILITY_STRUCTURE_OK'

# Animation Hitches is a compositor-sensitive performance gate. Local desktop
# load is intentionally not used as release evidence; only GitHub Actions runs
# the 33 ms xctrace gate. Local invocations still validate deterministic preview,
# layout, and accessibility contracts above.
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
  echo 'RESULT=DRIVE_UI_PERF_CI_ONLY_SKIPPED_LOCALLY'
  echo 'RESULT=DRIVE_UI_OK'
  exit 0
fi

echo 'RESULT=DRIVE_UI_PERF_CI_ENVIRONMENT'
command -v xcrun >/dev/null
echo 'UI_XCTRACE_LIST_BEGIN'
python3 "${UI_BOUNDED}" --timeout "${UI_XCTRACE_EXPORT_TIMEOUT_SECONDS}" \
  xcrun xctrace list templates | grep -Fx 'Animation Hitches' >/dev/null
echo 'UI_XCTRACE_LIST_END'
echo 'UI_XCTRACE_RECORD_BEGIN'
python3 "${UI_BOUNDED}" --timeout "${UI_XCTRACE_RECORD_TIMEOUT_SECONDS}" \
  xcrun xctrace record --quiet \
    --template 'Animation Hitches' \
    --output "${TRACE}" \
    --time-limit 8s \
    --no-prompt \
    --target-stdout "${HITCH_LOG}" \
    --launch -- "${BIN}" --hitch-only
echo 'UI_XCTRACE_RECORD_END'

grep -Fq 'UI_HITCH_AUTOMATION_READY=1' "${HITCH_LOG}"
grep -Fq 'RESULT=DRIVE_UI_HITCH_AUTOMATION_OK' "${HITCH_LOG}"

echo 'UI_XCTRACE_TOC_EXPORT_BEGIN'
python3 "${UI_BOUNDED}" --timeout "${UI_XCTRACE_EXPORT_TIMEOUT_SECONDS}" \
  xcrun xctrace export --input "${TRACE}" --toc --output "${TOC_XML}"
echo 'UI_XCTRACE_TOC_EXPORT_END'
echo 'UI_HITCH_TRACE_TIMEBASE:'
/usr/bin/grep -E '<start-date>|UI_HITCH_TOGGLES_(BEGIN|END)_EPOCH=' "${TOC_XML}" "${HITCH_LOG}" || true
echo 'UI_HITCH_TRACE_SCHEMAS:'
/usr/bin/grep -oE 'schema="[^"]+"' "${TOC_XML}" | /usr/bin/sort -u || true
echo 'UI_XCTRACE_FRAME_EXPORT_BEGIN'
python3 "${UI_BOUNDED}" --timeout "${UI_XCTRACE_EXPORT_TIMEOUT_SECONDS}" \
  xcrun xctrace export --input "${TRACE}" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches-frame-lifetimes"]' \
    --output "${HITCH_XML}"
echo 'UI_XCTRACE_FRAME_EXPORT_END'
echo 'UI_XCTRACE_EVENT_EXPORT_BEGIN'
python3 "${UI_BOUNDED}" --timeout "${UI_XCTRACE_EXPORT_TIMEOUT_SECONDS}" \
  xcrun xctrace export --input "${TRACE}" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]' \
    --output "${HITCH_EVENT_XML}"
echo 'UI_XCTRACE_EVENT_EXPORT_END'
python3 "${ROOT}/Apps/Drive/Tests/UI/ParseAnimationHitches.py" \
  --toc "${TOC_XML}" \
  --hitches "${HITCH_XML}" \
  --events "${HITCH_EVENT_XML}" \
  --log "${HITCH_LOG}"

echo 'RESULT=DRIVE_UI_OK'
