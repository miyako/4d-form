# Windows implementation notes

`fourdform.exe` renders Windows reference previews of a `.4DForm` with the same
CLI contract as macOS: flags, range validation, exit codes, atomic output,
deterministic theme/page/language selection, bounded pixel dimensions and the
selected canvas only. The macOS output is a reference for macOS, not evidence
of Windows behavior, and vice versa.

## Division of work

| Layer | Where | Windows implementation |
|---|---|---|
| Parser, typed IR, dependencies | upstream `FourDFileKit` (4d-ql) | Portable file, picture and typography adapters. `FormRenderer.analyze/render` take `platform: .windows`, which loads `styleSheets.css` + `styleSheets_windows.css` and reports `referencePlatform` `Windows`. |
| Controls, palettes, metrics | upstream `FourDRender` | `FormTheme.windowsClassic` (light only), `.fluentLight`, `.fluentDark`, calibrated against licensed 4D 21 on Windows 11. See the upstream renderer docs for the calibration record. No copy of the calibrated renderer lives here. |
| CLI | `Sources/FormImage/Command.swift` | Host-platform theme table: `classic`, `fluent-light`, `fluent-dark`; default `classic`, or `fluent-dark` when the form forces dark. macOS names (`classic-light`, `liquid-glass-*`, ...) are rejected, not aliased. |
| DOM adapter | `Sources/FormImage/CanvasScripts.swift` | Shared by both rasterizers: selects the upstream canvas, removes report chrome, waits for fonts and images, returns canvas size from the upstream SVG. |
| Raster | `Sources/FormImage/WindowsRasterizer.swift`, `Sources/CWebView2Raster/` | Microsoft Edge WebView2 (Evergreen runtime), described below. |
| Packaging | `scripts/build-windows.ps1`, CI/release workflows, `release.json` | `fourdform-windows-x64.zip` and `fourdform-windows-arm64.zip`, each built and smoke-tested on a native runner. |

## WebView2 raster adapter

- **Deployment:** the system Evergreen WebView2 Runtime; the pinned SDK
  (`scripts/fetch-webview2.ps1`) contributes headers and the static loader only.
  A missing runtime is an explicit error.
- **Isolation:** each render creates a hidden, off-screen tool window, its own
  STA COM apartment and a fresh `%TEMP%\fourdform-webview2-{GUID}` profile.
  The profile is deleted after the browser process exits. Scripts run, but
  dialogs, context menus, the DevTools UI, host objects, web messages, autofill,
  status bar and zoom are disabled.
- **No network:** the HTML is served from memory at
  `https://fourdform.invalid/form.html` through `WebResourceRequested`; every
  other request is answered 403, and the browser runs with host-resolver rules
  that map every host to `NOTFOUND`, no proxy and background networking off.
  This also avoids the 2 MB `NavigateToString` limit.
- **Paint determinism:** `--force-color-profile=srgb`, software paint, grayscale
  anti-aliasing (`--disable-lcd-text`), rasterization scale 1, no monitor-DPI
  tracking, light `prefers-color-scheme` and reduced motion. The theme comes
  from the upstream initial theme classes, never the system theme.
- **Readiness, not sleeps:** `NavigationCompleted`, then `Runtime.evaluate`
  awaits the shared prepare script (fonts, images, layout). The
  device-metrics override and window bounds are set to the exact `ImageSize`,
  then two animation frames are awaited before `Page.captureScreenshot` clips
  the canvas.
- **Output:** the capture is decoded with WIC, resampled only if the device
  disagrees with the requested size, and re-encoded as an 8-bit RGBA PNG of
  exactly the requested dimensions.
- **Failures:** runtime/controller creation, browser process failure,
  navigation errors, DevTools errors and script exceptions all propagate as
  messages. The whole stage has a 30-second deadline, enforced by a
  `MsgWaitForMultipleObjectsEx` message pump.

## Verification

`swift test` and `scripts/smoke.py` run the same acceptance contract on both
platforms: PNG signature, CRCs and real decoding, exact dimensions and limits,
common-page paint, selected page, subform-local coordinates and clipping,
embedded pictures, French XLIFF, repeated identical bytes, unchanged inputs,
explicit errors, and the other platform's theme names rejected. The packaged
binary runs from a directory containing only its archive contents with an empty
`PATH`. Creating the symlink-alias case needs Developer Mode or the symlink
privilege on Windows; without it, smoke skips that one case.

Determinism means identical bytes on the same Windows build, fonts, WebView2
Runtime version and CLI build. Evergreen WebView2 updates may change
anti-aliasing slightly; they do not change geometry.

## Building

Install Swift for Windows (6.x) with Visual Studio C++ build tools and a
Windows 10/11 SDK, then run `scripts\fetch-webview2.ps1`, `swift test` and
`scripts\build-windows.ps1`. The build bundles exactly the Swift/MSVC runtime
DLLs that `fourdform.exe` transitively imports (found with `dumpbin
/dependents`), plus the WebView2 SDK's BSD-3-Clause notice. Asset names in
`release.json` are stable; coordinate any change with `miyako/skills`.
