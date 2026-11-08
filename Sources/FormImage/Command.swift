import Foundation
import FourDFileKit
import FourDRender

public struct CommandError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct ImageSize: Equatable {
    public let width: Int
    public let height: Int

    public init(width: Double, height: Double, scale: Double, maximum: Int) throws {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 8192, height <= 8192,
              scale.isFinite, (0.1...4).contains(scale), (1...4096).contains(maximum) else {
            throw CommandError("Invalid canvas or raster limits.")
        }
        let factor = min(scale, Double(maximum) / max(width, height))
        self.width = max(1, min(maximum, Int(ceil(width * factor))))
        self.height = max(1, min(maximum, Int(ceil(height * factor))))
    }
}

public struct ImageCommand {
    public static let version = "0.1.0"
    public static let usage = """
    usage: fourdform [options] [--] path.4DForm
      --output, -o PATH      PNG destination (default: INPUT.preview.png)
      --theme NAME           classic-light (default; dark if form forces it), classic-dark,
                             liquid-glass-light, liquid-glass-dark
      --page N               Nonnegative page number (default: 1, else first)
      --language BCP47       Localization preference; repeat in priority order
                             (default: en, independent of system locale)
      --scale NUMBER         Pixels per form point, 0.1...4 (default: 1)
      --max-dimension N      Fit proportionally within 1...4096 pixels (default: 2048)
      --help, -h             Show help
      --version              Show version
    Static macOS reference preview; no 4D or Quick Look installation required.
    Exit status: 0 success/help, 2 usage error, 1 analysis/render/write error.
    """

    public let input: URL
    public let output: URL
    public var scale = 1.0
    public var maximum = 2048
    public var languages: [String] = []
    public var options = FormRenderOptions()

    public init(_ arguments: [String]) throws {
        var path: String?
        var destination: String?
        var index = 0
        var positionalOnly = false
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CommandError("\(flag) requires a value.") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            if positionalOnly || !argument.hasPrefix("-") {
                guard path == nil else { throw CommandError("Provide exactly one .4DForm path.") }
                path = argument
            } else {
                switch argument {
                case "--": positionalOnly = true
                case "--output", "-o": destination = try value(argument)
                case "--theme":
                    let name = try value(argument)
                    switch name {
                    case "classic-light": options.initialTheme = .classicLight
                    case "classic-dark": options.initialTheme = .classicDark
                    case "liquid-glass-light", "glass-light": options.initialTheme = .glassLight
                    case "liquid-glass-dark", "glass-dark": options.initialTheme = .glassDark
                    default: throw CommandError("Unknown theme: \(name).")
                    }
                case "--page":
                    guard let page = Int(try value(argument)), page >= 0 else {
                        throw CommandError("--page must be a nonnegative integer.")
                    }
                    options.initialPage = page
                case "--language":
                    let language = try value(argument)
                    guard !language.isEmpty, language.count <= 128,
                          language.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                        throw CommandError("--language must be a nonempty BCP47 language tag.")
                    }
                    languages.append(language)
                case "--scale":
                    guard let number = Double(try value(argument)), number.isFinite, (0.1...4).contains(number) else {
                        throw CommandError("--scale must be a finite number from 0.1 through 4.")
                    }
                    scale = number
                case "--max-dimension":
                    guard let number = Int(try value(argument)), (1...4096).contains(number) else {
                        throw CommandError("--max-dimension must be an integer from 1 through 4096.")
                    }
                    maximum = number
                default: throw CommandError("Unknown option: \(argument).")
                }
            }
            index += 1
        }
        guard let path else { throw CommandError("Provide a .4DForm path.") }
        input = URL(fileURLWithPath: path).standardizedFileURL
        guard input.pathExtension.lowercased() == "4dform" else {
            throw CommandError("Input must have the .4DForm extension.")
        }
        output = destination.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? input.deletingPathExtension().appendingPathExtension("preview.png")
        guard output.pathExtension.lowercased() == "png" else { throw CommandError("Output must have the .png extension.") }
        guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else {
            throw CommandError("The output must not replace the input form.")
        }
        if languages.isEmpty { languages = ["en"] }
    }

    public func render() throws -> FormRenderResult {
        let renderer = FormRenderer()
        let form = try renderer.analyze(url: input, preferredLanguages: languages)
        var selected = options
        if selected.initialTheme == nil {
            selected.initialTheme = form.properties["colorScheme"]?.string == "dark" ? .classicDark : .classicLight
        }
        return try renderer.render(form: form, options: selected)
    }
}
