// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EvidenceContract",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EvidenceContract", targets: ["EvidenceContract"])
    ],
    targets: [
        .target(name: "EvidenceContract"),
        .testTarget(name: "EvidenceContractTests", dependencies: ["EvidenceContract"])
    ]
)
