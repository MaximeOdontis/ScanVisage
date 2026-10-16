import Foundation
import simd

enum TrackState {
    case searching   // pas encore de visage
    case tracking    // suivi correct
    case lost        // visage perdu par ARKit
}

/// Direction interne (signe des angles). .right : caméra du côté gauche du patient, comme une tête tournée vers sa droite
/// (qui apparaît à droite de l'écran en miroir). .up : caméra sous le visage, comme un menton levé.
enum GuideDirection {
    case center
    case right
    case left
    case up
    case down
    case upRight
    case upLeft
    case downRight
    case downLeft
}

/// Niveaux de qualité : plus d'arrêts et des arrêts plus longs.
enum ScanMode: String, CaseIterable, Identifiable {
    case rapide
    case precis
    case maximal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rapide: return "Rapide"
        case .precis: return "Précis"
        case .maximal: return "Maximal"
        }
    }

    var detail: String {
        switch self {
        case .rapide: return "5 poses, environ 40 s"
        case .precis: return "9 poses, environ 1 min 30"
        case .maximal: return "13 poses, environ 2 min 30"
        }
    }

    /// Durée de maintien à chaque arrêt (secondes passées dans la zone cible).
    var holdSeconds: Double {
        switch self {
        case .rapide: return 1.2
        case .precis: return 2.2
        case .maximal: return 3.0
        }
    }

    /// Taille des voxels du modèle final (mètres). En dessous de 1,2 mm, aucun gain mesuré avec ce capteur.
    var finalVoxel: Double {
        switch self {
        case .rapide: return 0.0015
        case .precis: return 0.0012
        case .maximal: return 0.0012
        }
    }

    var smoothingIterations: Int {
        switch self {
        case .rapide: return 8
        case .precis: return 10
        case .maximal: return 10
        }
    }
}

/// Qui bouge pendant le scan.
/// - phoneMoves : le patient reste immobile, un opérateur déplace le téléphone autour du visage (par défaut).
///   Évite la déformation des tissus mous quand le patient tourne la tête (mesurée sur un scan réel :
///   joues et lèvres décalées de 1 à 2 mm en médiane entre poses, front stable).
/// - headMoves : le téléphone est posé, le patient tourne la tête (scan seul, moins précis).
enum CaptureStyle: String, CaseIterable, Identifiable {
    case phoneMoves
    case headMoves

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phoneMoves: return "Le téléphone tourne"
        case .headMoves: return "La tête tourne"
        }
    }

    // Amplitudes cibles (degrés). Le téléphone peut aller plus loin que la tête sans gêne.
    var yawTarget: Double { self == .phoneMoves ? 42.0 : 38.0 }
    var pitchUpTarget: Double { self == .phoneMoves ? 25.0 : 22.0 }    // caméra sous le visage (menton levé)
    var pitchDownTarget: Double { self == .phoneMoves ? 22.0 : 18.0 }  // caméra au-dessus (menton baissé)
}

/// Bloc de profondeur : moyenne de quelques images où la tête n'a presque pas bougé (moins de 1,2° et 4 mm).
/// Un arrêt en contient un à quatre ; le plus long est le « représentant » de l'arrêt
/// (image couleur, export PLY, recalage multivue), les autres apportent des points de vue légèrement différents.
struct KeyFrame {
    let label: String
    /// 0 à 4 pour les cinq poses exportées (face, droite, gauche, haut, bas), nil pour les autres arrêts.
    let exportIndex: Int?
    /// Numéro de l'arrêt (0 = face).
    let stop: Int
    var representative: Bool = false
    var depth: [Float] = []
    var intr: Intrinsics?
    var yaw: Double = 0
    var pitch: Double = 0
    var medianDepth: Double = 0
    var prior: RigidPose = RigidPose.identity   // pose donnée par ARKit
    var pose: RigidPose = RigidPose.identity    // pose après recalage
    var frames: Int = 0                         // nombre de trames moyennées
    var color: ColorFrame?

    var isUsable: Bool { !depth.isEmpty && intr != nil }

    /// Correction apportée par le recalage, mesurée au bout du nez (mm) et en rotation (degrés).
    var shiftMillimeters: Double {
        let nose = V3(0, 0, 0.12)
        return simd_length(pose.apply(nose) - prior.apply(nose)) * 1000.0
    }
    var rotationDegrees: Double { prior.inverse().compose(pose).rotationAngleDegrees }
}

struct EngineStatus {
    var state: TrackState = .searching
    var yawDeg: Double = 0
    var pitchDeg: Double = 0
    var distance: Double = 0       // distance du point le plus proche du visage (m)
    var accepted: Int = 0          // trames gardées dans l'arrêt en cours
    var direction: GuideDirection = .center
    var instruction: String = ""
    var say: String?
    var cling: Bool = false        // cible atteinte
    var done: Bool = false         // arrêt terminé
    var autoFinish: Bool = false
    var hold: Double = 0           // progression du maintien (0 à 1)
    var stopIndex: Int = 0
    var stopTotal: Int = 0
    var warning: String?           // alerte à dire à voix haute (distance, visage perdu)
    var ring: [Float] = [Float](repeating: 0, count: ScanEngine.ringCount)
}

struct FaceStats {
    var zmed: Double
    var znear: Double              // 3e centile : en pratique le bout du nez
}

/// Moteur de scan.
/// Capture : angles de la tête (ARKit), guidage, et à chaque arrêt quelques blocs de profondeur moyennée.
/// Reconstruction : filtre bilatéral, recalage multivue ICP (les poses ARKit ne suffisent pas),
/// fusion TSDF, maillage, couleurs.
/// Toutes les méthodes sont appelées depuis la même file série.
final class ScanEngine {

    static let ringCount = 72

    // Seuils de détection automatique (degrés) : amplitudes dans CaptureStyle
    static let centerTol = 8.0
    static let diagonalFactor = 0.65   // les diagonales demandent 65 % de l'amplitude de chaque axe

    /// Signe appliqué au yaw calculé depuis ARKit. Documentation Apple : +X du repère visage = gauche du visage,
    /// donc yaw > 0 = tête tournée vers la droite du patient. Vérifié sur un scan réel.
    static let defaultYawSign = 1.0

    /// Poses exportées, nommées par le côté du visage visible (identique dans les deux modes).
    static let keyLabels = ["face", "profil_droit", "profil_gauche", "dessous", "dessus"]

    // Tolérance d'un bloc (au-delà, le bloc est clos et un autre commence ; l'arrêt continue)
    static let blockMaxDegrees = 1.2
    static let blockMaxShift = 0.004
    static let maxBlocksPerStop = 4

    // Fusion
    static let truncation = 0.007

    private struct Step {
        let direction: GuideDirection
        let label: String?           // arrêt enregistré (nil : simple déplacement)
        let exportIndex: Int?
        let instruction: String
        let factor: Double           // fraction de l'amplitude cible (0,5 pour un arrêt intermédiaire)
        let hold: Double             // secondes de maintien
    }

    /// Directions internes (signe des angles) : .right = caméra du côté gauche du patient
    /// (comme une tête tournée vers sa droite), .up = caméra sous le visage (comme un menton levé).
    private static func makeSteps(_ mode: ScanMode, _ style: CaptureStyle) -> [Step] {
        let h = mode.holdSeconds
        let phone = style == .phoneMoves
        var list = [Step]()
        list.append(Step(direction: .center, label: "face", exportIndex: 0,
                         instruction: phone ? "Téléphone face au visage, à 30 centimètres. Tenez la position."
                                            : "Regardez l'écran, bien de face, et tenez la position.",
                         factor: 1, hold: h * 1.5))
        func back() {
            list.append(Step(direction: .center, label: nil, exportIndex: nil,
                             instruction: phone ? "Revenez face au visage." : "Revenez au centre.",
                             factor: 1, hold: 0.5))
        }
        func axis(_ d: GuideDirection, _ label: String, _ idx: Int?, _ full: String, _ half: String?) {
            if mode == .maximal, let halfText = half {
                list.append(Step(direction: d, label: label + "_mi", exportIndex: nil,
                                 instruction: halfText, factor: 0.5, hold: h))
            }
            list.append(Step(direction: d, label: label, exportIndex: idx, instruction: full, factor: 1, hold: h))
            back()
        }
        if phone {
            axis(.left, "profil_droit", 1, "Tournez lentement autour du visage, vers la droite du patient.",
                 "À mi-chemin vers la droite du patient, puis tenez la position.")
            axis(.right, "profil_gauche", 2, "Tournez lentement autour du visage, vers la gauche du patient.",
                 "À mi-chemin vers la gauche du patient, puis tenez la position.")
            axis(.up, "dessous", 3, "Descendez lentement le téléphone sous le menton, en visant le visage.",
                 "Descendez un peu le téléphone, puis tenez la position.")
            axis(.down, "dessus", 4, "Montez lentement le téléphone au-dessus du front, en visant le visage.",
                 "Montez un peu le téléphone, puis tenez la position.")
            if mode != .rapide {
                axis(.upLeft, "dessous_droit", nil, "En bas, du côté droit du patient.", nil)
                axis(.upRight, "dessous_gauche", nil, "En bas, du côté gauche du patient.", nil)
                axis(.downLeft, "dessus_droit", nil, "En haut, du côté droit du patient.", nil)
                axis(.downRight, "dessus_gauche", nil, "En haut, du côté gauche du patient.", nil)
            }
        } else {
            // tête tournée vers sa droite : la caméra voit le côté gauche du visage
            axis(.right, "profil_gauche", 2, "Tournez lentement la tête vers votre droite.",
                 "Un peu vers votre droite, puis tenez la position.")
            axis(.left, "profil_droit", 1, "Tournez lentement la tête vers votre gauche.",
                 "Un peu vers votre gauche, puis tenez la position.")
            axis(.up, "dessous", 3, "Levez lentement le menton.",
                 "Levez un peu le menton, puis tenez la position.")
            axis(.down, "dessus", 4, "Baissez lentement le menton.",
                 "Baissez un peu le menton, puis tenez la position.")
            if mode != .rapide {
                axis(.upRight, "dessous_gauche", nil, "Menton levé, tournez vers votre droite.", nil)
                axis(.upLeft, "dessous_droit", nil, "Menton levé, tournez vers votre gauche.", nil)
                axis(.downRight, "dessus_gauche", nil, "Menton baissé, tournez vers votre droite.", nil)
                axis(.downLeft, "dessus_droit", nil, "Menton baissé, tournez vers votre gauche.", nil)
            }
        }
        return list
    }

    // État du scan
    private var mode: ScanMode = .precis
    private var style: CaptureStyle = .phoneMoves
    private var steps: [Step] = ScanEngine.makeSteps(.precis, .phoneMoves)
    private var yawSign = ScanEngine.defaultYawSign
    private var lastPrior: RigidPose?
    private var lastTime: Double?
    private var stepIndex = 0
    private var stepStart = -1.0
    private var reached = false
    private var everReached = false
    private var heldTime = 0.0
    private var finished = false
    private var stopCounter = 0
    private var progress: [GuideDirection: Double] = [:]
    private(set) var captured: [KeyFrame] = []

    // Bloc d'accumulation courant
    private struct Block {
        var sum: [Float] = []
        var cnt: [UInt8] = []
        var n = 0
        var anchor = RigidPose.identity
        var yaw = 0.0
        var pitch = 0.0
        var zmed = 0.0
        var color: ColorFrame?
        var intr: Intrinsics?

        mutating func clear() {
            sum = []
            cnt = []
            n = 0
            color = nil
            intr = nil
        }
    }
    private var block = Block()
    private var stopBlocks: [KeyFrame] = []

    func reset(mode: ScanMode = .precis, style: CaptureStyle = .phoneMoves,
               yawSign: Double = ScanEngine.defaultYawSign) {
        self.mode = mode
        self.style = style
        self.yawSign = yawSign
        steps = ScanEngine.makeSteps(mode, style)
        lastPrior = nil
        lastTime = nil
        stepIndex = 0
        stepStart = -1
        reached = false
        everReached = false
        heldTime = 0
        finished = false
        stopCounter = 0
        progress = [:]
        captured = []
        block = Block()
        stopBlocks = []
    }

    var currentInstruction: String {
        steps[min(stepIndex, steps.count - 1)].instruction
    }

    private var stopTotal: Int { steps.filter { $0.label != nil }.count }

    /// Représentants des cinq poses exportées, dans l'ordre face, droite, gauche, haut, bas (nil si non capturée).
    var exportedKeyframes: [KeyFrame?] {
        var out = [KeyFrame?](repeating: nil, count: ScanEngine.keyLabels.count)
        for kf in captured where kf.representative {
            if let i = kf.exportIndex, i < out.count { out[i] = kf }
        }
        return out
    }

    var captureStyle: CaptureStyle { style }

    /// Nombre d'arrêts réussis.
    var stopsCaptured: Int { captured.filter { $0.representative }.count }

    // MARK: Profondeur au centre de l'image

    func faceStats(depth: [Float], intr: Intrinsics) -> FaceStats? {
        let W = intr.width
        let H = intr.height
        let y0 = Int(0.3 * Double(H))
        let y1 = Int(0.7 * Double(H))
        let x0 = Int(0.25 * Double(W))
        let x1 = Int(0.75 * Double(W))
        var vals = [Float]()
        var total = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                total += 1
                let d = depth[y * W + x]
                if d > 0.05 { vals.append(d) }
                x += 2
            }
            y += 2
        }
        if total == 0 || vals.count < 100 { return nil }
        vals.sort()
        return FaceStats(zmed: Double(vals[vals.count / 2]), znear: Double(vals[vals.count * 3 / 100]))
    }

    // MARK: Angles de la tête

    /// Angles bruts à partir de la position de la caméra dans le repère visage ARKit.
    /// yaw > 0 : tête tournée vers la droite du patient. pitch > 0 : menton levé.
    static func headAngles(_ pose: RigidPose) -> (yaw: Double, pitch: Double) {
        let c: V3 = pose.inverse().t        // position de la caméra dans le repère visage
        let yaw = atan2(c.x, c.z) * 180.0 / Double.pi
        let horiz = (c.x * c.x + c.z * c.z).squareRoot()
        let pitch = -atan2(c.y, horiz) * 180.0 / Double.pi
        return (yaw.isFinite ? yaw : 0, pitch.isFinite ? pitch : 0)
    }

    // MARK: Traitement d'une trame

    /// `prior` : pose visage -> capteur donnée par ARKit (nil si ARKit ne voit pas le visage).
    /// `time` : horodatage de la trame en secondes.
    func process(depth: [Float], intr: Intrinsics, prior: RigidPose?, color: ColorFrame?, time: Double) -> EngineStatus {
        var out = EngineStatus()
        finishStatus(&out)
        let dt = lastTime.map { min(0.2, max(0, time - $0)) } ?? 0
        lastTime = time
        if stepStart < 0 { stepStart = time }

        guard let prior = prior else {
            out.state = .lost
            out.warning = style == .phoneMoves ? "Visage perdu. Revenez face au visage." : "Visage perdu. Regardez l'écran."
            if stepIndex < steps.count { closeBlock(steps[stepIndex]) }
            return out
        }
        out.state = .tracking

        // Image prise pendant un mouvement rapide : floue, ignorée
        var moving = false
        if let lp = lastPrior {
            let rel = lp.inverse().compose(prior)
            moving = rel.rotationAngleDegrees > 2.0 || simd_length(rel.t) > 0.004
        }
        lastPrior = prior

        let raw = ScanEngine.headAngles(prior)
        let yaw = raw.yaw * yawSign
        let pitch = raw.pitch
        out.yawDeg = yaw
        out.pitchDeg = pitch
        let stats = faceStats(depth: depth, intr: intr)
        let zmed = stats?.zmed ?? prior.t.z
        out.distance = stats?.znear ?? 0
        if out.distance > 0.37 {
            out.warning = style == .phoneMoves ? "Rapprochez le téléphone." : "Rapprochez-vous."
        } else if out.distance > 0 && out.distance < 0.23 {
            out.warning = style == .phoneMoves ? "Éloignez un peu le téléphone." : "Reculez un peu."
        }

        if finished || stepIndex >= steps.count {
            out.autoFinish = finished
            return out
        }

        func advance() {
            stepIndex += 1
            stepStart = time
            reached = false
            everReached = false
            heldTime = 0
            stopBlocks = []
            block.clear()
            if stepIndex >= steps.count {
                finished = true
                out.autoFinish = true
            } else {
                out.say = steps[stepIndex].instruction
            }
        }

        let step = steps[stepIndex]
        let amp = amplitude(step.direction, yaw: yaw, pitch: pitch)
        if step.direction != .center {
            progress[step.direction] = max(progress[step.direction] ?? 0, min(1, amp))
        }

        // Arrêt intermédiaire dépassé sans s'être arrêté : on le saute
        if !reached && step.factor < 1 && amp >= step.factor + 0.3 {
            advance()
            finishStatus(&out)
            return out
        }

        let ok = inTarget(step, yaw: yaw, pitch: pitch, relaxed: everReached)
        if ok {
            if !reached {
                reached = true
                if !everReached {
                    everReached = true
                    if step.label != nil {
                        out.cling = true
                        out.say = step.direction == .center ? "Tenez la position." : "Stop."
                    }
                }
            }
        } else if reached {
            reached = false
            if step.label != nil { closeBlock(step) }
        }

        if reached {
            heldTime += dt
            if step.label != nil {
                if !moving {
                    accumulate(depth: depth, intr: intr, prior: prior, color: color,
                               yaw: yaw, pitch: pitch, zmed: zmed, step: step)
                }
                let frames = block.n + stopBlocks.reduce(0) { $0 + $1.frames }
                out.accepted = frames
                out.hold = min(1, heldTime / step.hold)
                let complete = heldTime >= step.hold && frames >= 6
                let timeout = (time - stepStart) > step.hold * 3.0 + 5.0
                if complete || timeout {
                    closeBlock(step)
                    if finalizeStop() { out.done = true }
                    advance()
                }
            } else if heldTime >= step.hold {
                advance()
            }
        }

        finishStatus(&out)
        return out
    }

    private func finishStatus(_ out: inout EngineStatus) {
        out.direction = steps[min(stepIndex, steps.count - 1)].direction
        out.instruction = currentInstruction
        out.ring = ringLevels()
        out.stopTotal = stopTotal
        out.stopIndex = min(stopCounter + 1, max(1, stopTotal))
    }

    // MARK: Amplitudes et cibles

    private func amplitude(_ d: GuideDirection, yaw: Double, pitch: Double) -> Double {
        let ay = yaw / style.yawTarget
        let up = pitch / style.pitchUpTarget
        let down = -pitch / style.pitchDownTarget
        let k = ScanEngine.diagonalFactor
        switch d {
        case .center: return 0
        case .right: return ay
        case .left: return -ay
        case .up: return up
        case .down: return down
        case .upRight: return min(ay, up) / k
        case .upLeft: return min(-ay, up) / k
        case .downRight: return min(ay, down) / k
        case .downLeft: return min(-ay, down) / k
        }
    }

    /// `relaxed` : une fois la cible atteinte une première fois, la zone est élargie
    /// pour que de petits mouvements ne fassent pas perdre l'arrêt.
    private func inTarget(_ s: Step, yaw: Double, pitch: Double, relaxed: Bool) -> Bool {
        if s.direction == .center {
            let tol = (s.label == "face" ? 6.0 : ScanEngine.centerTol) + (relaxed ? 4.0 : 0.0)
            return abs(yaw) < tol && abs(pitch) < tol
        }
        let a = amplitude(s.direction, yaw: yaw, pitch: pitch)
        if a < s.factor - (relaxed ? 0.2 : 0.0) { return false }
        if s.factor < 1 { return a < s.factor + (relaxed ? 0.45 : 0.3) }
        return true
    }

    // MARK: Blocs de profondeur moyennée

    private func accumulate(depth: [Float], intr: Intrinsics, prior: RigidPose, color: ColorFrame?,
                            yaw: Double, pitch: Double, zmed: Double, step: Step) {
        if block.n > 0 {
            // la tête a bougé par rapport à la première trame du bloc : on clôt ce bloc et on en commence un autre
            let rel = block.anchor.inverse().compose(prior)
            if rel.rotationAngleDegrees > ScanEngine.blockMaxDegrees
                || simd_length(rel.t) > ScanEngine.blockMaxShift
                || block.sum.count != depth.count {
                closeBlock(step)
            }
        }
        if block.n == 0 {
            block.sum = [Float](repeating: 0, count: depth.count)
            block.cnt = [UInt8](repeating: 0, count: depth.count)
            block.anchor = prior
            block.yaw = yaw
            block.pitch = pitch
            block.zmed = zmed
            block.color = color
            block.intr = intr
        }
        if block.n >= 200 { return }   // le compteur par pixel est sur 8 bits
        var s = block.sum
        var c = block.cnt
        block.sum = []
        block.cnt = []
        let count = depth.count
        depth.withUnsafeBufferPointer { dp in
            s.withUnsafeMutableBufferPointer { sp in
                c.withUnsafeMutableBufferPointer { cp in
                    for i in 0..<count {
                        let d = dp[i]
                        if d > 0.05 {
                            sp[i] += d
                            cp[i] &+= 1
                        }
                    }
                }
            }
        }
        block.sum = s
        block.cnt = c
        block.n += 1
    }

    /// Clôt le bloc courant et l'ajoute aux blocs de l'arrêt (au plus `maxBlocksPerStop`, les plus longs).
    private func closeBlock(_ step: Step) {
        defer { block.clear() }
        guard block.n >= 3, let intr = block.intr, let label = step.label else { return }
        let minCount = UInt8(max(2, min(200, block.n / 2)))
        var avg = [Float](repeating: Float.nan, count: block.sum.count)
        for k in 0..<block.sum.count where block.cnt[k] >= minCount {
            avg[k] = block.sum[k] / Float(block.cnt[k])
        }
        var kf = KeyFrame(label: label, exportIndex: step.exportIndex, stop: stopCounter)
        kf.depth = avg
        kf.intr = intr
        kf.yaw = block.yaw
        kf.pitch = block.pitch
        kf.medianDepth = block.zmed
        kf.prior = block.anchor
        kf.pose = block.anchor
        kf.frames = block.n
        kf.color = block.color
        stopBlocks.append(kf)
        if stopBlocks.count > ScanEngine.maxBlocksPerStop {
            var smallest = 0
            for k in 1..<stopBlocks.count where stopBlocks[k].frames < stopBlocks[smallest].frames {
                smallest = k
            }
            stopBlocks.remove(at: smallest)
        }
    }

    /// Termine l'arrêt : le bloc le plus long devient le représentant (seul à garder son image couleur).
    private func finalizeStop() -> Bool {
        defer { stopBlocks = [] }
        guard !stopBlocks.isEmpty else { return false }
        var best = 0
        for k in 1..<stopBlocks.count where stopBlocks[k].frames > stopBlocks[best].frames {
            best = k
        }
        if stopBlocks[best].frames < 3 { return false }
        var rep = stopBlocks[best]
        rep.representative = true
        captured.append(rep)
        for k in 0..<stopBlocks.count where k != best {
            var kf = stopBlocks[k]
            kf.color = nil
            captured.append(kf)
        }
        stopCounter += 1
        return true
    }

    /// À appeler à l'arrêt manuel : conserve l'arrêt en cours s'il a assez de trames.
    func flush() {
        if !finished && stepIndex < steps.count && steps[stepIndex].label != nil {
            closeBlock(steps[stepIndex])
            _ = finalizeStop()
        }
        stopBlocks = []
        block.clear()
    }

    // MARK: Anneau : un secteur par direction

    private func ringLevels() -> [Float] {
        let n = ScanEngine.ringCount
        var levels = [Float](repeating: 0, count: n)
        let centers: [(GuideDirection, Double)] = [
            (.up, 0), (.upRight, 45), (.right, 90), (.downRight, 135),
            (.down, 180), (.downLeft, 225), (.left, 270), (.upLeft, 315)
        ]
        let halfWidth = mode == .rapide ? 40.0 : 22.5
        for (d, deg0) in centers {
            let p = Float(progress[d] ?? 0)
            if p <= 0 { continue }
            // mode opérateur : le secteur allumé est le côté du visage vu, tel qu'il apparaît dans le miroir
            let deg = style == .phoneMoves ? (360 - deg0).truncatingRemainder(dividingBy: 360) : deg0
            for i in 0..<n {
                let a = Double(i) * 360.0 / Double(n)
                var diff = abs(a - deg)
                if diff > 180 { diff = 360 - diff }
                if diff <= halfWidth { levels[i] = max(levels[i], p) }
            }
        }
        return levels
    }

    // MARK: Reconstruction après capture

    /// Volume couvrant la région de la tête (voir TSDFVolume.insideHead).
    static func makeVolume(voxel: Double, trunc: Double) -> TSDFVolume {
        let nx = Int((0.22 / voxel).rounded(.up)) + 1
        let ny = Int((0.275 / voxel).rounded(.up)) + 1
        let nz = Int((0.225 / voxel).rounded(.up)) + 1
        return TSDFVolume(origin: V3(-0.11, -0.125, -0.06), nx: nx, ny: ny, nz: nz, voxel: voxel, trunc: trunc)
    }

    /// Filtrage, recalage multivue, fusion TSDF, maillage lissé et coloré.
    /// `report(fraction, texte)` : progression pour l'interface.
    func buildMesh(report: @escaping (Double, String) -> Void) -> Mesh? {
        let n = captured.count
        guard n >= 2, captured[0].representative, captured[0].label == "face" else { return nil }
        for kf in captured where !kf.isUsable { return nil }

        // 1. Filtre bilatéral de chaque bloc (le bruit du capteur est figé : la moyenne dans le temps ne suffit pas)
        for i in 0..<n {
            report(0.02 + 0.08 * Double(i) / Double(n), "Filtrage de la profondeur")
            let intr = captured[i].intr!
            captured[i].depth = bilateralFilter(captured[i].depth, width: intr.width, height: intr.height)
        }

        // 2. Nuages de points limités à la tête (marge de 3 cm : les poses ARKit sont approximatives)
        var clouds = [ViewCloud]()
        for kf in captured {
            let full = makeViewCloud(depth: kf.depth, intr: kf.intr!, step: 2)
            clouds.append(selectHeadPoints(full, pose: kf.prior, margin: 0.03))
        }

        // 3. Recalage multivue des représentants (un par arrêt, la face reste fixe)
        let reps = (0..<n).filter { captured[$0].representative }.sorted { captured[$0].stop < captured[$1].stop }
        var repPoses = reps.map { captured[$0].prior }
        multiViewICP(clouds: reps.map { clouds[$0] }, poses: &repPoses, progress: { f in
            report(0.10 + 0.25 * f, "Recalage des poses")
        })
        var correction = [Int: RigidPose]()     // par arrêt : pose ARKit -> pose recalée, dans le repère visage
        for (k, idx) in reps.enumerated() {
            captured[idx].pose = repPoses[k]
            correction[captured[idx].stop] = captured[idx].prior.inverse().compose(repPoses[k])
        }

        // 4. Autres blocs : correction de leur arrêt, puis affinage sur l'ensemble des représentants
        let others = (0..<n).filter { !captured[$0].representative }
        if !others.isEmpty {
            let target = faceFrameTarget(reps.map { (cloud: clouds[$0], pose: captured[$0].pose) })
            let grid = PointGrid(points: target.points, cell: 0.008)
            for (k, idx) in others.enumerated() {
                report(0.35 + 0.08 * Double(k) / Double(others.count), "Recalage des images intermédiaires")
                var pose = captured[idx].prior.compose(correction[captured[idx].stop] ?? RigidPose.identity)
                let src = subsample(clouds[idx], maxCount: 6000)
                if src.count >= 200 {
                    for level: Float in [0.008, 0.005, 0.003] {
                        pose = icpRefine(source: src, pose: pose, grid: grid, targetNormals: target.normals,
                                         maxDist: level, iterations: 3)
                    }
                }
                captured[idx].pose = pose
            }
        }
        clouds = []

        // 5. Fusion TSDF (troncature large : moyenne les vues entre elles malgré le bruit figé du capteur)
        let voxel = mode.finalVoxel
        let fine = ScanEngine.makeVolume(voxel: voxel, trunc: ScanEngine.truncation)
        for i in 0..<n {
            report(0.43 + 0.17 * Double(i) / Double(n), "Fusion (\(i + 1) sur \(n))")
            let kf = captured[i]
            let weights = TSDFVolume.pixelWeights(depth: kf.depth, intr: kf.intr!, span: 3)
            let wgt = Float(0.5 + 0.5 * min(1.0, Double(kf.frames) / 10.0))
            fine.integrate(depth: kf.depth, weights: weights, intr: kf.intr!, pose: kf.pose, weight: wgt)
        }

        // 6. Surface, lissage, plus grande composante
        report(0.62, "Extraction de la surface")
        var m = extractMesh(from: fine)
        if m.triangleCount < 2000 { return nil }
        report(0.72, "Lissage")
        taubinSmooth(&m, iterations: mode.smoothingIterations)
        m = largestComponent(m)
        if m.triangleCount < 2000 { return nil }

        // 7. Couleurs (représentants seulement)
        let colored = captured.filter { $0.color != nil }
        if !colored.isEmpty {
            report(0.80, "Couleurs")
            m.colors = colorizeMesh(m, stops: colored, progress: { f in
                report(0.80 + 0.18 * f, "Couleurs")
            })
        }
        report(1.0, "Terminé")
        return m
    }

    // MARK: Nuage de points d'une pose clé (repère capteur, mètres), avec couleur si disponible

    func keyframeCloud(_ kf: KeyFrame) -> (points: [Float], colors: [UInt8]?) {
        guard let intr = kf.intr else { return ([], nil) }
        let W = intr.width
        let H = intr.height
        var pts = [Float]()
        pts.reserveCapacity(W * H)
        let withColor = kf.color != nil
        var cols = [UInt8]()
        if withColor { cols.reserveCapacity(W * H) }
        for y in 0..<H {
            for x in 0..<W {
                let z = kf.depth[y * W + x]
                if z > 0.10 && z < 1.20 && abs(Double(z) - kf.medianDepth) < 0.15 {
                    let zd = Double(z)
                    let px = (Double(x) - intr.cx) * zd / intr.fx
                    let py = (Double(y) - intr.cy) * zd / intr.fy
                    pts.append(Float(px))
                    pts.append(Float(py))
                    pts.append(z)
                    if let cf = kf.color {
                        if let c = cf.color(atSensorPoint: V3(px, py, zd)) {
                            cols.append(UInt8(c.x.rounded()))
                            cols.append(UInt8(c.y.rounded()))
                            cols.append(UInt8(c.z.rounded()))
                        } else {
                            cols.append(128)
                            cols.append(128)
                            cols.append(128)
                        }
                    }
                }
            }
        }
        return (pts, withColor ? cols : nil)
    }
}
