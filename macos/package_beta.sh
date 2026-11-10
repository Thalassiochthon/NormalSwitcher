#!/bin/bash
set -euo pipefail
# Package a signed app using a file-based HFS image; no device mount is required.
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
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/contents"
ditto "$app" "$staging/contents/NormalSwitcher.app"
ln -s /Applications "$staging/contents/Applications"
hdiutil makehybrid -hfs -hfs-volume-name NormalSwitcher -o "$staging/raw.dmg" "$staging/contents"
hdiutil convert "$staging/raw.dmg" -format UDZO -o "$asset"
hdiutil verify "$asset"
shasum -a 256 "$asset"
