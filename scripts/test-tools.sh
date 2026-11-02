#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
OUT="$PWD/.build/tools-checks"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$OUT" -strict-concurrency=complete -warn-concurrency
swiftc -parse-as-library -I "$OUT" -L "$OUT" -lBridgeCore -Xlinker -rpath -Xlinker "$OUT" Sources/Babelfin/ProviderNetwork.swift Sources/Babelfin/ComposedNetworkStages.swift Sources/Babelfin/SpeechToolsService.swift Sources/Babelfin/MeetingTextStage.swift Sources/Babelfin/AppleLocalStages.swift Sources/Babelfin/MeetingAudioExport.swift ToolsChecks/main.swift -o "$OUT/ToolsChecks" -strict-concurrency=complete -warn-concurrency
"$OUT/ToolsChecks"
