// swift-tools-version:5.7
import Foundation
import PackageDescription

let includesProPackage = ProcessInfo.processInfo.environment["LUFSY_PRO"] == "true"

var dependencies: [Package.Dependency] = [
  .package(url: "https://github.com/kapoko/sparkle-updater", from: "0.1.0"),
  .package(path: "Packages/LufsyShared"),
]

if includesProPackage {
  dependencies.append(.package(path: "../../Packages/LufsyPro"))
}

var lufsyTargetDependencies: [Target.Dependency] = [
  .product(name: "SparkleUpdater", package: "sparkle-updater"),
  .product(name: "LufsyShared", package: "lufsyshared"),
]

if includesProPackage {
  lufsyTargetDependencies.append(.product(name: "LufsyPro", package: "lufsypro"))
}

let package = Package(
  name: "lufsy",
  platforms: [
    .macOS("14.4")
  ],
  products: [
    .executable(name: "Lufsy", targets: ["Lufsy"])
  ],
  dependencies: dependencies,
  targets: [
    .executableTarget(
      name: "Lufsy",
      dependencies: lufsyTargetDependencies,
      path: "src",
      swiftSettings: includesProPackage ? [.define("LUFSY_PRO")] : []
    )
  ]
)
