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
  dependencies: [],
  targets: [
    .target(
      name: "AsterPTY",
      publicHeadersPath: "include"
    ),
    .target(
      name: "AsterCore",
      dependencies: ["AsterPTY"]
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
