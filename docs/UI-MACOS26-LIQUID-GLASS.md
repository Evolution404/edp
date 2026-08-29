# macOS 26 Liquid Glass UI

## Scope

This branch applies one internal SwiftUI design language to EDP Drive and EDP Studio. It does not change raw-device, mounting, credential, XPC, persistence, or broker protocols.

The shared layer lives in `Shared/UI/EDPDesignSystem.swift` and provides semantic spacing, radii, motion, glass surfaces, content cards, status pills, section headers, notices, and empty states.

## Design rules

- Glass is reserved for navigation, toolbars, compact status, and focused controls.
- Dense content such as the sector hex viewer remains on an opaque semantic surface.
- Status color is a restrained accent, not a large saturated fill. In dark mode, status pills use a low-intensity tint and fine semantic outline.
- Finder access is a secondary glass action. Mounting remains the prominent action.
- Motion is scoped to the changing view or value. Reduce Motion replaces movement with a short fade; Reduce Transparency switches glass surfaces to semantic opaque backgrounds.
- All fills derive from system dynamic colors, so light, dark, increased-contrast, and accessibility appearances remain legible without fixed black or white backgrounds.

## Verification

- Drive: Swift 6 optimized compile with warnings as errors.
- Studio: unsigned arm64 Release `xcodebuild`, including broker, app icon, asset catalog, and shared UI source.
- Installer scripts: shell syntax validation and shared-source wiring checks.
- CI contracts: menu-bar window style, split-view structure, disk-map scroll width, and shared design source checks.
- Visual review: Drive fixture in dark appearance, including connected/mounted/read-only/credential states and the refined status/Finder hierarchy.
- Safety: visual review used fixture data and did not execute raw-sector writes, mount, unmount, eject, credential, or service actions.

Performance profiling with real interaction traces remains a release-machine acceptance activity; the implementation removes broad container animations and limits effects to local state transitions so that the final signed build can be measured without fixture or debugger overhead.
