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
- Native Metal animation and a reusable Canvas 2D-to-Metal renderer
- Global cursor tracking without intercepting desktop clicks
- Smooth cursor parallax, bending lines, and interaction ripples
- Adaptive 60 FPS while interacting and 24 FPS while idle
- 75% logical render scale to reduce fill-rate cost on Retina displays
- Two-buffer Metal swap chain instead of the default three-buffer allocation
- Rendering suspension when visible app windows collectively hide a display's desktop
- Automatic suspension during sleep and inactive login sessions
- Incremental display reconciliation without restarting retained-screen renderers
- A paused last frame retained by the same renderer during Space transitions
- Menu bar pause and resume controls
- Default-on pause only when a display's desktop is fully hidden
- Persistent wallpaper library with switching, reveal, and uninstall actions
- Runtime language switching between English and Simplified Chinese
- Native MP4, M4V, and MOV playback through AVFoundation
- Automatic Metal rendering for compatible script-only Canvas 2D wallpapers
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

- Automatic detection of compatible local Canvas 2D wallpapers
- Original wallpaper JavaScript execution through JavaScriptCore without modifying project files
- Metal-backed paths, full circles, solid fills, rounded strokes, simple shadows, and overlay effects
- Canvas animation frames, resize, mouse events, body background color, and property callbacks
- Conservative WebKit fallback when a project uses unsupported Canvas, DOM, image, media, or network APIs
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

- The Metal Canvas path does not yet translate images, text, gradients, partial arcs,
  complex transforms, clipping, or complex DOM/CSS; those projects use WebKit
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
- Successful imports are added to **Wallpaper Library...** automatically. The
  library also discovers existing projects under Wallflow's managed import folder.
- Removing a managed ZIP import deletes Wallflow's installed copy after
  confirmation. Removing an external file or URL only removes its library record.
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
backbone. Native and Canvas-Metal renderers draw below Retina native resolution,
use short command buffers, and suspend covered displays. Compatible Canvas 2D
wallpapers run their original JavaScript in-process and batch drawing into Metal
at 24 FPS. Other HTML wallpapers fall back to WebKit at 24 FPS and a device pixel
ratio of 1. Native video uses AVFoundation with short buffering and a 1080p
decode cap.

The default **Pause When Desktop Is Hidden** option stops rendering, media,
audio, and wallpaper input only when the union of visible application windows
hides an entire display's desktop. This also handles browsers that compose full
screen from several windows. Normal application windows do not pause Wallflow
while any desktop area remains exposed. Mouse input is observed globally without
intercepting it, so the original application receives the click and an interactive
wallpaper can react to the same click.

During a full-screen or Space transition, Wallflow keeps the same desktop window,
WebKit surface, and renderer alive at a constant desktop level. It pauses only the
animation clock, media, audio, and input while the desktop is invisible, then
continues from the same frame when the desktop returns. The static macOS desktop
frame is only a fallback for times when Wallflow is not running; it is not used as
a Space-transition layer. Incremental display reconciliation separately reuses
every retained display renderer when another display is connected or disconnected.

## Architecture direction

Metal is the shared rendering foundation for the Apple Silicon-only target.
The Canvas compatibility layer now executes the original wallpaper JavaScript
with JavaScriptCore and translates supported Canvas 2D commands into reusable
Metal primitives. It is selected by capabilities rather than wallpaper identity,
so compatible projects need no per-wallpaper source changes. Standalone video
uses AVFoundation, unsupported web capabilities fall back to WebKit, and current
scene image layers use Core Animation until their Metal translators are ready.

## Verification

The project includes framework-free self-tests so they run with Apple Command
Line Tools alone:

```sh
swift run Wallflow --self-test
swift run Wallflow --canvas-metal-self-test /path/to/project.json
swift run Wallflow --web-self-test
swift run Wallflow --video-self-test /path/to/video.mp4
swift run Wallflow --library-self-test
```

The first command validates project loading, renderer selection, the wallpaper
library, desktop visibility, packages, textures, and scene construction. The
second executes an unchanged Canvas wallpaper through Metal and verifies drawing,
properties, input, pause, and resume. The third starts a real WKWebView. The
fourth verifies native video playback and frame capture. The fifth renders the
bilingual wallpaper management window to a PNG fixture.

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
