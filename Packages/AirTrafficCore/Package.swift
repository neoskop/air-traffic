// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirTrafficCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AirTrafficCore", targets: ["AirTrafficCore"]),
    ],
    targets: [
        // Kleiner ObjC-Helfer: NSPredicate(format:) wirft bei Parse-Fehlern eine
        // NSException, die Swift nicht fangen kann.
        .target(name: "AirTrafficCoreObjC"),
        .target(name: "AirTrafficCore", dependencies: ["AirTrafficCoreObjC"]),
        .testTarget(
            name: "AirTrafficCoreTests",
            dependencies: ["AirTrafficCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
