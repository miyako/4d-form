// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FourDForm",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "fourdform", targets: ["FourDFormCLI"])],
    dependencies: [
        .package(url: "https://github.com/miyako/4d-ql.git",
                 revision: "42580e8c0d1c1c5506d349c4c2e071c40fc0e02c")
    ],
    targets: [
        .target(name: "FormImage",
                dependencies: [.product(name: "FourDFileKit", package: "4d-ql"),
                               .product(name: "FourDRender", package: "4d-ql")]),
        .executableTarget(name: "FourDFormCLI", dependencies: ["FormImage"], path: "Sources/fourdform"),
        .testTarget(name: "FormImageTests", dependencies: ["FormImage"],
                    resources: [.copy("Fixtures")])
    ]
)
