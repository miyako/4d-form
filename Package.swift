// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FourDForm",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "fourdform", targets: ["FourDFormCLI"])],
    dependencies: [
        .package(url: "https://github.com/miyako/4d-ql.git",
                 revision: "2be2142b1efdba4e1ad4f28e5b9fc0eaf6ddc61b")
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
