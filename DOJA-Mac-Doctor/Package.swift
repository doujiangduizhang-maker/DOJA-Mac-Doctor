// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DOJAMacDoctor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DOJAMacDoctor", targets: ["DoctorApp"]),
        .executable(name: "doctor-scan", targets: ["DoctorCLI"]),
        .library(name: "DoctorCore", targets: ["DoctorCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "DoctorCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "DoctorApp", dependencies: ["DoctorCore"]),
        .executableTarget(name: "DoctorCLI", dependencies: ["DoctorCore"]),
        .testTarget(name: "DoctorCoreTests", dependencies: ["DoctorCore"])
    ]
)
