#!/bin/zsh
# Builds the Babelfin Microphone and Babelfin Speaker virtual audio drivers from the
# unmodified upstream source in upstream/ (GPL-3.0). Only compile-time settings differ.
# Output: .build/loopback-drivers/<name>.driver. This script never installs a driver,
# changes system audio defaults or restarts Core Audio.
set -eu
HERE="${0:A:h}"
ROOT="${HERE:h:h}"
OUT="${1:-$ROOT/.build/loopback-drivers}"
ICON="$ROOT/Resources/AppIcon.icns"
cd "$HERE"
mkdir -p "$OUT"

# The upstream license forbids the BlackHole name on modified builds. Four literals do not
# follow the name macros; replace them in a build copy so upstream/ stays byte-identical.
SOURCE="$OUT/BabelfinLoopback.c"
sed -e 's/CFSTR("BlackHole Box")/CFSTR(kDriver_Name " Box")/' \
    -e 's/CFSTR("BlackHole")/CFSTR(kDriver_Name)/' \
    -e 's/CFSTR("Existential Audio Inc.")/CFSTR(kManufacturer_Name)/' \
    -e 's/implemented by the BlackHole driver/implemented by the " kDriver_Name " driver/' \
    upstream/BlackHole.c > "$SOURCE"
grep -q 'CFSTR("BlackHole\|CFSTR("Existential\|by the BlackHole driver' "$SOURCE" && { print -u2 "Upstream names remain in $SOURCE"; exit 1; }

build() {
  local name="$1" executable="$2" bundle_id="$3" factory="$4"
  local bundle="$OUT/$name.driver"
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  clang -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -O2 -Wno-deprecated-declarations \
    -DkDriver_Name="\"$name\"" -DkPlugIn_BundleID="\"$bundle_id\"" -DkPlugIn_Icon='"Babelfin.icns"' \
    -DkHas_Driver_Name_Format=false -DkDevice_Name="\"$name\"" -DkDevice2_Name="\"$name Mirror\"" \
    -DkManufacturer_Name='"Babelfin"' -DkNumber_Of_Channels=2 \
    -framework CoreAudio -framework CoreFoundation -framework Accelerate \
    "$SOURCE" -o "$bundle/Contents/MacOS/$executable"
  sed -e "s/@EXECUTABLE@/$executable/g" -e "s/@BUNDLE_ID@/$bundle_id/g" -e "s/@NAME@/$name/g" \
      -e "s/@FACTORY@/$factory/g" -e "s/@VERSION@/$(cat upstream/VERSION)/g" Info.plist.in > "$bundle/Contents/Info.plist"
  cp -X "$ICON" "$bundle/Contents/Resources/Babelfin.icns"
  cp -X upstream/LICENSE "$bundle/Contents/Resources/LICENSE"
  xattr -cr "$bundle"
  codesign --force --sign - "$bundle"
  codesign --verify --strict "$bundle"
  print "Built $bundle"
}

build "Babelfin Microphone" BabelfinMicrophone no.tallmaker.Babelfin.Microphone 7E935707-753E-42B3-B2DF-060BA4B4B0C2
build "Babelfin Speaker" BabelfinSpeaker no.tallmaker.Babelfin.Speaker F22E4939-CCC7-4BD1-AD9B-03578CA43744
