# Optimized Previews for OBS Studio

Lighter, read-only previews for OBS Studio and Aitum Vertical, designed to reduce
the overhead of their native previews while streaming or recording.

## How it works

The plugin displays the image OBS has already produced, without rendering your
scenes again. You can replace the native previews in their usual positions or
open the optimized previews in separate docks:

- **Optimized Preview:** your main OBS canvas.
- **Optimized Aitum Vertical Preview:** your Aitum Vertical canvas, or another
  additional canvas you select.

The previews are for viewing only; switch back to the native preview to select
or move sources. Aitum Vertical is optional if you only need the main preview.

## Why use it?

Drawing the native OBS and Aitum Vertical previews adds work alongside your
stream or recording. Under heavy load, that overhead can contribute to rendering
lag and missed frames.

Optimized Previews provides a lighter way to keep watching both canvases while
disabling the native previews. The benefit depends on your hardware and workload;
the original improvements were measured on macOS.

## Configuration

### Replace the native previews

Right-click the OBS or Aitum Vertical preview and enable **Use optimized preview
(read-only)**. The plugin disables that native preview and takes its place.
Uncheck the same option to restore the native preview. Your choice is saved.

The horizontal replacement pauses while OBS is in Studio Mode, which requires
the native preview.

### Use separate docks

Open **Docks → Optimized Preview** or **Docks → Optimized Aitum Vertical Preview**.
Disable the corresponding native preview manually to avoid running both at once.

### Choose the frame rate and canvas

Right-click an optimized preview to access its options:

| Option | What it does |
|---|---|
| **Frame rate limit** | Follow the OBS frame rate, or limit the preview to 60, 30, or 20 FPS. A lower limit reduces preview work. |
| **Canvas** | Choose which additional canvas the vertical preview displays. |

These choices are saved automatically. Hidden previews stop rendering.

### Switch automatically

In **Tools → Optimized previews…**, choose when to switch previews:

- Use optimized previews when streaming starts.
- Use optimized previews when recording starts.
- Restore native previews when streaming stops.
- Restore native previews when recording stops.

All four options are off by default and apply to both previews. Native previews
are restored only when no OBS stream or recording remains active. Aitum
Vertical's own streaming and recording outputs do not trigger these switches.

### Check for updates

The same Tools dialog lets you enable **Check for updates when OBS starts** or
check manually. Updates are downloaded and installed by the user.

## Compatibility and testing

Requires **OBS Studio 31.1.0 or later**. For the vertical preview, Aitum Vertical
1.6.x is optional; other additional canvases can also be selected.

| Platform | Package | Manual testing status |
|---|---|---|
| macOS ARM64 / Apple Silicon | Universal PKG | PKG tested successfully. |
| macOS Intel x64 | Same universal PKG | Not yet tested on an Intel Mac. |
| Windows x64 | x64 installer | Confirmed working correctly. |
| Windows ARM64 | ARM64 installer | Not yet tested manually. |
| Linux x64 and ARM64 | TAR.GZ or DEB for each architecture | Not yet tested manually. |

macOS requires version 14 or later and the **OpenGL** renderer; **Metal is not
supported**. Windows requires **Direct3D 11**. Linux requires **OpenGL 3.3** with
`ARB_sync` support.

Choose the architecture matching **OBS**, including when running x64 OBS under
emulation on Windows ARM. The builds awaiting manual testing are available for
users who wish to try them.

Earlier automated checks covered macOS with OBS 31.1.0 and 33.0.1, Intel execution
under Rosetta, and Linux rendering in containers with Mesa llvmpipe. Manual
installation and real-world verification remain pending where indicated above.

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

### Windows

Run the EXE matching **your OBS architecture**. The default installation root is:

```text
C:\ProgramData\obs-studio\plugins
```

The installer creates an `obs-optimized-previews` directory containing the DLL
and resources. For portable OBS, select its `data/plugins` directory. OBS and
the plugin require the Visual C++ runtime for the corresponding architecture. The EXE installers are not Authenticode-signed.

### Linux

Choose the package matching your OBS architecture. Release binaries use Ubuntu
24.04 as their baseline: glibc 2.39, GCC 13's libstdc++, Qt 6.4, and libepoxy.
Distributions with older libraries require a source build or a package built
for that distribution.

**Per-user installation with native OBS:** extract the TAR.GZ into
`${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins`:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins"
tar -xzf obs-optimized-previews_1.0.0_linux-amd64.tar.gz \
  -C "${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins"
```

Replace `amd64` with `arm64` as appropriate. The archive contains:

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
sudo apt install ./obs-optimized-previews_1.0.0_linux-amd64.deb
# For ARM64, use obs-optimized-previews_1.0.0_linux-arm64.deb instead.
```

The DEB installs the module in `/usr/lib/obs-plugins` and its resources in
`/usr/share/obs/obs-plugins/obs-optimized-previews`. `apt` checks the package's
dependencies. Avoid installing both the per-user archive and the DEB.

**OBS Flatpak:** requires an extension built for OBS's Flathub runtime. These
native packages are not Flatpak extensions. Publishing a Flathub extension is a
separate process; see the [official OBS plugin guide](https://obsproject.com/kb/plugins-guide).

## Limitations

- Previews are read-only. Source editing, guides, and safe areas remain in the
  native previews, and the horizontal replacement is unavailable in Studio Mode.
- The macOS preview is SDR; HDR canvases are not tone-mapped like the native OBS
  preview. Metal on macOS is unsupported.
- Preview presentation adds some latency. On Windows and Linux, the image is
  limited to a 1920×1080 bounding box while preserving its aspect ratio.
- Native-slot integration can be affected by OBS or Aitum Vertical updates. If
  the option disappears, use the separate docks and disable the native previews.
- If a hotkey or another control re-enables a native preview, the optimized
  replacement stops displaying. Its saved preference is reapplied on the next
  OBS launch.

## Uninstallation

- **Windows:** use Installed apps → Optimized Previews for OBS Studio.
- **Linux DEB:** run `sudo apt remove obs-optimized-previews`.
- **Linux TAR.GZ:** remove
  `${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins/obs-optimized-previews`.

On macOS, with OBS closed:

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugins/obs-optimized-previews.plugin
```

Preferences are preserved in `plugin_config/obs-optimized-previews/settings.json`
inside the OBS configuration directory. To remove the macOS preferences as well:

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugin_config/obs-optimized-previews
```

## Technical details

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
the latest completed image on the main thread. Publication uses `try_lock`, so
the graphics thread never waits for the Qt consumer.

This path includes a GPU-to-CPU copy. Readback is limited to a 1920×1080 bounding
box while preserving the aspect ratio and avoiding upscaling. The additional
canvas can have one extra frame of latency. The macOS IOSurface performance
measurements below apply specifically to that implementation.

The plugin does not modify OBS or other plugins. Rendering uses the public OBS
31.1.0+ API. Integration into native preview slots also relies on Qt widget
details; see [Limitations](#limitations).

### Implementation notes

- macOS uses bilinear scaling with four samples for reductions of 2:1 or greater.
  Its original presentation path adds roughly 1–1.5 video frames of latency plus
  the display refresh. The Windows/Linux path can add further latency and incurs
  a GPU-to-CPU copy.
- Native-slot integration depends on internal Qt widget names, classes, and
  context-menu behavior in OBS 33 and Vertical Canvas 1.6.x. Separate docks are
  the fallback if these details change.
- macOS vertical texture identification relies on libobs-opengl's sRGB binding
  behavior. If that changes, the vertical preview can stop rendering while OBS
  continues working normally.
- OBS has an internal race during canvas resolution changes:
  `obs_canvas_reset_video()` resets `canvas->mix` outside the mutex. The macOS
  path avoids reading that mix every frame, but occasional verification uses
  the same API as the Vertical Canvas preview.
- Hidden previews can release their graphics resources after ten seconds of
  inactivity.

### Performance and diagnostics

With the macOS OpenGL renderer, OBS presents native previews inside its
graphics thread (`render_displays()` → `device_present()`: `glFlush`, context
switching, `glBlitFramebuffer`, and `[NSOpenGLContext flushBuffer]`). At 60 FPS,
that thread must deliver a frame every 16.67 ms. Waiting for the compositor can
make a frame arrive late.

In the original demanding production setup, native previews caused several
percentage points of rendering lag; disabling them removed that lag. Results
depend on the workload and hardware.

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

## License

GPL-2.0 or later, like OBS Studio. Based on
[obs-plugintemplate](https://github.com/obsproject/obs-plugintemplate).
