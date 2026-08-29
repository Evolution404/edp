#!/bin/bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  build-macos-icon.sh icns <source.svg> <output.icns>
  build-macos-icon.sh appiconset <source.svg> <output.AppIcon.appiconset>
EOF
  exit 64
}

[[ $# -eq 3 ]] || usage
MODE="$1"
SOURCE="$2"
OUTPUT="$3"
[[ -f "$SOURCE" ]] || { echo "icon source not found: $SOURCE" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/edp-app-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BASE_PNG="$TMP/icon-1024.png"

/usr/bin/sips -s format png -z 1024 1024 "$SOURCE" --out "$BASE_PNG" >/dev/null
[[ -s "$BASE_PNG" ]] || { echo "failed to render SVG icon source" >&2; exit 2; }

render_png() {
  local size="$1"
  local path="$2"
  /usr/bin/sips -z "$size" "$size" "$BASE_PNG" --out "$path" >/dev/null
}

case "$MODE" in
  icns)
    ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    render_png 16   "$ICONSET/icon_16x16.png"
    render_png 32   "$ICONSET/icon_16x16@2x.png"
    render_png 32   "$ICONSET/icon_32x32.png"
    render_png 64   "$ICONSET/icon_32x32@2x.png"
    render_png 128  "$ICONSET/icon_128x128.png"
    render_png 256  "$ICONSET/icon_128x128@2x.png"
    render_png 256  "$ICONSET/icon_256x256.png"
    render_png 512  "$ICONSET/icon_256x256@2x.png"
    render_png 512  "$ICONSET/icon_512x512.png"
    cp "$BASE_PNG" "$ICONSET/icon_512x512@2x.png"
    mkdir -p "$(dirname "$OUTPUT")"
    /usr/bin/iconutil -c icns "$ICONSET" -o "$OUTPUT"
    ;;
  appiconset)
    mkdir -p "$OUTPUT"
    render_png 16   "$OUTPUT/icon_16x16.png"
    render_png 32   "$OUTPUT/icon_16x16@2x.png"
    render_png 32   "$OUTPUT/icon_32x32.png"
    render_png 64   "$OUTPUT/icon_32x32@2x.png"
    render_png 128  "$OUTPUT/icon_128x128.png"
    render_png 256  "$OUTPUT/icon_128x128@2x.png"
    render_png 256  "$OUTPUT/icon_256x256.png"
    render_png 512  "$OUTPUT/icon_256x256@2x.png"
    render_png 512  "$OUTPUT/icon_512x512.png"
    cp "$BASE_PNG" "$OUTPUT/icon_512x512@2x.png"
    ;;
  *)
    usage
    ;;
esac
