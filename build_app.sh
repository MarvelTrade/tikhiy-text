#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h}
build_dir="$root_dir/.build"
app_dir="$build_dir/Тихий Текст.app"
icon_png="$build_dir/icon-1024.png"
iconset="$build_dir/AppIcon.iconset"

cd "$root_dir"
swift build -c release

rm -rf "$app_dir" "$iconset"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$iconset"
cp "$build_dir/release/TikhiyText" "$app_dir/Contents/MacOS/TikhiyText"
cp "$root_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

swift "$root_dir/Scripts/make_icon.swift" "$icon_png"
for spec in '16 icon_16x16.png' '32 icon_16x16@2x.png' '32 icon_32x32.png' '64 icon_32x32@2x.png' '128 icon_128x128.png' '256 icon_128x128@2x.png' '256 icon_256x256.png' '512 icon_256x256@2x.png' '512 icon_512x512.png' '1024 icon_512x512@2x.png'; do
    pixels=${spec%% *}; name=${spec#* }
    sips -z "$pixels" "$pixels" "$icon_png" --out "$iconset/$name" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
