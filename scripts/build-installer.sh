#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
    "") scripts/build-app.sh ;;
    --skip-build) ;;
    *) printf 'Usage: %s [--skip-build]\n' "$0" >&2; exit 2 ;;
esac
app="$PWD/dist/Setcheck.app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
staging=$(mktemp -d "$PWD/.build/installer.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/root"
ditto --norsrc --noextattr --noacl "$app" "$staging/root/Setcheck.app"
pkgbuild --analyze --root "$staging/root" "$staging/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$staging/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleHasStrictIdentifier true' "$staging/components.plist"
package="$PWD/dist/Setcheck-${version}-macos-$(uname -m).pkg"
pkgbuild --root "$staging/root" --component-plist "$staging/components.plist" \
    --identifier dev.archigene.setcheck.installer --version "$version" \
    --install-location /Applications --ownership recommended --min-os-version "$minimum" "$package"
printf 'Installer: %s\nMinimum macOS: %s\n' "$package" "$minimum"
