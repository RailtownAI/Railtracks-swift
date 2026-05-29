// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "RailtracksSwift",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "RailtracksSwift",
            targets: ["RailtracksSwift"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/RailtownAI/Conduit",
            branch: "main",
//            exact: "0.3.18",
            traits: [
                .trait(name: "OpenAI"),
                .trait(name: "OpenRouter"),
                .trait(name: "Anthropic"),
                .trait(name: "MLX"),
            ]
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.10.1"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            from: "600.0.0"
        ),
        .package(
            url: "https://github.com/FabricioSffair/RailtracksInstrumentationKit",
            branch: "main"
        ),
    ],
    targets: [
        .macro(
            name: "RTSMacro",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "RailtracksSwift",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Conduit", package: "Conduit"),
                .product(name: "RailtracksInstrumentationKit", package: "RailtracksInstrumentationKit"),
                "RTSMacro"
            ]
        ),
        .testTarget(
            name: "RailtracksSwiftTests",
            dependencies: ["RailtracksSwift"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
