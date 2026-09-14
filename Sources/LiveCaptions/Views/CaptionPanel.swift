import AppKit
import Combine
import SwiftUI
import Translation

/// Floating, borderless, always-on-top panel that shows the last caption lines.
/// Draggable by its background, resizable, optionally click-through.
final class CaptionPanel: NSPanel {
    private let captioner: Captioner
    private var host: NSHostingView<CaptionOverlay>?

    init(captioner: Captioner) {
        self.captioner = captioner
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(900, screen.width * 0.7)
        let frame = CGRect(x: screen.midX - width / 2, y: screen.minY + 80, width: width, height: 150)
        super.init(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless, .resizable, .utilityWindow], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        ignoresMouseEvents = UserDefaults.standard.bool(forKey: "clickThrough")
        let view = NSHostingView(rootView: CaptionOverlay(captioner: captioner))
        contentView = view
        host = view
        setFrameAutosaveName("CaptionPanel")
    }

    func refresh() { host?.rootView = CaptionOverlay(captioner: captioner) }
}

struct CaptionOverlay: View {
    @ObservedObject var captioner: Captioner
    @AppStorage("fontSize") private var fontSize: Double = 22
    @AppStorage("showOriginal") private var showOriginal = true

    private var lines: [(String, String?)] {
        var out: [(String, String?)] = captioner.history.suffix(2).map { ($0.text, $0.translation) }
        if !captioner.live.isEmpty { out.append((captioner.live, nil)) }
        return Array(out.suffix(captioner.targetLanguage == nil ? 3 : 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if lines.isEmpty {
                Text(captioner.state == .loading ? "Loading speech model…" : captioner.state == .listening ? "Listening…" : "Captions off")
                    .font(.system(size: fontSize * 0.8)).foregroundStyle(.white.opacity(0.7))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                let isLive = i == lines.count - 1 && !captioner.live.isEmpty
                if captioner.targetLanguage == nil || showOriginal || l.1 == nil {
                    Text(l.0).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(isLive ? .white.opacity(0.85) : .white)
                }
                if let t = l.1 {
                    Text(t).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
                }
            }
        }
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: captioner.live)
    }
}

// MARK: - Translation (macOS 15+)

struct TranslationBridge: View {
    @EnvironmentObject private var captioner: Captioner
    var body: some View { if #available(macOS 15, *) { TranslationHost() } else { EmptyView() } }
}

@available(macOS 15, *)
struct TranslationHost: View {
    @EnvironmentObject private var captioner: Captioner
    @State private var config: TranslationSession.Configuration? = nil
    @State private var pending: [(Int, String)] = []

    var body: some View {
        Color.clear.frame(width: 1, height: 1).opacity(0.01)
            .onChange(of: captioner.targetLanguage) { _, target in
                config = target.map { TranslationSession.Configuration(source: Locale.Language(identifier: "en"), target: $0) }
            }
            .onChange(of: captioner.translationRequest?.id) { _, _ in
                guard let r = captioner.translationRequest else { return }
                pending.append((r.id, r.text))
                if config == nil, let t = captioner.targetLanguage { config = TranslationSession.Configuration(source: Locale.Language(identifier: "en"), target: t) } else { config?.invalidate() }
            }
            .translationTask(config) { session in
                let batch = pending; pending.removeAll()
                do {
                    try await session.prepareTranslation()   // downloads the language pack the first time
                    guard !batch.isEmpty else { return }
                    let requests = batch.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: String($0.0)) }
                    for try await r in session.translate(batch: requests) {
                        if let id = r.clientIdentifier.flatMap(Int.init) { captioner.setTranslation(r.targetText, for: id) }
                    }
                } catch {
                    fputs("[livecaptions] translation failed: \(error)\n", stderr)
                }
            }
    }
}
