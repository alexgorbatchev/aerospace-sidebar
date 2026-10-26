// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "aerospace-sidebar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AerospaceSidebar", targets: ["AerospaceSidebar"]),
        .executable(name: "aerospace-sidebar", targets: ["AerospaceSidebarCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
        .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.5"),
    ],
    targets: [
        .target(name: "SidebarProtocol"),
        .target(
            name: "SidebarKit",
            dependencies: [
                "SidebarProtocol",
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                .product(name: "TOML", package: "swift-toml"),
            ]
        ),
        .executableTarget(
            name: "AerospaceSidebar",
            dependencies: ["SidebarKit"]
        ),
        .target(
            name: "SidebarCLI",
            dependencies: [
                "SidebarProtocol",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "AerospaceSidebarCLI",
            dependencies: ["SidebarCLI"]
        ),
        .testTarget(
            name: "SidebarProtocolTests",
            dependencies: ["SidebarProtocol"]
        ),
        .testTarget(
            name: "SidebarKitTests",
            dependencies: [
                "SidebarKit",
                "AerospaceSidebar",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ]
        ),
        .testTarget(
            name: "SidebarCLITests",
            dependencies: [
                "SidebarCLI",
                "AerospaceSidebarCLI",
            ]
        ),
    ]
)
