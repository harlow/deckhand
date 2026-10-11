import DeckhandCore
import Foundation

struct UnavailableAudioIssue: Identifiable, Equatable {
    enum Kind { case protected, noLocalFile, fileUnavailable }
    var track: SourceTrack
    var id: String { track.id }
    var kind: Kind {
        if track.unavailableReason?.contains("Protected (DRM)") == true { return .protected }
        return track.location == nil ? .noLocalFile : .fileUnavailable
    }
    var reason: String {
        switch kind {
        case .protected: "Protected Apple Music track"
        case .noLocalFile: "No local audio file"
        case .fileUnavailable: "Saved audio file is missing or unreadable"
        }
    }
    var actionTitle: String { kind == .fileUnavailable ? "Locate File…" : "Choose Audio File…" }

    static func summary(_ issues: [Self]) -> String {
        let count = issues.count.formatted()
        let tracks = issues.count == 1 ? "track" : "tracks"
        if issues.allSatisfy({ $0.kind == .protected }) { return "\(count) protected \(tracks) can’t be copied to USB." }
        if issues.allSatisfy({ $0.kind == .noLocalFile }) { return "\(count) \(tracks) \(issues.count == 1 ? "has" : "have") no local audio file." }
        if issues.allSatisfy({ $0.kind == .fileUnavailable }) { return "\(count) audio \(issues.count == 1 ? "file" : "files") couldn’t be found or read." }
        return "\(count) \(tracks) \(issues.count == 1 ? "has" : "have") unavailable audio."
    }
}
