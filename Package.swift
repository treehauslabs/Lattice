// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lattice",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Lattice",
            targets: ["Lattice"]),
        .executable(
            name: "LatticeDemo",
            targets: ["LatticeDemo"]),
        .executable(
            name: "LatticeNode",
            targets: ["LatticeNode"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "4.0.0"),
        .package(url: "https://github.com/treehauslabs/cashew.git", branch: "master"),
        .package(url: "https://github.com/hyugit/UInt256.git", branch: "master"),
        .package(url: "https://github.com/swift-libp2p/swift-cid.git", from: "0.0.1"),
        .package(url: "https://github.com/JohnSundell/CollectionConcurrencyKit.git", from: "0.2.0"),
        .package(url: "https://github.com/treehauslabs/Acorn.git", from: "1.0.0"),
        .package(url: "https://github.com/treehauslabs/AcornDiskWorker.git", branch: "master"),
        .package(url: "https://github.com/treehauslabs/Tally.git", from: "1.0.0"),
        .package(url: "https://github.com/treehauslabs/Ivy.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Lattice",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "CID", package: "swift-cid"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "CollectionConcurrencyKit", package: "CollectionConcurrencyKit"),
                .product(name: "Acorn", package: "Acorn"),
                .product(name: "AcornDiskWorker", package: "AcornDiskWorker"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "Ivy", package: "Ivy"),
            ]),
        .executableTarget(
            name: "LatticeDemo",
            dependencies: ["Lattice"]),
        .executableTarget(
            name: "LatticeNode",
            dependencies: ["Lattice"]),
        .testTarget(
            name: "LatticeTests",
            dependencies: ["Lattice"])
    ]
)
