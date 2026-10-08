// swift-tools-version: 6.3

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
        ),
        // Test kit for packages that author their own tool packs: spawn a
        // built one-shot binary, drive its stdin, read its exit.
        .library(
            name: "MCPToolTestKit",
            targets: ["MCPToolTestKit"]
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
            url: "https://github.com/apple/swift-syntax.git",
            "603.0.0"..<"604.0.0"
        ),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            from: "2.6.0"
        ),
        .package(
            url: "https://github.com/apple/swift-docc-plugin.git",
            from: "1.0.0"
        ),
        // QuickJSON v2 — Foundation-free JSON codec (yyjson-backed).
        .package(
            url: "https://github.com/tannerdsilva/QuickJSON.git",
            from: "2.0.3"
        ),
        // SwiftSlash v5 — bring-your-own data channels: bind a caller-owned
        // NIO pipe channel onto a spawned child's stdio while SwiftSlash
        // handles spawn, reaping, and cancellation only.
        .package(
            url: "https://github.com/tannerdsilva/SwiftSlash.git",
            from: "5.0.0"
        ),
        // ArgumentParser — used only by the two-file pack fixture, which
        // compile-checks the selective-import layout a pack with its own CLI
        // needs. The library itself does not depend on it.
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
    ],
    targets: [
        // --- Test fixture server ---
        //
        // standalone `@MCPApplication` executable spawned by the real-client
        // integration verification (mcp-python SDK over stdio) and later by
        // the Phase 2 subprocess-client tests. not part of the library.
        .executableTarget(
            name: "MCPFixtureServer",
            dependencies: ["MCP"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // --- Test fixture stdin tool ---
        //
        // a compiled `interface: .oneShot` binary spawned by the end-to-end
        // suite: plugin envelope, JSON-RPC, introspection, exit contract.
        // not part of the library.
        .executableTarget(
            name: "MCPFixtureTool",
            dependencies: ["MCP"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // --- Test fixture: two-file pack layout ---
        //
        // compile-checks the selective-import template a pack with its own CLI
        // needs: MCP tools in one file, an ArgumentParser entry in another.
        // `import MCP` in the entry file would collide with ArgumentParser's
        // own `@Argument`/`@Option`/`@Flag`/`@OptionGroup`. not part of the
        // library.
        .executableTarget(
            name: "MCPTwoFilePack",
            dependencies: [
                "MCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // --- Reference tool pack: the fleet model ---
        //
        // twelve tools in one `interface: .oneShot` binary, spanning every
        // return shape the facade supports (Void, String, Int, Codable,
        // throwing, debug-only, access-gated). the worked example the pack
        // article points at. not part of the library.
        .executableTarget(
            name: "MCPToolPack",
            dependencies: ["MCP"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

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
                .product(name: "QuickJSON", package: "QuickJSON"),
                .product(name: "SwiftSlash", package: "SwiftSlash"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // --- Test kit for pack authors ---
        //
        // spawns a built one-shot tool binary and drives it the way a harness
        // does: real process, real pipes, real exit codes. Foundation is fine
        // here — this target is not on the library's wire path.
        .target(
            name: "MCPToolTestKit",
            dependencies: [
                .product(name: "QuickJSON", package: "QuickJSON"),
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
                .product(name: "SwiftParser", package: "swift-syntax"),
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
            dependencies: [
                "MCP",
                "MCPMacros",
                "MCPToolTestKit",
                .product(name: "QuickJSON", package: "QuickJSON"),
                .product(name: "SwiftSlash", package: "SwiftSlash"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
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
