import SwiftUI
import UIKit
import AVFoundation
import SceneKit
import ARKit
import simd

// MARK: - Vue principale

struct ContentView: View {
    @StateObject private var cam = DepthCaptureManager()
    @State private var shareItem: ShareItem?
    @State private var showColor = true
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cam.phase == .done, let mesh = cam.displayMesh {
                resultView(mesh: mesh)
            } else {
                scanView
            }
        }
        .onAppear { cam.prepare() }
        .onDisappear { cam.pause() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    // MARK: Écran de capture

    private var scanView: some View {
        ZStack {
            // Retournement fait par SwiftUI (un transform posé directement sur la vue UIKit n'est pas fiable)
            ARPreview(session: cam.arSession)
                .scaleEffect(x: cam.mirrorPreview ? -1 : 1, y: 1)
                .ignoresSafeArea()

            // Fond noir avec une ouverture ovale, comme l'enrôlement Face ID
            GeometryReader { geo in
                let ovalW = geo.size.width * 0.74
                let ovalH = ovalW * 1.36
                ZStack {
                    Rectangle()
                        .fill(Color.black)
                        .mask(
                            ZStack {
                                Rectangle()
                                Ellipse()
                                    .frame(width: ovalW, height: ovalH)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        )
                    Ellipse()
                        .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                        .frame(width: ovalW, height: ovalH)
                    FaceIDRing(
                        radiusX: ovalW / 2 + 14,
                        radiusY: ovalH / 2 + 14,
                        levels: cam.phase == .scanning ? cam.ring : [],
                        color: ringColor
                    )
                    // Les flèches s'adressent au patient qui tourne la tête ; en mode opérateur, la voix guide.
                    if cam.phase == .scanning && cam.style == .headMoves {
                        DirectionArrow(direction: cam.direction, ovalW: ovalW, ovalH: ovalH)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                Text(cam.message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(12)

                Spacer()

                if cam.phase == .countdown && cam.countdown > 0 {
                    Text("\(cam.countdown)")
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(radius: 8)
                }

                if cam.phase == .processing {
                    VStack(spacing: 8) {
                        ProgressView(value: min(1, max(0, cam.buildProgress)))
                            .progressViewStyle(LinearProgressViewStyle(tint: .green))
                        Text("\(cam.buildText) (\(Int((cam.buildProgress * 100).rounded())) %)")
                            .font(.footnote)
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(12)
                }

                Spacer()

                if cam.phase == .scanning {
                    VStack(spacing: 6) {
                        if cam.holdProgress > 0 {
                            ProgressView(value: min(1, cam.holdProgress))
                                .progressViewStyle(LinearProgressViewStyle(tint: .green))
                                .frame(maxWidth: 220)
                        }
                        Text("Pose \(cam.stopIndex)/\(cam.stopTotal)  |  Rotation \(Int(cam.yawDeg.rounded()))°  |  Inclinaison \(Int(cam.pitchDeg.rounded()))°")
                            .font(.footnote)
                            .foregroundColor(.white)
                        if cam.style == .phoneMoves {
                            Text("Patient : ne bougez pas, regardez droit devant vous")
                                .font(.footnote.bold())
                                .foregroundColor(.white)
                        }
                        if cam.noseDistance > 0.36 {
                            Text("Trop loin (nez à \(Int((cam.noseDistance * 100).rounded())) cm) : rapprochez-vous")
                                .font(.footnote.bold())
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(8)
                }

                if cam.phase == .idle {
                    idleControls
                    Button("Démarrer le scan") { cam.startScan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!cam.supported)
                }
                if cam.phase == .scanning {
                    Button("Terminer maintenant") { cam.stopScan() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                }
            }
            .padding()
        }
    }

    private var idleControls: some View {
        VStack(spacing: 8) {
            Picker("Qui bouge", selection: $cam.style) {
                ForEach(CaptureStyle.allCases) { c in
                    Text(c.title).tag(c)
                }
            }
            .pickerStyle(.segmented)
            Text(cam.style == .phoneMoves
                 ? "Patient immobile, l'opérateur tourne le téléphone autour du visage (le plus précis)."
                 : "Téléphone posé, le patient tourne la tête (scan seul).")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
            Picker("Qualité", selection: $cam.quality) {
                ForEach(ScanMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            Text(cam.quality.detail)
                .font(.caption)
                .foregroundColor(.white)

            if cam.senseChecked {
                Button(showSettings ? "Masquer le test de sens" : "Test de sens (gauche / droite)") {
                    showSettings.toggle()
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))
            }

            if showSense {
                VStack(spacing: 8) {
                    Text("Test de sens : tournez la tête vers VOTRE droite. Votre image doit aller vers la droite de l'écran, comme dans un miroir, et le point blanc aussi. Levez le menton : le point monte.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                    SenseGauge(yaw: cam.yawDeg, pitch: cam.pitchDeg)
                    Toggle("Image en miroir", isOn: $cam.mirrorPreview)
                        .font(.caption)
                        .foregroundColor(.white)
                    Toggle("Inverser le point (droite/gauche)", isOn: $cam.invertSides)
                        .font(.caption)
                        .foregroundColor(.white)
                    if !cam.senseChecked {
                        Button("Le sens est correct") {
                            cam.senseChecked = true
                            showSettings = false
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.65))
        .cornerRadius(10)
    }

    /// Le test de sens s'affiche tant qu'il n'a pas été validé une première fois.
    private var showSense: Bool { showSettings || !cam.senseChecked }

    private var ringColor: Color {
        if cam.phase == .scanning && cam.trackState == .lost { return .orange }
        return .green
    }

    // MARK: Écran de résultat

    private func resultView(mesh: Mesh) -> some View {
        VStack(spacing: 10) {
            MeshSceneView(mesh: mesh, version: cam.meshVersion, useColor: showColor && mesh.hasColors)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(cam.message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding(.horizontal)

            Text("Vérifiez la latéralité : vue de face, la joue gauche du patient doit être à droite de l'écran. Pivoter et Miroir corrigent le STL et le PLY couleur si besoin.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal)

            HStack(spacing: 10) {
                if mesh.hasColors {
                    Button(showColor ? "Couleur : oui" : "Couleur : non") { showColor.toggle() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                Button("Pivoter 90°") { cam.rotate90() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button(cam.mirrored ? "Miroir actif" : "Miroir") { cam.toggleMirror() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }

            HStack(spacing: 10) {
                Button("Partager (zip)") {
                    if let url = cam.zipLastScan() {
                        shareItem = ShareItem(url: url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Nouveau scan") { cam.newScan() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .padding()
    }
}

// MARK: - Anneau de progression façon Face ID

/// Anneau de repères radiaux autour de l'ovale, comme à l'enrôlement Face ID.
/// Le téléphone reste immobile, le patient dessine un cercle avec la tête : chaque repère passe au vert
/// quand la tête a été inclinée dans sa direction (haut du cercle = menton levé, droite = tête tournée vers sa droite).
struct FaceIDRing: View {
    let radiusX: CGFloat
    let radiusY: CGFloat
    let levels: [Float]
    let color: Color

    private let count = 72

    private func level(_ i: Int) -> Double {
        i < levels.count ? Double(levels[i]) : 0
    }

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                tick(i)
            }
        }
    }

    private func tick(_ i: Int) -> some View {
        let theta = 2.0 * Double.pi * Double(i) / Double(count)
        let x = Double(radiusX) * sin(theta)
        let y = -Double(radiusY) * cos(theta)
        let nx = sin(theta) / Double(radiusX)
        let ny = -cos(theta) / Double(radiusY)
        let angle = atan2(ny, nx)
        let lv = level(i)
        let lit = lv >= 0.85
        let grow = min(1.0, lv / 0.85)
        return Capsule()
            .fill(lit ? color : Color.white.opacity(0.35 + 0.3 * grow))
            .frame(width: CGFloat(12.0 + 12.0 * grow), height: 4)
            .rotationEffect(.radians(angle))
            .offset(x: CGFloat(x), y: CGFloat(y))
            .animation(.easeOut(duration: 0.2), value: lv)
    }
}

// MARK: - Flèche de direction

/// Flèche indiquant le mouvement demandé, vue par le patient face à l'écran (droite de l'écran = sa droite).
struct DirectionArrow: View {
    let direction: GuideDirection
    let ovalW: CGFloat
    let ovalH: CGFloat

    var body: some View {
        Group {
            switch direction {
            case .right:
                arrow("arrow.right").offset(x: ovalW * 0.32)
            case .left:
                arrow("arrow.left").offset(x: -ovalW * 0.32)
            case .up:
                arrow("arrow.up").offset(y: -ovalH * 0.36)
            case .down:
                arrow("arrow.down").offset(y: ovalH * 0.36)
            case .upRight:
                arrow("arrow.up.right").offset(x: ovalW * 0.28, y: -ovalH * 0.30)
            case .upLeft:
                arrow("arrow.up.left").offset(x: -ovalW * 0.28, y: -ovalH * 0.30)
            case .downRight:
                arrow("arrow.down.right").offset(x: ovalW * 0.28, y: ovalH * 0.30)
            case .downLeft:
                arrow("arrow.down.left").offset(x: -ovalW * 0.28, y: ovalH * 0.30)
            case .center:
                Image(systemName: "circle.dashed")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: direction)
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 54, weight: .bold))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.6), radius: 6)
    }
}

// MARK: - Aperçu caméra (ARKit)

struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Test de sens

/// Pavé qui montre la rotation mesurée : vers la droite de l'écran quand la tête tourne vers la droite
/// de l'écran (comme dans un miroir), vers le haut quand le menton monte.
struct SenseGauge: View {
    let yaw: Double
    let pitch: Double

    var body: some View {
        let size: CGFloat = 110
        let dx = CGFloat(max(-45, min(45, yaw)) / 45.0) * (size / 2 - 8)
        let dy = CGFloat(max(-30, min(30, pitch)) / 30.0) * (size / 2 - 8)
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                .frame(width: size, height: size)
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: size, height: 1)
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: size)
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .offset(x: dx, y: -dy)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Aperçu 3D du maillage

struct MeshSceneView: UIViewRepresentable {
    let mesh: Mesh
    let version: Int
    let useColor: Bool

    final class Coordinator {
        var lastKey = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.1, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let key = "\(version)-\(useColor)"
        if context.coordinator.lastKey == key { return }
        context.coordinator.lastKey = key
        view.scene = Self.makeScene(mesh, useColor: useColor)
    }

    static func makeScene(_ mesh: Mesh, useColor: Bool) -> SCNScene {
        let scene = SCNScene()
        let n = mesh.vertices.count
        var centroid = SIMD3<Float>(0, 0, 0)
        for v in mesh.vertices { centroid += v }
        if n > 0 { centroid /= Float(n) }

        var verts = [SCNVector3]()
        verts.reserveCapacity(n)
        for v in mesh.vertices {
            let c = v - centroid
            verts.append(SCNVector3(c.x, c.y, c.z))
        }

        var normals = [SCNVector3]()
        normals.reserveCapacity(n)
        for u in vertexNormals(mesh) {
            normals.append(SCNVector3(u.x, u.y, u.z))
        }

        let vSource = SCNGeometrySource(vertices: verts)
        let nSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        var sources = [vSource, nSource]
        if useColor && mesh.hasColors {
            var floats = [Float]()
            floats.reserveCapacity(n * 3)
            for c in mesh.colors {
                floats.append(Float(c.x) / 255)
                floats.append(Float(c.y) / 255)
                floats.append(Float(c.z) / 255)
            }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            let cSource = SCNGeometrySource(data: data, semantic: .color, vectorCount: n,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.size,
                                            dataOffset: 0, dataStride: MemoryLayout<Float>.size * 3)
            sources.append(cSource)
        }
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = (useColor && mesh.hasColors) ? UIColor.white : UIColor(white: 0.85, alpha: 1)
        material.lightingModel = .blinn
        material.isDoubleSided = true
        geometry.materials = [material]
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 5
        camera.fieldOfView = 40
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0, 0.55)
        scene.rootNode.addChildNode(camNode)
        return scene
    }
}

// MARK: - Partage

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
