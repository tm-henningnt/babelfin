#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
mkdir -p .build/brand/Babelfin.iconset Assets/Brand/MenuBar Resources
SOURCE="$PWD/Assets/Brand/Babelfin-fish-microphone.png"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out ".build/brand/Babelfin.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out ".build/brand/Babelfin.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
if ! iconutil -c icns .build/brand/Babelfin.iconset -o Resources/AppIcon.icns 2>/dev/null; then
    # The command-line-tools host can reject valid iconsets; package the same PNGs directly.
    python3 scripts/package-icon.py .build/brand/Babelfin.iconset Resources/AppIcon.icns
fi
sips -g format Resources/AppIcon.icns >/dev/null
swiftc -module-cache-path "$PWD/.build/clang-cache" Sources/Babelfin/MenuBarSymbol.swift scripts/ExportMenuBarSymbol.swift -o .build/brand/export-menu-symbol
.build/brand/export-menu-symbol Assets/Brand/MenuBar
printf 'App icon and menu-bar previews regenerated.\n'
