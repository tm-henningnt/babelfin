#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
OUT="$PWD/.build/provider-checks"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$OUT" -strict-concurrency=complete -warn-concurrency
swiftc -parse-as-library -I "$OUT" -L "$OUT" -lBridgeCore -Xlinker -rpath -Xlinker "$OUT" Sources/Babelfin/SocketRedirectPolicy.swift Sources/Babelfin/OpenAITranslationProvider.swift ProviderChecks/main.swift -o "$OUT/ProviderChecks" -strict-concurrency=complete -warn-concurrency
"$OUT/ProviderChecks"
