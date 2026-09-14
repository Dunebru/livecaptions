import AppKit
import SwiftUI

struct LiveCaptionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var captioner = Captioner.shared
    @AppStorage("fontSize") private var fontSize: Double = 22
    @AppStorage("showOriginal") private var showOriginal = true
    @AppStorage("clickThrough") private var clickThrough = false

    init() {
        // `--start [system|microphone]` begins captioning on launch (used for scripted testing).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--start") {
            let arg = args.count > i + 1 ? args[i + 1] : "system"
            if arg.hasPrefix("file:") { Captioner.shared.capture.testFile = URL(fileURLWithPath: String(arg.dropFirst(5))) }
            AppDelegate.pendingStart = arg == "microphone" ? .microphone : .system
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(captioner)
        } label: {
            Image(systemName: captioner.state == .listening ? "captions.bubble.fill" : "captions.bubble")
        }
        .menuBarExtraStyle(.window)
        .onChange(of: captioner.state) { _, s in fputs("[livecaptions] state \(s)\n", stderr) }

        Window("Live Captions", id: "about") {
            AboutView().environmentObject(captioner)
        }
        .windowResizability(.contentSize)
    }
}

/// Owns the floating caption panel; the SwiftUI scene only hosts the menu bar item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    static var pendingStart: AudioSource?
    var captionPanel: CaptionPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        if let src = Self.pendingStart {
            Self.pendingStart = nil
            Task { @MainActor in
                Captioner.shared.source = src
                self.showPanel(with: Captioner.shared)
                await Captioner.shared.start()
            }
        }
    }

    func showPanel(with captioner: Captioner) {
        if captionPanel == nil { captionPanel = CaptionPanel(captioner: captioner) }
        captionPanel?.orderFrontRegardless()
    }

    func hidePanel() { captionPanel?.orderOut(nil) }
}

struct MenuContent: View {
    @EnvironmentObject private var captioner: Captioner
    @AppStorage("fontSize") private var fontSize: Double = 22
    @AppStorage("showOriginal") private var showOriginal = true
    @AppStorage("clickThrough") private var clickThrough = false
    @Environment(\.openWindow) private var openWindow

    static let languages: [(String, String?)] = [("Off", nil), ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"), ("Polish", "pl"), ("Russian", "ru"), ("Ukrainian", "uk"), ("Turkish", "tr"), ("Arabic", "ar"), ("Hindi", "hi"), ("Japanese", "ja"), ("Korean", "ko"), ("Chinese (Simplified)", "zh-Hans"), ("Chinese (Traditional)", "zh-Hant"), ("Indonesian", "id"), ("Vietnamese", "vi"), ("Thai", "th")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "captions.bubble.fill").foregroundStyle(Color.accentColor)
                Text("Live Captions").font(.headline)
                Spacer()
                statusDot
            }
            Button {
                Task {
                    if captioner.state == .listening { await captioner.stop(); AppDelegate.shared?.hidePanel() }
                    else { AppDelegate.shared?.showPanel(with: captioner); await captioner.start() }
                }
            } label: {
                Label(captioner.state == .listening ? "Stop Captions" : (captioner.state == .loading ? "Loading model…" : "Start Captions"), systemImage: captioner.state == .listening ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(captioner.state == .loading)
            if case .failed(let m) = captioner.state { Text(m).font(.caption).foregroundStyle(.red).lineLimit(3) }

            Picker("Listen to", selection: $captioner.source) { ForEach(AudioSource.allCases) { Text($0.rawValue).tag($0) } }.disabled(captioner.state == .listening)
            Picker("Translate to", selection: Binding(get: { captioner.targetLanguage?.minimalIdentifier ?? "" }, set: { code in
                captioner.targetLanguage = code.isEmpty ? nil : Locale.Language(identifier: code)
                // The translation session lives in the transcript window so macOS can show its
                // language download sheet there; open it when a language is picked.
                if !code.isEmpty { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) }
            })) {
                ForEach(Self.languages, id: \.1) { name, code in Text(name).tag(code ?? "") }
            }
            if #unavailable(macOS 15) { Text("Translation needs macOS 15.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Show original with translation", isOn: $showOriginal).disabled(captioner.targetLanguage == nil)
            HStack { Text("Text size"); Slider(value: $fontSize, in: 14...40, step: 1); Text("\(Int(fontSize))").monospacedDigit().frame(width: 26) }
            Toggle("Click through the overlay", isOn: $clickThrough)
            Divider()
            HStack {
                Button("Clear") { captioner.clear() }
                Button("Transcript…") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: clickThrough) { _, v in AppDelegate.shared?.captionPanel?.ignoresMouseEvents = v }
        .onChange(of: fontSize) { _, _ in AppDelegate.shared?.captionPanel?.refresh() }
        .onChange(of: showOriginal) { _, _ in AppDelegate.shared?.captionPanel?.refresh() }
    }

    private var statusDot: some View {
        let color: Color = switch captioner.state { case .listening: .green; case .loading: .orange; case .failed: .red; case .idle: .secondary }
        return Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Transcript window: everything captioned this session, copyable.
struct AboutView: View {
    @EnvironmentObject private var captioner: Captioner
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(captioner.history.map { line in line.translation.map { "\(line.text)\n\($0)" } ?? line.text }.joined(separator: "\n\n"), forType: .string)
                }
            }
            if captioner.history.isEmpty {
                Text("Start captions from the menu bar icon. Everything heard shows up here.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(captioner.history) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.text).textSelection(.enabled)
                            if let t = line.translation { Text(t).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        .id(line.id)
                    }
                    .onChange(of: captioner.history.count) { _, _ in if let l = captioner.history.last { proxy.scrollTo(l.id) } }
                }
            }
        }
        .padding(14)
        .frame(width: 520, height: 420)
        .background(TranslationBridge().environmentObject(captioner))
    }
}
