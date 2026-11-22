#!/bin/zsh
# Publishes the version in VERSION as a GitHub release: builds the DMG from a clean, pushed main,
# writes cumulative release notes from CHANGELOG.md (every version newer than NOTES_SINCE, newest first)
# and creates the release with the DMG attached, marked latest.
#
#   ./release.sh                 # notes cover everything newer than the last 26.10.x
#   NOTES_SINCE=26.11 ./release.sh
#   ./release.sh --notes-only    # print the notes, publish nothing
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
NOTES_SINCE="${NOTES_SINCE:-26.10}"
NOTES="$(mktemp -t ag-notes)"

grep -q "^## ${VERSION}\$" CHANGELOG.md || { echo "CHANGELOG.md has no '## ${VERSION}' section." >&2; exit 1; }
{
    print "Everything since ${NOTES_SINCE}, newest first.\n"
    # From the top section down to the first heading of the NOTES_SINCE series.
    awk -v since="## ${NOTES_SINCE}" 'index($0, since) == 1 { exit } /^## / { f = 1 } f' CHANGELOG.md
    print "## Install\n"
    print "Open the DMG and drag Antenna Genius to Applications. This build is ad hoc signed: the first time, open it, then choose Open Anyway in System Settings › Privacy & Security.\n"
    print "macOS asks once whether Antenna Genius may send notifications, before the first alert.\n"
    print 'If you saved network settings with a version before 26.11.4, your remote access password may have been reset to "1": set a new one in Settings › Network.'
} > "$NOTES"

if [[ "${1:-}" == "--notes-only" ]]; then cat "$NOTES"; exit 0; fi

[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first." >&2; exit 1; }
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Push main first (HEAD differs from origin/main)." >&2; exit 1; }
! gh release view "$VERSION" >/dev/null 2>&1 || { echo "Release $VERSION already exists." >&2; exit 1; }

./make_dmg.sh
gh release create "$VERSION" "dist/AntennaGenius-${VERSION}-macos-universal.dmg" \
    --target "$(git rev-parse HEAD)" --title "Antenna Genius 8x2 Native App - Macosx" \
    --notes-file "$NOTES" --latest
rm -f "$NOTES"
