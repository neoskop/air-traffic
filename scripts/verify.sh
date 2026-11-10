#!/usr/bin/env bash
# Prüft den Stand: Core-Tests, danach Debug-Build von App, Safari-Erweiterung und Kommandozeilen-Tool.
#
#   scripts/verify.sh [--core]
#
#   --core   nur die Tests des Core-Pakets (ohne Xcode-Build)
#
# Der Build landet in build/verify. Xcode meldet die gebaute App bei LaunchServices an; das Skript
# meldet sie sofort wieder ab und löscht sie, damit macOS nie die Build-Kopie statt der installierten
# App für Links, airtraffic:// oder die Safari-Erweiterung nimmt. Die App wird nie gestartet.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "Fehler: $*" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }

CORE_ONLY=0
case "${1:-}" in
  "") ;;
  --core) CORE_ONLY=1 ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unbekannte Option $1" ;;
esac

step "Core-Tests"
swift test --package-path Packages/AirTrafficCore

if [[ $CORE_ONLY -eq 1 ]]; then
  step "Fertig – Core-Tests grün"
  exit 0
fi

for tool in xcodegen xcodebuild; do
  command -v "$tool" >/dev/null || die "$tool fehlt"
done

DERIVED="$ROOT/build/verify"
APP="$DERIVED/Build/Products/Debug/Air Traffic.app"
INSTALLED="/Applications/Air Traffic.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Läuft immer, auch nach einem fehlgeschlagenen Build: Build-Kopie abmelden und löschen,
# installierte App wieder als maßgebliche Kopie eintragen.
cleanup() {
  if [[ -d "$APP" ]]; then
    # -R: auch eingebettete Apps abmelden (Sparkles Updater.app), sonst bleibt ein Eintrag ohne Datei zurück.
    "$LSREG" -u -R "$APP" >/dev/null 2>&1 || true
    rm -rf "$APP"
  fi
  if [[ -d "$INSTALLED" ]]; then
    "$LSREG" -f "$INSTALLED" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "Debug-Build (build/verify)"
xcodegen generate --quiet
xcodebuild -project AirTraffic.xcodeproj -scheme AirTraffic -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" build -quiet

[[ -d "$APP" ]] || die "App nicht gebaut: $APP"
[[ -x "$APP/Contents/Helpers/airtraffic" ]] || die "Kommandozeilen-Tool fehlt im Bundle"
[[ -d "$APP/Contents/PlugIns/SafariExtension.appex" ]] || die "Safari-Erweiterung fehlt im Bundle"

step "Fertig – Tests grün, Build ohne Fehler"
