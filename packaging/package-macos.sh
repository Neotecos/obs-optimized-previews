#!/bin/bash
# Build and package both macOS architectures. The two signing identities are
# mandatory for a distributable release; no silently ad-hoc signed PKG.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CODESIGN_IDENT:?Set CODESIGN_IDENT to a Developer ID Application identity}"
: "${PKG_SIGN_IDENT:?Set PKG_SIGN_IDENT to a Developer ID Installer identity}"
version=$(python3 -c 'import json; print(json.load(open("buildspec.json"))["version"])')
build=build_macos-universal
cmake --preset macos-universal -DCODESIGN_IDENTITY="$CODESIGN_IDENT" -DOP_BUILD_TESTS=OFF
cmake --build --preset macos-universal --parallel
bundle="$build/Release/obs-optimized-previews.plugin"
lipo "$bundle/Contents/MacOS/obs-optimized-previews" -verify_arch arm64
lipo "$bundle/Contents/MacOS/obs-optimized-previews" -verify_arch x86_64
codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENT" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/payload/Library/Application Support/obs-studio/plugins" release
ditto "$bundle" "$root/payload/Library/Application Support/obs-studio/plugins/obs-optimized-previews.plugin"
pkgbuild --analyze --root "$root/payload" "$root/components.plist"
python3 - "$root/components.plist" <<'PYCOMPONENTS'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as stream:
    components = plistlib.load(stream)
for component in components:
    component['BundleIsRelocatable'] = False
with open(path, 'wb') as stream:
    plistlib.dump(components, stream)
PYCOMPONENTS
pkgbuild --component-plist "$root/components.plist" --identifier com.alekstyle.obs.optimized-previews --version "$version" \
  --root "$root/payload" --install-location / "$root/component.pkg"
# User-domain package installs Library/ relative to the user's home.
cat > "$root/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1.0">
  <title>Optimized Previews</title>
  <options hostArchitectures="arm64,x86_64" customize="never" allow-external-scripts="no"/>
  <domains enable_currentUserHome="true" enable_localSystem="false" enable_anywhere="false"/>
  <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
  <choices-outline><line choice="plugin"/></choices-outline>
  <choice id="plugin" visible="false"><pkg-ref id="com.alekstyle.obs.optimized-previews"/></choice>
  <pkg-ref id="com.alekstyle.obs.optimized-previews" version="$version">component.pkg</pkg-ref>
</installer-gui-script>
XML
output="release/obs-optimized-previews-$version-macos-universal.pkg"
productbuild --distribution "$root/distribution.xml" --package-path "$root" --sign "$PKG_SIGN_IDENT" "$output"
pkgutil --check-signature "$output"
# Credentials stay in the keychain, never in the repository or build logs.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$output" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$output"
  xcrun stapler validate "$output"
fi
shasum -a 256 "$output" > "$output.sha256"
