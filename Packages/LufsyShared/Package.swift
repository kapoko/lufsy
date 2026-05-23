// swift-tools-version:5.7
import PackageDescription

let package = Package(
  name: "LufsyShared",
  platforms: [
    .macOS("14.4")
  ],
  products: [
    .library(name: "LufsyShared", targets: ["LufsyShared"])
  ],
  targets: [
    .target(name: "LufsyShared"),
    .testTarget(name: "LufsySharedTests", dependencies: ["LufsyShared"]),
  ]
)
