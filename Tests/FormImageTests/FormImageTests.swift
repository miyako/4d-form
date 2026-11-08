import XCTest
import AppKit
import ImageIO
@testable import FormImage

final class FormImageTests: XCTestCase {
    func testLimitsAndArguments() throws {
        XCTAssertEqual(try ImageSize(width: 240, height: 160, scale: 2, maximum: 4096),
                       try ImageSize(width: 480, height: 320, scale: 1, maximum: 4096))
        let fit = try ImageSize(width: 8192, height: 4096, scale: 4, maximum: 2048)
        XCTAssertEqual(fit.width, 2048)
        XCTAssertEqual(fit.height, 1024)
        for args in [[], ["x.json"], ["--scale", "nan", "x.4DForm"], ["--scale", "5", "x.4DForm"],
                     ["--max-dimension", "4097", "x.4DForm"], ["--page", "-1", "x.4DForm"],
                     ["--theme", "windows", "x.4DForm"], ["--output", "x.4DForm", "x.4DForm"],
                     ["--language", "", "x.4DForm"], ["x.4DForm", "y.4DForm"]] {
            XCTAssertThrowsError(try ImageCommand(args))
        }
        let command = try ImageCommand(["--", "-form.4DForm"])
        XCTAssertEqual(command.languages, ["en"])
        XCTAssertTrue(command.output.path.hasSuffix("-form.preview.png"))
    }

    @MainActor func testRealPNGAndDeterminism() throws {
        _ = NSApplication.shared
        let input = Bundle.module.url(forResource: "simple", withExtension: "4DForm", subdirectory: "Fixtures")!
        let before = try Data(contentsOf: input)
        let command = try ImageCommand([input.path])
        let rendered = try command.render()
        let first = try MacRasterizer().png(html: rendered.html, scale: 1, maximum: 2048)
        let second = try MacRasterizer().png(html: rendered.html, scale: 1, maximum: 2048)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Array(first.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(first as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 160)
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = 20 * image.bytesPerRow + 20 * 4
        XCTAssertGreaterThan(bytes[offset], 240, "Common-page red rectangle must paint at (20,20)")
        XCTAssertLessThan(bytes[offset + 1], 20)
        XCTAssertLessThan(bytes[offset + 2], 20)
        XCTAssertEqual(try Data(contentsOf: input), before)
        let scaled = try MacRasterizer().png(html: rendered.html, scale: 2, maximum: 4096)
        let scaledSource = try XCTUnwrap(CGImageSourceCreateWithData(scaled as CFData, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(scaledSource, 0, nil)?.width, 480)
    }

    @MainActor func testRasterFailuresAreExplicitAndBounded() throws {
        _ = NSApplication.shared
        XCTAssertThrowsError(try MacRasterizer().png(html: "<html><body>No canvas</body></html>",
                                                    scale: 1, maximum: 2048)) { error in
            XCTAssertTrue(String(describing: error).contains("No selected form canvas"))
        }
        XCTAssertThrowsError(try MacRasterizer().png(html: "<html></html>", scale: 1,
                                                    maximum: 2048, timeout: 0)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }
}
