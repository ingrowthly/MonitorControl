// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "AutoBrightnessCore",
  platforms: [.macOS(.v10_14)],
  products: [
    .library(name: "AutoBrightnessCore", targets: ["AutoBrightnessCore"]),
    .executable(name: "SensorProbe", targets: ["SensorProbe"]),
  ],
  targets: [
    .target(
      name: "AutoBrightnessCore",
      linkerSettings: [
        .linkedFramework("CoreBluetooth"),
        .linkedFramework("IOKit"),
      ]
    ),
    .testTarget(
      name: "AutoBrightnessCoreTests",
      dependencies: ["AutoBrightnessCore"]
    ),
    .executableTarget(
      name: "SensorProbe",
      dependencies: ["AutoBrightnessCore"]
    ),
  ]
)
