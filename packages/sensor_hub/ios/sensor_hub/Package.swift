// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "sensor_hub",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "sensor-hub", targets: ["sensor_hub"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "sensor_hub",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
