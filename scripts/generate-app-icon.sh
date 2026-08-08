#!/bin/zsh
set -euo pipefail
umask 077

script_dir=${0:A:h}
project_dir=${script_dir:h}
source_svg="$project_dir/Assets/friend-or-foe-shield.svg"
master_png="$project_dir/Assets/friend-or-foe-shield.png"
icon_path="$project_dir/Assets/AppIcon.icns"
rsvg_path=${RSVG_CONVERT:-$(command -v rsvg-convert || true)}

[[ -f "$source_svg" ]] || { print -u2 -- "Missing $source_svg"; exit 66; }
[[ -n "$rsvg_path" && -x "$rsvg_path" ]] || {
  print -u2 -- "rsvg-convert is required to generate the app icon"
  exit 69
}
[[ -x /usr/bin/sips && -x /usr/bin/iconutil ]] || {
  print -u2 -- "macOS sips and iconutil are required"
  exit 69
}

temp_root=$(/usr/bin/mktemp -d /tmp/travel-lockdown-app-icon.XXXXXX)
[[ "$temp_root" == /tmp/travel-lockdown-app-icon.* ]] || {
  print -u2 -- "Unexpected temporary directory"
  exit 70
}
iconset="$temp_root/AppIcon.iconset"
mkdir -m 700 "$iconset"

cleanup() {
  [[ "$temp_root" == /tmp/travel-lockdown-app-icon.* ]] && rm -rf -- "$temp_root"
}
trap cleanup EXIT

"$rsvg_path" -w 1024 -h 1024 -o "$master_png" "$source_svg"

for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size=${spec%% *}
  name=${spec#* }
  /usr/bin/sips -z "$size" "$size" "$master_png" -o "$iconset/$name" >/dev/null
done

/usr/bin/iconutil -c icns "$iconset" -o "$icon_path"
[[ -s "$master_png" && -s "$icon_path" ]] || {
  print -u2 -- "Generated icon artifacts are missing"
  exit 74
}
