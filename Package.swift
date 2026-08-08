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
    // File Pane 使用固定版本的 GFM 解析器和 highlight.js 包装。精确版本避免
    // 上游语法、资源 bundle 或 Swift 工具链要求在普通构建中漂移。
    .package(url: "https://github.com/smittytone/HighlighterSwift.git", exact: "3.1.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
  ],
  targets: [
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
    // Aster 需要在终端内核边界实现原生键盘选区、矩形选区与像素级滚动；
    // SwiftTerm 1.15 没有公开这些状态，因此以锁定上游 revision 的本地 target
    // 维护最小补丁。来源、许可证和同步流程记录在 Vendor/SwiftTerm/UPSTREAM.md。
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
        "SwiftTerm",
        .product(name: "Highlighter", package: "HighlighterSwift"),
      ]
    ),
    .testTarget(
      name: "AsterCoreTests",
      dependencies: ["AsterCore"]
    ),
    .testTarget(
      name: "AsterTests",
      dependencies: ["Aster", "AsterCore", "SwiftTerm"]
    ),
  ]
)
