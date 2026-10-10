import Analysis
import DeckhandCore
import OneLibrary

/// Per-drive output settings: explicit choices win, then the drive's saved values, then defaults.
public struct OutputSettings: Sendable, Equatable {
    public var keyFormat: OneLibraryDatabase.KeyFormat = .classic
    public var cues: CueMode = .both
    public var hotCues: HotCueStyle = .named
    public var buildLead = 8
    public var trackColor: TrackColorRule = .energy
    public var phrases = true

    public init() {}

    /// Keys this version reads; others (from older versions, like `cueSource`) are ignored and dropped on the next save.
    static let keys = ["keyFormat", "cues", "hotCues", "buildLead", "trackColor", "phrases"]

    public init(saved: [String: String]?, keyFormat: OneLibraryDatabase.KeyFormat? = nil, cues: CueMode? = nil,
                hotCues: HotCueStyle? = nil, buildLead: Int? = nil, trackColor: TrackColorRule? = nil, phrases: Bool? = nil) {
        let saved = saved ?? [:]
        self.keyFormat = keyFormat ?? saved["keyFormat"].flatMap(OneLibraryDatabase.KeyFormat.init(rawValue:)) ?? .classic
        self.cues = cues ?? saved["cues"].flatMap(CueMode.init(rawValue:)) ?? .both
        self.hotCues = hotCues ?? saved["hotCues"].flatMap(HotCueStyle.init(rawValue:)) ?? .named
        self.buildLead = buildLead ?? saved["buildLead"].flatMap(Int.init) ?? 8
        self.trackColor = trackColor ?? saved["trackColor"].flatMap(TrackColorRule.init(rawValue:)) ?? .energy
        self.phrases = phrases ?? saved["phrases"].map { $0 == "true" } ?? true
    }

    public var dictionary: [String: String] {
        ["keyFormat": keyFormat.rawValue, "cues": cues.rawValue, "hotCues": hotCues.rawValue,
         "buildLead": String(buildLead), "trackColor": trackColor.rawValue, "phrases": String(phrases)]
    }

    public var summary: String {
        "cues \(cues.rawValue), hot cues \(hotCues.rawValue) (build lead \(buildLead) bars), "
            + "keys \(keyFormat.rawValue), track color \(trackColor.rawValue), phrases \(phrases ? "on" : "off")"
    }
}

/// Everything about how a sync writes a drive, besides the library and selection.
public struct OutputProfile: Sendable {
    public var settings: OutputSettings
    public var anlzOptions = AnlzWriter.Options()
    /// Analyze tracks without cached analysis during the sync. When false they're synced without BPM/key and get
    /// them, with analysis files, on a later sync once analyzed.
    public var analyzeMissing = true
    /// Write cover art (needs an artwork source). When false the drive's art is left as it is.
    public var artwork = true
    /// Rewrite every track's analysis files even where they're unchanged (hidden `--rewrite-analysis`).
    public var rewriteAnalysisFiles = false

    public init(settings: OutputSettings = OutputSettings()) {
        self.settings = settings
    }

    /// Versions of everything that turns a cache entry into analysis files. Recorded in each track's `anlzInputs`, so
    /// bumping one (see docs/sync-engine.md) has every drive check its analysis files once; files are rewritten only
    /// where the result differs.
    public static let recipe = "a\(TrackAnalysis.currentVersion).c\(CueAnalyzer.version).s\(StructureAnalyzer.version)"
        + ".b\(CueBuilder.version).w\(AnlzWriter.formatVersion)"

    /// What, besides the cache entry, decides a track's analysis files.
    var anlzKey: String {
        let s = settings
        return "pqt2=\(anlzOptions.includeExtendedBeatGrid);mask=\(anlzOptions.maskPhrases);cues=\(s.cues.rawValue);"
            + "hot=\(s.hotCues.rawValue);lead=\(s.buildLead);phrases=\(s.phrases);\(Self.recipe)"
    }
}
