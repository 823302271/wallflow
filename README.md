# Wallflow

[English](README.md) | [简体中文](README.zh-CN.md)

Wallflow is an early native macOS interactive wallpaper renderer. The current
prototype focuses on low-overhead native video and Metal rendering plus
Wallpaper Engine web and scene compatibility.

> [!IMPORTANT]
> Wallflow is under active development. It does not yet provide full Wallpaper
> Engine compatibility; check the compatibility sections below before opening
> a project.

## Requirements

- macOS 13 Ventura or later
- Swift 5.10 or later (Xcode or Apple Command Line Tools)
- Apple Silicon Mac; Intel and Universal builds are intentionally unsupported

## Current prototype

- AppKit desktop-level windows on every display
- Metal-rendered animation with no CPU-side particle simulation
- Global cursor tracking without intercepting desktop clicks
- Smooth cursor parallax, bending lines, and interaction ripples
- Adaptive 60 FPS while interacting and 24 FPS while idle
- 75% logical render scale to reduce fill-rate cost on Retina displays
- Two-buffer Metal swap chain instead of the default three-buffer allocation
- Rendering suspension when a foreground window covers an entire display
- Automatic suspension during sleep and inactive login sessions
- Incremental display reconciliation without restarting retained-screen renderers
- Static Wallflow fallback frames during full-screen and Space transitions
- Menu bar pause and resume controls
- Default-on pause when another application has a visible window
- Runtime language switching between English and Simplified Chinese
- Native MP4, M4V, and MOV playback through AVFoundation
- Project import from a video, directory, `project.json`, `index.html`, or `scene.pkg`

## Native video wallpapers

MP4 does **not** need to be converted to HTML. Wallflow opens MP4, M4V, and MOV
files directly through AVFoundation, uses the system hardware video decoder when
available, loops playback natively, and does not start a WebKit process for a
video wallpaper. Local files, Finder drag and open, HTTP(S) video URLs, and a
Wallpaper Engine-style `project.json` with `"type": "video"` are supported.

Playback buffers are kept short and decoding is capped at 1920 x 1080 to limit
memory, GPU, and energy use. Higher-resolution sources still fill the display but
are decoded at the capped working resolution.

## Wallpaper Engine web compatibility

Implemented:

- Local HTML, CSS, JavaScript, media, and project-relative assets through WebKit
- `window.wallpaperPropertyListener.applyUserProperties`
- `applyGeneralProperties` with the host FPS target
- `setPaused` plus a frozen frame while rendering is suspended
- Synthetic DOM mouse move, pointer move, left click, and right click events
- Media autoplay and remote web content access
- Registration shims for audio and media listeners
- Native property editor for checkbox, slider, color, combo, text, file, and directory values
- Incremental property callbacks and per-project property persistence
- Global HTML media mute control, with only the primary display allowed to play audio

Not implemented yet:

- Live audio spectrum data
- macOS media player metadata forwarding
- Random-file directory callbacks currently return an empty path
- Web Audio API nodes are not yet included in the global media mute bridge

## Wallpaper Engine scene compatibility

Implemented:

- Native, bounds-checked `PKGVxxxx` package table parsing
- Random access to packaged files without extracting the whole archive
- `scene.json` general settings and object classification
- Image descriptor and material JSON resolution
- Static image layers with origin, scale, rotation, alpha, and fullscreen layout
- Camera parallax and per-layer parallax depth
- `.tex` RGBA8888, R8, RG88, DXT1, DXT3, and DXT5 decoding
- LZ4-compressed texture bodies
- Embedded PNG, JPEG, GIF, BMP, TIFF, and WebP through ImageIO
- `TEXS0001` through `TEXS0003` sprite frame tables and compositor-driven playback
- Sprite pause and resume without restarting the animation
- Packaged sound objects using AVFoundation-supported audio formats
- Loop, random, and single sound playback with pause and global mute
- Project preview fallback when a scene layer cannot be rendered

Not implemented yet:

- Wallpaper Engine shader translation and multi-pass effects
- Particle systems, SceneScript, puppet meshes, and lights
- Video textures and script-triggered sound controls
- Wallpaper Engine built-in asset packs that are not present in `scene.pkg`

## Run

```sh
git clone git@github.com:823302271/wallflow.git
cd wallflow
swift run -c release
```

Use the waveform icon in the menu bar to pause or quit Wallflow.

Use **Open Wallpaper...** from the menu bar to choose a Wallpaper Engine
project. A web compatibility fixture is included at `Fixtures/web-wallpaper`.

## Import wallpapers

- **Open Wallpaper...** accepts MP4/M4V/MOV, a project directory,
  `project.json`, `index.html`, `scene.pkg`, or a complete ZIP archive.
- **Import from URL...** accepts an HTTP(S) MP4/M4V/MOV URL, web wallpaper URL,
  or a complete ZIP project URL.
- A supported file or ZIP can be opened with Wallflow from Finder, including by
  dragging the file onto `Wallflow.app`.
- ZIP imports are checked for path traversal, symbolic links, excessive file
  count, and excessive extracted size before they are loaded.

For projects with local assets, import the complete project directory or ZIP.
A remote `project.json` or `scene.pkg` alone is incomplete because its sibling
textures, scripts, materials, and media are not included.

### Why an import can fail

| Message or reason | Resolution |
| --- | --- |
| No supported project entry | Include MP4/M4V/MOV, `project.json`, `index.html`, or `scene.pkg`. |
| Malformed `project.json` | Validate its JSON and confirm the `file` and `type` fields. |
| Missing or outside entry file | Keep the entry and all assets inside the project directory. |
| Unsupported wallpaper type | Application wallpapers and unsupported video containers are not implemented yet. Convert the video container to MP4, M4V, or MOV without converting it to HTML. |
| Remote `.json` or `.pkg` is incomplete | Package the entire project as ZIP and import that URL. |
| Steam Workshop URL | Import the locally downloaded Workshop folder or an author-provided ZIP. |
| Unsafe ZIP path or symbolic link | Rebuild the archive with regular files and relative paths only. |
| Archive is too large | Downloads are limited to 512 MB; extracted projects to 1 GB and 100,000 files. |
| Multiple projects at the same archive level | Put one wallpaper project in each ZIP. |

An import may succeed while some scene effects are missing. Standalone video
wallpapers are supported; video textures embedded inside a scene package are not
yet supported. Check the scene compatibility section for the remaining limits.

## Animation customization

Web wallpapers can expose Wallpaper Engine user properties. Wallflow currently
applies checkbox, slider, color, combo, text, file, and directory values and
persists them per project.

Scene customization will be added in stages. The planned order is playback
speed and FPS limits, camera/parallax controls, effect toggles, per-layer
properties, then particle and audio-reactive parameters. Scene controls will
only appear after the corresponding renderer binding is implemented.

To create a double-clickable app bundle:

```sh
./scripts/package-app.sh
open dist/Wallflow.app
```

The generated app is ad-hoc signed for local use. Wallflow is a menu bar app,
so it does not display a Dock icon.

## Performance design

Wallflow targets Apple Silicon exclusively and uses Metal as the rendering
backbone. It avoids continuous CPU-side simulation, lowers the frame rate while
idle, renders below Retina native resolution, uses a two-buffer swap chain, and
suspends covered displays. HTML wallpapers are capped at 24 FPS and a device
pixel ratio of 1, and run in WebKit only when a web project is selected. Native
video uses AVFoundation with short buffering and a 1080p decode cap.

The default **Pause When Another App Is Active** option immediately stops
rendering, media, audio, and global wallpaper input while another application
has a visible window in the active Space. Disable it only when animation should
continue in desktop areas visible around normal windows.

When WindowServer temporarily exposes the system desktop during a full-screen or
Space transition, Wallflow keeps a resident last-frame window behind the live
renderer and also sets the system desktop to that captured frame. The original
desktop is restored when Wallflow exits normally. Separately,
incremental display reconciliation reuses every retained display renderer when a
different display is connected or disconnected.

## Architecture direction

Metal is the shared rendering foundation for the Apple Silicon-only target.
Standalone video uses AVFoundation. WebKit remains an isolated compatibility
host for HTML projects, and supported scene image layers currently use Core
Animation as an interim compositor. Shader effects, particles, and scene layers
will move through the shared Metal pipeline as their translators are implemented.

## Verification

The project includes framework-free self-tests so they run with Apple Command
Line Tools alone:

```sh
swift run Wallflow --self-test
swift run Wallflow --web-self-test
swift run Wallflow --video-self-test /path/to/video.mp4
```

The first command validates project loading, package bounds checks, scene
resolution, LZ4, embedded images, DXT, and scene layer construction. The second
starts a real WKWebView and verifies Wallpaper Engine property and mouse APIs.
The third opens a real video and verifies playback, pause/resume, and frame capture.

## Project layout

- `Sources/Wallflow`: AppKit, Metal, WebKit, scene decoding, and audio code
- `Fixtures/web-wallpaper`: local HTML compatibility fixture
- `scripts/package-app.sh`: release app bundle builder
- `AppBundle/Info.plist`: macOS application metadata
- `THIRD_PARTY_NOTICES.md`: third-party format and implementation notices

## Contributing

Bug reports should include the macOS version, Mac model, wallpaper type, and a
minimal reproducible project when licensing permits. Do not upload paid or
copyrighted Workshop assets without redistribution permission.
