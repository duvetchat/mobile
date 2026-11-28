// swift-tools-version: 5.9
// Written by tool/vendor_core.sh: the core's framework for iOS, which its CI built, as a binary target.

import PackageDescription

let package = Package(
    name: "duvet_e2e",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "duvet-e2e", targets: ["duvet_e2e"])
    ],
    targets: [
        .binaryTarget(name: "duvet_e2e", path: "Frameworks/duvet_e2e.xcframework")
    ]
)
