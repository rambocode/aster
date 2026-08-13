// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "AsterTerminal",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AsterCore", targets: ["AsterCore"]),
    .executable(name: "Aster", targets: ["Aster"]),
  ],
  dependencies: [
    // HighlighterSwift 3.1.0 需要补充 macOS 发布包的资源定位：上游 `Bundle.module`
    // 会在脱离构建机后 fatalError，因此固定源码和补丁一起放在 Vendor 下维护。
    .package(path: "Vendor/HighlighterSwift"),
    // Markdown 解析器继续锁定精确版本，避免语法和 Swift 工具链要求静默漂移。
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
  ],
  targets: [
    // libghostty 目前只发布 internal C header，仓库因此锁定上游 revision 并在本地
    // 生成静态 XCFramework。来源、ABI 风险与更新流程记录在 Vendor/Ghostty/README.md。
    .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
    .target(
      name: "AsterPTY",
      publicHeadersPath: "include"
    ),
    .target(
      name: "AsterCore",
      dependencies: [
        "AsterPTY",
        .product(name: "Markdown", package: "swift-markdown"),
      ]
    ),
    // SwiftTerm 仅保留为迁移期回归适配器，让旧内核的精细行为测试仍可独立运行；
    // 产品终端由 GhosttyKit 承载，不再把 SwiftTerm 视图挂入工作区。
    .target(
      name: "SwiftTerm",
      path: "Vendor/SwiftTerm/Sources/SwiftTerm",
      exclude: ["Mac/README.md"],
      resources: [
        .process("Apple/Metal/Shaders.metal")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .executableTarget(
      name: "Aster",
      dependencies: [
        "AsterCore",
        "GhosttyKit",
        "SwiftTerm",
        .product(name: "Highlighter", package: "HighlighterSwift"),
      ],
      resources: [
        // libghostty 运行时从 GHOSTTY_RESOURCES_DIR 寻找 shell integration，并从
        // 同级目录推导 terminfo。两个目录必须保持层级，不能使用 `.process` 扁平化。
        .copy("Ghostty/Resources/ghostty"),
        .copy("Ghostty/Resources/terminfo"),
      ],
      swiftSettings: [
        .unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"]),
      ],
      linkerSettings: [
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
    .testTarget(
      name: "AsterCoreTests",
      dependencies: ["AsterCore"]
    ),
    .testTarget(
      name: "AsterTests",
      dependencies: [
        "Aster",
        "AsterCore",
        "SwiftTerm",
        .product(name: "Highlighter", package: "HighlighterSwift"),
      ]
    ),
  ]
)
