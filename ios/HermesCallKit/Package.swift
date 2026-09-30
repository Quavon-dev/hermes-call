// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesCallKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [.library(name: "HermesCallCore", targets: ["HermesCallCore"])],
    dependencies: [.package(url: "https://github.com/jedisct1/swift-sodium", exact: "0.11.0")],
    targets: [
        .target(
            name: "CCPace",
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("shim")]
        ),
        .target(
            name: "HermesCallCore",
            dependencies: ["CCPace", .product(name: "Clibsodium", package: "swift-sodium")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "HermesCallCoreTests", dependencies: ["HermesCallCore"]),
    ]
)
