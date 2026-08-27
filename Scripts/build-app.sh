#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
build_dir="${AI_CALL_ASSISTANT_BUILD_DIR:-$project_dir/.build}"

# Build a universal executable so the same archive works on Apple Silicon and
# Intel Macs. SwiftPM places the merged binary in its universal release folder.
swift build --scratch-path "$build_dir" -c release --arch arm64 --arch x86_64
bin_dir="$(swift build --scratch-path "$build_dir" -c release --arch arm64 --arch x86_64 --show-bin-path)"
app_dir="$project_dir/dist/Callya.app"
archive_path="$project_dir/dist/Callya.zip"
dmg_path="$project_dir/dist/Callya.dmg"
app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$project_dir/Info.plist")"
dmg_volume_name="Callya $app_version"
staging_dir="$(mktemp -d /tmp/ai-call-assistant-build.XXXXXX)"
verification_dir="$(mktemp -d /tmp/ai-call-assistant-verify.XXXXXX)"
dmg_source_dir="$(mktemp -d /tmp/ai-call-assistant-dmg.XXXXXX)"
dmg_mount_dir="$(mktemp -d /tmp/ai-call-assistant-mount.XXXXXX)"
staged_app="$staging_dir/Callya.app"
verified_app="$verification_dir/Callya.app"
dmg_attached=false

cleanup_staging() {
  if [[ "$dmg_attached" == true ]]; then
    /usr/bin/hdiutil detach "$dmg_mount_dir" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- \
    "$staging_dir" \
    "$verification_dir" \
    "$dmg_source_dir" \
    "$dmg_mount_dir"
}
trap cleanup_staging EXIT

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$bin_dir/AICallAssistant" "$staged_app/Contents/MacOS/AICallAssistant"
cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
xattr -cr "$staged_app"
signing_identity="${AI_CALL_ASSISTANT_CODE_SIGN_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
  # A default ad-hoc signature has a designated requirement based on CDHash,
  # which changes on every build and invalidates TCC permissions. Keep a
  # stable local-development requirement until a real identity is configured.
  codesign \
    --force \
    --options runtime \
    --entitlements "$project_dir/Resources/AICallAssistant.entitlements" \
    --requirements '=designated => identifier "com.aicallassistant.desktop"' \
    --sign - \
    "$staged_app"
  print -u2 "warning: local ad-hoc signing; set AI_CALL_ASSISTANT_CODE_SIGN_IDENTITY for distribution"
else
  codesign \
    --force \
    --options runtime \
    --entitlements "$project_dir/Resources/AICallAssistant.entitlements" \
    --sign "$signing_identity" \
    "$staged_app"
fi
codesign --verify --all-architectures --deep --strict "$staged_app"

mkdir -p "$project_dir/dist"
if [[ -d "$app_dir" ]]; then
  /bin/rm -rf -- "$app_dir"
fi
ditto --noextattr "$staged_app" "$app_dir"
xattr -cr "$app_dir"
if ! codesign --verify --all-architectures --deep --strict "$app_dir"; then
  print -u2 "warning: workspace metadata changed the local .app; use the verified ZIP or DMG"
fi

# Cloud-backed workspaces may re-attach Finder metadata to an .app after this
# script returns. The ZIP is created from the clean staging bundle and omits
# resource-fork metadata, so it remains a portable, verifiable handoff.
/bin/rm -f -- "$archive_path"
/usr/bin/ditto -c -k --norsrc --keepParent "$staged_app" "$archive_path"

# Verify the exact bytes that will be sent, not only the staging bundle. This
# catches lost executable permissions and AppleDouble/Finder metadata that can
# otherwise make Finder show only “The application can’t be opened”.
/usr/bin/ditto -x -k "$archive_path" "$verification_dir"
[[ -x "$verified_app/Contents/MacOS/AICallAssistant" ]]
/usr/bin/lipo "$verified_app/Contents/MacOS/AICallAssistant" \
  -verify_arch arm64 x86_64
codesign --verify --all-architectures --deep --strict "$verified_app"
if [[ -n "$(find "$verification_dir" \
  \( -name __MACOSX -o -name '._*' \) -print -quit)" ]]; then
  print -u2 "error: archive contains AppleDouble metadata"
  exit 1
fi

# A read-only disk image is an alternative handoff when a messenger or cloud
# provider rewrites bundle metadata during ZIP extraction.
/usr/bin/ditto --noextattr "$staged_app" \
  "$dmg_source_dir/Callya.app"
/bin/ln -s /Applications "$dmg_source_dir/Applications"
/bin/rm -f -- "$dmg_path"
/usr/bin/hdiutil create \
  -fs HFS+ \
  -format UDZO \
  -volname "$dmg_volume_name" \
  -srcfolder "$dmg_source_dir" \
  "$dmg_path" >/dev/null
/usr/bin/hdiutil verify "$dmg_path" >/dev/null
/usr/bin/hdiutil attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "$dmg_mount_dir" \
  "$dmg_path" >/dev/null
dmg_attached=true
mounted_app="$dmg_mount_dir/Callya.app"
[[ -x "$mounted_app/Contents/MacOS/AICallAssistant" ]]
/usr/bin/lipo "$mounted_app/Contents/MacOS/AICallAssistant" \
  -verify_arch arm64 x86_64
codesign --verify --all-architectures --deep --strict "$mounted_app"
/usr/bin/hdiutil detach "$dmg_mount_dir" >/dev/null
dmg_attached=false

echo "$app_dir"
echo "$archive_path"
echo "$dmg_path"
