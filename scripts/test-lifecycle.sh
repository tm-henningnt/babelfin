#!/bin/zsh
set -eu
cd "${0:A:h}/.."
CHECK_DIR="$PWD/.build/lifecycle-checks"
mkdir -p "$CHECK_DIR"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
source scripts/build-bridge-core.sh
build_bridge_core "$CHECK_DIR"
swiftc -parse-as-library -D LIFECYCLE_CHECKS -strict-concurrency=complete -warn-concurrency \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lBridgeCore -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  "${APP_MODEL_SOURCE:-Sources/Babelfin/AppModel.swift}" Sources/Babelfin/UsageStore.swift \
  Sources/Babelfin/AppPreferences.swift Sources/Babelfin/ConversationModel.swift \
  Sources/Babelfin/CoreAudioConsumerMonitor.swift \
  Sources/Babelfin/AudioPipelineControlling.swift Sources/Babelfin/AudioPipeline.swift Sources/Babelfin/DeviceInputCapture.swift \
  Sources/Babelfin/AudioDevices.swift Sources/Babelfin/KeychainStore.swift Sources/Babelfin/LocalCredentialStore.swift \
  Sources/Babelfin/SocketRedirectPolicy.swift Sources/Babelfin/OpenAITranslationProvider.swift \
  Sources/Babelfin/ProviderFactory.swift Sources/Babelfin/DirectServiceWires.swift Sources/Babelfin/TranslationServerSettings.swift Sources/Babelfin/ComposedTranslationProvider.swift \
  Sources/Babelfin/ProviderNetwork.swift Sources/Babelfin/ComposedNetworkStages.swift \
  Sources/Babelfin/ElevenLabsSpeechRecognizer.swift Checks/LifecycleChecks.swift \
  -o "$CHECK_DIR/LifecycleChecks"
"$CHECK_DIR/LifecycleChecks"
