# Wallflow

[English](README.md) | [简体中文](README.zh-CN.md)

Wallflow is an early native macOS interactive wallpaper renderer. The current
prototype focuses on a low-overhead native renderer plus Wallpaper Engine web
and scene compatibility.

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
- Menu bar pause and resume controls
- Project import from a directory, `project.json`, `index.html`, or `scene.pkg`

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
suspends covered displays. HTML wallpapers run in WebKit only when a web project
is selected, because the web process has a higher baseline memory cost than the
native renderer.

## Architecture direction

Metal is the shared rendering foundation for the Apple Silicon-only target.
Video support will use AVFoundation. WebKit remains an isolated compatibility
host for HTML projects, and supported scene image layers currently use Core
Animation as an interim compositor. Shader effects, particles, and scene layers
will move through the shared Metal pipeline as their translators are implemented.

## Verification

The project includes framework-free self-tests so they run with Apple Command
Line Tools alone:

```sh
swift run Wallflow --self-test
swift run Wallflow --web-self-test
```

The first command validates project loading, package bounds checks, scene
resolution, LZ4, embedded images, DXT, and scene layer construction. The second
starts a real WKWebView and verifies Wallpaper Engine property and mouse APIs.

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
