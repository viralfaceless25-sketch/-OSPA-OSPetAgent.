#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-release}
app_dir="$project_dir/build/AvatarCompanion.app"

cd "$project_dir"
swift build -c "$configuration"
binary_dir=$(swift build -c "$configuration" --show-bin-path)

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/AvatarCompanion" "$app_dir/Contents/MacOS/AvatarCompanion"
cp "$project_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"

xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
