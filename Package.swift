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
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.15.0")
  ],
  targets: [
    .target(
      name: "AsterPTY",
      publicHeadersPath: "include"
    ),
    .target(
      name: "AsterCore",
      dependencies: ["AsterPTY"]
    ),
    .executableTarget(
      name: "Aster",
      dependencies: [
        "AsterCore",
        .product(name: "SwiftTerm", package: "SwiftTerm"),
      ]
    ),
    .testTarget(
      name: "AsterCoreTests",
      dependencies: ["AsterCore"]
    ),
    .testTarget(
      name: "AsterTests",
      dependencies: ["Aster", "AsterCore"]
    ),
  ]
)
