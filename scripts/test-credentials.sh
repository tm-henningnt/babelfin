#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
CHECK_DIR="$PWD/.build/credential-checks"
CHECK_TARGET="$(uname -m)-apple-macosx13.0"
mkdir -p "$CHECK_DIR"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$CHECK_DIR" -target "$CHECK_TARGET" -strict-concurrency=complete -warn-concurrency -warnings-as-errors
swiftc -target "$CHECK_TARGET" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lBridgeCore -Xlinker -rpath -Xlinker "$CHECK_DIR" Sources/Babelfin/LocalCredentialStore.swift Sources/Babelfin/KeychainStore.swift Sources/Babelfin/CredentialOperationActivity.swift CredentialChecks/main.swift -o "$CHECK_DIR/CredentialChecks" -strict-concurrency=complete -warn-concurrency -warnings-as-errors
"$CHECK_DIR/CredentialChecks"
