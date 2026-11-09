#if os(Windows)
import CWebView2Raster
import Foundation

private final class SizeLimits {
    let scale: Double
    let maximum: Int
    init(scale: Double, maximum: Int) { self.scale = scale; self.maximum = maximum }
}

private func cString(_ message: String) -> UnsafeMutablePointer<CChar>? {
    message.withCString { source in
        let length = strlen(source) + 1
        guard let target = malloc(length)?.assumingMemoryBound(to: CChar.self) else { return nil }
        memcpy(target, source, length)
        return target
    }
}

/// Uses the same ImageSize contract as macOS for the canvas-to-pixel mapping.
private let sizeCallback: fourdform_size_callback = { context, width, height, pixelWidth, pixelHeight, error in
    let limits = Unmanaged<SizeLimits>.fromOpaque(context!).takeUnretainedValue()
    do {
        let size = try ImageSize(width: width, height: height, scale: limits.scale, maximum: limits.maximum)
        pixelWidth!.pointee = Int32(size.width)
        pixelHeight!.pointee = Int32(size.height)
        return 0
    } catch let failure {
        let message = (failure as? LocalizedError)?.errorDescription ?? String(describing: failure)
        error!.pointee = cString(message)
        return 1
    }
}

/// The only Windows image platform adapter: a private, network-blocked
/// Microsoft Edge WebView2 (Evergreen runtime) instance per render.
/// All form analysis, geometry and paint remain upstream.
public final class WindowsRasterizer {
    private var used = false

    public init() {}

    public func png(html: String, scale: Double, maximum: Int, timeout: TimeInterval = 30) throws -> Data {
        guard !used else { throw CommandError("A rasterizer instance can only be used once.") }
        used = true
        let context = Unmanaged.passRetained(SizeLimits(scale: scale, maximum: maximum))
        defer { context.release() }
        var png: UnsafeMutablePointer<UInt8>?
        var length = 0
        var error: UnsafeMutablePointer<CChar>?
        let bytes = Array(html.utf8)
        let status = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { html in
                fourdform_webview2_png(html, buffer.count, CanvasScripts.prepare, CanvasScripts.resize,
                                       sizeCallback, context.toOpaque(), timeout, &png, &length, &error)
            }
        }
        defer {
            fourdform_free(png)
            fourdform_free(error)
        }
        guard status == 0, let png else {
            throw CommandError(error.map { String(cString: $0) } ?? "WebView2 rasterization failed.")
        }
        return Data(bytes: png, count: length)
    }

    /// Decodes a PNG with Windows Imaging Component into tightly packed RGBA rows.
    public static func decodeRGBA(_ data: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        var width: Int32 = 0, height: Int32 = 0
        var rgba: UnsafeMutablePointer<UInt8>?
        var error: UnsafeMutablePointer<CChar>?
        let status = data.withUnsafeBytes { buffer in
            fourdform_wic_decode_png(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
                                     &width, &height, &rgba, &error)
        }
        defer {
            fourdform_free(rgba)
            fourdform_free(error)
        }
        guard status == 0, let rgba else {
            throw CommandError(error.map { String(cString: $0) } ?? "PNG decoding failed.")
        }
        return (Int(width), Int(height), Array(UnsafeBufferPointer(start: rgba, count: Int(width) * Int(height) * 4)))
    }
}
#endif
