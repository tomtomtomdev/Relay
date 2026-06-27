#!/usr/bin/env bash
#
# archive.sh — Relay's build → notarize pipeline (PLAN Slice 8, SPEC §6).
#
# Produces a signed, notarized, stapled artifact ready for distribution, by shelling out
# to the platform toolchain in order:
#
#   xcodebuild archive
#     -> xcodebuild -exportArchive   (Developer ID)
#     -> create-dmg                  (package the .app into a .dmg)
#     -> xcrun notarytool submit --wait
#     -> xcrun stapler staple
#
# Zero-dep guardrail: every external tool is *shelled out* here, never linked or vendored
# into the app. The notary credentials live in a `notarytool` keychain profile created out
# of band (`xcrun notarytool store-credentials <profile>`); this script only ever names the
# profile — it never receives, prints, or logs a password, app-specific password, or token.
#
# Usage:
#   scripts/archive.sh [--dry-run]
#                      [--scheme NAME] [--configuration NAME]
#                      [--notary-profile NAME] [--team-id ID] [--output-dir DIR]
#
# Contract with the app's Archiver adapter: on success the ONLY line printed to stdout is
#   RELAY_ARTIFACT=/abs/path/to/Relay.dmg
# All human-readable logs go to stderr. `--dry-run` plans every stage (and prints the
# artifact line) without invoking a single tool, so it is safe and offline for CI.

set -euo pipefail

SCHEME="${SCHEME:-Relay}"
CONFIGURATION="${CONFIGURATION:-Release}"
NOTARY_PROFILE="${NOTARY_PROFILE:-Relay}"
TEAM_ID="${TEAM_ID:-}"
OUTPUT_DIR="${OUTPUT_DIR:-build}"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --scheme)         SCHEME="$2"; shift ;;
    --configuration)  CONFIGURATION="$2"; shift ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift ;;
    --team-id)        TEAM_ID="$2"; shift ;;
    --output-dir)     OUTPUT_DIR="$2"; shift ;;
    -h|--help)        grep '^#' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) printf 'archive.sh: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

log() { printf '%s\n' "$*" >&2; }

# Echo the command to the log, then run it — unless this is a dry run.
run() {
  log "+ $*"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$OUTPUT_DIR" in
  /*) : ;;                                  # already absolute
  *)  OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR" ;;
esac

ARCHIVE_PATH="$OUTPUT_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$OUTPUT_DIR/export"
APP_PATH="$EXPORT_DIR/$SCHEME.app"
DMG_PATH="$OUTPUT_DIR/$SCHEME.dmg"
EXPORT_OPTIONS="$OUTPUT_DIR/ExportOptions.plist"

# Developer ID export options. Written only on a real run.
write_export_options() {
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '%s\n' '  <key>method</key><string>developer-id</string>'
    printf '%s\n' '  <key>signingStyle</key><string>automatic</string>'
    printf '%s\n' '  <key>teamID</key><string>'"$TEAM_ID"'</string>'
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } > "$EXPORT_OPTIONS"
}

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$OUTPUT_DIR"
  rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_PATH"
fi

# --- 1. Archive --------------------------------------------------------------------------
log "[archive] building $SCHEME ($CONFIGURATION) -> $ARCHIVE_PATH"
run xcodebuild archive \
  -project "$REPO_ROOT/Relay.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH"

# --- 2. Export (Developer ID) ------------------------------------------------------------
log "[export] exporting a Developer ID app -> $APP_PATH"
if [ "$DRY_RUN" -eq 0 ]; then write_export_options; fi
run xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR"

# --- 3. Package the DMG ------------------------------------------------------------------
log "[dmg] packaging -> $DMG_PATH"
run create-dmg \
  --volname "$SCHEME" \
  --app-drop-link 320 150 \
  --icon "$SCHEME.app" 160 150 \
  "$DMG_PATH" \
  "$APP_PATH"

# --- 4. Notarize -------------------------------------------------------------------------
# Credentials come from the named keychain profile only — never inline.
log "[notarize] submitting to Apple's notary service (profile: $NOTARY_PROFILE)"
run xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# --- 5. Staple ---------------------------------------------------------------------------
log "[staple] stapling the notarization ticket onto $DMG_PATH"
run xcrun stapler staple "$DMG_PATH"

log "[done] artifact ready"
printf 'RELAY_ARTIFACT=%s\n' "$DMG_PATH"
