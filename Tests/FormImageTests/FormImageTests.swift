import XCTest
#if os(macOS)
import AppKit
import ImageIO
#endif
@testable import FormImage

/// Platform raster adapter under test (AppKit/WebKit on macOS, WebView2 on Windows).
@MainActor private func rasterize(_ html: String, scale: Double = 1, maximum: Int = 2048,
                                  timeout: TimeInterval = 30) throws -> Data {
    #if os(macOS)
    _ = NSApplication.shared
    return try MacRasterizer().png(html: html, scale: scale, maximum: maximum, timeout: timeout)
    #else
    return try WindowsRasterizer().png(html: html, scale: scale, maximum: maximum, timeout: timeout)
    #endif
}

/// Decoded PNG as tightly packed RGBA rows.
private func pixels(_ png: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
    #if os(macOS)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(CGContext(data: &rgba, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, rgba)
    #else
    return try WindowsRasterizer.decodeRGBA(png)
    #endif
}

final class FormImageTests: XCTestCase {
    func testLimitsAndArguments() throws {
        XCTAssertEqual(try ImageSize(width: 240, height: 160, scale: 2, maximum: 4096),
                       try ImageSize(width: 480, height: 320, scale: 1, maximum: 4096))
        let fit = try ImageSize(width: 8192, height: 4096, scale: 4, maximum: 2048)
        XCTAssertEqual(fit.width, 2048)
        XCTAssertEqual(fit.height, 1024)
        for args in [[], ["x.json"], ["--scale", "nan", "x.4DForm"], ["--scale", "5", "x.4DForm"],
                     ["--max-dimension", "4097", "x.4DForm"], ["--page", "-1", "x.4DForm"],
                     ["--theme", "windows", "x.4DForm"], ["--theme", "dark", "x.4DForm"],
                     ["--output", "x.4DForm", "x.4DForm"],
                     ["--language", "", "x.4DForm"], ["x.4DForm", "y.4DForm"]] {
            XCTAssertThrowsError(try ImageCommand(args))
        }
        let command = try ImageCommand(["--", "-form.4DForm"])
        XCTAssertEqual(command.languages, ["en"])
        XCTAssertTrue(command.output.path.hasSuffix("-form.preview.png"))
    }

    func testThemeNamesArePlatformSpecific() throws {
        #if os(Windows)
        let accepted: [(String, FormTheme)] = [("classic", .windowsClassic), ("fluent-light", .fluentLight),
                                               ("fluent-dark", .fluentDark)]
        let foreign = ["classic-light", "classic-dark", "liquid-glass-light", "liquid-glass-dark",
                       "glass-light", "glass-dark"]
        XCTAssertEqual(ImageCommand.platform, .windows)
        #else
        let accepted: [(String, FormTheme)] = [("classic-light", .classicLight), ("classic-dark", .classicDark),
                                               ("liquid-glass-light", .glassLight), ("glass-light", .glassLight),
                                               ("liquid-glass-dark", .glassDark), ("glass-dark", .glassDark)]
        let foreign = ["classic", "fluent-light", "fluent-dark"]
        XCTAssertEqual(ImageCommand.platform, .macOS)
        #endif
        for (name, theme) in accepted {
            XCTAssertEqual(try ImageCommand(["--theme", name, "x.4DForm"]).options.initialTheme, theme, name)
            XCTAssertTrue(ImageCommand.usage.contains(name) || name.hasPrefix("glass-"), name)
        }
        for name in foreign {
            XCTAssertThrowsError(try ImageCommand(["--theme", name, "x.4DForm"]), name)
        }
    }

    @MainActor func testRealPNGAndDeterminism() throws {
        let input = Bundle.module.url(forResource: "simple", withExtension: "4DForm", subdirectory: "Fixtures")!
        let before = try Data(contentsOf: input)
        let command = try ImageCommand([input.path])
        let rendered = try command.render()
        let first = try rasterize(rendered.html)
        let second = try rasterize(rendered.html)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Array(first.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let image = try pixels(first)
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 160)
        let offset = (20 * image.width + 20) * 4
        XCTAssertGreaterThan(image.rgba[offset], 240, "Common-page red rectangle must paint at (20,20)")
        XCTAssertLessThan(image.rgba[offset + 1], 20)
        XCTAssertLessThan(image.rgba[offset + 2], 20)
        XCTAssertEqual(try Data(contentsOf: input), before)
        let scaled = try rasterize(rendered.html, scale: 2, maximum: 4096)
        XCTAssertEqual(try pixels(scaled).width, 480)
        #if os(Windows)
        XCTAssertEqual(rendered.document.referencePlatform, "Windows")
        #endif
    }

    @MainActor func testRasterFailuresAreExplicitAndBounded() throws {
        XCTAssertThrowsError(try rasterize("<html><body>No canvas</body></html>")) { error in
            XCTAssertTrue(String(describing: error).contains("No selected form canvas"))
        }
        XCTAssertThrowsError(try rasterize("<html></html>", timeout: 0)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        let brokenImage = """
        <html><body><div class="form-preview"><div class="form-appearance">
        <div class="form-page"><div class="form-scroll">
        <svg width="80" height="80"><image href="data:image/png;base64,broken"/></svg>
        </div></div></div></div></body></html>
        """
        XCTAssertThrowsError(try rasterize(brokenImage))
    }
}
