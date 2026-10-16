import Foundation
import FaceRebuildCore

// Ligne de commande (facultatif, l'application « Reconstruction Visage » fait la même chose avec une fenêtre) :
//   swift run -c release FaceRebuild <dossier_ou_zip> [dossier_sortie] [--polygons 600000] [--detail custom|full|medium|reduced|raw] [--no-mask]

var args = Array(CommandLine.arguments.dropFirst())
var options = ReconstructionOptions()
if let i = args.firstIndex(of: "--polygons"), i + 1 < args.count {
    options.polygons = UInt(args[i + 1]) ?? options.polygons
    args.removeSubrange(i...(i + 1))
}
if let i = args.firstIndex(of: "--no-mask") {
    options.useMask = false
    args.remove(at: i)
}
if let i = args.firstIndex(of: "--detail"), i + 1 < args.count {
    options.detail = DetailChoice(rawValue: args[i + 1]) ?? .custom
    args.removeSubrange(i...(i + 1))
}
guard let first = args.first else {
    FileHandle.standardError.write("usage : FaceRebuild <dossier_ou_zip> [dossier_sortie] [--polygons 600000] [--detail custom|full|medium|reduced|raw] [--no-mask]\n".data(using: .utf8)!)
    exit(1)
}
let input = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
let output = args.count > 1 ? URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath, isDirectory: true) : nil

do {
    _ = try await Reconstructor.run(input: input, output: output, options: options,
                                    log: { print($0) }, progress: { _ in })
} catch {
    FileHandle.standardError.write(("Erreur : \(error)\n").data(using: .utf8)!)
    exit(1)
}
