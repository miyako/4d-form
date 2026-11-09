#if os(macOS)
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// The only image platform adapter. All form analysis, geometry and paint remain upstream.
@MainActor public final class MacRasterizer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var completion: Result<Data, Error>?
    private var scale = 1.0
    private var maximum = 2048
    private var navigation: WKNavigation?

    public func png(html: String, scale: Double, maximum: Int, timeout: TimeInterval = 30) throws -> Data {
        guard webView == nil else { throw CommandError("A rasterizer instance can only be used once.") }
        self.scale = scale
        self.maximum = maximum
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 16, height: 16), configuration: configuration)
        webView = view
        view.navigationDelegate = self
        view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 16, height: 16),
                              styleMask: .borderless, backing: .buffered, defer: false)
        self.window = window
        window.contentView = view
        window.orderFrontRegardless()
        navigation = view.loadHTMLString(html, baseURL: nil)
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
            window.orderOut(nil)
            window.contentView = nil
            self.window = nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while completion == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let completion else { throw CommandError("Rasterization timed out after \(Int(timeout)) seconds.") }
        return try completion.get()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(CanvasScripts.prepare, arguments: [:], in: nil, in: .page) { result in
            do {
                guard let size = try result.get() as? [String: Double],
                      let width = size["width"], let height = size["height"] else {
                    throw CommandError("WebKit returned invalid canvas dimensions.")
                }
                let pixels = try ImageSize(width: width, height: height, scale: self.scale, maximum: self.maximum)
                self.snapshot(webView, size: pixels)
            } catch { self.completion = .failure(error) }
        }
    }

    private func snapshot(_ view: WKWebView, size: ImageSize) {
        view.setFrameSize(NSSize(width: size.width, height: size.height))
        view.callAsyncJavaScript(CanvasScripts.resize, arguments: ["width": size.width, "height": size.height],
                                 in: nil, in: .page) { result in
            do { _ = try result.get() }
            catch { self.completion = .failure(error); return }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            config.snapshotWidth = NSNumber(value: size.width)
            config.afterScreenUpdates = true
            view.takeSnapshot(with: config) { image, error in
                do {
                    if let error { throw error }
                    guard let image, let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let context = CGContext(data: nil, width: size.width, height: size.height,
                              bitsPerComponent: 8, bytesPerRow: size.width * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw CommandError("WebKit did not produce a decodable raster image.")
                    }
                    context.interpolationQuality = .high
                    context.draw(source, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                    guard let raster = context.makeImage() else { throw CommandError("Cannot create PNG raster.") }
                    let data = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                        throw CommandError("Cannot create PNG encoder.")
                    }
                    CGImageDestinationAddImage(destination, raster, nil)
                    guard CGImageDestinationFinalize(destination) else { throw CommandError("PNG encoding failed.") }
                    self.completion = .success(data as Data)
                } catch { self.completion = .failure(error) }
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion = .failure(error)
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion = .failure(error)
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        completion = .failure(CommandError("WebKit content process terminated."))
    }
}
#endif
