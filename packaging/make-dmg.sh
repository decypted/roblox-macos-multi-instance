#!/bin/bash
# Packages a .app into a drag-to-Applications DMG.
# Usage: make-dmg.sh <path/to/App.app> "<Volume Name>" <out.dmg>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$1"; VOL="$2"; OUT="$3"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Private Python env with dmgbuild (created on first run).
if [ ! -x "$HERE/.venv/bin/dmgbuild" ]; then
  python3 -m venv "$HERE/.venv"
  "$HERE/.venv/bin/pip" install -q dmgbuild
fi

# Background at 1x and 2x, merged into one HiDPI TIFF.
swift "$HERE/make_background.swift" "$WORK/bg.png" 1 "$VOL"
swift "$HERE/make_background.swift" "$WORK/bg@2x.png" 2 "$VOL"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/bg.tiff" >/dev/null 2>&1

rm -f "$OUT"
"$HERE/.venv/bin/dmgbuild" -s "$HERE/dmg_settings.py" \
  -D app="$APP" -D background="$WORK/bg.tiff" \
  "$VOL" "$OUT"
