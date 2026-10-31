#!/bin/zsh
set -eu
cd "${0:A:h}/.."
# This checkout can remember a local certificate without putting it in source exports.
# Explicit environment choices always take precedence over the repository setting.
LOCAL_IDENTITY="${BABELFIN_LOCAL_SIGNING_IDENTITY:-}"
if [[ -z "$LOCAL_IDENTITY" && -z "${BABELFIN_SIGNING_IDENTITY:-}" && -e .git ]]; then
    LOCAL_IDENTITY="$(git config --local --get babelfin.localSigningIdentity || true)"
fi
if [[ -n "${BABELFIN_LOCAL_SIGNING_IDENTITY:-}" && -n "${BABELFIN_SIGNING_IDENTITY:-}" ]]; then
    printf 'Choose either a local signing identity or a Developer ID identity, not both.\n' >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --product Babelfin -debug-info-format none --disable-sandbox --cache-path "$PWD/.build/package-cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
TARGET_APP="${BABELFIN_APP_OUTPUT:-$PWD/dist/Babelfin.app}"
IDENTITY="${BABELFIN_SIGNING_IDENTITY:--}"
if [[ "${TARGET_APP:t}" != "Babelfin.app" || -L "$TARGET_APP" ]]; then
    printf 'Output must be a regular Babelfin.app bundle path.\n' >&2
    exit 1
fi
python3 - "$TARGET_APP" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1]).absolute()
if any(part.is_symlink() for part in (path, *path.parents)):
    raise SystemExit("Output and its parents must not be symlinks.")
PYTHON
mkdir -p "${TARGET_APP:h}"
TEMP_ROOT="$(mktemp -d "${TARGET_APP:h}/.Babelfin-build.XXXXXX")"
# Preserve the previous bundle if an installation/rollback failure needs inspection.
cleanup() {
    if [[ -d "$TEMP_ROOT/previous.app" ]]; then
        printf 'Previous bundle preserved at %s/previous.app\n' "$TEMP_ROOT" >&2
    else
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT
APP="$TEMP_ROOT/Babelfin.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X .build/release/Babelfin "$APP/Contents/MacOS/Babelfin"
cp -X Resources/Info.plist "$APP/Contents/Info.plist"
cp -X Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -X Resources/Help.html "$APP/Contents/Resources/Help.html"
cp -X Resources/update_installer.sh "$APP/Contents/Resources/update_installer.sh"
cp -X LICENSE "$APP/Contents/Resources/License.txt"
cp -X Assets/Brand/Babelfin-fish-microphone.png "$APP/Contents/Resources/BrandFish.png"
# The virtual audio drivers are optional: BABELFIN_BUNDLE_DRIVERS=1 includes them, and
# Settings > Audio devices then installs them. Release builds leave them out until the
# drivers are verified on other Macs; users install BlackHole instead.
DRIVERS="$APP/Contents/Resources/AudioDrivers"
if [[ "${BABELFIN_BUNDLE_DRIVERS:-0}" == 1 ]]; then
    zsh Drivers/BabelfinLoopback/build-drivers.sh "$TEMP_ROOT/drivers"
    mkdir -p "$DRIVERS"
    for name in "Babelfin Microphone" "Babelfin Speaker"; do
        ditto --noextattr --noqtn "$TEMP_ROOT/drivers/$name.driver" "$DRIVERS/$name.driver"
    done
    cp -X Drivers/BabelfinLoopback/upstream/LICENSE "$DRIVERS/GPL-3.0.txt"
fi
xattr -cr "$APP"
if [[ -n "$LOCAL_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp=none --entitlements Resources/Babelfin.entitlements --sign "$LOCAL_IDENTITY" "$APP"
    printf 'Locally certificate-signed development build; not notarized.\n'
elif [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
    printf 'Ad-hoc signed local review build; not notarized.\n'
else
    # Notarization rejects nested code with an ad-hoc signature. Sign the drivers before the app seals them.
    if [[ -d "$DRIVERS" ]]; then
        for name in "Babelfin Microphone" "Babelfin Speaker"; do
            codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DRIVERS/$name.driver"
        done
    fi
    codesign --force --options runtime --timestamp --entitlements Resources/Babelfin.entitlements --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
# Only a complete, verified bundle replaces the destination. Stale files cannot survive.
if [[ -e "$TARGET_APP" ]]; then
    if [[ ! -d "$TARGET_APP" ]]; then
        printf 'Output already exists and is not an app directory.\n' >&2
        exit 1
    fi
    mv "$TARGET_APP" "$TEMP_ROOT/previous.app"
fi
if ! mv "$APP" "$TARGET_APP"; then
    if [[ ! -e "$TARGET_APP" && -d "$TEMP_ROOT/previous.app" ]]; then
        mv "$TEMP_ROOT/previous.app" "$TARGET_APP"
    fi
    exit 1
fi
if [[ -d "$TEMP_ROOT/previous.app" ]]; then
    rm -rf "$TEMP_ROOT/previous.app"
fi
printf 'Built %s\n' "$TARGET_APP"
