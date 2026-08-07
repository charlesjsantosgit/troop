#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This combined Windows + macOS release builder must run on macOS." >&2
  exit 1
fi

if [[ -n "${GODOT_BIN:-}" ]]; then
  GODOT_COMMAND="$GODOT_BIN"
else
  GODOT_COMMAND="$(command -v godot || true)"
fi
MAKENSIS_COMMAND="$(command -v makensis || true)"

if [[ -z "$GODOT_COMMAND" || ! -x "$GODOT_COMMAND" ]]; then
  echo "Godot was not found. Set GODOT_BIN or add Godot to PATH." >&2
  exit 1
fi
if [[ -z "$MAKENSIS_COMMAND" || ! -x "$MAKENSIS_COMMAND" ]]; then
  echo "makensis was not found. Install it with: brew install makensis" >&2
  exit 1
fi
for REQUIRED_COMMAND in hdiutil codesign cmp ditto file lipo shasum; do
  if ! command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
    echo "Required command was not found: $REQUIRED_COMMAND" >&2
    exit 1
  fi
done

GODOT_VERSION="$($GODOT_COMMAND --version | tr -d '\r')"
if [[ "$GODOT_VERSION" != 4.7.stable.* ]]; then
  echo "TROOP's presets require Godot 4.7 stable; found $GODOT_VERSION" >&2
  exit 1
fi

APP_VERSION="$(sed -n 's/^config\/version="\([^"]*\)"/\1/p' "$PROJECT_ROOT/project.godot" | head -1)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
  echo "project.godot must contain a numeric config/version such as 0.1.0" >&2
  exit 1
fi
if [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  FILE_VERSION="$APP_VERSION.0"
else
  FILE_VERSION="$APP_VERSION"
fi

BUILD_ROOT="$PROJECT_ROOT/build/release-$APP_VERSION"
WINDOWS_BUILD="$BUILD_ROOT/windows"
MAC_BUILD="$BUILD_ROOT/macos"
DIST_DIR="$PROJECT_ROOT/dist"
WINDOWS_EXE="$WINDOWS_BUILD/TROOP.exe"
WINDOWS_PCK="$WINDOWS_BUILD/TROOP.pck"
WINDOWS_INSTALLER="$DIST_DIR/TROOP-$APP_VERSION-Windows-x86_64-Setup.exe"
MAC_BUILD_APP="$MAC_BUILD/TROOP.app"
MAC_DMG="$DIST_DIR/TROOP-$APP_VERSION-macOS-universal.dmg"
CONTENT_PCK="$DIST_DIR/TROOP-$APP_VERSION-content.pck"
CHECKSUMS="$DIST_DIR/TROOP-$APP_VERSION-SHA256SUMS.txt"

for OUTPUT_PATH in "$WINDOWS_EXE" "$WINDOWS_PCK" "$WINDOWS_INSTALLER" "$MAC_BUILD_APP" "$MAC_DMG" "$CONTENT_PCK" "$CHECKSUMS"; do
  if [[ -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
    echo "Refusing to overwrite existing output: $OUTPUT_PATH" >&2
    echo "Move the existing build aside before creating this version again." >&2
    exit 1
  fi
done

mkdir -p "$WINDOWS_BUILD" "$MAC_BUILD" "$DIST_DIR"

# Package the Mac app outside Documents so File Provider cannot attach Finder
# metadata that causes strict code-signature verification to fail.
MAC_DMG_STAGE="$(mktemp -d /tmp/troop-macos-package.XXXXXX)"
DMG_MOUNT_POINT=""
case "$MAC_DMG_STAGE" in
  /tmp/troop-macos-package.*) ;;
  *)
    echo "Unexpected temporary package path: $MAC_DMG_STAGE" >&2
    exit 1
    ;;
esac
cleanup_temporary_directories() {
  if [[ -n "$DMG_MOUNT_POINT" && "$DMG_MOUNT_POINT" == /tmp/troop-dmg-verify.* && -d "$DMG_MOUNT_POINT" && ! -L "$DMG_MOUNT_POINT" ]]; then
    hdiutil detach "$DMG_MOUNT_POINT" >/dev/null 2>&1 || true
    rmdir "$DMG_MOUNT_POINT" 2>/dev/null || true
  fi
  if [[ "$MAC_DMG_STAGE" == /tmp/troop-macos-package.* && -d "$MAC_DMG_STAGE" && ! -L "$MAC_DMG_STAGE" ]]; then
    if [[ -L "$MAC_DMG_STAGE/Applications" ]]; then
      if [[ "$(readlink "$MAC_DMG_STAGE/Applications")" != "/Applications" ]]; then
        echo "Refusing to clean a staging directory with an unexpected symlink" >&2
        return
      fi
      unlink "$MAC_DMG_STAGE/Applications"
    fi
    if find -P "$MAC_DMG_STAGE" -type l -print | grep -q .; then
      echo "Refusing to clean a staging directory that still contains symlinks" >&2
      return
    fi
    find "$MAC_DMG_STAGE" -mindepth 1 -maxdepth 1 -print >/dev/null
    rm -R "$MAC_DMG_STAGE"
  fi
}
trap cleanup_temporary_directories EXIT

MAC_APP="$MAC_DMG_STAGE/TROOP.app"

echo "[1/8] Importing resources with Godot $GODOT_VERSION"
"$GODOT_COMMAND" --headless --path "$PROJECT_ROOT" --import

echo "[2/8] Running the source-project smoke test"
SOURCE_SMOKE_OUTPUT="$("$GODOT_COMMAND" --headless --path "$PROJECT_ROOT" \
  res://scenes/main.tscn --quit-after 1200 -- smoke 2>&1)"
printf '%s\n' "$SOURCE_SMOKE_OUTPUT"
if ! grep -q '^SMOKE_OK ' <<< "$SOURCE_SMOKE_OUTPUT"; then
  echo "Source smoke test exited without its SMOKE_OK sentinel" >&2
  exit 1
fi

echo "[3/8] Exporting Windows x86_64"
"$GODOT_COMMAND" --headless --path "$PROJECT_ROOT" \
  --export-release "Windows Desktop" "$WINDOWS_EXE"

if [[ ! -s "$WINDOWS_EXE" || ! -s "$WINDOWS_PCK" ]]; then
  echo "Windows export did not create both TROOP.exe and TROOP.pck" >&2
  exit 1
fi
if ! file "$WINDOWS_EXE" | grep -q "PE32+ executable"; then
  echo "TROOP.exe is not a Windows x86_64 executable" >&2
  exit 1
fi

echo "[4/8] Compiling the per-user Windows installer"
"$MAKENSIS_COMMAND" -V2 \
  "-DAPP_VERSION=$APP_VERSION" \
  "-DFILE_VERSION=$FILE_VERSION" \
  "-DGAME_EXE=$WINDOWS_EXE" \
  "-DGAME_PCK=$WINDOWS_PCK" \
  "-DGODOT_LICENSE=$SCRIPT_DIR/GODOT_LICENSE.txt" \
  "-DPLAYER_README=$SCRIPT_DIR/PLAYER_README.txt" \
  "-DOUTPUT_FILE=$WINDOWS_INSTALLER" \
  "$SCRIPT_DIR/windows/TROOP.nsi"

if [[ ! -s "$WINDOWS_INSTALLER" ]]; then
  echo "The Windows installer was not created" >&2
  exit 1
fi
if ! file "$WINDOWS_INSTALLER" | grep -q "PE32 executable"; then
  echo "The NSIS output is not a Windows installer executable" >&2
  exit 1
fi

echo "[5/8] Exporting the universal macOS app"
"$GODOT_COMMAND" --headless --path "$PROJECT_ROOT" \
  --export-release "macOS" "$MAC_BUILD_APP"

if [[ ! -x "$MAC_BUILD_APP/Contents/MacOS/TROOP" ]]; then
  echo "The macOS export does not contain its TROOP executable" >&2
  exit 1
fi
ditto --norsrc --noextattr --noqtn "$MAC_BUILD_APP" "$MAC_APP"

MAC_BINARY="$MAC_APP/Contents/MacOS/TROOP"
if [[ ! -x "$MAC_BINARY" ]]; then
  echo "The clean macOS package copy does not contain its TROOP executable" >&2
  exit 1
fi
MAC_ARCHS="$(lipo -archs "$MAC_BINARY")"
if [[ "$MAC_ARCHS" != *"arm64"* || "$MAC_ARCHS" != *"x86_64"* ]]; then
  echo "The macOS executable is not Universal 2; found: $MAC_ARCHS" >&2
  exit 1
fi

# Optional Developer ID signing + notarization. When TROOP_MAC_SIGN_IDENTITY is
# set (a "Developer ID Application: …" identity in the keychain), the exported
# app is re-signed with the hardened runtime; when TROOP_MAC_NOTARY_PROFILE is
# also set (an `xcrun notarytool store-credentials` profile), the app and disk
# image are notarized and stapled so Gatekeeper opens the download with no
# "couldn't verify" dialog. Without these variables the build keeps Godot's
# ad-hoc signature exactly as before.
MAC_SIGN_IDENTITY="${TROOP_MAC_SIGN_IDENTITY:-}"
MAC_NOTARY_PROFILE="${TROOP_MAC_NOTARY_PROFILE:-}"
MAC_ENTITLEMENTS="$SCRIPT_DIR/macos/entitlements.plist"
if [[ -n "$MAC_SIGN_IDENTITY" ]]; then
  if [[ ! -f "$MAC_ENTITLEMENTS" ]]; then
    echo "Missing entitlements file: $MAC_ENTITLEMENTS" >&2
    exit 1
  fi
  echo "Re-signing TROOP.app with Developer ID: $MAC_SIGN_IDENTITY"
  codesign --force --timestamp --options runtime \
    --entitlements "$MAC_ENTITLEMENTS" \
    --sign "$MAC_SIGN_IDENTITY" "$MAC_APP"
  codesign --verify --strict --verbose=2 "$MAC_APP"
  if [[ -n "$MAC_NOTARY_PROFILE" ]]; then
    echo "Notarizing TROOP.app (profile: $MAC_NOTARY_PROFILE) — this can take a few minutes"
    MAC_NOTARY_ZIP="$MAC_DMG_STAGE/TROOP-notarize.zip"
    ditto -c -k --keepParent "$MAC_APP" "$MAC_NOTARY_ZIP"
    xcrun notarytool submit "$MAC_NOTARY_ZIP" \
      --keychain-profile "$MAC_NOTARY_PROFILE" --wait
    rm -f "$MAC_NOTARY_ZIP"
    xcrun stapler staple "$MAC_APP"
  fi
else
  codesign --verify --deep --strict "$MAC_APP"
fi

echo "[6/8] Smoke-testing the exported macOS app and creating its disk image"
EXPORTED_SMOKE_OUTPUT="$("$MAC_BINARY" --headless --quit-after 1200 -- smoke 2>&1)"
printf '%s\n' "$EXPORTED_SMOKE_OUTPUT"
if ! grep -q '^SMOKE_OK ' <<< "$EXPORTED_SMOKE_OUTPUT"; then
  echo "Exported macOS smoke test exited without its SMOKE_OK sentinel" >&2
  exit 1
fi
cp "$SCRIPT_DIR/GODOT_LICENSE.txt" "$MAC_DMG_STAGE/GODOT_LICENSE.txt"
cp "$SCRIPT_DIR/PLAYER_README.txt" "$MAC_DMG_STAGE/README.txt"
ln -s /Applications "$MAC_DMG_STAGE/Applications"
hdiutil create \
  -volname "TROOP $APP_VERSION" \
  -srcfolder "$MAC_DMG_STAGE" \
  -fs HFS+ \
  -format UDZO \
  "$MAC_DMG"
hdiutil verify "$MAC_DMG"

if [[ -n "$MAC_SIGN_IDENTITY" ]]; then
  echo "Signing the disk image"
  codesign --force --timestamp --sign "$MAC_SIGN_IDENTITY" "$MAC_DMG"
  if [[ -n "$MAC_NOTARY_PROFILE" ]]; then
    echo "Notarizing the disk image (profile: $MAC_NOTARY_PROFILE)"
    xcrun notarytool submit "$MAC_DMG" \
      --keychain-profile "$MAC_NOTARY_PROFILE" --wait
    xcrun stapler staple "$MAC_DMG"
    echo "Gatekeeper assessment of the stapled disk image:"
    spctl --assess --type open --context context:primary-signature -vv "$MAC_DMG"
  fi
fi

DMG_MOUNT_POINT="$(mktemp -d /tmp/troop-dmg-verify.XXXXXX)"
hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT_POINT" "$MAC_DMG" >/dev/null
if [[ ! -d "$DMG_MOUNT_POINT/TROOP.app" || ! -L "$DMG_MOUNT_POINT/Applications" ]]; then
  hdiutil detach "$DMG_MOUNT_POINT" >/dev/null
  rmdir "$DMG_MOUNT_POINT"
  DMG_MOUNT_POINT=""
  echo "The disk image is missing TROOP.app or its Applications shortcut" >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$DMG_MOUNT_POINT/TROOP.app"; then
  hdiutil detach "$DMG_MOUNT_POINT" >/dev/null
  rmdir "$DMG_MOUNT_POINT"
  DMG_MOUNT_POINT=""
  echo "The app signature did not survive disk-image creation" >&2
  exit 1
fi
hdiutil detach "$DMG_MOUNT_POINT" >/dev/null
rmdir "$DMG_MOUNT_POINT"
DMG_MOUNT_POINT=""

echo "[7/8] Publishing the cross-platform content pack"
MAC_EXPORTED_PCK="$MAC_BUILD_APP/Contents/Resources/TROOP.pck"
if [[ ! -s "$MAC_EXPORTED_PCK" ]]; then
  echo "The macOS export did not create TROOP.pck" >&2
  exit 1
fi
if ! cmp -s "$WINDOWS_PCK" "$MAC_EXPORTED_PCK"; then
  echo "Windows and macOS resource packs differ; refusing to publish one cross-platform update." >&2
  echo "Split the manifest into platform-specific content assets before releasing this build." >&2
  exit 1
fi
cp "$WINDOWS_PCK" "$CONTENT_PCK"

echo "[8/8] Writing SHA-256 checksums"
(
  cd "$DIST_DIR"
  shasum -a 256 \
    "$(basename "$WINDOWS_INSTALLER")" \
    "$(basename "$MAC_DMG")" \
    "$(basename "$CONTENT_PCK")" \
    > "$(basename "$CHECKSUMS")"
)

echo
echo "Release artifacts:"
ls -lh "$WINDOWS_INSTALLER" "$MAC_DMG" "$CONTENT_PCK" "$CHECKSUMS"
echo
if [[ -n "$MAC_SIGN_IDENTITY" && -n "$MAC_NOTARY_PROFILE" ]]; then
  echo "macOS: Developer ID signed, notarized, and stapled — Gatekeeper opens this DMG without warnings."
  echo "Windows: still unsigned (SmartScreen may warn). See packaging/README.md for Authenticode."
elif [[ -n "$MAC_SIGN_IDENTITY" ]]; then
  echo "macOS: Developer ID signed but NOT notarized — Gatekeeper will still warn on download."
  echo "Set TROOP_MAC_NOTARY_PROFILE to notarize; see packaging/README.md."
else
  echo "These builds are ad-hoc/unsigned previews. See packaging/README.md before public distribution."
  echo "macOS users can install without any Gatekeeper dialog via the terminal one-liner in README.md."
fi
