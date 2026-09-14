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
        // Retrieval-augmented generation: loaders, chunkers, embedders and vector stores.
        // A separate product so consumers opt in — the SPM equivalent of the Python engine's
        // `pip install railtracks[retrieval]` extra — and so the module stays cheap to extract
        // into its own repository later.
        .library(
            name: "RailtracksSwiftRAG",
            targets: ["RailtracksSwiftRAG"]
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
            .upToNextMinor(from: "0.3.1")
        ),
        // Declared rather than relied on transitively through Conduit: RailtracksSwiftRAG hashes
        // document sources and content, and an undeclared import would break the moment that
        // module is lifted into its own package.
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            from: "4.5.0"
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
        // Retrieval / RAG. Deliberately **does not depend on RailtracksSwift**: nothing in the
        // pipeline needs agent orchestration. Embedding goes straight to Conduit, and even the
        // semantic chunker splits on embedding distance rather than asking a model. The Python
        // engine's `railtracks/retrieval` is standalone for the same reason — it imports the
        // agent runtime nowhere, leaving the tool wrapper to user code.
        //
        // That keeps the module liftable into its own package by moving the folder.
        .target(
            name: "RailtracksSwiftRAG",
            dependencies: [
                .product(name: "Conduit", package: "Conduit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
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
        .testTarget(
            name: "RailtracksSwiftRAGTests",
            dependencies: [
                "RailtracksSwiftRAG",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
