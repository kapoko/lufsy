// swift-tools-version:5.7
import PackageDescription

let package = Package(
  name: "lufsy",
  platforms: [
    .macOS("14.4")
  ],
  products: [
    .executable(name: "Lufsy", targets: ["Lufsy"])
  ],
  dependencies: [
    .package(url: "https://github.com/kapoko/sparkle-updater", branch: "main")
  ],
  targets: [
    .executableTarget(
      name: "Lufsy",
      dependencies: [
        .product(name: "SparkleUpdater", package: "sparkle-updater")
      ],
      path: "src"
    )
  ]
)
