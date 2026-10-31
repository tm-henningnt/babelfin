#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
OUT="$PWD/.build/network-checks"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$OUT" -strict-concurrency=complete -warn-concurrency
swiftc -parse-as-library -I "$OUT" -L "$OUT" -lBridgeCore -Xlinker -rpath -Xlinker "$OUT" Sources/Babelfin/SocketRedirectPolicy.swift Sources/Babelfin/ProviderNetwork.swift Sources/Babelfin/ComposedTranslationProvider.swift Sources/Babelfin/ComposedNetworkStages.swift Sources/Babelfin/VoiceService.swift Sources/Babelfin/ElevenLabsSpeechRecognizer.swift NetworkChecks/main.swift -o "$OUT/NetworkChecks" -strict-concurrency=complete -warn-concurrency
"$OUT/NetworkChecks"
