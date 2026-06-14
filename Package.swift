// swift-tools-version:6.2
import PackageDescription

// SuperBox64 SpriteKit — a Swift WebAssembly reimplementation of Apple's
// SpriteKit, plus drop-in shims for AppKit / UIKit / GameKit / GameplayKit /
// GameController / AVFoundation / AudioToolbox / Cocoa. A game written for
// macOS or iOS adds this package as a dependency, picks the modules it imports,
// and compiles to wasm32-wasip1 unchanged.
//
// Everything compiles under Swift 6 language mode. The Apple-mirror global
// singletons (UIScreen.main / NSScreen.main / GKLocalPlayer.local / etc.) are
// marked nonisolated(unsafe): the wasm target is single-threaded, so there is
// no real concurrency to police, but the keyword is required for v6 to accept
// the mutable shared globals.
let package = Package(
    name: "SuperBox64Kit",
    products: [
        .library(name: "SpriteKit",      targets: ["SpriteKit"]),
        .library(name: "KitABI",         targets: ["KitABI"]),
        .library(name: "AppKit",         targets: ["AppKit"]),
        .library(name: "UIKit",          targets: ["UIKit"]),
        .library(name: "Cocoa",          targets: ["Cocoa"]),
        .library(name: "GameKit",        targets: ["GameKit"]),
        .library(name: "GameplayKit",    targets: ["GameplayKit"]),
        .library(name: "GameController", targets: ["GameController"]),
        .library(name: "AVFoundation",   targets: ["AVFoundation"]),
        .library(name: "AudioToolbox",   targets: ["AudioToolbox"]),
        .library(name: "CBox2D",         targets: ["CBox2D"]),
        .library(name: "CSDL3",          targets: ["CSDL3"]),
        .library(name: "CWamr",          targets: ["CWamr"]),
        .library(name: "CZip",           targets: ["CZip"]),
        .library(name: "Combine",        targets: ["Combine"]),
        .library(name: "SwiftUI",        targets: ["SwiftUI"]),
    ],
    targets: [
        // Box2D v3 (pure C, vendored from erincatto/box2d v3.1.1). Swift imports
        // the C API directly — no C++ bridge, no libc++ in the link. Each
        // function/data lands in its own section so the linker's gc-sections
        // keeps only the physics a game actually calls (unused joints, casts,
        // movers and the rest of the API drop out of the wasm).
        .target(
            name: "CBox2D",
            path: "Sources/CBox2D",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .define("NDEBUG"),
                .unsafeFlags(["-ffunction-sections", "-fdata-sections"]),
            ]
        ),
        .target(
            name: "CSDL3",
            path: "Sources/CSDL3",
            sources: ["src"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CWamr",
            path: "Sources/CWamr",
            sources: ["src"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CZip",
            path: "Sources/CZip",
            sources: ["src"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(name: "KitABI"),
        .target(name: "SpriteKit",      dependencies: ["KitABI", "CBox2D"],
                swiftSettings: []),
        .target(name: "AppKit",         dependencies: ["SpriteKit"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "UIKit",          dependencies: ["SpriteKit", "AppKit", "KitABI"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "Cocoa",          dependencies: ["AppKit"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "GameKit",        dependencies: ["SpriteKit", "UIKit", "KitABI"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "GameplayKit",    dependencies: ["SpriteKit", "KitABI"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "GameController", dependencies: ["SpriteKit", "KitABI"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "AVFoundation",   dependencies: ["SpriteKit", "KitABI"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "AudioToolbox",   swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "Combine",        swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "SwiftUI",        dependencies: ["Combine", "SpriteKit"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
