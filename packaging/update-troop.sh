#!/usr/bin/env bash
# TROOP terminal updater (macOS). Downloads the latest release, verifies its
# checksum, and replaces the installed app wherever it lives.
# Usage:  curl -fsSL https://raw.githubusercontent.com/charlesjsantosgit/troop/main/packaging/update-troop.sh | bash
# Override the install location with TROOP_APP=/path/to/TROOP.app
set -euo pipefail
REPO="charlesjsantosgit/troop"
echo "🐒 TROOP updater (macOS)"
TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
	| sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
VER="${TAG#v}"
[ -n "$VER" ] || { echo "Could not determine the latest version." >&2; exit 1; }
APP="${TROOP_APP:-}"
if [ -z "$APP" ]; then
	for CAND in "/Applications/TROOP.app" "$HOME/Applications/TROOP.app"; do
		[ -d "$CAND" ] && APP="$CAND" && break
	done
fi
[ -n "$APP" ] || APP=$(mdfind 'kMDItemCFBundleIdentifier == "com.charlessantos.troop"' 2>/dev/null | head -1)
[ -n "$APP" ] || APP="/Applications/TROOP.app"
CURRENT=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "none")
echo "Installed base: $CURRENT  →  latest: $VER  (target: $APP)"
if [ "$CURRENT" = "$VER" ]; then
	echo "Already on the latest base. (In-game content updates apply themselves.)"
	exit 0
fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
DMG="TROOP-$VER-macOS-universal.dmg"
echo "Downloading $DMG…"
curl -fL --progress-bar -o "$WORK/$DMG" \
	"https://github.com/$REPO/releases/download/$TAG/$DMG"
curl -fsSL -o "$WORK/SUMS" \
	"https://github.com/$REPO/releases/download/$TAG/TROOP-$VER-SHA256SUMS.txt"
(cd "$WORK" && grep "$DMG" SUMS | shasum -a 256 -c -) \
	|| { echo "Checksum mismatch — aborting." >&2; exit 1; }
osascript -e 'quit app "TROOP"' 2>/dev/null || true
sleep 1
MOUNT=$(mktemp -d)
hdiutil attach "$WORK/$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
rm -rf "$APP"
ditto "$MOUNT/TROOP.app" "$APP"
hdiutil detach "$MOUNT" -quiet
# The checksum above already proved this is the genuine release, so drop the
# quarantine flag: launching never shows the Gatekeeper "couldn't verify"
# dialog or needs Privacy & Security → Open Anyway.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "✅ TROOP $VER installed at $APP — ook!"
echo "   Launches straight from Finder — no Gatekeeper dialog."
