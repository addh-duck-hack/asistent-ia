// swift-tools-version: 6.0
// App macOS como Swift Package: se abre en Xcode con File > Open > Package.swift
// y se compila con `swift build`. Para firmar/notarizar (Fase 5) se migra a .xcodeproj.
import PackageDescription

let package = Package(
    name: "AsistentIA",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AsistentIA",
            path: "Sources/AsistentIA"
        ),
        .testTarget(
            name: "AsistentIATests",
            dependencies: ["AsistentIA"],
            path: "Tests/AsistentIATests"
        ),
    ]
)
