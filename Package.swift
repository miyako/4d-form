// swift-tools-version: 5.9
import PackageDescription

var formImageDependencies: [Target.Dependency] = [
    .product(name: "FourDFileKit", package: "4d-ql"),
    .product(name: "FourDRender", package: "4d-ql"),
]
var targets: [Target] = []

#if os(Windows)
// Build-time WebView2 SDK, fetched and checksum-verified by scripts/fetch-webview2.ps1.
let webView2 = Context.packageDirectory + "/Sources/CWebView2Raster/vendor"
formImageDependencies.append("CWebView2Raster")
targets.append(.target(
    name: "CWebView2Raster",
    exclude: ["vendor"],
    cxxSettings: [.headerSearchPath("vendor/include")],
    linkerSettings: [.unsafeFlags(["-L" + webView2 + "/lib"])]))
#endif

targets += [
    .target(name: "FormImage", dependencies: formImageDependencies),
    .executableTarget(name: "FourDFormCLI", dependencies: ["FormImage"], path: "Sources/fourdform"),
    .testTarget(name: "FormImageTests", dependencies: ["FormImage"],
                resources: [.copy("Fixtures")]),
]

let package = Package(
    name: "FourDForm",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "fourdform", targets: ["FourDFormCLI"])],
    dependencies: [
        .package(url: "https://github.com/miyako/4d-ql.git",
                 revision: "42580e8c0d1c1c5506d349c4c2e071c40fc0e02c")
    ],
    targets: targets,
    cxxLanguageStandard: .cxx17
)
