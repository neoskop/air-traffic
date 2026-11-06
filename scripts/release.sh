#!/usr/bin/env bash
# Release von Air Traffic (SPEC §17).
#
#   scripts/release.sh <version> [--notes "<Text>"] [--dry-run] [--no-sign]
#
# Ablauf: Versionen setzen (Build +1) → xcodegen → Release-Build → Developer-ID-Signatur
# (inkl. Safari-Erweiterung und Kommandozeilen-Tool) →
# Notarisierung + Staple → ZIP → Sparkle-Signatur
# (sign_update --account air-traffic, Schlüssel aus dem Schlüsselbund) → appcast.xml ergänzen →
# gh release create v<version>. Commit und Push macht das Skript nicht; es druckt die nächsten Befehle.
#
#   --notes "<Text>"  Release-Notes (Markdown, „- “ = Aufzählung). Sonst Abschnitt „## <version>“ aus CHANGELOG.md.
#   --dry-run         Nur bauen und signieren: project.yml und appcast.xml bleiben unverändert,
#                     kein GitHub-Release. Vorschau des Appcasts nach build/dist/appcast.dry-run.xml.
#   --no-sign         Nur mit --dry-run: ohne Developer-ID, Notarisierung und Sparkle-Signatur.
#
# Voraussetzungen: Developer-ID-Zertifikat im Schlüsselbund (DEVELOPER_ID), notarytool-Profil
# „air-traffic“ (NOTARY_PROFILE), Sparkle-Schlüssel im Schlüsselbund (Account air-traffic).
set -euo pipefail

SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
SIGNING_ACCOUNT="air-traffic"
REPO_SLUG="neoskop/air-traffic"
MIN_SYSTEM_VERSION="15.0"
# Developer ID Application: Neoskop GmbH (PVW9KTQ7MR) – SHA-1, weil der Name im Schlüsselbund doppelt vorkommt.
DEVELOPER_ID="${DEVELOPER_ID:-EF3BF4DE692DB8951ABA392B739551F17A7186D2}"
TEAM_ID="PVW9KTQ7MR"
# Zugangsdaten für notarytool (xcrun notarytool store-credentials air-traffic …).
NOTARY_PROFILE="${NOTARY_PROFILE:-air-traffic}"
APP_NAME="Air Traffic"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "Fehler: $*" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- Argumente ---------------------------------------------------------------
VERSION=""
NOTES=""
DRY_RUN=0
NO_SIGN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) [[ $# -ge 2 ]] || die "--notes braucht einen Text"; NOTES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-sign) NO_SIGN=1; shift ;;
    -h|--help) usage 0 ;;
    -*) die "Unbekannte Option $1" ;;
    *) [[ -z "$VERSION" ]] || die "Nur eine Version angeben"; VERSION="$1"; shift ;;
  esac
done
[[ -n "$VERSION" ]] || usage 64
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "Version „$VERSION“ hat nicht die Form 1.4 oder 1.4.2"
if [[ $NO_SIGN -eq 1 && $DRY_RUN -eq 0 ]]; then die "--no-sign nur zusammen mit --dry-run"; fi

# --- Voraussetzungen -----------------------------------------------------------
for tool in xcodegen xcodebuild ditto codesign plutil; do
  command -v "$tool" >/dev/null || die "$tool fehlt"
done
if [[ $DRY_RUN -eq 0 ]]; then
  command -v gh >/dev/null || die "gh (GitHub CLI) fehlt"
  gh auth status >/dev/null 2>&1 || die "gh ist nicht angemeldet (gh auth login)"
  if [[ -n "$(git status --porcelain)" ]]; then
    die "Arbeitsbaum nicht sauber – erst committen (das Release soll einem Commit entsprechen)"
  fi
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then die "Tag v$VERSION existiert schon"; fi
fi

APPCAST="$ROOT/appcast.xml"
if [[ -f "$APPCAST" ]] && grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST"; then
  die "appcast.xml enthält Version $VERSION schon"
fi

# --- Release-Notes ------------------------------------------------------------
if [[ -z "$NOTES" && -f CHANGELOG.md ]]; then
  NOTES="$(awk -v v="$VERSION" '
    $0 ~ "^## \\[?" v "\\]?([[:space:]]|$)" { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md | sed -e '/./,$!d')"
fi
if [[ -z "${NOTES//[[:space:]]/}" ]]; then
  [[ $DRY_RUN -eq 1 ]] || die "Keine Release-Notes: --notes angeben oder Abschnitt „## $VERSION“ in CHANGELOG.md anlegen"
  NOTES="- Air Traffic $VERSION"
fi

# --- Versionen ----------------------------------------------------------------
CURRENT_BUILD="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/p' project.yml | head -1)"
[[ -n "$CURRENT_BUILD" ]] || die "CURRENT_PROJECT_VERSION in project.yml nicht gefunden"
HIGHEST_BUILD="$CURRENT_BUILD"
if [[ -f "$APPCAST" ]]; then
  while read -r b; do
    if [[ -n "$b" && "$b" -gt "$HIGHEST_BUILD" ]]; then HIGHEST_BUILD="$b"; fi
  done < <(sed -nE 's/.*<sparkle:version>([0-9]+)<\/sparkle:version>.*/\1/p' "$APPCAST")
fi
BUILD=$((HIGHEST_BUILD + 1))

step "Version $VERSION (Build $BUILD)$([[ $DRY_RUN -eq 1 ]] && echo ' – Probelauf')"
if [[ $DRY_RUN -eq 0 ]]; then
  sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*).*/\1\"$VERSION\"/" project.yml
  sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*).*/\1\"$BUILD\"/" project.yml
  echo "project.yml aktualisiert"
fi

# --- Bauen --------------------------------------------------------------------
step "xcodegen generate"
xcodegen generate --quiet

DERIVED="$ROOT/build/release"
DIST="$ROOT/build/dist"
LOG="$ROOT/build/release-build.log"
mkdir -p "$DIST"
step "Release-Build (Log: build/release-build.log)"
if ! xcodebuild -project AirTraffic.xcodeproj -scheme AirTraffic -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  clean build >"$LOG" 2>&1; then
  tail -30 "$LOG" >&2
  die "Release-Build fehlgeschlagen"
fi
grep -E "warning: " "$LOG" | grep -v appintentsmetadataprocessor | sort -u | sed 's/^/  /' || true

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || die "App nicht gefunden: $APP"
PLIST="$APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw "$PLIST")" == "$VERSION" ]] || die "CFBundleShortVersionString passt nicht"
[[ "$(plutil -extract CFBundleVersion raw "$PLIST")" == "$BUILD" ]] || die "CFBundleVersion passt nicht"
plutil -extract SUPublicEDKey raw "$PLIST" >/dev/null || die "SUPublicEDKey fehlt in Info.plist"
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || die "Sparkle.framework ist nicht eingebettet"
# Safari-Erweiterung (SPEC §20): eingebettet, gleiche Version wie die App, mit Sandbox.
APPEX="$APP/Contents/PlugIns/SafariExtension.appex"
APPEX_ENTITLEMENTS="$ROOT/SafariExtension/SafariExtension.entitlements"
[[ -d "$APPEX" ]] || die "SafariExtension.appex ist nicht eingebettet"
[[ -f "$APPEX_ENTITLEMENTS" ]] || die "Entitlements der Erweiterung fehlen: $APPEX_ENTITLEMENTS"
[[ "$(plutil -extract CFBundleIdentifier raw "$APPEX/Contents/Info.plist")" == "de.neoskop.AirTraffic.SafariExtension" ]] \
  || die "Bundle-ID der Safari-Erweiterung passt nicht"
[[ "$(plutil -extract CFBundleShortVersionString raw "$APPEX/Contents/Info.plist")" == "$VERSION" ]] \
  || die "Version der Safari-Erweiterung passt nicht"
# Prüft, dass die appex signiert ist und die Sandbox trägt (Pflicht für Safari-Erweiterungen).
check_appex() {
  codesign --verify --strict "$APPEX" || die "Signatur der Safari-Erweiterung ungültig"
  local entitlements
  entitlements="$(codesign -d --entitlements - "$APPEX" 2>&1)" || die "Entitlements der Safari-Erweiterung nicht lesbar"
  grep -q "com.apple.security.app-sandbox" <<<"$entitlements" || die "Safari-Erweiterung ohne App-Sandbox signiert"
}
# Kommandozeilen-Tool + MCP-Server (SPEC §24): eingebettet, ausführbar, gleiche Version wie die App.
HELPER="$APP/Contents/Helpers/airtraffic"
[[ -x "$HELPER" ]] || die "Kommandozeilen-Tool fehlt: Contents/Helpers/airtraffic"
HELPER_VERSION="$(AIRTRAFFIC_CONFIG_PATH=/dev/null "$HELPER" --version 2>&1)" || die "Kommandozeilen-Tool startet nicht: $HELPER_VERSION"
[[ "$HELPER_VERSION" == "airtraffic $VERSION ($BUILD)" ]] \
  || die "Version des Kommandozeilen-Tools passt nicht: $HELPER_VERSION"
check_helper() {
  codesign --verify --strict "$HELPER" || die "Signatur des Kommandozeilen-Tools ungültig"
}
codesign --verify --deep --strict "$APP" || die "Code-Signatur ungültig"
check_appex
check_helper
echo "OK: $APP_NAME.app $VERSION ($BUILD), Sparkle, Safari-Erweiterung und Kommandozeilen-Tool eingebettet"

# --- Developer ID + Notarisierung ---------------------------------------------
# Signiert von innen nach außen (Sparkle-Helfer → Framework → Safari-Erweiterung → Kommandozeilen-Tool → App),
# Hardened Runtime + Zeitstempel,
# dann Notarisierung bei Apple und Ticket an die App heften. Mit --no-sign entfällt alles (nur Probelauf).
if [[ $NO_SIGN -eq 0 ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning)"
  grep -q "$DEVELOPER_ID" <<<"$IDENTITIES" \
    || die "Developer-ID-Zertifikat $DEVELOPER_ID nicht im Schlüsselbund"
  step "Developer-ID-Signatur ($DEVELOPER_ID)"
  sign() { codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"; }
  SPARKLE_B="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for helper in "$SPARKLE_B"/XPCServices/*.xpc "$SPARKLE_B/Autoupdate" "$SPARKLE_B/Updater.app"; do
    [[ -e "$helper" ]] || continue
    if [[ "$helper" == *Downloader.xpc ]]; then sign --preserve-metadata=entitlements "$helper"; else sign "$helper"; fi
  done
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  # Safari-Erweiterung vor der App, mit eigenen Entitlements (nur App-Sandbox).
  sign --entitlements "$APPEX_ENTITLEMENTS" "$APPEX"
  # Kommandozeilen-Tool (SPEC §24.1) vor der App; Kennung aus der eingebetteten Info.plist.
  sign "$HELPER"
  sign "$APP"
  codesign --verify --deep --strict "$APP" || die "Developer-ID-Signatur ungültig"
  check_appex
  check_helper
  # Notarisierung lehnt get-task-allow ab; die Debug-Entitlements aus dem Build dürfen nicht überleben.
  APPEX_SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - "$APPEX" 2>&1)"
  if grep -q "get-task-allow" <<<"$APPEX_SIGNED_ENTITLEMENTS"; then
    die "Safari-Erweiterung trägt noch get-task-allow"
  fi
  # Ausgabe erst einsammeln: `cmd | grep -q` kann mit pipefail per SIGPIPE scheitern.
  APP_SIGN_INFO="$(codesign -dv "$APP" 2>&1)"
  grep -q "TeamIdentifier=$TEAM_ID" <<<"$APP_SIGN_INFO" || die "TeamIdentifier ist nicht $TEAM_ID"
  APPEX_SIGN_INFO="$(codesign -dv "$APPEX" 2>&1)"
  grep -q "TeamIdentifier=$TEAM_ID" <<<"$APPEX_SIGN_INFO" || die "TeamIdentifier der Safari-Erweiterung ist nicht $TEAM_ID"
  HELPER_SIGN_INFO="$(codesign -dv "$HELPER" 2>&1)"
  grep -q "TeamIdentifier=$TEAM_ID" <<<"$HELPER_SIGN_INFO" || die "TeamIdentifier des Kommandozeilen-Tools ist nicht $TEAM_ID"
  grep -q "flags=.*runtime" <<<"$HELPER_SIGN_INFO" || die "Kommandozeilen-Tool ohne Hardened Runtime signiert"
  HELPER_SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - "$HELPER" 2>&1)"
  if grep -q "get-task-allow" <<<"$HELPER_SIGNED_ENTITLEMENTS"; then
    die "Kommandozeilen-Tool trägt noch get-task-allow"
  fi

  step "Notarisierung (Profil „$NOTARY_PROFILE“, dauert meist 1–5 min)"
  NOTARIZE_ZIP="$DIST/notarize-$VERSION.zip"
  rm -f "$NOTARIZE_ZIP"
  ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
  NOTARY_OUT="$(xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" \
    || die "notarytool fehlgeschlagen"
  rm -f "$NOTARIZE_ZIP"
  NOTARY_STATUS="$(plutil -extract status raw - <<<"$NOTARY_OUT" 2>/dev/null || echo "?")"
  NOTARY_ID="$(plutil -extract id raw - <<<"$NOTARY_OUT" 2>/dev/null || echo "?")"
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "Notarisierung: $NOTARY_STATUS (ID $NOTARY_ID)"
  fi
  echo "Notarisiert (ID $NOTARY_ID)"
  xcrun stapler staple "$APP" >/dev/null || die "stapler fehlgeschlagen"
  SPCTL_OUT="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
  grep -q "Notarized Developer ID" <<<"$SPCTL_OUT" \
    || die "Gatekeeper akzeptiert die App nicht als notarisiert"
  echo "OK: Gatekeeper akzeptiert die App (Notarized Developer ID)"
fi

# --- ZIP ----------------------------------------------------------------------
ZIP_NAME="Air-Traffic-$VERSION.zip"
ZIP="$DIST/$ZIP_NAME"
step "ZIP: build/dist/$ZIP_NAME"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
LENGTH="$(stat -f%z "$ZIP")"
echo "$LENGTH Bytes"

# --- Signieren ----------------------------------------------------------------
SIGNATURE=""
if [[ $NO_SIGN -eq 1 ]]; then
  step "Signatur übersprungen (--no-sign)"
  SIGNATURE="UNSIGNED-DRY-RUN"
else
  TOOLS="$ROOT/build/sparkle-tools"
  SIGN_UPDATE="$TOOLS/bin/sign_update"
  if [[ ! -x "$SIGN_UPDATE" ]]; then
    step "Sparkle-Werkzeuge $SPARKLE_VERSION laden"
    mkdir -p "$TOOLS"
    ARCHIVE="$TOOLS/Sparkle-$SPARKLE_VERSION.tar.xz"
    curl -fL --proto '=https' --retry 2 -o "$ARCHIVE" "$SPARKLE_URL"
    echo "$SPARKLE_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null || { rm -f "$ARCHIVE"; die "Prüfsumme der Sparkle-Werkzeuge falsch"; }
    tar -xJf "$ARCHIVE" -C "$TOOLS" ./bin
    [[ -x "$SIGN_UPDATE" ]] || die "sign_update nach dem Entpacken nicht gefunden"
  fi
  step "Sparkle-Signatur (Schlüsselbund, Account $SIGNING_ACCOUNT)"
  SIGN_OUTPUT="$("$SIGN_UPDATE" --account "$SIGNING_ACCOUNT" "$ZIP")" || die "sign_update fehlgeschlagen"
  SIGNATURE="$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<<"$SIGN_OUTPUT")"
  SIGNED_LENGTH="$(sed -nE 's/.*length="([0-9]+)".*/\1/p' <<<"$SIGN_OUTPUT")"
  [[ -n "$SIGNATURE" ]] || die "Keine Signatur in der Ausgabe von sign_update"
  [[ "$SIGNED_LENGTH" == "$LENGTH" ]] || die "Länge laut sign_update ($SIGNED_LENGTH) ≠ ZIP ($LENGTH)"
  echo "Signatur erstellt"
fi

# --- Appcast ------------------------------------------------------------------
DOWNLOAD_URL="https://github.com/$REPO_SLUG/releases/download/v$VERSION/$ZIP_NAME"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
NOTES_MD="$DIST/release-notes-$VERSION.md"
printf '%s\n' "$NOTES" >"$NOTES_MD"

# Markdown (Absätze, „- “-Listen) → einfaches HTML für Sparkle.
NOTES_HTML="$(awk '
  function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
  /^[[:space:]]*[-*][[:space:]]+/ {
    if (!inlist) { print "<ul>"; inlist = 1 }
    sub(/^[[:space:]]*[-*][[:space:]]+/, ""); print "<li>" esc($0) "</li>"; next
  }
  { if (inlist) { print "</ul>"; inlist = 0 } }
  /^[[:space:]]*$/ { next }
  /^#+[[:space:]]/ { sub(/^#+[[:space:]]+/, ""); print "<h3>" esc($0) "</h3>"; next }
  { print "<p>" esc($0) "</p>" }
  END { if (inlist) print "</ul>" }
' "$NOTES_MD")"

ITEM="$DIST/appcast-item-$VERSION.xml"
cat >"$ITEM" <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <description><![CDATA[
$NOTES_HTML
      ]]></description>
      <enclosure url="$DOWNLOAD_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
EOF

SKELETON='<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Air Traffic</title>
    <link>https://raw.githubusercontent.com/'"$REPO_SLUG"'/main/appcast.xml</link>
    <description>Updates für Air Traffic</description>
    <language>de</language>
  </channel>
</rss>'

if [[ $DRY_RUN -eq 1 ]]; then
  TARGET="$DIST/appcast.dry-run.xml"
  if [[ -f "$APPCAST" ]]; then cp "$APPCAST" "$TARGET"; else printf '%s\n' "$SKELETON" >"$TARGET"; fi
else
  TARGET="$APPCAST"
  [[ -f "$TARGET" ]] || printf '%s\n' "$SKELETON" >"$TARGET"
fi
# Neuester Eintrag oben: vor dem ersten <item>, sonst vor </channel>.
awk -v itemfile="$ITEM" '
  !done && (/<item>/ || /<\/channel>/) { while ((getline line < itemfile) > 0) print line; done = 1 }
  { print }
' "$TARGET" >"$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
if command -v xmllint >/dev/null; then xmllint --noout "$TARGET" || die "Appcast ist kein gültiges XML"; fi
step "Appcast: ${TARGET#"$ROOT/"}"

# --- GitHub-Release -----------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  step "Probelauf fertig – nichts veröffentlicht, project.yml und appcast.xml unverändert"
  echo "  ZIP:      build/dist/$ZIP_NAME"
  echo "  Appcast:  build/dist/appcast.dry-run.xml"
  exit 0
fi

step "GitHub-Release v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO_SLUG" --title "$APP_NAME $VERSION" --notes-file "$NOTES_MD"

cat <<EOF

Fertig. Das ZIP liegt im Release v$VERSION. Damit Sparkle es findet, jetzt den Appcast veröffentlichen:

  git add project.yml appcast.xml
  git commit -m "Release $VERSION"
  git push

EOF
