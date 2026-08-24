#!/usr/bin/env python3
"""Apply the macFUSE FSKit bridge changes used by installer preview builds.

This lives on the installer test branch so the real-device path can be validated
before the same changes are folded into the production Rust sources.
"""
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"expected snippet not found in {path}: {old!r}")
    path.write_text(text.replace(old, new, 1))


bridge = Path("crates/usbcore/src/bridge.rs")
session = Path("crates/usbcore/src/session.rs")

# macFUSE defaults to the VFS/kernel-extension backend. For the unsigned,
# one-click distribution use the FSKit backend instead. FSKit is user-space and
# does not require enabling third-party kernel extensions in Recovery Mode.
replace_once(
    bridge,
    '''fn mount_options() -> Vec<MountOption> {
    vec![
        MountOption::FSName("edp-usb".into()),
        MountOption::CUSTOM("volname=EDP Raw Bridge".into()),
        MountOption::CUSTOM("local".into()),
        MountOption::CUSTOM("noappledouble".into()),
        MountOption::CUSTOM("nobrowse".into()),
        MountOption::CUSTOM("async".into()),
        MountOption::CUSTOM(format!("iosize={REQUEST_BYTES}")),
        MountOption::DefaultPermissions,
    ]
}''',
    '''fn mount_options() -> Vec<MountOption> {
    vec![
        // macFUSE 5.x: select the user-space FSKit backend explicitly. The
        // default is the VFS/kernel-extension backend, which returns EPERM on
        // clean Apple Silicon systems where the kext has never been approved.
        MountOption::CUSTOM("backend=fskit".into()),
        MountOption::CUSTOM("volname=.EDP Raw Bridge".into()),
        MountOption::CUSTOM("local".into()),
        MountOption::CUSTOM("nobrowse".into()),
        MountOption::DefaultPermissions,
    ]
}''',
)

# FSKit only supports mount points below /Volumes. Keep logs/session metadata in
# /var/db, but put the transient raw bridge itself in a hidden /Volumes path.
replace_once(
    session,
    '    let bridge_mount = session_dir.join("bridge");',
    '    let bridge_mount = PathBuf::from("/Volumes").join(format!(".edp-bridge-{session_id}"));',
)

# Clean up the transient /Volumes directory when the bridge loop exits normally.
replace_once(
    bridge,
    '''    let result = session.run();
    stop.store(true, Ordering::Relaxed);''',
    '''    let result = session.run();
    let _ = std::fs::remove_dir(mountpoint);
    stop.store(true, Ordering::Relaxed);''',
)

print("Applied installer-preview FSKit bridge patch")
