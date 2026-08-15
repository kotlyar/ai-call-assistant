#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/AI Call Assistant.app"
staging_dir="$(mktemp -d /tmp/ai-call-assistant-build.XXXXXX)"
staged_app="$staging_dir/AI Call Assistant.app"

cleanup_staging() {
  /bin/rm -rf -- "$staging_dir"
}
trap cleanup_staging EXIT

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$bin_dir/AICallAssistant" "$staged_app/Contents/MacOS/AICallAssistant"
cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"
xattr -cr "$staged_app"
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [[ -d "$app_dir" ]]; then
  /bin/rm -rf -- "$app_dir"
fi
mkdir -p "$project_dir/dist"
ditto --noextattr "$staged_app" "$app_dir"
xattr -cr "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
