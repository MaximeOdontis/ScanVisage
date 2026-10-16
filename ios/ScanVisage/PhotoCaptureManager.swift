import ARKit
import AVFoundation
import AudioToolbox
import Combine
import CoreImage
import UIKit
import Vision

// MARK: - Format du dossier de capture (lu par l'outil Mac FaceRebuild)

/// Une photo. Image enregistrée dans l'orientation brute du capteur (paysage), sans rotation :
/// les intrinsèques et la pose correspondent à cette image.
struct PhotoFrame: Codable {
    let index: Int
    let image: String
    let mask: String?              // masque de personne (Vision), orienté « portrait » (voir maskOrientation)
    let width: Int
    let height: Int
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    /// Pose caméra -> monde ARKit (4 x 4, colonne par colonne). Caméra : x droite, y haut, z vers l'arrière
    /// par rapport à l'image brute. Monde : y vertical vers le haut, mètres.
    let cameraToWorld: [Float]
    let azimuthDeg: Double         // > 0 : caméra du côté gauche du patient
    let elevationDeg: Double       // > 0 : caméra au-dessus du visage
    let distance: Double           // mètres, du centre estimé du visage
    /// Rectangle du visage (Vision), coordonnées normalisées de l'image redressée en portrait, origine en bas à gauche.
    let faceBox: [Double]?
    let maskOrientation: String    // "portrait" : masque dans l'image redressée (rotation horaire de 90° de l'image brute)
    let timestamp: Double
    /// "visage" (séquence autour du visage) ou "bouche" (séquence de près sur la bouche, version HD+Mouth).
    let segment: String?
}

struct PhotoCapture: Codable {
    let version: Int
    let device: String
    let date: String
    let faceCenter: [Float]        // monde ARKit, estimation grossière (taille du visage)
    let frontal: [Float]           // direction horizontale visage -> caméra au début de la capture
    let frames: [PhotoFrame]
    let appVersion: String?
}

/// Numéro de version de l'application (à mettre à jour à chaque livraison, avec VERSION et CHANGELOG.md).
enum AppInfo {
    static let version = "2.0.4"
    static let name = "HD+Mouth"
}

/// Mode de capture : compromis entre durée et densité de photos.
enum PhotoMode: String, CaseIterable, Identifiable {
    case fast = "Rapide"
    case standard = "Standard"
    case precise = "Précis"

    var id: String { rawValue }

    /// Anneaux de points de vue : élévation (degrés, + = caméra au-dessus), pas en azimut, azimut maximal.
    var rings: [(el: Double, step: Double, maxAz: Double)] {
        switch self {
        case .fast:     return [(20, 15, 60), (0, 15, 75)]
        case .standard: return [(20, 15, 75), (0, 10, 80), (-25, 15, 60)]
        case .precise:  return [(30, 10, 70), (15, 10, 75), (0, 8, 80), (-25, 10, 60)]
        }
    }
    var ringNames: [String] {
        switch self {
        case .fast:     return ["Dessus", "Face"]
        case .standard: return ["Dessus", "Face", "Dessous"]
        case .precise:  return ["Haut", "Dessus", "Face", "Dessous"]
        }
    }
    var ringTol: Double { self == .precise ? 7.0 : 11.0 }
    var minPhotos: Int {
        switch self {
        case .fast: return 14
        case .standard: return 20
        case .precise: return 40
        }
    }
    var distanceText: String { self == .precise ? "25 à 30 cm" : "30 à 40 cm" }
    var nearLimit: Double { self == .precise ? 0.22 : 0.25 }
    var farLimit: Double { self == .precise ? 0.35 : 0.45 }
    var summary: String {
        switch self {
        case .fast: return "Environ 20 photos, 30 à 45 s. Sans anneau du dessous."
        case .standard: return "Environ 37 photos, 1 à 1,5 min."
        case .precise: return "Environ 65 photos, plus près (25 à 30 cm), 2 à 3 min."
        }
    }
}

// MARK: - Couverture : anneaux de points de vue autour du visage

enum Coverage {
    /// À changer uniquement à l'arrêt (avant « Démarrer »).
    static var mode: PhotoMode = .standard {
        didSet { bins = makeBins(mode.rings) }
    }
    static var rings: [(el: Double, step: Double, maxAz: Double)] { mode.rings }
    static var ringNames: [String] { mode.ringNames }
    static var ringTol: Double { mode.ringTol }

    /// Toutes les cases : (anneau, azimut). Azimut > 0 : caméra du côté gauche du patient.
    static var bins: [(ring: Int, az: Double)] = makeBins(PhotoMode.standard.rings)
    static var binCount: Int { bins.count }

    private static func makeBins(_ rings: [(el: Double, step: Double, maxAz: Double)]) -> [(ring: Int, az: Double)] {
        var out = [(ring: Int, az: Double)]()
        for (r, ring) in rings.enumerated() {
            var az = -ring.maxAz
            while az <= ring.maxAz + 0.001 {
                out.append((r, az))
                az += ring.step
            }
        }
        return out
    }

    static func bin(az: Double, el: Double) -> Int? {
        let rs = rings
        guard let r = rs.firstIndex(where: { abs($0.el - el) <= ringTol }) else { return nil }
        let half = rs[r].step / 2 + 0.001
        for (i, b) in bins.enumerated() where b.ring == r && abs(b.az - az) <= half {
            return i
        }
        return nil
    }
}

// MARK: - Gestionnaire de capture photo (caméra arrière)

final class PhotoCaptureManager: NSObject, ObservableObject, ARSessionDelegate {

    enum Phase { case idle, locating, capturing, mouthPrep, mouth, saving, done }

    let session = ARSession()

    @Published var phase: Phase = .idle
    @Published var message = "Visez le visage du patient, de face, à 30 à 40 cm."
    @Published var filled = [Bool](repeating: false, count: Coverage.binCount)
    @Published var currentBin: Int?
    @Published var azimuth = 0.0
    @Published var elevation = 0.0
    @Published var distance = 0.0
    @Published var count = 0
    @Published var faceVisible = false
    @Published var stable = false
    @Published var folder: URL?
    @Published var highResolution = true
    /// Version HD+Mouth : deuxième séquence de près sur la bouche, après la séquence autour du visage.
    @Published var withMouth = false
    @Published var mouthCount = 0
    /// Modifiable à l'arrêt seulement (sélecteur masqué pendant la capture).
    @Published var mode: PhotoMode = .standard {
        didSet {
            guard phase == .idle else { return }
            queue.sync { Coverage.mode = mode }
            filled = [Bool](repeating: false, count: Coverage.binCount)
            message = "Visez le visage du patient, de face, à \(mode.distanceText)."
        }
    }

    static let mouthMin = 12
    static let mouthMax = 40
    static var minPhotos: Int { Coverage.mode.minPhotos }
    static var autoFinishPhotos: Int { Coverage.binCount }

    private let queue = DispatchQueue(label: "photo.ar")
    private let ioQueue = DispatchQueue(label: "photo.io")
    private let ciContext = CIContext()

    // Accès sur `queue` uniquement
    private var running = false
    private var phaseQ: Phase = .idle
    private var lastVision = 0.0
    private var lastFaceBox: CGRect?
    private var lastFaceTime = -10.0
    private var lastFaceYaw: Double?
    private var lastTransform: simd_float4x4?
    private var sharpFrames = 0
    private var lastFrameTime = 0.0
    /// Durée d'exposition verrouillée (s), pour prédire le flou de bougé.
    private var exposureSeconds = 1.0 / 60.0
    private var locateSamples = [SIMD3<Float>]()
    private var locateStart = 0.0
    private var faceCenter = SIMD3<Float>(0, 0, 0)
    private var frontal = SIMD3<Float>(0, 0, 1)
    private var inFlight = false
    private var lastCaptureTime = -10.0
    private var frames = [PhotoFrame]()
    private var filledQ = [Bool](repeating: false, count: Coverage.binCount)
    private var folderQ: URL?
    private var withMouthQ = false
    private var mouthN = 0
    private var mouthSettleUntil = -1.0
    private var mouthLocked = false
    private var lastMouthPos: SIMD3<Float>?
    private var lastMouthDir: SIMD3<Float>?

    // MARK: Session

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            message = "Suivi ARKit non disponible sur cet appareil."
            return
        }
        let config = ARWorldTrackingConfiguration()
        if let fmt = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = fmt
            highResolution = true
        } else {
            highResolution = false
        }
        config.planeDetection = []
        session.delegate = self
        session.delegateQueue = queue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        queue.async { self.running = true }
    }

    func stop() {
        queue.async { self.running = false }
        session.pause()
        lockCamera(false)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Démarre : repère d'abord le visage (de face, environ 1 s), puis capture automatiquement.
    func begin() {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Photos_" + df.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        UIApplication.shared.isIdleTimerDisabled = true
        filled = [Bool](repeating: false, count: Coverage.binCount)
        count = 0
        mouthCount = 0
        folder = nil
        let wm = withMouth
        phase = .locating
        message = "De face, ne bougez plus : repérage du visage."
        queue.async {
            self.folderQ = url
            self.withMouthQ = wm
            self.mouthN = 0
            self.frames = []
            self.filledQ = [Bool](repeating: false, count: Coverage.binCount)
            self.locateSamples = []
            self.locateStart = -1
            self.inFlight = false
            self.lastCaptureTime = -10
            self.phaseQ = .locating
        }
    }

    func cancel() {
        queue.async { self.phaseQ = .idle }
        lockCamera(false)
        phase = .idle
        message = "Visez le visage du patient, de face, à \(mode.distanceText)."
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// « Terminer » : fin de la séquence visage (puis passage à la bouche si HD+Mouth), ou fin de la capture.
    func finish() {
        queue.async {
            switch self.phaseQ {
            case .capturing: self.endSequence1OnQueue()
            case .mouth, .mouthPrep: self.finishOnQueue()
            default: break
            }
        }
    }

    /// « Terminer sans bouche » (écran de préparation de la séquence bouche).
    func skipMouth() {
        queue.async { self.finishOnQueue() }
    }

    /// Lance la séquence bouche : mise au point à nouveau libre le temps de se stabiliser, puis verrouillée.
    func beginMouth() {
        queue.async {
            guard self.phaseQ == .mouthPrep else { return }
            self.mouthSettleUntil = -1
            self.mouthLocked = false
            self.lastMouthPos = nil
            self.lastMouthDir = nil
            self.sharpFrames = 0
            self.phaseQ = .mouth
            self.publish {
                self.phase = .mouth
                self.message = "Mise au point sur la bouche : ne bougez pas une seconde."
            }
        }
    }

    private func endSequence1OnQueue() {
        guard phaseQ == .capturing else { return }
        if withMouthQ {
            phaseQ = .mouthPrep
            lockCamera(false)
            sharpFrames = 0
            publish {
                self.phase = .mouthPrep
                self.message = "Séquence visage terminée. Approchez-vous de la bouche (environ 20 à 25 cm), bouche au centre du repère, puis touchez « Démarrer la bouche »."
            }
            speakTick()
        } else {
            finishOnQueue()
        }
    }

    // MARK: ARSessionDelegate (sur `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running else { return }
        let now = frame.timestamp
        guard case .normal = frame.camera.trackingState else {
            sharpFrames = 0
            publish { self.message = "Suivi en cours d'initialisation : bougez doucement le téléphone." }
            return
        }

        // Netteté : flou de bougé prédit pendant l'exposition, en pixels de la photo haute résolution.
        // On n'exige plus d'arrêt complet : un mouvement lent suffit si le flou prévu reste sous 4 pixels
        // (sur une photo de 12 Mpx, soit moins d'un pixel à la résolution utile pour la reconstruction).
        // Plus la lumière est forte, plus l'exposition est courte et plus on peut bouger vite.
        let T = frame.camera.transform
        if let L = lastTransform, now - lastFrameTime > 0.001 {
            let dt = Float(now - lastFrameTime)
            let rel = simd_mul(simd_inverse(L), T)
            let tr = rel.columns.0.x + rel.columns.1.y + rel.columns.2.z
            let ang = acos(max(-1, min(1, (tr - 1) / 2)))          // radians
            let mv = simd_length(SIMD3<Float>(rel.columns.3.x, rel.columns.3.y, rel.columns.3.z))
            let fxVideo = frame.camera.intrinsics[0][0]
            let fxPhoto = fxVideo * max(1, 4032 / Float(frame.camera.imageResolution.width))
            let refDist: Float = phaseQ == .mouth ? 0.22 : 0.35
            let speed = ang / dt + (mv / dt) / refDist             // rad/s équivalents à la distance de travail
            let blurPx = speed * Float(exposureSeconds) * fxPhoto
            if blurPx < 4.0 { sharpFrames += 1 } else { sharpFrames = 0 }
        }
        lastTransform = T
        lastFrameTime = now
        let isStable = sharpFrames >= 2

        // Détection du visage (environ 8 fois par seconde)
        if now - lastVision > 0.12 {
            lastVision = now
            detectFace(frame)
        }
        let faceRecent = now - lastFaceTime < 0.4
        var centered = false
        if faceRecent, let b = lastFaceBox {
            centered = b.midX > 0.2 && b.midX < 0.8 && b.midY > 0.2 && b.midY < 0.85
        }

        switch phaseQ {
        case .locating:
            if locateStart < 0 { locateStart = now }
            if faceRecent, let b = lastFaceBox, let p = facePoint(box: b, camera: frame.camera),
               abs(lastFaceYaw ?? 0) < 0.25 {
                locateSamples.append(p)
            }
            if locateSamples.count >= 8 {
                var m = SIMD3<Float>(0, 0, 0)
                for s in locateSamples { m += s }
                m /= Float(locateSamples.count)
                faceCenter = m
                let cam = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
                var h = cam - m
                h.y = 0
                frontal = simd_length(h) > 1e-4 ? simd_normalize(h) : SIMD3<Float>(0, 0, 1)
                phaseQ = .capturing
                lockCamera(true)
                publish {
                    self.phase = .capturing
                    self.message = "Tournez lentement autour du visage : une photo est prise à chaque case grise dès que l'image est nette."
                }
                speakTick()
            } else if now - locateStart > 6 {
                locateStart = now
                locateSamples = []
                publish { self.message = "Visage non trouvé : de face, à \(Coverage.mode.distanceText), visage entier dans l'image." }
            }
        case .capturing:
            let cam = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
            let v = cam - faceCenter
            let dist = simd_length(v)
            let el = Double(asin(max(-1, min(1, v.y / max(dist, 1e-4))))) * 180 / .pi
            var h = v
            h.y = 0
            let up = SIMD3<Float>(0, 1, 0)
            let left = simd_cross(up, frontal)          // gauche du patient
            let az = Double(atan2(simd_dot(h, left), simd_dot(h, frontal))) * 180 / .pi
            let bin = Coverage.bin(az: az, el: el)
            let okDist = dist > 0.22 && dist < 0.55
            // Le visage est suivi par sa position 3D (projetée dans l'image) : plus besoin que Vision
            // le détecte, ce qui échouait sur les profils au-delà de 60 à 70°.
            let inFrame = faceInFrame(camera: frame.camera)
            if isStable && inFrame && okDist && !inFlight && now - lastCaptureTime > 0.3,
               let b = bin, !filledQ[b] {
                capture(bin: b, segment: "visage", az: az, el: el, dist: Double(dist), fallback: frame)
            }
            let st = isStable
            let fv = inFrame
            publish {
                self.azimuth = az
                self.elevation = el
                self.distance = Double(dist)
                self.currentBin = bin
                self.stable = st
                self.faceVisible = fv
            }
        case .mouthPrep:
            let cam = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
            let d = Double(simd_length(cam - faceCenter))
            publish {
                self.distance = d
                self.faceVisible = d > 0.10 && d < 0.35
            }
        case .mouth:
            handleMouth(frame: frame, T: T, isStable: isStable)
        default:
            let fv = faceRecent && centered
            let d: Double
            if faceRecent, let b = lastFaceBox, let p = facePoint(box: b, camera: frame.camera) {
                let cam = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
                d = Double(simd_length(cam - p))
            } else {
                d = 0
            }
            publish {
                self.faceVisible = fv
                if d > 0 { self.distance = d }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        publish { self.message = "Erreur ARKit : \(error.localizedDescription)" }
    }

    // MARK: Séquence bouche (HD+Mouth)

    /// Photos prises dès que l'image est nette ET que le téléphone a bougé d'au moins 2,5 cm ou tourné de 8°
    /// depuis la dernière photo de la séquence : pas de grille, l'opérateur balaie la bouche en 2 à 3 passages.
    private func handleMouth(frame: ARFrame, T: simd_float4x4, isStable: Bool) {
        let now = frame.timestamp
        let cam = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        let fwd = -simd_normalize(SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z))
        let dist = simd_length(cam - faceCenter)
        let okDist = dist > 0.10 && dist < 0.35
        if mouthSettleUntil < 0 { mouthSettleUntil = now + 1.5 }
        if now < mouthSettleUntil {
            publish {
                self.distance = Double(dist)
                self.faceVisible = okDist
                self.stable = false
            }
            return
        }
        if !mouthLocked {
            mouthLocked = true
            lockCamera(true)
            sharpFrames = 0
            publish {
                self.message = "Balayez lentement la bouche de gauche à droite, puis refaites 1 à 2 passages un peu plus haut et un peu plus bas. Gardez la bouche au centre du repère."
            }
            speakTick()
            return
        }
        var moved = true
        if let p = lastMouthPos, let d = lastMouthDir {
            let shift = simd_length(cam - p)
            let ang = acos(max(-1, min(1, simd_dot(fwd, d)))) * 180 / .pi
            moved = shift > 0.025 || ang > 8
        }
        if isStable && okDist && moved && !inFlight && now - lastCaptureTime > 0.3
            && mouthN < PhotoCaptureManager.mouthMax {
            lastMouthPos = cam
            lastMouthDir = fwd
            capture(bin: nil, segment: "bouche", az: 0, el: 0, dist: Double(dist), fallback: frame)
        }
        let st = isStable
        publish {
            self.distance = Double(dist)
            self.faceVisible = okDist
            self.stable = st
        }
    }

    // MARK: Visage

    private func detectFace(_ frame: ARFrame) {
        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return
        }
        guard let faces = req.results, !faces.isEmpty else { return }
        var best = faces[0]
        for f in faces where f.boundingBox.width * f.boundingBox.height > best.boundingBox.width * best.boundingBox.height {
            best = f
        }
        lastFaceBox = best.boundingBox
        lastFaceYaw = best.yaw?.doubleValue
        lastFaceTime = frame.timestamp
    }

    /// Le centre du visage repéré au départ se projette-t-il dans la zone centrale de l'image ?
    private func faceInFrame(camera: ARCamera) -> Bool {
        let p = simd_mul(simd_inverse(camera.transform), SIMD4<Float>(faceCenter, 1))
        if p.z > -0.05 { return false }                    // derrière la caméra ou trop près
        let K = camera.intrinsics
        let res = camera.imageResolution
        let u = K[0][0] * p.x / -p.z + K[2][0]
        let v = -K[1][1] * p.y / -p.z + K[2][1]
        let un = u / Float(res.width)
        let vn = v / Float(res.height)
        return un > 0.15 && un < 0.85 && vn > 0.15 && vn < 0.85
    }

    /// Centre approximatif du visage dans le monde, à partir de sa taille dans l'image (largeur supposée 15 cm).
    /// `box` est en coordonnées normalisées de l'image redressée (portrait), origine en bas à gauche.
    private func facePoint(box: CGRect, camera: ARCamera) -> SIMD3<Float>? {
        let res = camera.imageResolution            // image brute, paysage
        let K = camera.intrinsics
        let fx = K[0][0]
        let fy = K[1][1]
        let cx = K[2][0]
        let cy = K[2][1]
        let widthPx = Float(box.width) * Float(res.height)   // largeur en portrait = hauteur de l'image brute
        guard widthPx > 10 else { return nil }
        let dist = fy * 0.15 / widthPx
        // portrait (x', y' depuis le bas) -> pixel brut : u = (1 - y') W, v = (1 - x') H
        let u = (1 - Float(box.midY)) * Float(res.width)
        let v = (1 - Float(box.midX)) * Float(res.height)
        let pc = SIMD4<Float>((u - cx) / fx * dist, -(v - cy) / fy * dist, -dist, 1)
        let w = simd_mul(camera.transform, pc)
        return SIMD3<Float>(w.x, w.y, w.z)
    }

    // MARK: Prise de vue

    private func capture(bin: Int?, segment: String, az: Double, el: Double, dist: Double, fallback: ARFrame) {
        inFlight = true
        lastCaptureTime = fallback.timestamp
        let box = segment == "visage" ? lastFaceBox : nil
        if highResolutionQ {
            session.captureHighResolutionFrame { [weak self] hr, _ in
                guard let self = self else { return }
                self.queue.async {
                    if let hr = hr {
                        self.store(frame: hr, bin: bin, segment: segment, az: az, el: el, dist: dist, box: box)
                    } else {
                        self.inFlight = false
                    }
                }
            }
        } else {
            store(frame: fallback, bin: bin, segment: segment, az: az, el: el, dist: dist, box: box)
        }
    }

    private var highResolutionQ: Bool {
        ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
    }

    /// Copie les données utiles de l'ARFrame, puis écrit l'image et le masque sur une autre file.
    private func store(frame: ARFrame, bin: Int?, segment: String, az: Double, el: Double, dist: Double, box: CGRect?) {
        let phaseOK = (phaseQ == .capturing && segment == "visage") || (phaseQ == .mouth && segment == "bouche")
        guard phaseOK, let folder = folderQ else {
            inFlight = false
            return
        }
        if let b = bin, filledQ[b] {
            inFlight = false
            return
        }
        let pb = frame.capturedImage
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let res = frame.camera.imageResolution
        let sx = Double(w) / Double(res.width)
        let sy = Double(h) / Double(res.height)
        let K = frame.camera.intrinsics
        let T = frame.camera.transform
        let index = frames.count + 1
        let imageName = String(format: "img_%03d.jpg", index)
        let maskName = String(format: "mask_%03d.png", index)
        var m = [Float]()
        for c in [T.columns.0, T.columns.1, T.columns.2, T.columns.3] {
            m.append(contentsOf: [c.x, c.y, c.z, c.w])
        }
        let pf = PhotoFrame(
            index: index, image: imageName, mask: maskName, width: w, height: h,
            fx: Double(K[0][0]) * sx, fy: Double(K[1][1]) * sy,
            cx: Double(K[2][0]) * sx, cy: Double(K[2][1]) * sy,
            cameraToWorld: m, azimuthDeg: az, elevationDeg: el, distance: dist,
            faceBox: box.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)] },
            maskOrientation: "portrait", timestamp: frame.timestamp, segment: segment)
        frames.append(pf)
        if let b = bin { filledQ[b] = true }
        if segment == "bouche" { mouthN += 1 }
        let n = frames.count
        let mn = mouthN
        publish {
            if let b = bin { self.filled[b] = true }
            self.count = n
            self.mouthCount = mn
        }
        speakTick()
        let ctx = ciContext
        ioQueue.async {
            let image = CIImage(cvPixelBuffer: pb)
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            let opts = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
            try? ctx.writeJPEGRepresentation(of: image, to: folder.appendingPathComponent(imageName),
                                             colorSpace: srgb, options: opts)
            // Masque de la personne (le fond est exclu de la reconstruction)
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .balanced
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
            if (try? handler.perform([req])) != nil, let mask = req.results?.first?.pixelBuffer {
                let gray = CGColorSpace(name: CGColorSpace.linearGray)!
                try? ctx.writePNGRepresentation(of: CIImage(cvPixelBuffer: mask),
                                                to: folder.appendingPathComponent(maskName),
                                                format: .L8, colorSpace: gray, options: [:])
            }
            self.queue.async {
                self.inFlight = false
                if segment == "visage" && n >= PhotoCaptureManager.autoFinishPhotos {
                    self.endSequence1OnQueue()
                } else if segment == "bouche" && mn >= PhotoCaptureManager.mouthMax {
                    self.finishOnQueue()
                }
            }
        }
    }

    private func finishOnQueue() {
        guard phaseQ == .capturing || phaseQ == .mouth || phaseQ == .mouthPrep, let folder = folderQ else { return }
        phaseQ = .saving
        publish {
            self.phase = .saving
            self.message = "Enregistrement…"
        }
        // attendre la fin des écritures en cours
        ioQueue.async {
            let df = ISO8601DateFormatter()
            var info = utsname()
            uname(&info)
            let device = withUnsafePointer(to: &info.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            self.queue.async {
                let capture = PhotoCapture(
                    version: 2, device: device, date: df.string(from: Date()),
                    faceCenter: [self.faceCenter.x, self.faceCenter.y, self.faceCenter.z],
                    frontal: [self.frontal.x, self.frontal.y, self.frontal.z],
                    frames: self.frames, appVersion: AppInfo.version)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try? enc.encode(capture).write(to: folder.appendingPathComponent("capture.json"))
                self.phaseQ = .done
                let n = self.frames.count
                self.lockCamera(false)
                self.publish {
                    self.phase = .done
                    self.folder = folder
                    self.message = "\(n) photos enregistrées. Renommez le dossier si besoin, partagez le zip vers le Mac, puis ouvrez Reconstruction Visage."
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }

    /// Renomme le dossier de capture (nom choisi par l'opérateur). Retourne le nom effectivement utilisé.
    @discardableResult
    func renameFolder(to wanted: String) -> String {
        guard let folder = folder else { return wanted }
        var name = wanted
        for bad in ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"] { name = name.replacingOccurrences(of: bad, with: "-") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == folder.lastPathComponent { return folder.lastPathComponent }
        let parent = folder.deletingLastPathComponent()
        var dest = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = parent.appendingPathComponent("\(name) (\(n))", isDirectory: true)
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: folder, to: dest)
            self.folder = dest
            queue.async { self.folderQ = dest }
            return dest.lastPathComponent
        } catch {
            return folder.lastPathComponent
        }
    }

    /// Archive .zip du dossier de photos (le nom du zip est celui du dossier).
    func zipFolder() -> URL? {
        guard let folder = folder else { return nil }
        var result: URL?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &err) { zipURL in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(folder.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipURL, to: dest)) != nil { result = dest }
        }
        return result
    }

    // MARK: Réglages de la caméra

    /// Exposition, balance des blancs et mise au point verrouillées pendant la capture :
    /// indispensable pour une texture homogène entre les photos.
    private func lockCamera(_ lock: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if lock {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                let e = CMTimeGetSeconds(device.exposureDuration)
                if e.isFinite && e > 0 { exposureSeconds = e }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            device.unlockForConfiguration()
        } catch {
            // réglage impossible : la capture continue en automatique
        }
    }

    // MARK: Utilitaires

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func speakTick() {
        DispatchQueue.main.async {
            AudioServicesPlaySystemSound(1057)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
