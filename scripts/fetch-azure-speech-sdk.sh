#!/bin/zsh
# Downloads Microsoft's Speech SDK framework for the Azure Live Interpreter route into Vendor/
# (ignored by Git). The archive must match the pinned SHA-256. Licence: Vendor/AzureSpeech/LICENSE.md.
set -eu
cd "${0:A:h}/.."
VERSION=1.53.0
SHA256=e07ac31d67b92e2ec57ed3ee1ae8fa3e779f1f60a7fbce33cd0097fe19507021
URL="https://csspeechstorage.blob.core.windows.net/drop/$VERSION/MicrosoftCognitiveServicesSpeech-MacOSXCFramework-$VERSION.zip"
TARGET=Vendor/AzureSpeech
if [[ -f "$TARGET/VERSION" && "$(cat $TARGET/VERSION)" == "$VERSION" ]]; then print "Azure Speech SDK $VERSION is present."; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
curl -fsSL "$URL" -o "$work/sdk.zip"
actual=$(shasum -a 256 "$work/sdk.zip" | cut -d' ' -f1)
[[ "$actual" == "$SHA256" ]] || { print -u2 "Azure Speech SDK checksum differs; not installed."; exit 1; }
rm -rf "$TARGET"; mkdir -p "$TARGET"
ditto -x -k "$work/sdk.zip" "$TARGET"
print -n "$VERSION" > "$TARGET/VERSION"
print "Installed Azure Speech SDK $VERSION in $TARGET."
