#!/bin/sh
set -eu

CARGO_BIN="${CARGO:-$HOME/.cargo/bin/cargo}"
MANIFEST="$SRCROOT/../../core/edpopen-ffi/Cargo.toml"

if [ ! -x "$CARGO_BIN" ]; then
  echo "error: cargo not found at $CARGO_BIN" >&2
  exit 1
fi

"$CARGO_BIN" build --release --manifest-path "$MANIFEST"
