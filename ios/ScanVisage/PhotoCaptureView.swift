import SwiftUI
import ARKit

/// Capture photo haute définition, caméra arrière. L'opérateur voit l'écran, le patient ne bouge pas.
struct PhotoCaptureView: View {
    let onBack: () -> Void
    @StateObject private var cap = PhotoCaptureManager()
    @State private var shareItem: ShareItem?
    @State private var folderName = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BackCameraPreview(session: cap.session)
                .ignoresSafeArea()

            if cap.phase == .mouth || cap.phase == .mouthPrep {
                ZStack {
                    Circle().stroke(Color.yellow.opacity(0.85), lineWidth: 2).frame(width: 170, height: 170)
                    Rectangle().fill(Color.yellow.opacity(0.85)).frame(width: 18, height: 2)
                    Rectangle().fill(Color.yellow.opacity(0.85)).frame(width: 2, height: 18)
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                HStack {
                    Button("Retour") {
                        cap.stop()
                        onBack()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    Spacer()
                    Text("\(cap.count) photos")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                }

                Text(cap.message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(12)

                Spacer()

                statusLine

                if cap.phase == .mouth || cap.phase == .mouthPrep {
                    VStack(spacing: 6) {
                        Text("Bouche : \(cap.mouthCount) / \(PhotoCaptureManager.mouthMax) photos (minimum \(PhotoCaptureManager.mouthMin))")
                            .font(.footnote.bold())
                            .foregroundColor(.white)
                        ProgressView(value: Double(cap.mouthCount), total: Double(PhotoCaptureManager.mouthMax))
                            .tint(.green)
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(12)
                } else {
                    CoverageGrid(filled: cap.filled, current: cap.currentBin)
                        .padding(10)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(12)
                }

                buttons
            }
            .padding()
        }
        .onAppear { cap.start() }
        .onDisappear { cap.stop() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    private var statusLine: some View {
        HStack(spacing: 12) {
            Label(cap.phase == .mouth || cap.phase == .mouthPrep
                    ? (cap.faceVisible ? "Distance bouche OK" : "Distance : 12 à 30 cm")
                    : (cap.faceVisible ? "Visage" : "Pas de visage"),
                  systemImage: cap.faceVisible ? "face.smiling" : "exclamationmark.triangle")
                .foregroundColor(cap.faceVisible ? .green : .orange)
            if cap.distance > 0 {
                Text("\(Int((cap.distance * 100).rounded())) cm")
                    .foregroundColor(cap.distance > cap.mode.farLimit || cap.distance < cap.mode.nearLimit ? .orange : .white)
            }
            if cap.phase == .capturing || cap.phase == .mouth {
                Text(cap.stable ? "Stable" : "Bouge")
                    .foregroundColor(cap.stable ? .green : .orange)
            }
        }
        .font(.footnote.bold())
        .padding(8)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var buttons: some View {
        switch cap.phase {
        case .idle:
            VStack(spacing: 6) {
                Toggle("HD+Mouth : 2e séquence de près sur la bouche", isOn: $cap.withMouth)
                    .font(.footnote.bold())
                    .foregroundColor(.white)
                Picker("Mode", selection: $cap.mode) {
                    ForEach(PhotoMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                Text(cap.mode.summary)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Text("Patient immobile, bonne lumière diffuse, écarteur si besoin. Téléphone en portrait, caméra arrière vers le visage.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                Button("Démarrer (de face)") { cap.begin() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if !cap.highResolution {
                    Text("Photos haute résolution indisponibles : la capture utilisera les images vidéo.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        case .locating:
            Button("Annuler") { cap.cancel() }
                .buttonStyle(.bordered)
                .tint(.white)
        case .capturing:
            HStack(spacing: 12) {
                Button("Annuler") { cap.cancel() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("Terminer") { cap.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cap.count < PhotoCaptureManager.minPhotos)
            }
        case .mouthPrep:
            VStack(spacing: 8) {
                Button("Démarrer la bouche") { cap.beginMouth() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Terminer sans bouche") { cap.skipMouth() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        case .mouth:
            HStack(spacing: 12) {
                Button("Annuler") { cap.cancel() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("Terminer") { cap.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cap.mouthCount < PhotoCaptureManager.mouthMin)
            }
        case .saving:
            ProgressView().tint(.white)
        case .done:
            VStack(spacing: 8) {
                HStack {
                    Text("Nom du dossier")
                        .font(.caption)
                        .foregroundColor(.white)
                    TextField("Nom du dossier", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                HStack(spacing: 12) {
                    Button("Partager (zip)") {
                        folderName = cap.renameFolder(to: folderName)
                        if let url = cap.zipFolder() { shareItem = ShareItem(url: url) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Nouvelle capture") { cap.cancel() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
            .onAppear { folderName = cap.folder?.lastPathComponent ?? "" }
        }
    }
}

/// Carte de couverture : 3 anneaux (dessus, face, dessous), cases placées selon leur azimut.
/// Gauche de la grille = côté droit du patient (l'opérateur, face au patient, se déplace dans le même sens).
struct CoverageGrid: View {
    let filled: [Bool]
    let current: Int?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<Coverage.rings.count, id: \.self) { r in
                HStack(spacing: 4) {
                    Text(Coverage.ringNames[r])
                        .font(.caption2)
                        .foregroundColor(.white)
                        .frame(width: 52, alignment: .leading)
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .topLeading) {
                            ForEach(cells(ring: r), id: \.self) { i in
                                let az = Coverage.bins[i].az
                                let step = Coverage.rings[r].step
                                let cw = max(4, w * CGFloat(step / 170.0) - 3)
                                let x = w * CGFloat((az + 85.0) / 170.0) - cw / 2
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(i < filled.count && filled[i] ? Color.green : Color.white.opacity(0.25))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.yellow, lineWidth: current == i ? 2 : 0)
                                    )
                                    .frame(width: cw, height: 14)
                                    .offset(x: x, y: 0)
                            }
                        }
                    }
                    .frame(height: 14)
                }
            }
            HStack {
                Text("côté droit du patient")
                Spacer()
                Text("côté gauche")
            }
            .font(.caption2)
            .foregroundColor(.white.opacity(0.8))
            .padding(.leading, 56)
        }
    }

    private func cells(ring r: Int) -> [Int] {
        Coverage.bins.indices.filter { Coverage.bins[$0].ring == r }
    }
}

/// Aperçu de la caméra arrière (session ARKit de suivi du monde).
struct BackCameraPreview: UIViewRepresentable {
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
