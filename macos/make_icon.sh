#!/bin/bash
# Иконка приложения из мастер-картинки 1024×1024: macos/icon-1024.png (дизайн kutawhat, #39;
# исходник в Figma — ссылка в #39). Делает набор размеров, RuSwitcher.icns (его берёт
# build_app.sh и create_dmg.sh), картинки AppIcon в Assets.xcassets и icon.png для README.
#   macos/make_icon.sh
set -euo pipefail
cd "$(dirname "$0")"
SRC=icon-1024.png
[ "$(sips -g pixelWidth "$SRC" | awk '/pixelWidth/{print $2}')" = 1024 ] || { echo "нужен $SRC 1024×1024" >&2; exit 1; }

rm -rf RuSwitcher.iconset && mkdir RuSwitcher.iconset
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$SRC" --out "RuSwitcher.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$SRC" --out "RuSwitcher.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns RuSwitcher.iconset -o RuSwitcher.icns
for s in 16 32 64 128 256 512 1024; do
    sips -z "$s" "$s" "$SRC" --out "Assets.xcassets/AppIcon.appiconset/icon_$s.png" >/dev/null
done
sips -z 256 256 "$SRC" --out icon.png >/dev/null
echo "готово: RuSwitcher.icns, RuSwitcher.iconset, Assets.xcassets, icon.png"
