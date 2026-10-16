import ARKit
import AVFoundation
import AudioToolbox
import Combine
import UIKit

// MARK: - Modèles

struct PoseMeta: Codable {
    let index: Int
    let label: String
    let width: Int
    let height: Int
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let frames: Int
    let points: Int
    let medianDepthMeters: Double
    let units: String
    let device: String
    let date: String
    let yawDeg: Double
    let pitchDeg: Double
    /// Pose visage -> capteur (3 x 4, ligne par ligne, mètres). Repère capteur : x droite, y bas, z devant.
    let sensorFromFace: [Double]
    let source: String
    /// "phoneMoves" (le téléphone tourne autour du visage) ou "headMoves" (le patient tourne la tête).
    let captureStyle: String
    /// Trames moyennées pour cette pose, couleur présente, correction du recalage global.
    let framesAveraged: Int
    let hasColor: Bool
    let refinedShiftMm: Double
    let refinedRotationDeg: Double
    let colorFx: Double?
    let colorFy: Double?
    let colorCx: Double?
    let colorCy: Double?
    let colorWidth: Int?
    let colorHeight: Int?
}

enum ScanPhase {
    case idle
    case countdown
    case scanning
    case processing
    case done
}

private enum CaptureMode {
    case off
    case preview
    case scan
}

// MARK: - Gestionnaire de capture (ARKit face tracking + profondeur TrueDepth)

final class DepthCaptureManager: NSObject, ObservableObject, ARSessionDelegate {

    let arSession = ARSession()

    @Published var phase: ScanPhase = .idle
    @Published var message = "Initialisation"
    @Published var countdown = 0
    @Published var supported = true
    @Published var faceFound = false
    @Published var trackState: TrackState = .searching
    @Published var yawDeg = 0.0
    @Published var pitchDeg = 0.0
    @Published var acceptedFrames = 0
    @Published var processedFrames = 0
    @Published var direction: GuideDirection = .center
    @Published var ring = [Float](repeating: 0, count: ScanEngine.ringCount)
    @Published var resultFolder: URL?
    @Published var displayMesh: Mesh?
    @Published var meshVersion = 0
    @Published var quarterTurns = 0
    @Published var mirrored = false
    @Published var quality: ScanMode = .precis
    /// Qui bouge : le téléphone (opérateur) par défaut, ou la tête du patient.
    @Published var style: CaptureStyle = CaptureStyle(rawValue: UserDefaults.standard.string(forKey: "captureStyleV1") ?? "") ?? .phoneMoves {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "captureStyleV1") }
    }
    @Published var holdProgress = 0.0
    @Published var stopIndex = 0
    @Published var stopTotal = 0
    @Published var buildProgress = 0.0
    @Published var buildText = ""

    /// Réglages de sens, mémorisés. Voir le test de sens à l'écran d'accueil.
    /// Inverse le sens du yaw (ne devrait pas être nécessaire : le sens suit la documentation d'ARKit).
    @Published var invertSides: Bool = UserDefaults.standard.bool(forKey: "invertSidesV3") {
        didSet { UserDefaults.standard.set(invertSides, forKey: "invertSidesV3") }
    }
    /// Aperçu retourné horizontalement pour se comporter comme un miroir (activé par défaut).
    @Published var mirrorPreview: Bool = (UserDefaults.standard.object(forKey: "mirrorPreviewV3") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(mirrorPreview, forKey: "mirrorPreviewV3") }
    }
    /// Test de sens validé par l'utilisateur.
    @Published var senseChecked: Bool = UserDefaults.standard.bool(forKey: "senseCheckedV3") {
        didSet { UserDefaults.standard.set(senseChecked, forKey: "senseCheckedV3") }
    }
    /// Distance du point le plus proche du visage (bout du nez), en mètres.
    @Published var noseDistance = 0.0

    /// Signe appliqué au yaw d'ARKit (voir ScanEngine.defaultYawSign).
    private var yawSign: Double {
        invertSides ? -ScanEngine.defaultYawSign : ScanEngine.defaultYawSign
    }

    private let deliveryQueue = DispatchQueue(label: "scanvisage.ar")
    private let procQueue = DispatchQueue(label: "scanvisage.proc")
    private let synth = AVSpeechSynthesizer()
    private let engine = ScanEngine()

    // Partagés entre files : protégés par `lock`
    private let lock = NSLock()
    private var mode: CaptureMode = .off
    private var busy = false
    private var lastPreview = 0.0

    // Accès uniquement depuis `procQueue`
    private var baseMesh: Mesh?
    private var lastWarningTime = -100.0
    private var processedCount = 0

    // MARK: Préparation

    func prepare() {
        #if targetEnvironment(simulator)
        supported = false
        message = "Le simulateur n'a pas de capteur TrueDepth. Utilisez un iPhone."
        #else
        guard ARFaceTrackingConfiguration.isSupported else {
            supported = false
            message = "Cet appareil ne permet pas le suivi du visage (Face ID requis)."
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.startAR()
                } else {
                    self.message = "Accès à la caméra refusé. Autorisez-le dans Réglages."
                }
            }
        }
        #endif
    }

    /// Arrête la session (passage à un autre mode).
    func pause() {
        setMode(.off)
        arSession.pause()
        onMain { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func startAR() {
        arSession.delegate = self
        arSession.delegateQueue = deliveryQueue
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
        config.maximumNumberOfTrackedFaces = 1
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        setMode(.preview)
        message = "Placez le visage dans l'ovale, le nez à 30 cm de l'écran."
    }

    private func setMode(_ m: CaptureMode) {
        lock.lock()
        mode = m
        lock.unlock()
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: Son, voix, haptique

    private func speak(_ text: String, interrupt: Bool = false) {
        onMain {
            if interrupt { self.synth.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
            utterance.rate = 0.52
            self.synth.speak(utterance)
        }
    }

    private func cling() {
        onMain {
            AudioServicesPlaySystemSound(1057)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: Déroulement

    func startScan() {
        onMain {
            guard self.supported, self.phase == .idle else { return }
            self.phase = .countdown
            self.resultFolder = nil
            self.displayMesh = nil
            self.ring = [Float](repeating: 0, count: ScanEngine.ringCount)
            self.acceptedFrames = 0
            self.processedFrames = 0
            self.direction = .center
            self.trackState = .searching
            self.buildProgress = 0
            self.buildText = ""
            if self.style == .phoneMoves {
                self.message = "Patient : ne bougez plus, regardez droit devant vous."
                self.speak("Patient, ne bougez plus et regardez droit devant vous. Opérateur, placez le téléphone face au visage, à 30 centimètres. Début dans cinq secondes.", interrupt: true)
                UIApplication.shared.isIdleTimerDisabled = true
                self.tick(5)
            } else {
                self.message = "Téléphone immobile, visage dans l'ovale."
                self.speak("Gardez le téléphone immobile. Ne bougez que la tête. Début dans trois secondes.", interrupt: true)
                UIApplication.shared.isIdleTimerDisabled = true
                self.tick(3)
            }
        }
    }

    private func tick(_ n: Int) {
        if n == 0 {
            beginScanning()
            return
        }
        countdown = n
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.tick(n - 1)
        }
    }

    private func beginScanning() {
        countdown = 0
        phase = .scanning
        message = style == .phoneMoves ? "Téléphone face au visage, à 30 cm." : "Regardez l'écran, bien de face."
        let q = quality
        let cs = style
        let ys = yawSign
        holdProgress = 0
        stopIndex = 0
        stopTotal = 0
        procQueue.async {
            self.engine.reset(mode: q, style: cs, yawSign: ys)
            self.processedCount = 0
            self.lastWarningTime = -100
            self.setMode(.scan)
            self.speak(self.engine.currentInstruction)
        }
    }

    func stopScan() {
        onMain {
            guard self.phase == .scanning else { return }
            self.phase = .processing
            self.message = "Calcul du modèle en cours"
            self.buildProgress = 0
            self.buildText = "Préparation"
            self.setMode(.off)
            self.procQueue.async {
                self.engine.flush()
                self.finalizeScan()
            }
        }
    }

    func newScan() {
        onMain {
            self.phase = .idle
            self.displayMesh = nil
            self.resultFolder = nil
            self.message = "Placez le visage dans l'ovale, le nez à 30 cm de l'écran."
            UIApplication.shared.isIdleTimerDisabled = false
            self.procQueue.async {
                self.baseMesh = nil
                self.setMode(.preview)
            }
        }
    }

    // MARK: ARSessionDelegate (sur `deliveryQueue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depthData = frame.capturedDepthData else { return }

        lock.lock()
        let current = mode
        var accept = current != .off && !busy
        if accept && current == .preview && frame.timestamp - lastPreview < 0.3 { accept = false }
        if accept {
            busy = true
            if current == .preview { lastPreview = frame.timestamp }
        }
        lock.unlock()
        if !accept { return }

        // Copie immédiate des données : ne pas retenir l'ARFrame.
        let prior = Self.facePose(frame)
        let extracted = extract(depthData, camera: frame.camera)
        let color: ColorFrame? = current == .scan ? ColorFrame.capture(frame.capturedImage, camera: frame.camera) : nil
        let stamp = frame.timestamp

        procQueue.async {
            defer {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
            guard let data = extracted else { return }
            if current == .preview {
                self.handlePreview(depth: data.depth, intr: data.intr, prior: prior)
            } else {
                self.handleScan(depth: data.depth, intr: data.intr, prior: prior, color: color, time: stamp)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        report("Erreur ARKit : \(error.localizedDescription)")
    }

    private func report(_ text: String) {
        onMain { self.message = text }
    }

    /// Le bruit du capteur croît avec le carré de la distance : viser 28 à 33 cm du bout du nez.
    static func distanceAdvice(_ d: Double) -> String {
        let cm = Int((d * 100).rounded())
        if d > 0.36 { return "Nez à \(cm) cm : rapprochez-vous (idéal 30 cm)." }
        if d < 0.24 { return "Nez à \(cm) cm : reculez un peu (idéal 30 cm)." }
        return "Nez à \(cm) cm : bonne distance."
    }

    /// Pose visage -> capteur (x droite, y bas, z devant) à partir d'ARKit.
    private static func facePose(_ frame: ARFrame) -> RigidPose? {
        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else { return nil }
        let camInv = simd_inverse(frame.camera.transform)
        let m = simd_mul(camInv, face.transform)   // visage -> caméra ARKit (x droite, y haut, z vers l'arrière)
        let c0 = V3(Double(m.columns.0.x), -Double(m.columns.0.y), -Double(m.columns.0.z))
        let c1 = V3(Double(m.columns.1.x), -Double(m.columns.1.y), -Double(m.columns.1.z))
        let c2 = V3(Double(m.columns.2.x), -Double(m.columns.2.y), -Double(m.columns.2.z))
        let t = V3(Double(m.columns.3.x), -Double(m.columns.3.y), -Double(m.columns.3.z))
        let R = simd_double3x3(columns: (c0, c1, c2))
        return RigidPose(R: R, t: t)
    }

    // MARK: Aperçu avant scan

    private func handlePreview(depth: [Float], intr: Intrinsics, prior: RigidPose?) {
        let found = prior != nil
        let fs = engine.faceStats(depth: depth, intr: intr)
        let dist = found ? (fs?.znear ?? 0) : 0
        let raw: (yaw: Double, pitch: Double)? = prior.map { ScanEngine.headAngles($0) }
        onMain {
            guard self.phase == .idle || self.phase == .countdown else { return }
            self.faceFound = found
            if let a = raw {
                // test de sens : yaw > 0 = tête tournée vers la droite de l'écran (miroir)
                self.yawDeg = a.yaw * self.yawSign
                self.pitchDeg = a.pitch
            }
            self.noseDistance = dist
            if self.phase == .idle {
                if found && dist > 0 {
                    self.message = Self.distanceAdvice(dist)
                } else {
                    self.message = "Placez le visage dans l'ovale, le nez à 30 cm de l'écran."
                }
            }
        }
    }

    // MARK: Scan

    private func handleScan(depth: [Float], intr: Intrinsics, prior: RigidPose?, color: ColorFrame?, time: Double) {
        processedCount += 1
        let st = engine.process(depth: depth, intr: intr, prior: prior, color: color, time: time)
        let processed = processedCount
        if st.cling { cling() }
        if st.done { onMain { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
        if let s = st.say {
            speak(s, interrupt: s == "Stop." || s == "Tenez la position.")
        } else if let w = st.warning, time - lastWarningTime > 5 {
            // alerte vocale espacée (l'opérateur ne voit pas l'écran), sans couper une consigne en cours
            lastWarningTime = time
            onMain {
                if !self.synth.isSpeaking { self.speak(w) }
            }
        }

        onMain {
            guard self.phase == .scanning else { return }
            self.trackState = st.state
            self.yawDeg = st.yawDeg
            self.pitchDeg = st.pitchDeg
            self.ring = st.ring
            self.acceptedFrames = st.accepted
            self.holdProgress = st.hold
            self.stopIndex = st.stopIndex
            self.stopTotal = st.stopTotal
            self.processedFrames = processed
            if st.distance > 0 { self.noseDistance = st.distance }
            self.direction = st.direction
            self.faceFound = st.state == .tracking
            if st.state == .lost {
                self.message = st.warning ?? "Visage non détecté."
            } else {
                self.message = st.instruction
            }
            if st.autoFinish {
                self.speak("Scan terminé.")
                self.stopScan()
            }
        }
    }

    // MARK: Extraction de la profondeur

    private func extract(_ data: AVDepthData, camera: ARCamera) -> (depth: [Float], intr: Intrinsics)? {
        let converted = data.depthDataType == kCVPixelFormatType_DepthFloat32
            ? data
            : data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)

        var intr: Intrinsics
        if let cal = data.cameraCalibrationData {
            let k = cal.intrinsicMatrix
            let ref = cal.intrinsicMatrixReferenceDimensions
            let sx = Double(w) / Double(ref.width)
            let sy = Double(h) / Double(ref.height)
            intr = Intrinsics(fx: Double(k.columns.0.x) * sx, fy: Double(k.columns.1.y) * sy,
                              cx: Double(k.columns.2.x) * sx, cy: Double(k.columns.2.y) * sy,
                              width: w, height: h)
        } else {
            let k = camera.intrinsics
            let res = camera.imageResolution
            let sx = Double(w) / Double(res.width)
            let sy = Double(h) / Double(res.height)
            intr = Intrinsics(fx: Double(k.columns.0.x) * sx, fy: Double(k.columns.1.y) * sy,
                              cx: Double(k.columns.2.x) * sx, cy: Double(k.columns.2.y) * sy,
                              width: w, height: h)
        }

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        var out = [Float](repeating: Float.nan, count: w * h)
        out.withUnsafeMutableBufferPointer { ob in
            for y in 0..<h {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<w {
                    let z = row[x]
                    if z.isFinite && z > 0.10 && z < 1.5 {
                        ob[y * w + x] = z
                    }
                }
            }
        }
        return (out, intr)
    }

    // MARK: Fin de scan : maillage, STL, poses clés

    private func finalizeScan() {
        let mesh = engine.buildMesh { [weak self] fraction, text in
            self?.onMain {
                self?.buildProgress = fraction
                self?.buildText = text
            }
        }
        guard let mesh = mesh else {
            let got = engine.stopsCaptured
            onMain {
                self.phase = .idle
                self.message = got < 2
                    ? "Pas assez de poses (\(got)). Vérifiez la distance (nez à 30 cm), l'éclairage, et tenez la position à chaque arrêt."
                    : "Maillage insuffisant avec \(got) poses. Recommencez, nez à 30 cm, en tenant la position à chaque arrêt."
                UIApplication.shared.isIdleTimerDisabled = false
                self.setMode(.preview)
            }
            speak("Scan insuffisant. Recommencez.")
            return
        }

        let folder = Self.makeScanFolder()
        var missing = [String]()
        let device = Self.machineId()
        let styleName = engine.captureStyle.rawValue
        let stamp = ISO8601DateFormatter().string(from: Date())
        let exported = engine.exportedKeyframes

        for (i, label) in ScanEngine.keyLabels.enumerated() {
            guard let kf = exported[i], kf.isUsable, let intr = kf.intr else {
                missing.append(label)
                continue
            }
            let cloud = engine.keyframeCloud(kf)
            let n = cloud.points.count / 3
            if n < 2000 {
                missing.append(label)
                continue
            }
            let R = kf.pose.R
            let t = kf.pose.t
            let sf: [Double] = [
                R.columns.0.x, R.columns.1.x, R.columns.2.x, t.x,
                R.columns.0.y, R.columns.1.y, R.columns.2.y, t.y,
                R.columns.0.z, R.columns.1.z, R.columns.2.z, t.z
            ]
            let base = String(format: "pose_%02d", i + 1)
            let meta = PoseMeta(
                index: i, label: label, width: intr.width, height: intr.height,
                fx: intr.fx, fy: intr.fy, cx: intr.cx, cy: intr.cy,
                frames: kf.frames, points: n, medianDepthMeters: kf.medianDepth, units: "meters",
                device: device, date: stamp, yawDeg: kf.yaw, pitchDeg: kf.pitch,
                sensorFromFace: sf, source: "arkit_guided_v5_icp", captureStyle: styleName,
                framesAveraged: kf.frames, hasColor: cloud.colors != nil,
                refinedShiftMm: kf.shiftMillimeters, refinedRotationDeg: kf.rotationDegrees,
                colorFx: kf.color?.fx, colorFy: kf.color?.fy, colorCx: kf.color?.cx, colorCy: kf.color?.cy,
                colorWidth: kf.color?.width, colorHeight: kf.color?.height
            )
            do {
                try MeshIO.writePLY(points: cloud.points, colors: cloud.colors,
                                    to: folder.appendingPathComponent(base + ".ply"))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(meta).write(to: folder.appendingPathComponent(base + ".json"))
            } catch {
                missing.append(label)
            }
        }

        baseMesh = mesh
        var filesOK = true
        do {
            try MeshIO.writeBinarySTL(mesh, to: folder.appendingPathComponent("visage.stl"))
            try MeshIO.writeMeshPLY(mesh, to: folder.appendingPathComponent("visage_couleur.ply"))
        } catch {
            filesOK = false
        }

        let miss = missing
        let ok = filesOK
        let stops = engine.stopsCaptured
        let blocks = engine.captured.count
        let colored = mesh.hasColors
        onMain {
            self.resultFolder = folder
            self.quarterTurns = 0
            self.mirrored = false
            self.displayMesh = mesh
            self.meshVersion += 1
            self.phase = .done
            UIApplication.shared.isIdleTimerDisabled = false
            var text = ok
                ? "Scan terminé : \(mesh.triangleCount) triangles, \(stops) poses (\(blocks) vues) fusionnées" + (colored ? ", couleur incluse." : ", sans couleur.")
                : "Maillage créé, mais écriture des fichiers impossible."
            if !miss.isEmpty {
                text += " Poses non exportées : " + miss.joined(separator: ", ") + "."
            }
            self.message = text
        }
    }

    // MARK: Orientation du résultat

    func rotate90() {
        onMain {
            self.quarterTurns = (self.quarterTurns + 1) % 4
            self.refreshOrientation()
        }
    }

    func toggleMirror() {
        onMain {
            self.mirrored.toggle()
            self.refreshOrientation()
        }
    }

    private func refreshOrientation() {
        let qt = quarterTurns
        let mir = mirrored
        let folder = resultFolder
        procQueue.async {
            guard let base = self.baseMesh, let folder = folder else { return }
            let m = transformedMesh(base, quarterTurns: qt, mirror: mir)
            try? MeshIO.writeBinarySTL(m, to: folder.appendingPathComponent("visage.stl"))
            try? MeshIO.writeMeshPLY(m, to: folder.appendingPathComponent("visage_couleur.ply"))
            self.onMain {
                self.displayMesh = m
                self.meshVersion += 1
            }
        }
    }

    // MARK: Fichiers

    private static func makeScanFolder() -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Scan_" + df.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Archive .zip du dernier scan (5 PLY + 5 JSON + visage.stl + visage_couleur.ply).
    func zipLastScan() -> URL? {
        guard let folder = resultFolder else { return nil }
        var result: URL?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinatorError) { zipURL in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(folder.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: zipURL, to: dest)
                result = dest
            } catch {
                result = nil
            }
        }
        return result
    }

    private static func machineId() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
