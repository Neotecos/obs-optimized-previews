#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case $(uname -m) in
  x86_64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'Only x64 and ARM64 are supported' >&2; exit 1 ;;
esac
version=$(python3 -c 'import json; print(json.load(open("buildspec.json"))["version"])')
build="build_linux-$arch"
cmake --preset "linux-$arch" -DOP_BUILD_TESTS=OFF "$@"
cmake --build --preset "linux-$arch" --parallel
cmake --install "$build" --prefix "$PWD/$build/stage/usr"
# Keep CPack's temporary tree private to this architecture; x64 and ARM64
# packaging may run concurrently in the same checkout.
mkdir -p release
cpack --config "$build/CPackConfig.cmake" -G DEB -B "$PWD/$build/packages"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
plugin="$root/obs-optimized-previews"
mkdir -p "$plugin/bin/64bit" "$plugin/data" release
cp "$build/stage/usr/lib/obs-plugins/obs-optimized-previews.so" "$plugin/bin/64bit/"
cp -R data/locale "$plugin/data/"
cp "$build/manifest.json" "$plugin/data/"
cp LICENSE "$plugin/data/"
archive="release/obs-optimized-previews-$version-linux-$arch.tar.gz"
tar -czf "$archive" -C "$root" obs-optimized-previews
sha256sum "$archive" > "$archive.sha256"
