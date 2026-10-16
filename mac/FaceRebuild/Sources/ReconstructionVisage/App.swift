import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FaceRebuildCore

@main
struct ReconstructionVisageApp: App {
    var body: some Scene {
        WindowGroup("Reconstruction visage v\(ToolVersion.current)") {
            ContentView()
                .frame(minWidth: 600, minHeight: 520)
        }
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case standard = "Standard (300 000 polygones)"
    case high = "Élevé (600 000 polygones)"
    case maximum = "Maximum (1 000 000 polygones, texture 8K)"
    case ultra = "Ultra (4 000 000 polygones, texture 16K, très long et lourd)"
    case hdMouth = "HD+Mouth (3 000 000 polygones, plein détail sur la bouche, allégé ailleurs)"
    var id: String { rawValue }
    var polygons: UInt {
        switch self {
        case .standard: return 300_000
        case .high: return 600_000
        case .maximum: return 1_000_000
        case .ultra: return 4_000_000
        case .hdMouth: return 3_000_000
        }
    }
    var highTexture: Bool { self == .ultra || self == .hdMouth }
}

@MainActor
final class Job: ObservableObject {
    enum State {
        case idle
        case running
        case done(ReconstructionResult)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var source: URL?
    @Published var progress = 0.0
    @Published var lines: [String] = []
    @Published var quality: Quality = .high
    @Published var useMask = true
    @Published var info: CaptureInfo?
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.title = "Photos de la capture"
        panel.message = "Choisir le dossier des photos transférées depuis l'iPhone, ou son fichier zip."
        panel.prompt = "Choisir"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            setSource(url)
        }
    }

    /// Résout le dossier de capture (décompresse un zip une seule fois) et lit son résumé.
    func setSource(_ url: URL) {
        guard !isRunning else { return }
        source = url
        info = nil
        state = .idle
        progress = 0
        lines = []
        Task.detached { [weak self] in
            do {
                let folder = try Reconstructor.locateCapture(url)
                let info = try Reconstructor.inspect(folder)
                await MainActor.run {
                    self?.source = folder
                    self?.info = info
                    if info.mouthPhotos >= 5 { self?.quality = .hdMouth }
                }
            } catch {
                let text = "\(error)"
                await MainActor.run { self?.state = .failed(text) }
            }
        }
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    func start() {
        guard let src = source, !isRunning else { return }
        state = .running
        progress = 0
        lines = []
        var options = ReconstructionOptions()
        options.polygons = quality.polygons
        options.highTexture = quality.highTexture
        options.hdMouth = quality == .hdMouth
        options.useMask = useMask
        let opts = options
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Reconstruction du visage")
        task = Task.detached { [weak self] in
            do {
                let result = try await Reconstructor.run(
                    input: src, options: opts,
                    log: { line in Task { @MainActor in self?.append(line) } },
                    progress: { p in Task { @MainActor in self?.progress = p } })
                await MainActor.run { self?.state = .done(result) }
            } catch {
                let cancelled = Task.isCancelled
                let text = "\(error)"
                await MainActor.run {
                    if cancelled {
                        self?.append("Annulé.")
                        self?.state = .idle
                    } else {
                        self?.state = .failed(text)
                    }
                }
            }
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    func cancel() {
        task?.cancel()
    }
}

struct ContentView: View {
    @StateObject private var job = Job()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reconstruction du visage")
                .font(.title2.bold())
            Text("Choisir le dossier des photos transférées depuis l'iPhone (ou son fichier zip), puis lancer. Le résultat est écrit dans un sous-dossier « resultat ».")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Choisir le dossier...") { job.choose() }
                    .disabled(job.isRunning)
                Text(job.source?.path ?? "Aucun dossier choisi (un dossier peut aussi être glissé dans cette fenêtre)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            if let i = job.info {
                Text("\(i.photos) photos dont \(i.mouthPhotos) de la séquence bouche, capture du \(i.date.prefix(10)), app \(i.appVersion ?? "ancienne version")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Picker("Qualité", selection: $job.quality) {
                ForEach(Quality.allCases) { q in Text(q.rawValue).tag(q) }
            }
            .disabled(job.isRunning)
            Toggle("Utiliser les masques de la tête calculés sur l'iPhone (recommandé)", isOn: $job.useMask)
                .disabled(job.isRunning)

            HStack {
                Button("Lancer la reconstruction") { job.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(job.source == nil || job.isRunning)
                if job.isRunning {
                    Button("Annuler") { job.cancel() }
                }
            }

            if job.isRunning {
                ProgressView(value: job.progress)
                Text("\(Int(job.progress * 100)) %")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            resultView

            LogView(lines: job.lines)
        }
        .padding(20)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in job.setSource(url) }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch job.state {
        case .done(let r):
            VStack(alignment: .leading, spacing: 8) {
                Text("Terminé")
                    .font(.headline)
                Text(String(format: "%d photos, %d poses retrouvées, facteur d'échelle %.4f, écart des caméras %.1f mm, %d triangles.",
                            r.photos, r.posesFound, r.scaleFactor, r.cameraDeviationMm, r.triangles))
                    .font(.callout)
                if r.hdMouthApplied {
                    Text("HD+Mouth appliqué : visage_HD_bouche.stl (bouche en pleine densité) et bouche_HD.stl (zone bouche seule), même repère.")
                        .font(.callout)
                }
                if r.cameraDeviationMm > 10 {
                    Text("Écart des caméras supérieur à 10 mm : le patient a peut-être bougé ou le suivi a dérivé. Vérifier le résultat avant tout usage.")
                        .font(.callout)
                        .foregroundColor(.orange)
                }
                HStack {
                    Button("Ouvrir le dossier du résultat") {
                        NSWorkspace.shared.open(r.outputFolder)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Afficher \(r.mainSTLName)") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [r.outputFolder.appendingPathComponent(r.mainSTLName)])
                    }
                }
            }
        case .failed(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("Échec")
                    .font(.headline)
                    .foregroundColor(.red)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        default:
            EmptyView()
        }
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bas")
                }
                .padding(8)
            }
            .background(Color.black.opacity(0.06))
            .cornerRadius(6)
            .onChange(of: lines.count) { _, _ in
                proxy.scrollTo("bas", anchor: .bottom)
            }
        }
    }
}
