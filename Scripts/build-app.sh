#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/AI Call Assistant.app"

if [[ -d "$app_dir" ]]; then
  /bin/rm -rf -- "$app_dir"
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/AICallAssistant" "$app_dir/Contents/MacOS/AICallAssistant"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
xattr -cr "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
