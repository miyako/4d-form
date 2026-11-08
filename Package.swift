// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FourDForm",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "fourdform", targets: ["FourDFormCLI"])],
    dependencies: [
        .package(url: "https://github.com/miyako/4d-ql.git",
                 revision: "31e7608805cd71c19590780a6f9c91b9c506af4b")
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
