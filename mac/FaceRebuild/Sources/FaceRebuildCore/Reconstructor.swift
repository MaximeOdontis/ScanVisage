import Foundation
import RealityKit
import CoreVideo
import simd

public struct ReconstructionError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public enum DetailChoice: String, CaseIterable {
    case custom, full, medium, reduced, raw
}

public struct ReconstructionOptions {
    /// Nombre maximal de polygones du modèle brut (niveau « custom »). « full » plafonne à environ 100 000.
    public var polygons: UInt = 600_000
    public var detail: DetailChoice = .custom
    /// Masques de la tête calculés sur l'iPhone (recommandé).
    public var useMask = true
    /// Texture 16K au lieu de 8K : c'est la texture, pas le nombre de polygones, qui donne l'aspect photo-réaliste.
    public var highTexture = false
    /// Version HD+Mouth : plein détail dans la zone de la bouche, maillage allégé ailleurs
    /// (nécessite une séquence bouche dans la capture).
    public var hdMouth = false
    /// Taille de cellule (mm) du maillage allégé hors de la bouche.
    public var outsideCellMm = 0.6
    /// Demi-dimensions (m) de la zone bouche autour de son centre : X, Y, Z du repère du visage.
    public var mouthHalfSize = SIMD3<Double>(0.05, 0.04, 0.05)
    public init() {}
}

public struct ReconstructionResult {
    public let outputFolder: URL
    public let photos: Int
    public let posesFound: Int
    public let scaleFactor: Double
    public let cameraDeviationMm: Double
    public let triangles: Int
    public let mouthPhotos: Int
    public let hdMouthApplied: Bool
    public let mainSTLName: String
}

public struct CaptureInfo {
    public let photos: Int
    public let mouthPhotos: Int
    public let appVersion: String?
    public let date: String
}

/// Reconstruction photogrammétrique d'un visage à partir d'une capture de l'app iPhone (mode Photo HD).
///
/// Étapes : Object Capture d'Apple avec masques de la tête -> poses des caméras ->
/// mise à l'échelle et orientation par les poses ARKit (similitude de Horn) -> repère du visage ->
/// découpe -> exports en millimètres : visage.stl, visage_couleur.ply, visage.obj (+ texture).
public enum Reconstructor {

    public typealias Log = @Sendable (String) -> Void
    public typealias Progress = @Sendable (Double) -> Void

    /// Résumé d'un dossier de capture (contenant capture.json).
    public static func inspect(_ folder: URL) throws -> CaptureInfo {
        let data = try Data(contentsOf: folder.appendingPathComponent("capture.json"))
        let c = try JSONDecoder().decode(PhotoCapture.self, from: data)
        return CaptureInfo(photos: c.frames.count,
                           mouthPhotos: c.frames.filter { $0.segment == "bouche" }.count,
                           appVersion: c.appVersion, date: c.date)
    }

    /// Point le plus proche de tous les axes optiques des photos (monde ARKit, mètres) : centre de la bouche visée.
    static func intersectAxes(_ frames: [PhotoFrame]) -> SIMD3<Double>? {
        var A = simd_double3x3(diagonal: SIMD3<Double>(0, 0, 0))
        var b = SIMD3<Double>(0, 0, 0)
        var n = 0
        for f in frames where f.cameraToWorld.count == 16 {
            let m = f.cameraToWorld
            let p = SIMD3<Double>(Double(m[12]), Double(m[13]), Double(m[14]))
            var d = -SIMD3<Double>(Double(m[8]), Double(m[9]), Double(m[10]))
            let l = simd_length(d)
            if l < 1e-9 { continue }
            d /= l
            let P = matrix_identity_double3x3 - simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
            A += P
            b += P * p
            n += 1
        }
        guard n >= 3, abs(simd_determinant(A)) > 1e-9 else { return nil }
        return simd_inverse(A) * b
    }
    /// Accepte un dossier de capture, un dossier qui en contient un, ou le fichier zip partagé depuis l'iPhone.
    public static func locateCapture(_ url: URL, log: Log = { _ in }) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ReconstructionError("Introuvable : \(url.path)")
        }
        var root = url
        if !isDir.boolValue {
            guard url.pathExtension.lowercased() == "zip" else {
                throw ReconstructionError("Choisir un dossier ou un fichier zip.")
            }
            let parent = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            var dest = parent.appendingPathComponent(base, isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = parent.appendingPathComponent("\(base) (\(n))", isDirectory: true)
                n += 1
            }
            log("Décompression de \(url.lastPathComponent)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, dest.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw ReconstructionError("Décompression impossible.")
            }
            root = dest
        }
        if fm.fileExists(atPath: root.appendingPathComponent("capture.json").path) { return root }
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.lastPathComponent == "capture.json" && !u.path.contains("__MACOSX") {
                return u.deletingLastPathComponent()
            }
        }
        throw ReconstructionError("capture.json introuvable dans \(root.lastPathComponent). Ce n'est pas un dossier de capture Photo HD.")
    }

    public static func run(input: URL,
                           output: URL? = nil,
                           options: ReconstructionOptions = ReconstructionOptions(),
                           log: @escaping Log = { _ in },
                           progress: @escaping Progress = { _ in }) async throws -> ReconstructionResult {
        guard PhotogrammetrySession.isSupported else {
            throw ReconstructionError("Object Capture n'est pas disponible sur ce Mac (Apple Silicon ou GPU compatible requis, macOS 14 ou plus).")
        }
        let folder = try locateCapture(input, log: log)
        let outDir = output ?? folder.appendingPathComponent("resultat", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        progress(0.01)

        // 1. Lecture de la capture
        let json = try Data(contentsOf: folder.appendingPathComponent("capture.json"))
        let capture = try JSONDecoder().decode(PhotoCapture.self, from: json)
        let frames = capture.frames.filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.image).path)
        }
        let mouthFrames = frames.filter { $0.segment == "bouche" }
        log("Outil version \(ToolVersion.current) \(ToolVersion.name)")
        log("Capture du \(capture.date) (\(capture.device), app \(capture.appVersion ?? "inconnue")) : \(frames.count) photos dont \(mouthFrames.count) de la séquence bouche")
        guard frames.count >= 10 else { throw ReconstructionError("Trop peu de photos (\(frames.count)).") }

        // 2. Échantillons chargés à la demande (images 12 Mpx : on évite de toutes les garder en mémoire)
        let useMask = options.useMask
        let samples = AnySequence<PhotogrammetrySample> {
            var i = 0
            return AnyIterator<PhotogrammetrySample> {
                while i < frames.count {
                    let f = frames[i]
                    i += 1
                    guard let pb = Images.pixelBuffer(folder.appendingPathComponent(f.image)) else {
                        log("Image illisible : \(f.image)")
                        continue
                    }
                    var s = PhotogrammetrySample(id: f.index, image: pb)
                    if useMask, f.segment != "bouche", let m = Images.headMask(frame: f, folder: folder,
                                                       width: CVPixelBufferGetWidth(pb),
                                                       height: CVPixelBufferGetHeight(pb)) {
                        s.objectMask = m
                    }
                    return s
                }
                return nil
            }
        }

        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering = .unordered
        config.featureSensitivity = .high
        config.isObjectMaskingEnabled = !useMask
        let isCustom = options.detail == .custom
        if isCustom {
            config.customDetailSpecification.maximumPolygonCount = options.polygons
            if options.highTexture, #available(macOS 15.0, *) {
                config.customDetailSpecification.maximumTextureDimension = .sixteenK    // 16K : macOS 15 ou plus
            } else {
                config.customDetailSpecification.maximumTextureDimension = .eightK
            }
        }
        let detail: PhotogrammetrySession.Request.Detail
        switch options.detail {
        case .custom: detail = .custom
        case .full: detail = .full
        case .medium: detail = .medium
        case .reduced: detail = .reduced
        case .raw: detail = .raw
        }
        let session = try PhotogrammetrySession(input: samples, configuration: config)

        // 3. Reconstruction : modèle OBJ texturé + poses des caméras
        let rawDir = outDir.appendingPathComponent("object_capture", isDirectory: true)
        try? FileManager.default.removeItem(at: rawDir)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        try session.process(requests: [.modelFile(url: rawDir, detail: detail), .poses])
        log("Reconstruction en cours (plusieurs minutes)")

        let (posesOpt, modelURL) = try await withTaskCancellationHandler {
            try await collect(session: session, log: log, progress: progress)
        } onCancel: {
            session.cancel()
        }
        guard modelURL != nil else { throw ReconstructionError("Aucun modèle produit.") }
        progress(0.90)

        // 4. Mise à l'échelle et orientation : poses Object Capture -> poses ARKit (mètres, y vertical)
        guard let poses = posesOpt else { throw ReconstructionError("Poses des caméras indisponibles.") }
        var arkit = [SIMD3<Double>]()
        var recT = [SIMD3<Double>]()       // hypothèse 1 : translation = position de la caméra
        var recC = [SIMD3<Double>]()       // hypothèse 2 : pose monde -> caméra
        for f in frames {
            guard let p = poses.posesBySample[f.index], f.cameraToWorld.count == 16 else { continue }
            arkit.append(SIMD3(Double(f.cameraToWorld[12]), Double(f.cameraToWorld[13]), Double(f.cameraToWorld[14])))
            let t = SIMD3<Double>(Double(p.translation.x), Double(p.translation.y), Double(p.translation.z))
            recT.append(t)
            let q = p.rotation
            let R = Alignment.rotation(w: Double(q.real), x: Double(q.imag.x), y: Double(q.imag.y), z: Double(q.imag.z))
            recC.append(-(R.transpose * t))
        }
        log("Poses retrouvées : \(arkit.count) sur \(frames.count)")
        guard let simA = Alignment.similarity(from: recT, to: arkit),
              let simB = Alignment.similarity(from: recC, to: arkit) else {
            throw ReconstructionError("Pas assez de poses pour la mise à l'échelle.")
        }
        let sim = simA.rms <= simB.rms ? simA : simB
        log(String(format: "Mise à l'échelle par ARKit : facteur %.4f, écart des positions de caméra %.1f mm",
                   sim.s, sim.rms * 1000))
        if sim.rms > 0.010 {
            log("ATTENTION : écart supérieur à 10 mm. Le patient a peut-être bougé, ou le suivi ARKit a dérivé. Vérifier le résultat.")
        }

        // 5. Maillage dans le repère du visage : origine au centre du visage, Y vertical, Z sortant du visage,
        //    X vers la gauche du patient. Unités : mètres jusqu'à l'export.
        let objURL = try findOBJ(in: rawDir)
        var mesh = try TexturedMesh.loadOBJ(objURL)
        log("Modèle brut : \(mesh.vertices.count) sommets, \(mesh.faces.count) triangles")
        mesh.transform { sim.apply($0) }
        var fz = SIMD3<Double>(Double(capture.frontal[0]), 0, Double(capture.frontal[2]))
        fz = simd_length(fz) > 1e-6 ? simd_normalize(fz) : SIMD3(0, 0, 1)
        let fy = SIMD3<Double>(0, 1, 0)
        let fx = simd_cross(fy, fz)
        let c0 = SIMD3<Double>(Double(capture.faceCenter[0]), Double(capture.faceCenter[1]), Double(capture.faceCenter[2]))
        func toFace(_ p: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
            let d = p - c
            return SIMD3(simd_dot(d, fx), simd_dot(d, fy), simd_dot(d, fz))
        }
        mesh.transform { toFace($0, c0) }
        // centre recalculé sur le maillage (l'estimation de l'iPhone est approximative), puis découpe de la tête
        mesh.crop { simd_length($0) < 0.25 }
        let c1 = mesh.centroid
        mesh.transform { $0 - c1 }
        mesh.crop { p in abs(p.x) < 0.13 && p.y > -0.17 && p.y < 0.17 && p.z > -0.12 }
        mesh.keepLargestComponent()

        // Version HD+Mouth : centre de la bouche = point d'intersection des axes optiques de la séquence bouche
        var mouthCenter: SIMD3<Double>?
        if options.hdMouth {
            if mouthFrames.count >= 5, let mw = intersectAxes(mouthFrames) {
                let m = toFace(mw, c0) - c1
                if simd_length(m) < 0.2 {
                    mouthCenter = m
                    log(String(format: "Centre de la bouche (repère du visage) : x %.1f, y %.1f, z %.1f mm",
                               m.x * 1000, m.y * 1000, m.z * 1000))
                } else {
                    log("ATTENTION : centre de la bouche aberrant (\(Int(simd_length(m) * 1000)) mm du centre), allègement non appliqué.")
                }
            } else {
                log("ATTENTION : HD+Mouth demandé mais pas de séquence bouche exploitable (au moins 5 photos). Maillage uniforme.")
            }
        }
        let half = options.mouthHalfSize
        let mc = mouthCenter
        func inMouth(_ p: SIMD3<Double>) -> Bool {
            guard let m = mc else { return false }
            let d = p - m
            return abs(d.x) < half.x && abs(d.y) < half.y && abs(d.z) < half.z
        }
        if mc != nil {
            let before = mesh.faces.count
            mesh.decimateOutside(keep: inMouth, cell: options.outsideCellMm / 1000)
            mesh.keepLargestComponent()
            log("Allègement hors de la bouche : \(before) -> \(mesh.faces.count) triangles")
        }
        mesh.bakeVertexColors()
        log("Visage : \(mesh.vertices.count) sommets, \(mesh.faces.count) triangles")
        guard mesh.faces.count > 1000 else { throw ReconstructionError("Maillage du visage trop petit après découpe.") }
        progress(0.95)

        // 6. Exports en millimètres
        let base = mc != nil ? "visage_HD_bouche" : "visage"
        try mesh.writeSTL(outDir.appendingPathComponent(base + ".stl"), scale: 1000)
        try mesh.writePLY(outDir.appendingPathComponent(base + "_couleur.ply"), scale: 1000)
        try mesh.writeOBJ(outDir.appendingPathComponent(base + ".obj"), scale: 1000)
        if mc != nil {
            // zone bouche seule, pleine densité, même repère que le visage (pour le recalage des empreintes 3D)
            var patch = mesh
            patch.crop { inMouth($0) }
            patch.keepLargestComponent()
            if patch.faces.count > 100 {
                try patch.writeSTL(outDir.appendingPathComponent("bouche_HD.stl"), scale: 1000)
                try patch.writePLY(outDir.appendingPathComponent("bouche_HD_couleur.ply"), scale: 1000)
                log("Zone bouche seule : \(patch.faces.count) triangles (bouche_HD.stl)")
            }
        }

        let report: [String: Any] = [
            "photos": frames.count,
            "posesRetrouvees": arkit.count,
            "facteurEchelle": sim.s,
            "ecartCamerasMm": sim.rms * 1000,
            "triangles": mesh.faces.count,
            "detail": options.detail.rawValue,
            "polygonesMax": isCustom ? Int(options.polygons) : 0,
            "texture16K": options.highTexture,
            "masques": useMask,
            "versionOutil": ToolVersion.current,
            "versionAppCapture": capture.appVersion ?? "inconnue",
            "photosBouche": mouthFrames.count,
            "hdMouth": mc != nil,
            "centreBoucheMm": mc.map { [$0.x * 1000, $0.y * 1000, $0.z * 1000] } ?? [],
            "celluleHorsBoucheMm": mc != nil ? options.outsideCellMm : 0,
            "repere": "mm, X = gauche du patient, Y = haut, Z = sortant du visage, origine au centre du maillage"
        ]
        let rep = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try rep.write(to: outDir.appendingPathComponent("rapport.json"))
        progress(1.0)
        log("Terminé : \(outDir.path)")
        return ReconstructionResult(outputFolder: outDir, photos: frames.count, posesFound: arkit.count,
                                    scaleFactor: sim.s, cameraDeviationMm: sim.rms * 1000,
                                    triangles: mesh.faces.count, mouthPhotos: mouthFrames.count,
                                    hdMouthApplied: mc != nil, mainSTLName: base + ".stl")
    }

    /// Consomme les sorties d'Object Capture jusqu'à la fin du traitement.
    private static func collect(session: PhotogrammetrySession,
                                log: Log,
                                progress: Progress) async throws -> (PhotogrammetrySession.Poses?, URL?) {
        var poses: PhotogrammetrySession.Poses?
        var modelURL: URL?
        var lastPercent = -1
        outputs: for try await out in session.outputs {
            switch out {
            case .requestProgress(_, let fraction):
                let p = Int(fraction * 100)
                if p != lastPercent {
                    lastPercent = p
                    progress(0.02 + 0.88 * min(1, max(0, fraction)))
                    if p % 10 == 0 { log("Reconstruction \(p) %") }
                }
            case .requestComplete(_, let result):
                switch result {
                case .poses(let p): poses = p
                case .modelFile(let url): modelURL = url
                default: break
                }
            case .requestError(_, let error):
                log("Erreur de requête : \(error)")
            case .invalidSample(let id, let reason):
                log("Photo \(id) ignorée : \(reason)")
            case .skippedSample(let id):
                log("Photo \(id) non utilisée")
            case .processingComplete:
                break outputs
            case .processingCancelled:
                throw ReconstructionError("Reconstruction annulée.")
            default:
                break
            }
        }
        return (poses, modelURL)
    }

    private static func findOBJ(in dir: URL) throws -> URL {
        let items = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
        guard let obj = items.first(where: { $0.lowercased().hasSuffix(".obj") }) else {
            throw ReconstructionError("Pas de fichier OBJ dans \(dir.path)")
        }
        return dir.appendingPathComponent(obj)
    }
}
