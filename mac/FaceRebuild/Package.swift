// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FaceRebuild",
    platforms: [.macOS(.v14)],
    targets: [
        // Logique de reconstruction (partagée par l'application et la ligne de commande)
        .target(name: "FaceRebuildCore", path: "Sources/FaceRebuildCore"),
        // Ligne de commande (facultatif)
        .executableTarget(name: "FaceRebuild", dependencies: ["FaceRebuildCore"], path: "Sources/FaceRebuild"),
        // Application avec fenêtre, lancée par « Reconstruction Visage.command »
        .executableTarget(name: "ReconstructionVisage", dependencies: ["FaceRebuildCore"], path: "Sources/ReconstructionVisage")
    ]
)
