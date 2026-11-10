// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkspaceTabs",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WorkspaceTabs", targets: ["WorkspaceTabs"])],
    targets: [
        .target(name: "WorkspaceCore", resources: [.process("Resources")]),
        .executableTarget(name: "WorkspaceTabs", dependencies: ["WorkspaceCore"]),
        .executableTarget(name: "WorkspaceCoreChecks", dependencies: ["WorkspaceCore"], path: "Tests/WorkspaceCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
