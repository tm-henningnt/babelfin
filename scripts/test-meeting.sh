#!/bin/zsh
set -eu
cd "${0:A:h}/.."
CHECK_DIR="$PWD/.build/meeting-checks"
mkdir -p "$CHECK_DIR"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$CHECK_DIR" -strict-concurrency=complete -warn-concurrency
swiftc -parse-as-library -strict-concurrency=complete -warn-concurrency \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lBridgeCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  MeetingChecks/core.swift -o "$CHECK_DIR/MeetingCoreChecks"
"$CHECK_DIR/MeetingCoreChecks"
