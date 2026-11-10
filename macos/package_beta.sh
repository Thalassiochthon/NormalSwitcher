#!/bin/bash
set -euo pipefail
# Verify the signed app again on the read-only volume used by the updater.
project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:?Usage: package_beta.sh OUTPUT_DIRECTORY}"
version=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$project_dir/../release/macos-beta.json")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]$ ]] || exit 2
app="$project_dir/NormalSwitcher.app"
requirement='anchor apple generic and certificate leaf[subject.OU] = "HDFDUW2PQ7"'
codesign --verify --deep --strict -R="$requirement" "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = com.antonjas.normalswitcher
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
mkdir -p "$output_dir"
asset="$output_dir/NormalSwitcher-$version.dmg"
test ! -e "$asset"
staging=$(mktemp -d "${TMPDIR:-/tmp/}normalswitcher-beta.XXXXXX")
mount_point="$staging/mount"
mounted=false
cleanup() {
    if $mounted; then
        hdiutil detach "$mount_point" -quiet || return
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
mkdir "$staging/contents"
ditto "$app" "$staging/contents/NormalSwitcher.app"
ln -s /Applications "$staging/contents/Applications"
# makehybrid injects FinderInfo attributes that strict code signing rejects.
image="$staging/NormalSwitcher.dmg"
hdiutil create -volname NormalSwitcher -srcfolder "$staging/contents" -format UDZO "$image"
hdiutil verify "$image"
hdiutil attach "$image" -nobrowse -readonly -mountpoint "$mount_point"
mounted=true
codesign --verify --deep --strict -R="$requirement" "$mount_point/NormalSwitcher.app"
hdiutil detach "$mount_point" -quiet
mounted=false
mv -n "$image" "$asset"
test ! -e "$image"
shasum -a 256 "$asset"
