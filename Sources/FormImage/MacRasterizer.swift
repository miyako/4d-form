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
        // Work only on trusted, escaped upstream markup. Never evaluate form methods or events.
        let prepare = """
        const svg = [...document.querySelectorAll('.form-page > .form-scroll > svg')]
          .find(s => s.closest('.form-appearance').offsetHeight > 0 &&
                     s.closest('.form-page').offsetHeight > 0);
        if (!svg) throw new Error('No selected form canvas in shared renderer output');
        const width = Number(svg.getAttribute('width'));
        const height = Number(svg.getAttribute('height'));
        if (!(width >= 1 && height >= 1 && width <= 8192 && height <= 8192))
          throw new Error('Invalid shared canvas size');
        await document.fonts.ready;
        await Promise.all([...document.querySelectorAll('image')].map(async node => {
          const image = new Image();
          image.src = node.getAttribute('href');
          await image.decode();
        }));
        const preview = document.querySelector('.form-preview');
        const appearance = svg.closest('.form-appearance');
        for (const node of [...document.querySelectorAll('body style')]) document.head.appendChild(node);
        document.body.replaceChildren(preview);
        for (const node of [...preview.children]) {
          if (node !== appearance && node.tagName !== 'STYLE' && node.tagName !== 'svg') node.remove();
        }
        for (const node of [...appearance.children]) {
          if (!node.contains(svg)) node.remove();
        }
        const style = document.createElement('style');
        style.textContent = `html,body{margin:0!important;padding:0!important;overflow:hidden!important}
          body *{animation:none!important;transition:none!important}
          .form-preview,.form-appearance,.form-page,.form-scroll{margin:0!important;
          padding:0!important;border:0!important;max-width:none!important;max-height:none!important;
          overflow:visible!important}
          .form-caption,.form-themes,.form-pages{display:none!important}
          .form-appearance,.form-page{display:block!important}
          .form-scroll>svg{display:block!important}`;
        document.head.appendChild(style);
        return {width,height};
        """
        webView.callAsyncJavaScript(prepare, arguments: [:], in: nil, in: .page) { result in
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
        let script = """
        const svg = document.querySelector('.form-page > .form-scroll > svg');
        svg.setAttribute('width', width); svg.setAttribute('height', height);
        return {width: svg.getBoundingClientRect().width, height: svg.getBoundingClientRect().height};
        """
        view.callAsyncJavaScript(script, arguments: ["width": size.width, "height": size.height],
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
