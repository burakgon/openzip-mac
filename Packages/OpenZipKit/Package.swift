// swift-tools-version: 6.2
import PackageDescription

// Everything that is not user interface: listing an archive, extracting from it, creating
// and changing one, and what has to happen around that on a Mac (quarantine, resource
// forks, where extracted files end up). The app target only adds windows on top.
//
// The reading and writing itself is done by 7-Zip's console program, which the kit runs
// as a separate process. Its tests need that program: scripts/build-7zz.sh builds it.
let package = Package(
    name: "OpenZipKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenZipKit", targets: ["OpenZipKit"]),
    ],
    targets: [
        .target(name: "OpenZipKit"),
        .testTarget(
            name: "OpenZipKitTests",
            dependencies: ["OpenZipKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
