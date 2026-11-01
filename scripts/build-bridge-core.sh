#!/bin/zsh
# Sourced by standalone checks. Preserve each caller's target, defines and optimizer.
# The C object is linked into BridgeCore; no additional runtime library is required.
function build_bridge_core() {
  local destination="$1"
  shift
  mkdir -p "$destination"
  local -a cflags
  cflags=()
  local -a swiftflags
  swiftflags=("$@")
  local index
  for (( index=1; index <= $#swiftflags; index++ )); do
    case "${swiftflags[index]}" in
      -target) cflags+=(-target "${swiftflags[index+1]}"); (( index++ )) ;;
      -O) cflags+=(-O2) ;;
      -Onone) cflags+=(-O0) ;;
      -g) cflags+=(-g) ;;
    esac
  done
  # Checks with the same flags and sources share one build. The key covers the flags, the
  # compilers and every source file, so a change to any of them builds again.
  local key
  key=$({ print -r -- "${swiftflags[*]}|${cflags[*]}"; swiftc --version 2>&1; clang --version 2>&1
          cat Sources/BridgeCore/*.swift Sources/CAtomicMixer/CAtomicMixer.c Sources/CAtomicMixer/include/*; } | shasum -a 256 | cut -c1-16)
  local cache="$PWD/.build/bridge-core-cache/$key"
  if [[ ! -f "$cache/libBridgeCore.dylib" ]]; then
    local staging="$cache.partial.$$"
    rm -rf "$staging"; mkdir -p "$staging"
    clang -std=c11 -Wall -Wextra -Werror -ffp-contract=off "${cflags[@]}" -I Sources/CAtomicMixer/include \
      -c Sources/CAtomicMixer/CAtomicMixer.c -o "$staging/CAtomicMixer.o"
    # Also make the Clang module discoverable to all downstream Swift consumers
    # through their existing -I destination, including independently exported source.
    cp Sources/CAtomicMixer/include/CAtomicMixer.h Sources/CAtomicMixer/include/module.modulemap "$staging/"
    swiftc "${swiftflags[@]}" -I "$staging" -parse-as-library -emit-library -emit-module -module-name BridgeCore \
      Sources/BridgeCore/*.swift "$staging/CAtomicMixer.o" -o "$staging/libBridgeCore.dylib" \
      -emit-module-path "$staging/BridgeCore.swiftmodule"
    rm -rf "$cache"; mv "$staging" "$cache"
    # Builds for older sources are not used again.
    find "${cache:h}" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
  fi
  # Each check links and loads its own copy, named by its own path as an uncached build is.
  cp -R "$cache/." "$destination/"
  install_name_tool -id "$destination/libBridgeCore.dylib" "$destination/libBridgeCore.dylib" 2>/dev/null
  codesign --force --sign - "$destination/libBridgeCore.dylib" 2>/dev/null
}
