#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift run --disable-sandbox --cache-path "$PWD/.build/package-cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" CoreChecks
zsh scripts/test-mixer-concurrency.sh
zsh scripts/test-provider.sh
zsh scripts/test-lifecycle.sh
zsh scripts/test-composed.sh
zsh scripts/test-network.sh
zsh scripts/test-meeting.sh
zsh scripts/test-tools.sh
zsh scripts/test-recording-providers.sh
zsh scripts/test-credentials.sh
zsh scripts/test-transport.sh

zsh scripts/test-devices.sh
