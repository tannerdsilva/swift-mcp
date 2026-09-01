// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "MCP",
            targets: ["MCP"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.76.0"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.0"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            from: "602.0.0"
        ),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            from: "2.6.0"
        ),
        .package(
            url: "https://github.com/apple/swift-docc-plugin.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        // --- Main MCP library ---
        .target(
            name: "MCP",
            dependencies: [
                .target(name: "MCPMacros"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // --- Macro implementation ---
        .macro(
            name: "MCPMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // --- Unit tests ---
        .testTarget(
            name: "MCPTests",
            dependencies: ["MCP", "MCPMacros"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // --- Macro tests ---
        .testTarget(
            name: "MCPMacroTests",
            dependencies: [
                "MCPMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
