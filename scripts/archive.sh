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
METHOD="${METHOD:-developer-id}"
OUTPUT_DIR="${OUTPUT_DIR:-build}"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --scheme)         SCHEME="$2"; shift ;;
    --configuration)  CONFIGURATION="$2"; shift ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift ;;
    --team-id)        TEAM_ID="$2"; shift ;;
    --method)         METHOD="$2"; shift ;;
    --output-dir)     OUTPUT_DIR="$2"; shift ;;
    -h|--help)        grep '^#' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) printf 'archive.sh: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

case "$METHOD" in
  developer-id|development) : ;;
  *) printf 'archive.sh: unknown --method: %s (use developer-id or development)\n' "$METHOD" >&2; exit 64 ;;
esac

log() { printf '%s\n' "$*" >&2; }

# Resolve a Team ID from the keychain when one wasn't passed, so an empty `teamID` can't
# slip into the export options (`exportArchive "teamID" should be non-empty`). Reads the
# local codesigning identities only — no network, safe offline. Skipped on a dry run.
detect_team_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -Eo '\([A-Z0-9]{10}\)' | head -n1 | tr -d '()'
}

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

# Export options for the chosen `--method`. Written only on a real run.
write_export_options() {
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '%s\n' '  <key>method</key><string>'"$METHOD"'</string>'
    printf '%s\n' '  <key>signingStyle</key><string>automatic</string>'
    printf '%s\n' '  <key>teamID</key><string>'"$TEAM_ID"'</string>'
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } > "$EXPORT_OPTIONS"
}

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$OUTPUT_DIR"
  rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_PATH"

  # A Developer ID export needs a non-empty Team ID (`exportArchive "teamID" should be
  # non-empty`); resolve one from the keychain when not passed. A local `development`
  # build is lifted straight out of the archive, so it needs no team.
  if [ "$METHOD" = "developer-id" ] && [ -z "$TEAM_ID" ]; then
    TEAM_ID="$(detect_team_id)"
    if [ -z "$TEAM_ID" ]; then
      log "archive.sh: no Team ID — pass --team-id or install a Developer ID identity"
      exit 78
    fi
    log "[team] using detected Team ID: $TEAM_ID"
  fi
fi

# --- 1. Archive --------------------------------------------------------------------------
# Automatic signing with no team flag: the archive is signed to run locally — exactly what
# a `development` build wants, and the base a `developer-id` export later re-signs.
log "[archive] building $SCHEME ($CONFIGURATION) -> $ARCHIVE_PATH"
run xcodebuild archive \
  -project "$REPO_ROOT/Relay.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH"

# --- 2. Export ---------------------------------------------------------------------------
# A local `development` build lifts the runnable, locally-signed `.app` straight out of the
# archive — no `-exportArchive`, no provisioning profile, no Developer ID certificate. A
# `developer-id` build re-signs and exports for distribution.
if [ "$METHOD" = "development" ]; then
  log "[export] copying the development app -> $APP_PATH"
  ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
  run mkdir -p "$EXPORT_DIR"
  run cp -R "$ARCHIVED_APP" "$APP_PATH"
else
  log "[export] exporting a Developer ID app -> $APP_PATH"
  if [ "$DRY_RUN" -eq 0 ]; then write_export_options; fi
  run xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR"
fi

# --- 3. Package the DMG ------------------------------------------------------------------
# Both methods ship a `.dmg`. A `development` dmg just carries a locally-signed app.
# Prefer `create-dmg` (nicer layout: an Applications drop-link), but fall back to the
# always-present `hdiutil` so a clean macOS box without Homebrew still packages a dmg.
log "[dmg] packaging -> $DMG_PATH"
if command -v create-dmg >/dev/null 2>&1; then
  run create-dmg \
    --volname "$SCHEME" \
    --app-drop-link 320 150 \
    --icon "$SCHEME.app" 160 150 \
    "$DMG_PATH" \
    "$APP_PATH"
else
  log "[dmg] create-dmg not found — falling back to hdiutil"
  run hdiutil create \
    -volname "$SCHEME" \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

# A development build stops here: notarization needs Developer ID notary credentials a dev
# machine need not have, so the dmg is packaged but left un-notarized.
if [ "$METHOD" = "development" ]; then
  log "[done] development dmg ready (not notarized)"
  printf 'RELAY_ARTIFACT=%s\n' "$DMG_PATH"
  exit 0
fi

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
