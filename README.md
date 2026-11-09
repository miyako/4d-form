# 4d-form

Standalone **macOS and Windows PNG preview generator** for a `.4DForm` path. The executable
`fourdform` analyzes a form and its static project dependencies, then rasterizes
the same calibrated HTML/SVG used by [4d-ql](https://github.com/miyako/4d-ql).
No 4D application, Quick Look extension, hosting app or project-method
execution is required. Each platform renders its own 4D appearances: macOS
Classic/Liquid Glass, and Windows Classic/Fluent.

```sh
fourdform "/path/MyProject/Project/Sources/Forms/Contact/form.4DForm" \
  --output contact.png --theme classic-light --page 1 --scale 2
fourdform "/path/form.4DForm" --theme liquid-glass-dark --language fr \
  --max-dimension 2048 --output french-dark.png
```

```powershell
fourdform.exe "C:\MyProject\Project\Sources\Forms\Contact\form.4DForm" `
  --output contact.png --theme fluent-dark --scale 2
```

The output is an actual PNG of **only the selected form canvas**, without report
headings, page tabs, theme selectors or captions. Success prints the output path;
warnings and errors go to stderr. Without `--output`, the destination is
`form.preview.png` beside the input. An existing destination is atomically
replaced only after successful rasterization.

## Install on macOS

Requires macOS 12 or newer, a logged-in graphical macOS session, and system
AppKit/WebKit. The universal binary contains arm64 and x86_64 slices.

Download `fourdform-macos-universal.tar.xz`, `SHA256SUMS` and `release.json` from
[Releases](https://github.com/miyako/4d-form/releases). Verify before extraction:

```sh
shasum -a 256 -c SHA256SUMS
tar -xJf fourdform-macos-universal.tar.xz
./fourdform --version
./fourdform --help
```

The archive contains one executable at its root. It can be copied anywhere; it
does not need source files, SwiftPM, `PATH` tools or a 4D runtime. Project CSS,
JSON pointers, pictures, inherited forms, subforms and XLIFF still require their
normal project-relative files: moving only the input form may remove context.

Initial releases are **ad-hoc signed, not Developer ID signed or notarized**.
Downloading may trigger Gatekeeper. Follow your organization's normal approval
process or build from source; the installer never disables Gatekeeper or changes
system security settings. Signing credentials must be configured separately by
the repository owner, never embedded in this repository.

## Install on Windows

Requires Windows 10 or newer (x64 or arm64) with the **Microsoft Edge WebView2
Runtime (Evergreen)**, which ships with Windows 11 and current Windows 10
updates. Download `fourdform-windows-x64.zip` or `fourdform-windows-arm64.zip`
with `SHA256SUMS` and `release.json`, then verify before extraction:

```powershell
(Get-FileHash fourdform-windows-arm64.zip -Algorithm SHA256).Hash   # compare with SHA256SUMS
Expand-Archive fourdform-windows-arm64.zip fourdform
.\fourdform\fourdform.exe --version
```

The archive holds `fourdform.exe`, the Swift/MSVC runtime DLLs it imports and
the WebView2 SDK loader's BSD-3-Clause notice; keep them together. Windows binaries are **not Authenticode signed**, so
SmartScreen may warn. Rendering uses a private, hidden, network-blocked WebView2
instance with a temporary profile that is deleted afterwards; no desktop
interaction is needed beyond an ordinary user session.

[miyako/skills](https://github.com/miyako/skills) integrates this product with its
existing `4dform` skill and `4dtools` provisioner, installing into the consumer
project's `tools/4dform/fourdform`, not global `PATH`. Its installer consumes the
pinned upstream release and checks `SHA256SUMS`; unlike the OOP language tool it
does not maintain a second vendored build of the renderer.

## Options and behavior

| Option | Default | Meaning |
|---|---|---|
| `--output`, `-o` | `INPUT.preview.png` | PNG path; parent directory must exist |
| `--theme` (macOS) | `classic-light`, or `classic-dark` if form forces dark | `classic-light`, `classic-dark`, `liquid-glass-light`, `liquid-glass-dark`; `glass-light`/`glass-dark` aliases |
| `--theme` (Windows) | `classic`; `fluent-light` if form sets `fluentUI`; `fluent-dark` if form forces dark | `classic` (Windows Classic, light only), `fluent-light`, `fluent-dark` |
| `--page` | page 1, else first | Nonnegative page; page 0 is shared behind other pages |
| `--language` | `en` | Repeat BCP47 preferences in priority order |
| `--scale` | `1` | Pixels per form point, finite range 0.1–4 |
| `--max-dimension` | `2048` | Proportional fit, integer range 1–4096 pixels |
| `--` | — | End options; permits a filename starting with `-` |
| `--help`, `--version`, `--license` | — | Metadata or embedded product/shared-library MIT notice; no rendering |

The output width/height are the ceiling of the shared canvas dimensions times
`min(scale, maxDimension / max(canvasWidth, canvasHeight))`, at least one pixel
and no greater than `maxDimension`. The upstream canvas is bounded at 8192
points; the output is bounded at 4096 × 4096 pixels. Larger canvases are cropped
upstream with a warning, not silently interpreted as native 4D output.
Explicit page/theme requests that do not exist or conflict with `colorScheme`
are errors. Input must be `.4DForm`; output must be `.png`.

Theme names are platform-specific: the reference appearance always matches the
host OS, and the other platform's names are rejected (exit 2) rather than
silently aliased.

Exit status is **0** for success/help, **2** for command syntax/limits errors,
and **1** for filesystem, form analysis, unsupported appearance, WebKit/WebView2, timeout
or PNG encoding failures. Render completion waits for fonts and embedded images,
forces layout and requests an after-screen-updates snapshot; no guessed paint
delay or endless wait. The entire raster stage has a 30-second deadline.

This is a static macOS or Windows reference preview, not a 4D form interpreter. No events,
methods, expressions, bindings or live data run. Dynamic/unsupported plugin,
web, Write Pro and View Pro controls remain warning-marked placeholders.
Determinism means identical bytes for repeated renders on the **same OS/fonts,
input dependencies and CLI build**, not cross-version native font equivalence.
Theme and language defaults do not follow the user's locale or system theme.

## Build, verify and package

Install Xcode command-line tools and Swift 5.9 or newer:

```sh
swift build --product fourdform
swift test
bash scripts/build-macos.sh
python3 scripts/smoke.py dist/fourdform
```

On systems with `git safe.bareRepository=explicit`, scope SwiftPM's bare-cache
access to one command instead of changing global configuration:

```sh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository \
  GIT_CONFIG_VALUE_0=all swift test
```

On Windows, install Swift 6 for Windows with the Visual Studio C++ tools, then:

```powershell
scripts\fetch-webview2.ps1      # pinned WebView2 SDK headers/static loader (build time only)
swift test
scripts\build-windows.ps1       # dist\fourdform-windows-<host arch>.zip, runs smoke.py
```

The macOS build script creates both architectures targeting macOS 12, combines them
with `lipo`, ad-hoc signs, checks the slices and packages a root-only `.tar.xz`
with `SHA256SUMS` and the release manifest. CI verifies real decoded PNGs,
geometry, themes/pages, clipping, scale/limits, standalone execution with empty
`PATH`, invalid inputs and the upstream self-authored static/benchmark corpus.

Releases follow the OOP example's `v*` tags and stable versionless asset names.
The release workflow refuses a tag that disagrees with `--version` or
`release.json`; it publishes the macOS universal archive, the Windows x64 and
arm64 archives (each built and smoke-tested on its native runner), one combined
`SHA256SUMS` and the manifest. Repository source remains MIT licensed. See
[dependency provenance](docs/DEPENDENCIES.md) and the
[Windows implementation notes](docs/WINDOWS-HANDOVER.md).
