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
    // 独立 MCP server：Claude Code / Codex 经 stdio 只读查询 Session Memory，
    // 与主应用进程解耦，App 未运行时依然可查历史。
    .executable(name: "aster-memory-mcp", targets: ["AsterMemoryMCP"]),
  ],
  dependencies: [
    // HighlighterSwift 3.1.0 需要补充 macOS 发布包的资源定位：上游 `Bundle.module`
    // 会在脱离构建机后 fatalError，因此固定源码和补丁一起放在 Vendor 下维护。
    .package(path: "Vendor/HighlighterSwift"),
    // Markdown 解析器继续锁定精确版本，避免语法和 Swift 工具链要求静默漂移。
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    // Sparkle 的 SPM 包本体就是一个 remote binaryTarget，每个 tag 都会重写清单里的
    // url + checksum，SwiftPM 会对下载的 XCFramework 做 SHA256 校验，供应链风险已被
    // checksum 覆盖。这里用 `from:` 而不是其它依赖惯用的 `exact:`：更新器的安装与
    // 校验修复走 patch 版本，锁死会拿不到安全修复；可复现性由 Package.resolved 保证。
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
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
    // Session Memory 存储层：系统 libsqlite3 + FTS5，零外部依赖。
    // 领域模型留在 AsterCore；本 target 只做 SQL 编解码与文件布局。
    .target(
      name: "AsterMemory",
      dependencies: ["AsterCore"]
    ),
    // stdio JSON-RPC 2.0 的 MCP server，可执行名 aster-memory-mcp；只读开库。
    .executableTarget(
      name: "AsterMemoryMCP",
      dependencies: ["AsterCore", "AsterMemory"]
    ),
    .executableTarget(
      name: "Aster",
      dependencies: [
        "AsterCore",
        "AsterMemory",
        "GhosttyKit",
        "SwiftTerm",
        .product(name: "Highlighter", package: "HighlighterSwift"),
        .product(name: "Sparkle", package: "Sparkle"),
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
        // Sparkle 是动态 framework，install name 为
        // @rpath/Sparkle.framework/Versions/B/Sparkle。Xcode 会自动写
        // LD_RUNPATH_SEARCH_PATHS，SwiftPM 不会，必须手写，否则打好的 .app 在 dyld
        // 阶段就崩，连 build-app.sh 末尾的 --verify-packaged-resources 都跑不起来。
        // 代价：xctest 宿主不在 .app 布局里，测试须经 scripts/test.sh 注入
        // DYLD_FRAMEWORK_PATH（SwiftPM 对动态 binaryTarget 的已知缺口）。
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
      ]
    ),
    .testTarget(
      name: "AsterCoreTests",
      dependencies: ["AsterCore"]
    ),
    .testTarget(
      name: "AsterMemoryTests",
      dependencies: ["AsterMemory", "AsterCore"]
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
