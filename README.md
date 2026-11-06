# Optimized Previews for OBS Studio

An OBS Studio plugin for macOS, Windows, and Linux that replaces the OBS and
Vertical Canvas (Aitum) previews with read-only previews presented independently
of the OBS preview displays.

| Platform | Architectures | Renderer | Release packages |
|---|---|---|---|
| macOS 14+ | ARM64 and Intel x64 | OpenGL with IOSurface/Core Animation | Signed and notarized universal PKG |
| Windows | x64 and ARM64 | Direct3D 11 with asynchronous readback and Qt | EXE installer and ZIP for each architecture |
| Linux | x64 and ARM64 | OpenGL with asynchronous readback and Qt | TAR.GZ and DEB for each architecture |

Requires **OBS Studio 31.1.0 or later**. The plugin architecture must match the
architecture of **OBS**, including when running x64 OBS under emulation on
Windows ARM.

- **Optimized Preview:** the main, horizontal canvas.
- **Optimized Aitum Vertical Preview:** the “Aitum Vertical” canvas from Vertical
  Canvas, or another additional canvas you select.

The previews can replace the native previews in their existing slots or appear
in separate docks. They are read-only: sources cannot be selected or moved.
Vertical Canvas is optional; the horizontal preview works without it.

## Testing status

The following status reflects manual testing reported by the maintainer:

| Platform | Manual testing status |
|---|---|
| macOS ARM64 / Apple Silicon | The PKG has been tested successfully. |
| macOS Intel x64 | Not yet tested on an Intel Mac. The universal PKG includes the Intel build. |
| Windows x64 | Confirmed working correctly. |
| Windows ARM64 | Not yet tested manually. |
| Linux x64 and ARM64 | Not yet tested manually. |

The Intel, Windows ARM64, and Linux builds are available for testing. Earlier
build validation included macOS render checks against OBS 31.1.0 and 33.0.1,
an Intel build check under Rosetta, and Linux render checks using Mesa llvmpipe
in containers. These automated checks do not establish the manual installation
and real-world compatibility status of those platforms.

## Why

With the macOS OpenGL renderer, OBS presents each native preview inside its
graphics thread (`render_displays()` → `device_present()`: `glFlush`, context
switching, `glBlitFramebuffer`, and `[NSOpenGLContext flushBuffer]`). At 60 FPS,
that thread must deliver a frame every 16.67 ms. If presentation waits for the
window compositor, the frame can arrive late and OBS drops it.

Under demanding production workloads, including multitrack streaming,
recording, and multiple outputs, native previews have been observed to cause
several percentage points of rendering lag. Disabling those previews removed
that lag in the measured setup. Results depend on the workload and hardware.

## How it works

### macOS

```text
OBS graphics thread                          Main thread (Qt/AppKit)
──────────────────────────────────           ──────────────────────────
render_main_texture() for each mix           Preview CADisplayLink
 └ plugin's rendered callback                ├ reads the latest ready IOSurface
    ├ main canvas or vertical canvas?         │  (a very short lock; the graphics
    ├ custom shader: canvas texture ──►       │   thread only uses trylock)
    │  free IOSurface in an 8-slot ring       └ CALayer.contents = IOSurface
    ├ glFenceSync                                 (Core Animation composes it
    └ polls older fences with timeout 0:           outside OBS)
       publishes the newest completed frame
```

- Each preview is drawn **once per video frame**, in its own mix's callback,
  immediately after composition. No scene is rendered again.
- Scaling uses a single shader pass directly into the IOSurface, with bilinear
  filtering in linear space and four samples for reductions of 2:1 or greater.
  libobs IOSurface textures cannot be used as render targets, so the plugin
  uses its own FBOs and direct OpenGL calls, saving and restoring every state it
  changes. In the original measurements, this path took roughly one third of
  the CPU time of `glBlitFramebuffer` or drawing through an intermediate libobs
  texture.
- A surface is reused only after its fence has completed, when it is neither
  published nor displayed, and when `IOSurfaceIsInUse()` indicates that
  WindowServer has stopped composing it. If no surface is free, the plugin
  skips a preview frame rather than delaying OBS.
- The vertical canvas texture is identified without relying on its dimensions:
  Source Record and multitrack mixes can create textures of the same size.
  libobs-opengl sets `GL_TEXTURE_SRGB_DECODE_EXT` whenever it binds a texture
  for drawing. The plugin marks a candidate, draws the canvas into a 2×2 target
  through the public `obs_render_canvas_texture_src_color_only()` API, and
  checks whether the marker changed. Verification runs every five seconds and
  after a canvas `video_reset`.
- The main thread retains the strong reference to the vertical canvas.
  Releasing it in a graphics callback would deadlock `mixes_mutex`.

### Windows and Linux

Windows and Linux scale the already composed canvas texture, copy it through a
three-slot staging ring, and poll GPU completion without waiting. Qt presents
the latest completed image on its own thread. Publication uses `try_lock`, so
the graphics thread never waits for the Qt consumer.

This path includes a GPU-to-CPU copy. Readback is limited to a 1920×1080 bounding
box while preserving the aspect ratio and avoiding upscaling. The additional
canvas can have one extra frame of latency. The macOS IOSurface performance
measurements below apply specifically to that implementation.

The plugin does not modify OBS or other plugins. Rendering uses the public OBS
31.1.0+ API. Integration into native preview slots also relies on Qt widget
details; see [Limitations](#limitations).

## Requirements

- macOS 14 or later with the **OpenGL** renderer, Windows with **Direct3D 11**,
  or Linux with **OpenGL 3.3** and `ARB_sync` support.
- OBS Studio **31.1.0 or later**. Earlier versions lack the canvas API used by
  the plugin. With Metal on macOS, the previews display an unsupported-renderer
  message and do not render.
- Linux release binaries use Ubuntu 24.04 as their baseline: glibc 2.39,
  GCC 13's libstdc++, Qt 6.4, and libepoxy. Distributions with older libraries
  require a source build or a package built for that distribution.
- Optional: Vertical Canvas (Aitum) 1.6.x for the vertical preview.
- To build: CMake 3.28+, Xcode 16+ on macOS, Visual Studio 2022/2026 with the C++
  desktop workload on Windows, or GCC/Clang and Ninja on Linux.

## Installation

Download the appropriate package from
[GitHub Releases](https://github.com/Neotecos/obs-optimized-previews/releases).
Close OBS before installing or upgrading.

### macOS

Open the signed and notarized universal PKG. The same package includes Apple
Silicon and Intel binaries and installs the plugin for the current user:

```text
~/Library/Application Support/obs-studio/plugins/obs-optimized-previews.plugin
```

For manual installation, copy the built `.plugin` bundle to that directory.
The PKG has been tested successfully on ARM64; installation on Intel hardware
has not yet been verified.

### Windows

Run the EXE matching **your OBS architecture**. The default installation root is:

```text
C:\ProgramData\obs-studio\plugins
```

The installer creates an `obs-optimized-previews` directory containing the DLL
and resources. For portable OBS, select its `data/plugins` directory or extract
the matching ZIP there. OBS and the plugin require the Visual C++ runtime for
the corresponding architecture. The EXE installers are not Authenticode-signed.

Windows x64 has been confirmed working. Windows ARM64 has not yet been tested
manually.

### Linux

Linux packages have not yet been tested manually. Choose the package matching
your OBS architecture and ensure the system meets the library requirements.

**Per-user installation with native OBS:** extract the TAR.GZ into
`${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins`:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins"
tar -xzf obs-optimized-previews-1.0.0-linux-x64.tar.gz \
  -C "${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins"
```

Replace `x64` with `arm64` as appropriate. The archive contains:

```text
obs-optimized-previews/
├── bin/64bit/obs-optimized-previews.so
└── data/
    ├── locale/
    └── manifest.json
```

OBS and Qt are supplied by the system. The `64bit` directory name is also used
for ARM64; it does not identify an x64 binary.

**Debian/Ubuntu and derivatives:** install the appropriate DEB with:

```sh
sudo apt install ./obs-optimized-previews_1.0.0_amd64.deb
# For ARM64, use obs-optimized-previews_1.0.0_arm64.deb instead.
```

The DEB installs the module in `/usr/lib/obs-plugins` and its resources in
`/usr/share/obs/obs-plugins/obs-optimized-previews`. `apt` checks the package's
dependencies. Avoid installing both the per-user archive and the DEB.

**OBS Flatpak:** requires an extension built for OBS's Flathub runtime. These
native packages are not Flatpak extensions. Publishing a Flathub extension is a
separate process; see the [official OBS plugin guide](https://obsproject.com/kb/plugins-guide).

## Uninstallation

- **Windows:** use Installed apps → Optimized Previews for OBS Studio.
- **Linux DEB:** run `sudo apt remove obs-optimized-previews`.
- **Linux TAR.GZ:** remove
  `${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins/obs-optimized-previews`.

On macOS, with OBS closed:

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugins/obs-optimized-previews.plugin
```

Preferences are preserved. To remove the macOS preferences as well:

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugin_config/obs-optimized-previews
```

## Configuration

### Replacing native previews

Right-click the OBS or Vertical Canvas preview and select **Use optimized
preview (read-only)**. The plugin disables the native preview and places its
own preview in the same slot. Uncheck the same option to restore the native
preview.

- The OBS preview is disabled through `obs_frontend_set_preview_enabled()`.
  Vertical Canvas uses its public Show/Hide Preview hotkeys, which are also
  accessible through obs-websocket.
- The preference is saved and reapplied when OBS starts.
- The horizontal replacement is unavailable in Studio Mode because OBS does
  not allow that preview to be disabled there. The native preview reappears
  while Studio Mode is active.
- Re-enabling the native preview through another mechanism, such as a hotkey,
  hides and stops the plugin preview. The preference remains saved for the
  next OBS launch.

### Automatic switching

Open **Tools → Optimized previews…**. Four options are available, all disabled
by default:

- Switch to the optimized preview when streaming starts.
- Switch to the optimized preview when recording starts.
- Switch back to the native preview when streaming stops.
- Switch back to the native preview when recording stops.

These settings apply to both previews. Native previews are restored only when
no OBS stream or recording remains active, to avoid reintroducing rendering
lag into an ongoing output. Vertical Canvas's own streaming and recording
outputs do not trigger these switches.

### Separate docks

Open **Docks → Optimized Preview** and **Docks → Optimized Aitum Vertical
Preview** to use separate docks. This is also the fallback if a future OBS or
Vertical Canvas update changes the native integration. Disable the native
previews manually in that case. A dock displays a placeholder while its preview
is embedded in the native slot.

### Preview options and saved settings

Right-click a plugin preview to choose:

- **Use optimized preview (read-only):** replace the corresponding native preview.
- **Frame rate limit:** the OBS frame rate, 60, 30, or 20 FPS.
- **Canvas:** select the additional canvas for the vertical preview.

Settings are stored in `plugin_config/obs-optimized-previews/settings.json`
inside the OBS configuration directory. On macOS, the full path is:

```text
~/Library/Application Support/obs-studio/plugin_config/obs-optimized-previews/settings.json
```

A hidden preview stops rendering. Resources can be released after ten seconds
of inactivity.

## Building and packaging

Release builds use the **OBS 31.1.0 SDK** and the official OBS dependencies from
**May 23, 2025**. macOS and Windows download the dependencies and verify SHA-256
hashes. SDKs and build directories are isolated by architecture. Local test
programs are disabled by default.

### macOS universal PKG

```sh
export CODESIGN_IDENT="Developer ID Application: Your Name (TEAMID)"
export PKG_SIGN_IDENT="Developer ID Installer: Your Name (TEAMID)"
# Optional: an existing notarytool credentials profile in your keychain.
export NOTARY_PROFILE="your-profile"
packaging/package-macos.sh
```

The script builds and verifies both architectures, signs the plugin and PKG,
and, when `NOTARY_PROFILE` is set, submits the installer to Apple, waits for
acceptance, and staples the ticket. Without that profile, the PKG is signed but
not notarized. Published PKG releases are notarized.

For development, use `cmake --preset macos` followed by
`cmake --build --preset macos`. The `macos-x64` and `macos-universal` presets
are also available.

### Windows installers

Use PowerShell with the Windows 10.0.20348+ SDK, the C++ tools for the target
architecture, and Inno Setup 6.4+ installed:

```powershell
./packaging/package-windows.ps1 -Architecture x64
./packaging/package-windows.ps1 -Architecture arm64
```

Each invocation generates an EXE installer and a ZIP. Matching x64 Qt host tools
are downloaded automatically for the ARM64 Qt package.

### Linux packages

Build in the reproducible Ubuntu 24.04 environment:

```sh
docker build -t op-linux-sdk -f packaging/linux.Dockerfile packaging
docker run --rm -v "$PWD:/work" op-linux-sdk packaging/package-linux.sh
```

Use an ARM64 host for ARM64 or an x64 host for x64. With Docker Desktop, add
`--platform linux/arm64` or `--platform linux/amd64` to **both** commands to
build under emulation.

With the OBS SDK, Qt 6, libepoxy, and Ninja already installed, run
`packaging/package-linux.sh`, optionally passing
`-DCMAKE_PREFIX_PATH=/path/to/sdk`. The script creates both TAR.GZ and DEB files.

### Continuous integration and release documentation

All generated packages are placed in `release/`. The
[Release builds workflow](.github/workflows/release-builds.yml) builds all five
targets and stores CI artifacts. Its manual dispatch can select one platform.
PKG signing and notarization run locally using the keychain; private signing
keys are not uploaded to CI. Publishing the GitHub release is a separate step.

See the [changelog](CHANGELOG.md) and [v1.0.0 release notes](docs/releases/v1.0.0.md)
for release details and the manual testing status.

### Local test programs

Enable available macOS test programs with `-DOP_BUILD_TESTS=ON`. They use libobs
and OpenGL from `/Applications/OBS.app`, initialize libobs without the OBS UI,
and do not read OBS profiles. **Do not run GPU tests while OBS is streaming:**
the renderer, dock, and copy probes add GPU load. Test-only files are local
development resources and are excluded from new commits.

| Program | Coverage |
|---|---|
| `op-render-test` | Orientation, sRGB color, dimensions, vertical canvas identification, `video_reset`, frame rate limits, canvas removal, and callback cost. |
| `op-dock-test` | A real Qt preview window, display link behavior, IOSurface ownership, undocking, latency, and presentation cadence. |
| `op-copy-probe` | Graphics-thread cost of alternative texture copy paths. |
| `op-integration-test` | Native-slot and context-menu integration using representative OBS and Vertical Canvas widgets. |
| `op-version-compare-test` | Release version comparison and update-response handling. |

With the `macos` preset, executables are placed in `build_macos/RelWithDebInfo/`.

## Measurement

The macOS OBS profiler includes `op_rendered_callback`, `op_poll`,
`op_preview_main`, `op_preview_vertical`, `op_verify_vertical_texture`, and
`op_recreate_surfaces`. With native previews disabled, `render_displays`
should take very little time.

At shutdown, the plugin logs published frames, skipped frames, mean and maximum
presentation latency, presented frames, superseded frames, and gaps exceeding
1.5 frame intervals. On a 144 Hz display, 60 FPS video naturally alternates
between two and three display refreshes per frame; a 120 Hz display can show
each frame for exactly two refreshes.

Original macOS measurements on an Apple M4 Max, with a 2560×1440 main canvas
and a 1080×1920 vertical canvas, without a production OBS workload:

| Measurement | Result |
|---|---:|
| Median callback cost | 20–25 µs |
| p99 callback cost | 0.17–0.47 ms |
| Mean latency to Core Animation | 19–22 ms |

## Limitations

- macOS and Linux require OpenGL; Windows requires Direct3D 11. Metal previews
  on macOS are unsupported.
- The macOS IOSurface path is SDR. HDR canvases are not tone-mapped in the same
  way as the native OBS preview.
- Previews are read-only: there are no source selection handles, guides,
  safe areas, or Studio Mode editing controls.
- macOS scaling uses bilinear filtering with four samples for reductions of
  2:1 or greater. Windows and Linux also incur a CPU readback cost and have a
  1920×1080 readback bounding box.
- On macOS, vertical texture identification relies on libobs-opengl's sRGB
  binding behavior. If that changes, the vertical preview can stop rendering
  while OBS continues working normally.
- The original macOS path adds roughly 1–1.5 video frames of latency plus the
  display refresh. Additional latency is possible on the portable path.
- Native-slot integration depends on internal Qt widget names, classes, and
  context-menu behavior in OBS 33 and Vertical Canvas 1.6.x. If these change,
  the menu option may disappear and the plugin previews remain in their docks.
- OBS has an internal race during canvas resolution changes:
  `obs_canvas_reset_video()` resets `canvas->mix` outside the mutex. The macOS
  path avoids reading that mix every frame, but occasional verification uses
  the same API as the Vertical Canvas preview.
- Manual verification remains pending for Intel macOS, Windows ARM64, and Linux;
  see [Testing status](#testing-status).

## License

GPL-2.0 or later, like OBS Studio. Based on
[obs-plugintemplate](https://github.com/obsproject/obs-plugintemplate).
