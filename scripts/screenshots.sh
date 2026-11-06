#!/usr/bin/env bash
# README-Screenshots aus der neutralen Demo-Config (SPEC §18).
#
#   scripts/screenshots.sh [--no-build]
#
# Baut die Debug-App (außer mit --no-build) und rendert mit `--snapshot` alle Ansichten hell und dunkel
# nach docs/images/. Nutzt ausschließlich docs/demo-config.json – nie die eigene Konfiguration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="$ROOT/docs/demo-config.json"
OUT="$ROOT/docs/images"
APP="$ROOT/build/Build/Products/Debug/Air Traffic.app/Contents/MacOS/Air Traffic"

[[ -f "$CONFIG" ]] || { echo "Fehler: $CONFIG fehlt" >&2; exit 1; }

if [[ "${1:-}" != "--no-build" ]]; then
  echo "▸ Debug-Build"
  xcodegen generate --quiet
  xcodebuild -project AirTraffic.xcodeproj -scheme AirTraffic -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build build -quiet
fi
[[ -x "$APP" ]] || { echo "Fehler: App nicht gebaut ($APP)" >&2; exit 1; }

echo "▸ Snapshots nach docs/images/"
mkdir -p "$OUT"
# Nur Snapshot-Bilder ersetzen; andere Bilder (z. B. trailer-poster.png) bleiben.
find "$OUT" -maxdepth 1 -name "*.png" ! -name "trailer-*" -delete
AIRTRAFFIC_CONFIG_PATH="$CONFIG" "$APP" --snapshot "$OUT"
