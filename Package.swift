// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlightCore",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FlightCore", path: "Sources/FlightCore")
    ]
)
