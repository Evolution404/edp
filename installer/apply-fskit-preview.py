#!/usr/bin/env python3
"""Apply the preview-only FSKit mountpoint change.

The bridge transport itself now uses macFUSE's official libfuse API directly.
This patch only moves the transient hidden bridge below /Volumes, which FSKit
requires, while keeping logs/session metadata in /var/db.
"""
from pathlib import Path

session = Path("crates/usbcore/src/session.rs")
text = session.read_text()
old = '    let bridge_mount = session_dir.join("bridge");'
new = '    let bridge_mount = PathBuf::from("/Volumes").join(format!(".edp-bridge-{session_id}"));'
if old in text:
    session.write_text(text.replace(old, new, 1))
elif new not in text:
    raise SystemExit("expected bridge mountpoint snippet not found")

print("Applied installer-preview /Volumes FSKit mountpoint patch")
