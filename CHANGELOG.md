# Changelog

## 1.0.0 — 2026-11-06

First stable release of Optimized Previews for OBS Studio 31.1.0 and later.

- Read-only previews of the main canvas and a selected additional canvas,
  including Aitum Vertical, in native preview slots or separate docks.
- Automatic switching when OBS starts or stops streaming or recording.
- Per-preview frame rate limits, saved preferences, and update checks.
- macOS ARM64 and Intel x64 in one signed and notarized universal PKG.
- Windows x64 and ARM64 EXE installers.
- Linux x64 and ARM64 TAR.GZ archives and Debian/Ubuntu DEB packages.
- English project documentation and explicit platform testing status.

### Manual testing status

- **macOS ARM64:** the PKG has been tested successfully.
- **Windows x64:** confirmed working correctly.
- **macOS Intel x64:** not yet tested on Intel hardware.
- **Windows ARM64:** not yet tested manually.
- **Linux x64 and ARM64:** not yet tested manually.

Earlier automated and emulated checks are described in the README. Packages for
platforms awaiting manual testing are included for users who wish to test them.

## 0.1.0

Initial development builds, macOS IOSurface rendering, native preview
integration, and cross-platform rendering and packaging work.
