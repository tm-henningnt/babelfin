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
  clang -std=c11 -Wall -Wextra -Werror -ffp-contract=off "${cflags[@]}" -I Sources/CAtomicMixer/include \
    -c Sources/CAtomicMixer/CAtomicMixer.c -o "$destination/CAtomicMixer.o"
  # Also make the Clang module discoverable to all downstream Swift consumers
  # through their existing -I destination, including independently exported source.
  cp Sources/CAtomicMixer/include/CAtomicMixer.h Sources/CAtomicMixer/include/module.modulemap "$destination/"
  swiftc "${swiftflags[@]}" -I "$destination" -parse-as-library -emit-library -emit-module -module-name BridgeCore \
    Sources/BridgeCore/*.swift "$destination/CAtomicMixer.o" -o "$destination/libBridgeCore.dylib" \
    -emit-module-path "$destination/BridgeCore.swiftmodule"
}
