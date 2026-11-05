#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-cache}"
swift build --disable-sandbox -c release
binary_dir=$(swift build --disable-sandbox -c release --show-bin-path)
mkdir -p dist .build
staging=$(mktemp -d "$PWD/.build/app.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Setcheck.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/setcheck" "$app/Contents/MacOS/setcheck"
python3 scripts/bundle-runtime.py "$app"
swift scripts/make-icon.swift "$app/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY.md "$app/Contents/Resources/"
python3 - "$app" <<'PY'
import json,pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1])
runtime=json.loads((app/'Contents/Resources/ThirdParty/runtime.json').read_text())
info={'CFBundleIdentifier':'dev.archigene.setcheck','CFBundleName':'Setcheck','CFBundleDisplayName':'Setcheck',
'CFBundleExecutable':'setcheck','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1',
'CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':runtime['minimum_macos'],'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication',
'CFBundleDocumentTypes':[{'CFBundleTypeName':'DJ Playlist','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','CFBundleTypeExtensions':['nml','m3u','m3u8','xml']}]}
with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump(info,f)
PY
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
rm -rf "$PWD/dist/Setcheck.app"
mv "$app" "$PWD/dist/Setcheck.app"
printf 'Application: %s\n' "$PWD/dist/Setcheck.app"
