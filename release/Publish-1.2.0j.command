#!/bin/bash
# Sign the prepared NormalSwitcher beta with the existing Apple identity and publish the verified DMG.
set -euo pipefail
version=1.2.0j
repository=https://github.com/Thalassiochthon/NormalSwitcher
source_commit=c3fb1d4a9a1a46e4239cbade449db6b8cd39996a
archive_hash=c7e75fa04429c9bd538874123a4a1cd335a0914e70732c4edf07faf57935601c
archive_name="NormalSwitcher-$version-for-signing.zip"
identity='Apple Development: antonjas@yandex.ru (29Y32MP5DM)'
output_dir="$(cd "$(dirname "$0")" && pwd)"
asset="$output_dir/NormalSwitcher-$version.dmg"
work="$(mktemp -d "${TMPDIR:-/tmp}/normalswitcher-publish.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "NormalSwitcher $version · подпись и публикация беты"
export GIT_TERMINAL_PROMPT=0
git clone --quiet --depth=2 --single-branch --branch "release/macos-$version" "$repository.git" "$work/src"
cd "$work/src"
cp "release/$archive_name" "$work/$archive_name"
git checkout --quiet --detach "$source_commit"
printf '%s  %s\n' "$archive_hash" "$work/$archive_name" | shasum -a 256 -c -
ditto -x -k "$work/$archive_name" macos
app=macos/NormalSwitcher.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = 86
if [[ -f "$asset" ]]; then
    # On a retry, publish exactly the disk image previously verified here.
    (cd "$output_dir" && shasum -a 256 -c "NormalSwitcher-$version.dmg.sha256")
else
    codesign --force --sign "$identity" --options runtime --entitlements macos/RuSwitcher.entitlements "$app"
    bash macos/package_beta.sh "$output_dir"
    (cd "$output_dir" && shasum -a 256 "NormalSwitcher-$version.dmg" > "NormalSwitcher-$version.dmg.sha256")
fi
# The project publisher uses the existing GitHub login. Keep the verified DMG for retry.
python3 scripts/publish_macos_beta.py "$asset"
echo "Бета опубликована: $repository/releases/tag/v$version"
