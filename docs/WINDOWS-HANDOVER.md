# Windows implementation handover

## Delivered and deliberately absent

The `fourdform` macOS CLI produces bounded, decoded PNGs using a new
`MacRasterizer` adapter and shared 4d-ql libraries. Windows is **not** supported,
built or runtime-tested. Do not publish a Windows asset until the adapters,
native calibration and Windows acceptance tests below exist. The macOS result
is a reference, not evidence of Windows control, font or palette behavior.

## Reusable boundary and Apple dependencies

| Layer | Reuse / work required |
|---|---|
| CLI contract | Reuse flags, range validation, exit codes, atomic output and deterministic theme/page/language selection from `Sources/FormImage/Command.swift`. Its current import of Apple-dependent library products prevents a Windows build today. |
| Typed IR | Preserve `FormRenderDocument` schema 1, ordered page/object arrays, nested static subforms, warnings and resource provenance. `referencePlatform` currently says `macOS`: introduce an explicit Windows platform boundary upstream, do not relabel these styles. |
| Parser/dependencies | Reuse form JSON/JSON pointers, static CSS, XLIFF, inheritance, subform resolution and passive picture safety logic in upstream `FourDFileKit`; replace platform imports/operations first. `ByteSource` currently uses POSIX file access. |
| Typography | `FormTextLayout` and `DiagramTypography` use CoreText; implement equivalent UTF-16/grapheme-safe measurement, alignment, wrapping, clipping and font fallback with DirectWrite or another measured Windows backend. |
| Colors/controls | `FormPreviewRenderer` imports AppKit and encodes calibrated macOS Classic/Liquid Glass metrics and palettes. Add an explicit reference-platform model and Windows styling upstream. Do not copy and diverge this renderer. |
| Pictures | AppKit/ImageIO/UTType helpers require Windows image decode/encode, explicit bounds, passive SVG sanitization and safe URI adapters (e.g. WIC plus a measured SVG path). |
| Raster | `Sources/FormImage/MacRasterizer.swift` is wholly Apple-only. Implement a Windows adapter accepting the agreed self-contained HTML/SVG and returning PNG bytes or an explicit error. WebView2 is a candidate, not a validated choice or currently provisioned dependency. |
| Packaging | Add real MSVC/Windows SDK builds and tested x64/arm64 release recipes only after implementation. Current `release.json` intentionally lists macOS only. Coordinate stable asset names/checksums with `miyako/skills`. |

## Toolchain and implementation sequence

1. Clone this repository on Windows and read its exact `Package.resolved` QL
   revision. Review upstream `Sources/FourDFileKit/Form`, `ByteSource`,
   `Sources/FourDRender/{FormRenderer,FormPreviewRenderer,FormTextLayout}.swift`
   and upstream `docs/{FORM-RENDERER,WINDOWS-HANDOVER}.md`. Install the official
   Swift Windows toolchain, compatible Visual Studio C++ build tools and Windows
   SDK. The current package is macOS-only; an unmodified Windows build is not a
   supported smoke test.
1. Add platform-conditioned filesystem, resource/image and typography adapters
   **in the shared QL repository**, keeping its macOS defaults and tests intact.
   Split Apple-only targets if needed. Keep the Codable typed IR portable; use
   an explicit reference platform and schema migration when required.
1. Implement a Windows raster backend here with an equivalent contract:
   selected canvas only, fonts/passive images ready before capture, no external
   network or form code execution, 30-second deadline, process failure
   propagation, exact bounded pixel dimensions and sRGB PNG encoding. For
   WebView2, document Evergreen versus bundled-runtime deployment, COM
   initialization/message pumping, hidden-window lifecycle, paint completion,
   profile cleanup and screenshot scaling. Do not use an arbitrary sleep.
1. Calibrate native Windows controls using a licensed full 4D installation as a
   **development-only reference**. Document OS, 4D version, display scale,
   theme/high-contrast setting and fonts. Consult canonical 4D skills and create
   `Project/Sources/dependencies.json` before launching a reference project.
   Tool4D is not evidence for unsupported native window/control behavior.
1. Add Windows CI and publish assets only after actual PNG decoding, geometry,
   dependency resolution and isolated binary tests pass on Windows. Decide
   Windows theme names based on that calibration; do not silently alias the
   current macOS Liquid Glass names to guessed Windows styles.

## Fixtures and required evidence

Use this repository's `simple.4DForm` and the pinned dependency's self-authored
`FormStaticProject` and `FormBenchmarkProject` fixtures. Keep entire projects
when testing CSS, pictures, JSON pointers, XLIFF, inheritance and subforms.
The scripts resolve these fixtures from `.build/checkouts/4d-ql`; a Windows
harness may locate the pinned checkout differently without copying calibrated
code. No external HDI/customer forms or Apple SF Pro fonts may be redistributed.

Match the macOS acceptance contract, not necessarily macOS native appearance:
verify PNG signature, chunk CRCs and actual decompression/decoding, exact
dimension/scale limits, common-page paint order, selected page visibility,
paint at known coordinates, subform-local coordinates and clipping, image
placement, static CSS/JSON references and French XLIFF. Test repeated bytes on
the same Windows environment; document OS/font-dependent differences.
Hash input/project files before and after. Test missing/malformed inputs,
unavailable themes/pages, bad output paths, nonfinite/unbounded scale,
timeout, content-process failure, locked destinations and no-network behavior.

Finally copy the binary plus fixture project into a directory without source,
4D, Quick Look, SwiftPM or developer `PATH`; run on each published architecture.
Record dynamic runtime/WebView2 requirements explicitly. Windows native
calibration and runtime validation remain open work, not a macOS release gate.
