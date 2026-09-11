// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "RailtracksSwift",
    platforms: [
        // currently limited by RailtracksInstrumentationKit,
        // can go lower or add tvOS, visionOS if update RailtracksInstrumentationKit's low limit
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "RailtracksSwift",
            targets: ["RailtracksSwift"]
        ),
        // SwiftUI views for observing a flow. A separate product so the core stays headless and
        // consumers opt in; it depends only on RailtracksSwift's public API.
        .library(
            name: "RailtracksSwiftUI",
            targets: ["RailtracksSwiftUI"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/RailtownAI/Conduit",
            exact: "0.3.23",
            traits: [
                .trait(name: "OpenAI"),
                .trait(name: "OpenRouter"),
                .trait(name: "Anthropic"),
                .trait(name: "Gemini"),
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
            url: "https://github.com/RailtownAI/railtracks-swift-instrumentation-kit",
            exact: "1.0.0"
        ),
        .package(
            url: "https://github.com/RailtownAI/railtown-swift-logger.git",
            .upToNextMinor(from: "0.3.2")
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
                .product(name: "RailtracksInstrumentationKit", package: "railtracks-swift-instrumentation-kit"),
                // `package:` is SPM's URL-derived identity (repo name), not the module name.
                .product(name: "RailtownLogger", package: "railtown-swift-logger"),
                "RTSMacro"
            ]
        ),
        .target(
            name: "RailtracksSwiftUI",
            dependencies: [
                "RailtracksSwift",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "RailtracksSwiftTests",
            dependencies: [
                "RailtracksSwift",
                "RailtracksSwiftUI",
                // GeminiOptionsTests asserts against Conduit's GenerateConfig / GeminiOptions
                // directly, so the import is declared rather than inherited transitively.
                .product(name: "Conduit", package: "Conduit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
