# Shared renderer provenance

`Package.swift` and `Package.resolved` pin an immutable commit of
[`miyako/4d-ql`](https://github.com/miyako/4d-ql), licensed MIT, copyright
2026 Keisuke Miyako. It supplies the `FourDFileKit` and `FourDRender` products.
No parser, calibrated geometry, font layout, CSS palette or control SVG
implementation is copied into this repository.
The executable embeds the full product/shared-library MIT notice, available via
`fourdform --license`, so the root-only binary archive carries its license too.

The public boundary is `FormRenderer.render(url:preferredLanguages:options:)`.
It returns self-contained HTML/SVG plus the version-1 `FormRenderDocument`
containing typed form models, ordered appearance/page/object arrays and notices.
The DOM adapter selects the upstream visible form canvas, preserves its styles,
embedded image definitions, clip paths and theme inheritance, and removes only
report chrome. Canvas dimensions are read from the upstream SVG, never
recomputed from object rectangles.

To update: coordinate with 4d-ql, set the full reviewed release commit in
`Package.swift`, run `swift package resolve`, commit `Package.resolved`, and run
`swift test` plus the universal build/smoke corpus. Do not substitute a floating
branch or fork of calibrated source. Shared behavior changes belong upstream
and must preserve Quick Look behavior as well as image output.

Tests use `Tests/FourDFileKitTests/Fixtures/{FormStaticProject,FormBenchmarkProject}`
from that exact dependency checkout, not copied native customer assets. These
are self-authored upstream MIT fixtures. The small local `simple.4DForm` fixture
is also self-authored under this repository's MIT license. External HDI forms,
private native screenshots and downloaded SF Pro fonts are **not** vendored or
packaged.

Runtime dependencies on macOS are Apple system AppKit, CoreText, ImageIO,
UniformTypeIdentifiers and WebKit, plus the Swift runtime supplied by macOS.
On Windows they are the system Microsoft Edge WebView2 Runtime (Evergreen),
Windows Imaging Component and the Swift/MSVC runtime DLLs bundled beside
`fourdform.exe` in the release archive (Apache-2.0 with Runtime Library
Exception / Microsoft Visual C++ redistributable terms).

## Microsoft WebView2 SDK (build time only)

`scripts/fetch-webview2.ps1` downloads NuGet `Microsoft.Web.WebView2`
1.0.4314.35, verifies SHA-256
`90778DEB1B77E36292828B4B5833C9255C27533F40E0DDD55891AE718944EDC4`, and copies
`WebView2.h`, `WebView2EnvironmentOptions.h`, the per-architecture
`WebView2LoaderStatic.lib` and its BSD-3-Clause `LICENSE.txt` into the
git-ignored `Sources/CWebView2Raster/vendor/`. The static loader is linked into
`fourdform.exe`, so `scripts/build-windows.ps1` ships the notice as
`WebView2-SDK-LICENSE.txt` in each Windows archive; no WebView2 SDK file is
committed. Update by changing the
version and hash together and re-running the Windows build and smoke corpus.
SwiftPM/source downloads are build-time only. Project dependencies are read
in-process under ordinary filesystem permissions, without host/XPC/4D access.
