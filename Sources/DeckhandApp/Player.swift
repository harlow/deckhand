import AppKit
import Analysis
import AVFoundation
import DeckhandCore
import Observation
import Sync

/// Full-detail view of the playing track: a finer waveform, song structure and named hot cues.
struct PlayerDetail: Equatable, Sendable {
    struct Phrase: Equatable, Sendable {
        var kind: StructureAnalyzer.Kind
        var start: Double
        var end: Double
        /// Loudness relative to the track's loudest section, 0–1.
        var energy: Double
    }

    struct HotCue: Equatable, Sendable {
        /// Pad number, 1 = A … 8 = H.
        var slot: Int
        var letter: String
        var name: String
        var position: Double
        var rgb: [UInt8]
    }

    var overview: Overview
    var phrases: [Phrase]
    var hotCues: [HotCue]
    /// Beat times in seconds, for beat jumps.
    var beats: [Double]
}

@MainActor @Observable
final class Player: NSObject, AVAudioPlayerDelegate {
    var cache: AnalysisCache?
    var queue: [TrackRow] = []
    private(set) var current: TrackRow?
    private(set) var detail: PlayerDetail?
    private(set) var artwork: NSImage?
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?

    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    /// Tracks played before the current one, oldest first (what ⌘← goes back through).
    private(set) var history: [TrackRow] = []

    var progress: Double { duration > 0 ? time / duration : 0 }

    enum StartPoint {
        /// Hot cue A, where a DJ would start the track.
        case mixIn
        /// Just before the first drop: the build, then the drop landing.
        case preview
    }

    /// Where to jump once a newly started track's analysis has loaded.
    @ObservationIgnored private var pendingStart: StartPoint?

    func play(from point: StartPoint, _ row: TrackRow, artwork provider: (any ArtworkProvider)? = nil) {
        if current?.id == row.id, detail != nil {
            play(row, artwork: provider)
            jump(to: point)
            return
        }
        pendingStart = point
        play(row, artwork: provider)
    }

    private func jump(to point: StartPoint) {
        switch point {
        case .mixIn: if !jumpToHotCue(1) { seek(to: 0) }
        case .preview: seek(seconds: previewStart)
        }
    }

    /// 16 beats before the first drop; without one, before the loudest section; without analysis,
    /// a third of the way in.
    var previewStart: Double {
        guard let d = detail, duration > 0,
              let target = d.phrases.first(where: { $0.kind == .drop }) ?? d.phrases.max(by: { $0.energy < $1.energy })
        else { return duration / 3 }
        let start = target.start * duration
        if d.beats.count > 1, let i = d.beats.lastIndex(where: { $0 <= start + 0.05 }) {
            return d.beats[max(0, i - 16)]
        }
        return max(0, start - 30)
    }

    func seek(seconds: Double) {
        guard duration > 0 else { return }
        seek(to: seconds / duration)
    }

    /// Seek within the playing song without changing its play/pause state.
    func jumpToPreview() { seek(seconds: previewStart) }

    /// Moves `n` beats (negative = back) along the beat grid, or by tempo when there's no grid.
    func jumpBeats(_ n: Int) {
        guard current != nil else { return }
        if let beats = detail?.beats, beats.count > 1 {
            let i = beats.lastIndex { $0 <= time + 0.05 } ?? 0
            seek(seconds: beats[max(0, min(beats.count - 1, i + n))])
        } else if let bpm = current?.bpm, bpm > 0 {
            seek(seconds: time + Double(n) * 60 / bpm)
        }
    }

    /// Jumps to hot cue `slot` (1 = A … 8 = H). Returns false when the track has no such cue.
    @discardableResult
    func jumpToHotCue(_ slot: Int) -> Bool {
        guard let cue = detail?.hotCues.first(where: { $0.slot == slot }) else { return false }
        seek(to: cue.position)
        return true
    }

    /// Next or previous section start (Intro, Build, Drop…). Going back from just after a start
    /// skips to the one before, so repeated presses keep moving.
    func jumpSection(_ direction: Int) {
        guard let d = detail, duration > 0 else { return }
        let starts = d.phrases.map { $0.start * duration }
        if direction > 0 {
            if let s = starts.first(where: { $0 > time + 0.25 }) { seek(seconds: s) }
        } else {
            seek(seconds: starts.last { $0 < time - 1 } ?? 0)
        }
    }

    /// Plays `row` from `fraction` of the way in (0 = start).
    func play(_ row: TrackRow, at fraction: Double = 0, artwork provider: (any ArtworkProvider)? = nil) {
        if current?.id == row.id, let audio {
            seek(to: fraction)
            if !audio.isPlaying { resume() }
            return
        }
        do {
            let a = try AVAudioPlayer(contentsOf: row.location)
            a.delegate = self
            a.prepareToPlay()
            a.currentTime = max(0, min(1, fraction)) * a.duration
            audio?.stop()
            audio = a
            if let current { history.append(current) }
            current = row
            duration = a.duration
            time = a.currentTime
            error = nil
            resume()
            Log.info("player", "Playing \(row.title)")
            loadDetail(for: row, artwork: provider)
        } catch {
            self.error = "Can't play \(row.title): \(error.localizedDescription)"
            Log.error("player", self.error!)
        }
    }

    func toggle() {
        guard let audio else {
            if let first = queue.first { queue.removeFirst(); play(first) }
            return
        }
        audio.isPlaying ? pause() : resume()
    }

    func seek(to fraction: Double) {
        guard let audio else { return }
        audio.currentTime = max(0, min(1, fraction)) * audio.duration
        time = audio.currentTime
    }

    func next() {
        guard !queue.isEmpty else { stop(); return }
        play(queue.removeFirst())
    }

    func previous() {
        if time > 3 || history.isEmpty { seek(to: 0); return }
        let prev = history.removeLast()
        if let current { queue.insert(current, at: 0) }
        current = nil   // so play() doesn't push it back onto history
        play(prev)
    }

    func enqueue(_ rows: [TrackRow], next: Bool = false) {
        let fresh = rows.filter { r in r.id != current?.id && !queue.contains { $0.id == r.id } }
        if next { queue.insert(contentsOf: fresh, at: 0) } else { queue += fresh }
    }

    func remove(at offsets: IndexSet) { queue.remove(atOffsets: offsets) }
    func move(from: IndexSet, to: Int) { queue.move(fromOffsets: from, toOffset: to) }

    private func resume() {
        audio?.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        audio?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    private func stop() {
        pause()
        audio = nil
        time = 0
    }

    func reset() {
        stop()
        current = nil
        detail = nil
        artwork = nil
        queue = []
        history = []
        duration = 0
        pendingStart = nil
        error = nil
    }

    private func tick() {
        guard let audio else { return }
        time = audio.currentTime
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.next() }
    }

    private func loadDetail(for row: TrackRow, artwork provider: (any ArtworkProvider)?) {
        detail = nil
        artwork = nil
        let cache = cache, hash = row.hash, id = row.id
        Task.detached {
            let image = provider?.artwork(forTrackId: id).flatMap(NSImage.init(data:))
            let detail = hash.flatMap { h in cache.flatMap { Self.detail(hash: h, cache: $0) } }
            await MainActor.run {
                guard self.current?.id == id else { return }
                self.detail = detail
                self.artwork = image
                if let point = self.pendingStart {
                    self.pendingStart = nil
                    if detail != nil { self.jump(to: point) } else if point == .preview { self.seek(to: 1.0 / 3) }
                }
            }
        }
    }

    nonisolated private static func detail(hash: String, cache: AnalysisCache) -> PlayerDetail? {
        guard let a = cache.analysis(forHash: hash) else { return nil }
        let ms = a.durationSeconds * 1000
        let sections = cache.sections(forHash: hash) ?? []
        let detected = cache.detectedCues(forHash: hash)
        let hot = CueAnalyzer.namedHotCues(sections: sections, analysis: a)
        let letters = Array("ABCDEFGH")
        return PlayerDetail(
            overview: Overview(a.waveforms, bins: 600, cuesMs: detected?.cues.map(\.timeMs) ?? [], durationMs: ms),
            phrases: sections.map { .init(kind: $0.kind, start: Double($0.startMs) / ms, end: Double($0.endMs) / ms, energy: $0.energy) },
            hotCues: hot.map { .init(slot: $0.slot, letter: String(letters[($0.slot - 1) % 8]), name: $0.name, position: Double($0.timeMs) / ms, rgb: $0.rgb) },
            beats: a.beats.map { Double($0.timeMs) / 1000 }
        )
    }
}
