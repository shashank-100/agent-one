// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhoneUse",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PhoneUseCore", targets: ["PhoneUseCore"]),
        .library(name: "PhoneUseUI", targets: ["PhoneUseUI"]),
    ],
    targets: [
        .target(name: "PhoneUseCore"),
        .target(name: "PhoneUseUI", dependencies: ["PhoneUseCore"]),
        .executableTarget(name: "phoneuse-probe", dependencies: ["PhoneUseCore"]),
        .executableTarget(name: "phoneuse-host", dependencies: ["PhoneUseCore"]),
        .executableTarget(name: "phoneuse-run", dependencies: ["PhoneUseCore"]),
    ]
)
