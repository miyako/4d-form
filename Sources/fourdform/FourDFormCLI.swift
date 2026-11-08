import AppKit
import FormImage
import Foundation

func fail(_ error: Error, status: Int32) -> Never {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(status)
}

@main struct FourDFormCLI {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(ImageCommand.usage)
            exit(0)
        }
        if arguments == ["--version"] {
            print("fourdform \(ImageCommand.version)")
            exit(0)
        }
        let command: ImageCommand
        do { command = try ImageCommand(arguments) }
        catch { fail(error, status: 2) }

        do {
            let rendered = try command.render()
            for notice in rendered.document.notices {
                FileHandle.standardError.write(Data("warning: \(notice)\n".utf8))
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let data = try MacRasterizer().png(html: rendered.html, scale: command.scale, maximum: command.maximum)
            try data.write(to: command.output, options: .atomic)
            print(command.output.path)
        } catch { fail(error, status: 1) }
    }
}
