// swift-tools-version:5.7
import PackageDescription

let package = Package(
  name: "ebur128",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "EBUR128", targets: ["EBUR128"])
  ],
  targets: [
    .executableTarget(
      name: "EBUR128",
      path: "src"
    )
  ]
)
