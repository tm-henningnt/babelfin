#!/bin/zsh
# Offline production-seam regression; never opens an engine or enumerates devices.
set -eu
cd "${0:A:h}/.."
OUT="$PWD/.build/mixer-checks"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$OUT" -O -D BABELFIN_MIXER_CHECKS -strict-concurrency=complete -warn-concurrency
swiftc -O -D BABELFIN_MIXER_CHECKS -parse-as-library -I "$OUT" -L "$OUT" -lBridgeCore \
  -Xlinker -rpath -Xlinker "$OUT" -strict-concurrency=complete -warn-concurrency \
  Checks/MixerConcurrencyChecks.swift -o "$OUT/MixerConcurrencyChecks"
"$OUT/MixerConcurrencyChecks"
