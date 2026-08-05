#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" != "--confirm" || "$#" -ne 1 ]]; then
  print -u2 "Usage: recover-travel-lockdown.sh --confirm"
  exit 64
fi

script_dir=${0:A:h}
app_binary="$script_dir/../build/TravelLockdown.app/Contents/MacOS/TravelLockdown"
[[ -x "$app_binary" ]] || { print -u2 "Travel Lockdown app bundle not found"; exit 66; }
exec "$app_binary" --restore
