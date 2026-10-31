#!/bin/zsh
set -eu
cd "${0:A:h}/.."
OUT="$PWD/.build/transport-checks"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$OUT" -strict-concurrency=complete -warn-concurrency
swiftc -D BABELFIN_TRANSPORT_CHECKS -parse-as-library -I "$OUT" -L "$OUT" -lBridgeCore -Xlinker -rpath -Xlinker "$OUT" Sources/Babelfin/SocketRedirectPolicy.swift Sources/Babelfin/ProviderNetwork.swift Sources/Babelfin/ComposedTranslationProvider.swift Sources/Babelfin/ElevenLabsSpeechRecognizer.swift Sources/Babelfin/OpenAITranslationProvider.swift TransportChecks/main.swift -o "$OUT/TransportChecks" -strict-concurrency=complete -warn-concurrency
python3 TransportChecks/peers.py "$OUT/TransportChecks"
