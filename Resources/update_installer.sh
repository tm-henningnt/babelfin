#!/bin/zsh -f
# Babelfin update installer. Babelfin starts a private copy of this script after it has
# downloaded and checksum-verified a release archive. The script verifies the archive
# again, prepares the new app beside the installed one, prints READY, waits for Babelfin
# to quit, swaps the bundles by rename and reopens Babelfin. On failure it restores the
# previous app and reopens it with a short reason. It never asks for an administrator
# password and never changes Gatekeeper, quarantine or Keychain settings.
set -u
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

fail() { print -u2 -- "$1"; cleanup_workspace; exit 1 }
cleanup_workspace() { [[ -n "${workspace:-}" && -d "$workspace" ]] && rm -rf -- "$workspace" }

archive="" sha256="" version="" build="" bundle_id="" target="" parent_pid="" workspace=""
while (( $# > 0 )); do
  case "$1" in
    --archive) archive="$2" ;; --sha256) sha256="$2" ;; --version) version="$2" ;; --build) build="$2" ;;
    --bundle-id) bundle_id="$2" ;; --target) target="$2" ;; --parent-pid) parent_pid="$2" ;; --workspace) workspace="$2" ;;
    *) fail "The update installer received an unknown option." ;;
  esac
  shift 2 || fail "The update installer received incomplete options."
done
[[ -n "$archive" && -n "$sha256" && -n "$version" && -n "$build" && -n "$bundle_id" && -n "$target" && -n "$parent_pid" && -n "$workspace" ]] \
  || fail "The update installer received incomplete options."
[[ "$sha256" =~ '^[0-9a-f]{64}$' && "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build" =~ '^[0-9]+$' && "$parent_pid" =~ '^[0-9]+$' ]] \
  || fail "The update installer received invalid values."

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null }

# Installed app: a regular, writable, non-translocated bundle with the expected identity.
target="${target:A}"
parent="${target:h}"
[[ "${target:t}" == "Babelfin.app" && -d "$target" && ! -L "$target" ]] || fail "Babelfin must be installed as Babelfin.app to update."
[[ "$target" != */AppTranslocation/* ]] || fail "Move Babelfin to the Applications folder, open it from there, then update again."
[[ -w "$parent" && -w "$target" ]] || fail "Babelfin cannot replace itself in this folder. Move it to a folder you can write to, such as Applications."
[[ "$(plist "$target" CFBundleIdentifier)" == "$bundle_id" ]] || fail "The installed app is not Babelfin."

# Archive: the same bytes Babelfin verified, extracted privately.
[[ -f "$archive" && ! -L "$archive" ]] || fail "The downloaded update is missing."
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$sha256" ]] || fail "The downloaded update failed its checksum check. Download it again."
staging="$workspace/staging"
mkdir -m 700 "$staging" || fail "The update could not be prepared."
ditto -x -k "$archive" "$staging" 2>/dev/null || fail "The downloaded update could not be unpacked."
entries=("$staging"/*(DN))
(( ${#entries} == 1 )) && [[ "${entries[1]:t}" == "Babelfin.app" && -d "${entries[1]}" ]] || fail "The downloaded update does not contain exactly one Babelfin app."
candidate="${entries[1]}"
[[ -z "$(find "$candidate" -type l -print -quit)" ]] || fail "The downloaded update contains unexpected links."
[[ "$(plist "$candidate" CFBundleIdentifier)" == "$bundle_id" && "$(plist "$candidate" CFBundleShortVersionString)" == "$version" \
   && "$(plist "$candidate" CFBundleVersion)" == "$build" && -x "$candidate/Contents/MacOS/Babelfin" ]] \
  || fail "The downloaded app does not match the published release."
codesign --verify --deep --strict "$candidate" 2>/dev/null || fail "The downloaded app failed its code signature check."

# Stage beside the installed app so the swap is two renames on one volume.
token="$(uuidgen | tr -d '-' | tr 'A-F' 'a-f')"
prepared="$parent/.Babelfin-update-$token.app"
backup="$parent/.Babelfin.app.backup-$token"
mv -- "$candidate" "$prepared" 2>/dev/null || fail "The update could not be placed beside Babelfin."
drop_prepared() { [[ -d "$prepared" ]] && rm -rf -- "$prepared" }

print READY
exec 1>/dev/null

# Wait for Babelfin to quit; a dialog can keep it open.
for i in {1..300}; do kill -0 "$parent_pid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$parent_pid" 2>/dev/null; then drop_prepared; fail "Babelfin did not quit, so the update was not installed."; fi

running() { pgrep -f -- "$target/Contents/MacOS/Babelfin" >/dev/null 2>&1 }
reopen_previous() {
  local note="$parent/.Babelfin-update-failure-$token.txt"
  print -r -- "$1" > "$note" 2>/dev/null && chmod 600 "$note"
  open -n "$target" --args --update-install-failure-file "$note" >/dev/null 2>&1
}
restore() {
  if [[ -d "$backup" ]]; then
    [[ -d "$target" ]] && rm -rf -- "$target"
    mv -- "$backup" "$target" 2>/dev/null || { print -u2 -- "Babelfin could not be restored. The previous app is at $backup."; exit 1 }
  fi
  drop_prepared
  reopen_previous "$1"
  fail "$1"
}
trap 'restore "The update was interrupted. The previous version of Babelfin was restored."' INT TERM HUP

mv -- "$target" "$backup" 2>/dev/null || { drop_prepared; fail "Babelfin could not be moved aside for the update."; }
mv -- "$prepared" "$target" 2>/dev/null || restore "The new version could not be installed. The previous version of Babelfin was restored."

open -n "$target" >/dev/null 2>&1 || restore "The new version could not be opened. The previous version of Babelfin was restored."
stable=0
for i in {1..100}; do
  if running; then (( stable += 1 )); (( stable >= 20 )) && break; else stable=0; fi
  sleep 0.2
done
if (( stable < 20 )); then
  running && { trap - INT TERM HUP; fail "The new version may still be starting; the previous app was kept at $backup."; }
  restore "The new version did not stay open. The previous version of Babelfin was restored."
fi

trap - INT TERM HUP
rm -rf -- "$backup"
cleanup_workspace
exit 0
