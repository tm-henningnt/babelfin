#!/bin/zsh
set -eu
cd "${0:A:h}/.."
OUT="$PWD/.build/device-checks"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$OUT" -strict-concurrency=complete -warn-concurrency
swiftc -parse-as-library -strict-concurrency=complete -warn-concurrency -I "$OUT" -L "$OUT" -lBridgeCore -Xlinker -rpath -Xlinker "$OUT" Sources/Babelfin/AudioDevices.swift Sources/Babelfin/AudioDriverInstaller.swift DeviceChecks/main.swift -o "$OUT/DeviceChecks"
"$OUT/DeviceChecks"
