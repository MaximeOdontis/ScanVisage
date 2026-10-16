import SwiftUI

@main
struct ScanVisageApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Écran de choix : photos haute définition (caméra arrière, reconstruction sur Mac)
/// ou scan TrueDepth (caméra frontale, calcul sur l'iPhone).
struct RootView: View {
    private enum Mode { case none, photo, depth }
    @State private var mode: Mode = .none
    @State private var testText: String?

    var body: some View {
        switch mode {
        case .none:
            chooser
        case .photo:
            PhotoCaptureView(onBack: { mode = .none })
        case .depth:
            ZStack(alignment: .topLeading) {
                ContentView()
                Button("Retour") { mode = .none }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
    }

    private var chooser: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Scan du visage")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                Text("Version \(AppInfo.version) \(AppInfo.name)")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                Button {
                    mode = .photo
                } label: {
                    VStack(spacing: 6) {
                        Text("Photo HD").font(.title2.bold())
                        Text("Caméra arrière, l'opérateur tourne autour du patient. Reconstruction sur Mac. Le plus précis.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                Button {
                    mode = .depth
                } label: {
                    VStack(spacing: 6) {
                        Text("TrueDepth").font(.title2.bold())
                        Text("Caméra frontale, calcul sur l'iPhone. Rapide, moins détaillé.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Button("Tester le calcul sur ce téléphone") {
                    testText = PhotogrammetryCheck.run()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .font(.footnote)
            }
            .padding(24)
        }
        .alert("Calcul sur le téléphone", isPresented: Binding(
            get: { testText != nil },
            set: { if !$0 { testText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(testText ?? "")
        }
    }

}
