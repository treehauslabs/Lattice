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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "4.0.0"),
        .package(url: "https://github.com/treehauslabs/cashew.git", from: "1.12.0"),
        .package(url: "https://github.com/treehauslabs/UInt256.git", from: "1.1.0"),
        .package(url: "https://github.com/swift-libp2p/swift-cid.git", from: "0.0.1"),
        .package(url: "https://github.com/JohnSundell/CollectionConcurrencyKit.git", from: "0.2.0"),
        .package(url: "https://github.com/jectivex/JXKit.git", from: "3.6.0"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.23.0"),
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
                .product(name: "JXKit", package: "JXKit"),
                .product(name: "P256K", package: "swift-secp256k1"),
            ]),
        .executableTarget(
            name: "LatticeDemo",
            dependencies: ["Lattice"]),
        .testTarget(
            name: "LatticeTests",
            dependencies: ["Lattice"])
    ]
)
