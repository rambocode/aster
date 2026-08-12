// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "AsterGhosttyPane",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AsterGhosttyPane", targets: ["AsterGhosttyPane"])
  ],
  targets: [
    // GhosttyKit 是 libghostty internal C API 的静态 XCFramework。它不进入主
    // Package.swift，避免未运行 setup 的 checkout 连 Aster 本身也无法构建。
    .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),
    .executableTarget(
      name: "AsterGhosttyPane",
      dependencies: ["GhosttyKit"],
      path: "Sources/GhosttyPane",
      // 目录结构是 libghostty 的运行时 contract：GHOSTTY_RESOURCES_DIR 指向
      // ghostty/，内核再从它推导同级 terminfo/。`.process("Resources")` 会把
      // 文件扁平化，因此必须逐目录 copy。
      resources: [
        .copy("Resources/README.md"),
        .copy("Resources/THIRD_PARTY_NOTICES.txt"),
        .copy("Resources/ghostty"),
        .copy("Resources/terminfo"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5),
        .unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"]),
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Carbon"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreText"),
        .linkedFramework("IOKit"),
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("QuartzCore"),
        .linkedLibrary("c++"),
      ]
    ),
  ]
)
