import AVFoundation
import FluidAudio
import Foundation

/// Runs the streaming recognizer on captured audio and turns it into caption lines.
///
/// Partial text updates the live line as words arrive. When the recognizer's text ends a sentence
/// or grows long, the sentence is committed to history and handed to the translator.
@MainActor
final class Captioner: ObservableObject {
    static let shared = Captioner()
    enum State: Equatable { case idle, loading, listening, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var live: String = ""              // sentence in progress
    @Published private(set) var history: [CaptionLine] = []    // committed sentences (newest last)
    @Published var source: AudioSource = .system
    @Published var targetLanguage: Locale.Language? = nil { didSet { UserDefaults.standard.set(targetLanguage?.minimalIdentifier, forKey: "target") } }
    @Published var translationRequest: (id: Int, text: String)? = nil
    var onCommit: ((CaptionLine) -> Void)?

    private var manager: (any StreamingAsrManager)?
    let capture = AudioCapture()
    private var pump: Task<Void, Never>?
    private var committedPrefix = ""     // text already committed from the current recognizer transcript
    private var nextID = 0
    private var lastChange = Date()

    struct CaptionLine: Identifiable, Equatable {
        let id: Int
        var text: String
        var translation: String? = nil
        let at: Date
    }

    init() {
        if let t = UserDefaults.standard.string(forKey: "target") { targetLanguage = Locale.Language(identifier: t) }
    }

    func start() async {
        guard state != .listening else { return }
        state = .loading
        fputs("[livecaptions] loading model\n", stderr)
        do {
            if manager == nil {
                let m = StreamingModelVariant.parakeetUnified1120ms.createManager()
                try await m.loadModels()
                await m.setPartialTranscriptCallback { [weak self] text in
                    fputs("[livecaptions] partial: \(text.suffix(60))\n", stderr)
                    Task { @MainActor in self?.handle(partial: text) }
                }
                manager = m
            }
            try await manager?.reset()
            committedPrefix = ""; live = ""
            var received = 0
            capture.onBuffer = { [weak self] buffer in
                guard let self, let m = self.manager else { return }
                received += 1
                if received % 100 == 1 { fputs("[livecaptions] audio buffers: \(received), frames \(buffer.frameLength) @ \(buffer.format.sampleRate) ch \(buffer.format.channelCount)\n", stderr) }
                Task { do { try await m.appendAudio(buffer) } catch { fputs("[livecaptions] append failed: \(error)\n", stderr) } }
            }
            capture.onError = { [weak self] msg in Task { @MainActor in self?.state = .failed(msg) } }
            try await capture.start(source: source)
            state = .listening
            fputs("[livecaptions] listening (\(source.rawValue))\n", stderr)
            pump = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard let self, let m = self.manager else { continue }
                    do { try await m.processBufferedAudio() } catch { fputs("[livecaptions] process failed: \(error)\n", stderr) }
                    await self.commitIfStale()
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            fputs("[livecaptions] start failed: \(error)\n", stderr)
        }
    }

    func stop() async {
        pump?.cancel(); pump = nil
        await capture.stop()
        if !live.isEmpty { commit(live) }
        live = ""
        if state == .listening { state = .idle }
    }

    func clear() { history.removeAll(); live = "" }

    // MARK: sentence logic

    private func handle(partial text: String) {
        // The recognizer returns the whole transcript so far; strip what we already committed.
        var rest = text
        if !committedPrefix.isEmpty, rest.hasPrefix(committedPrefix) { rest = String(rest.dropFirst(committedPrefix.count)) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest != live { live = rest; lastChange = Date() }
        // Commit finished sentences, keep the tail live.
        if let cut = Self.sentenceCut(in: rest) {
            let sentence = String(rest[..<cut]).trimmingCharacters(in: .whitespaces)
            let tail = String(rest[cut...]).trimmingCharacters(in: .whitespaces)
            committedPrefix = text.hasPrefix(committedPrefix) ? String(text.prefix(committedPrefix.count + rest.distance(from: rest.startIndex, to: cut) + 1)) : text
            commit(sentence)
            live = tail
        } else if rest.count > 160, let space = rest.index(rest.startIndex, offsetBy: 120, limitedBy: rest.endIndex).flatMap({ rest[$0...].firstIndex(of: " ") }) {
            let sentence = String(rest[..<space])
            committedPrefix = String(text.prefix(committedPrefix.count + (committedPrefix.isEmpty ? 0 : 1) + sentence.count + 1))
            commit(sentence)
            live = String(rest[space...]).trimmingCharacters(in: .whitespaces)
        }
    }

    private func commitIfStale() {
        // A pause of a few seconds ends the sentence even without punctuation.
        if !live.isEmpty, Date().timeIntervalSince(lastChange) > 2.5 {
            let text = live
            if let m = manager { Task { try? await m.reset() } }   // fresh transcript after a pause
            committedPrefix = ""
            live = ""
            commit(text)
        }
    }

    private func commit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        let line = CaptionLine(id: nextID, text: t, at: Date())
        nextID += 1
        history.append(line)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        if targetLanguage != nil { translationRequest = (line.id, t) }
        onCommit?(line)
    }

    func setTranslation(_ text: String, for id: Int) {
        if let i = history.firstIndex(where: { $0.id == id }) { history[i].translation = text }
    }

    /// Index just past the last sentence terminator that is followed by a space (or is at the end).
    nonisolated static func sentenceCut(in s: String) -> String.Index? {
        var last: String.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            if ".!?".contains(s[i]) {
                let next = s.index(after: i)
                if next == s.endIndex || s[next] == " " { last = next }
            }
            i = s.index(after: i)
        }
        // don't cut a lone abbreviation like "Dr." at the very start
        if let l = last, s.distance(from: s.startIndex, to: l) < 4 { return nil }
        return last
    }
}
