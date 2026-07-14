// swift-tools-version: 6.0

import PackageDescription
import Foundation

var coreCSettings: [CSetting] = [
    .unsafeFlags(["-Wall", "-Wextra", "-Werror", "-Wpedantic"]),
]
if ProcessInfo.processInfo.environment["SHOCKEMU_CORE_COVERAGE"] == "1" {
    coreCSettings.append(.unsafeFlags(["-fprofile-instr-generate", "-fcoverage-mapping"]))
}

let package = Package(
    name: "ShockEmu",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ShockEmuCore", targets: ["ShockEmuCore"]),
        .library(name: "ShockEmuRuntime", type: .dynamic, targets: ["ShockEmuRuntime"]),
        .executable(name: "shockemu", targets: ["shockemu"]),
        .executable(name: "InterposeHarness", targets: ["InterposeHarness"]),
    ],
    targets: [
        .target(
            name: "ShockEmuCore",
            publicHeadersPath: "include",
            cSettings: coreCSettings,
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .target(
            name: "ShockEmuRuntime",
            dependencies: ["ShockEmuCore"],
            cSettings: [
                .unsafeFlags(["-Wall", "-Wextra", "-Werror", "-Wpedantic"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "shockemu",
            dependencies: ["ShockEmuCore"],
            swiftSettings: [
                .unsafeFlags(["-warnings-as-errors"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "InterposeHarness",
            cSettings: [
                .unsafeFlags(["-Wall", "-Wextra", "-Werror", "-Wpedantic"]),
            ],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "ShockEmuCoreTests",
            dependencies: ["ShockEmuCore"]
        ),
        .testTarget(
            name: "ShockEmuCLITests",
            dependencies: ["shockemu"]
        ),
    ]
)
