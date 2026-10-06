#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/dist/PreviewMD.app"
contents_dir="$app_dir/Contents"
legal_dir="$contents_dir/Resources/Legal"
quicklook_dir="$contents_dir/PlugIns/PreviewMDQuickLook.appex"
quicklook_contents_dir="$quicklook_dir/Contents"
quicklook_build_dir="$project_dir/.build/quicklook"
quicklook_source="$project_dir/Sources/PreviewMDQuickLook/PreviewViewController.swift"
iconset_dir="$project_dir/.build/AppIcon.iconset"
master_icon="$project_dir/.build/AppIcon-1024.png"
signing_identity="${PREVIEWMD_SIGNING_IDENTITY:-}"

cd "$project_dir"

export SDKROOT="${PREVIEWMD_SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"

build_options=(-c release --arch arm64 --arch x86_64 --disable-sandbox)
swift build "${build_options[@]}"
# SwiftPM's output directory differs between toolchain/build-system versions.
# Ask the same build configuration instead of accidentally packaging an older
# product left in .build/apple/Products/Release.
build_dir="$(swift build "${build_options[@]}" --show-bin-path)"
for architecture in arm64 x86_64; do
  lipo "$build_dir/PreviewMD" -verify_arch "$architecture"
done

rm -rf "$app_dir" "$quicklook_build_dir"
mkdir -p \
  "$contents_dir/MacOS" \
  "$contents_dir/Resources" \
  "$legal_dir" \
  "$quicklook_contents_dir/MacOS" \
  "$quicklook_contents_dir/Resources" \
  "$quicklook_build_dir"

cp "$build_dir/PreviewMD" "$contents_dir/MacOS/PreviewMD"
cp -R "$build_dir/PreviewMD_PreviewMD.bundle" "$contents_dir/Resources/PreviewMD_PreviewMD.bundle"

cp "scripts/Info.plist" "$contents_dir/Info.plist"
cp "LICENSE" "$legal_dir/LICENSE"
cp "NOTICE" "$legal_dir/NOTICE"
cp "THIRD_PARTY_NOTICES.md" "$legal_dir/THIRD_PARTY_NOTICES.md"

for architecture in arm64 x86_64; do
  xcrun swiftc \
    -sdk "$SDKROOT" \
    -target "$architecture-apple-macos14.0" \
    -module-name PreviewMDQuickLook \
    -application-extension \
    -parse-as-library \
    -O \
    -module-cache-path "$project_dir/.build/ModuleCache" \
    "$quicklook_source" \
    -emit-executable \
    -o "$quicklook_build_dir/PreviewMDQuickLook-$architecture" \
    -framework AppKit \
    -framework Quartz \
    -framework WebKit \
    -Xlinker -e \
    -Xlinker _NSExtensionMain
done

lipo -create \
  "$quicklook_build_dir/PreviewMDQuickLook-arm64" \
  "$quicklook_build_dir/PreviewMDQuickLook-x86_64" \
  -output "$quicklook_contents_dir/MacOS/PreviewMDQuickLook"
chmod +x "$quicklook_contents_dir/MacOS/PreviewMDQuickLook"

cp "scripts/QuickLook-Info.plist" "$quicklook_contents_dir/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$contents_dir/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$contents_dir/Info.plist")"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $version" \
  "$quicklook_contents_dir/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion $build_number" \
  "$quicklook_contents_dir/Info.plist"
mkdir -p "$quicklook_contents_dir/Resources/Renderer"
for renderer_file in \
  auto-render.min.js \
  highlight.min.js \
  katex.min.css \
  katex.min.js \
  markdown-it-footnote.min.js \
  markdown-it.min.js \
  mermaid.min.js \
  renderer.css \
  renderer.js; do
  cp \
    "$project_dir/Sources/PreviewMD/Resources/Renderer/$renderer_file" \
    "$quicklook_contents_dir/Resources/Renderer/$renderer_file"
done
ditto \
  "$project_dir/Sources/PreviewMD/Resources/Renderer/fonts" \
  "$quicklook_contents_dir/Resources/Renderer/fonts"

rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"
swift "scripts/render-icon.swift" "$master_icon"
for size in 16 32 128 256 512; do
  double_size=$((size * 2))
  sips -z "$size" "$size" "$master_icon" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  sips -z "$double_size" "$double_size" "$master_icon" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
swift "scripts/build-icns.swift" "$iconset_dir" "$contents_dir/Resources/AppIcon.icns"

chmod +x "$contents_dir/MacOS/PreviewMD"

if [[ -n "$signing_identity" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$project_dir/scripts/QuickLook.entitlements" \
    --sign "$signing_identity" \
    "$quicklook_dir"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$app_dir"
  echo "Built and signed $app_dir"
else
  codesign \
    --force \
    --entitlements "$project_dir/scripts/QuickLook.entitlements" \
    --sign - \
    "$quicklook_dir"
  codesign --force --sign - "$app_dir"
  echo "Built $app_dir with an ad-hoc signature"
fi
