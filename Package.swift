// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TravelLockdown",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "TravelLockdown", targets: ["TravelLockdown"])],
    targets: [
        .executableTarget(
            name: "TravelLockdown",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SecurityFoundation")
            ]
        ),
        .testTarget(name: "TravelLockdownTests", dependencies: ["TravelLockdown"])
    ]
)
