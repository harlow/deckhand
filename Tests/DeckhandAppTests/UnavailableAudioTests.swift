@testable import DeckhandApp
import DeckhandCore
import Foundation
import Testing

@Suite struct UnavailableAudioTests {
    @Test func protectedAudioIsNotDescribedAsADisconnectedDisk() {
        let track = SourceTrack(id: "p", title: "Protected", unavailableReason: "Protected (DRM) track; no exportable local file")
        let issue = UnavailableAudioIssue(track: track)
        #expect(issue.kind == .protected)
        #expect(issue.actionTitle == "Choose Audio File…")
        #expect(UnavailableAudioIssue.summary([issue]) == "1 protected track can’t be copied to USB.")
    }

    @Test func distinguishesNoLocalFileFromUnavailableSavedPathAndMixedReasons() {
        let cloud = UnavailableAudioIssue(track: SourceTrack(id: "c", title: "Cloud"))
        let missing = UnavailableAudioIssue(track: SourceTrack(id: "m", title: "Missing", location: URL(fileURLWithPath: "/missing/song.mp3"), unavailableReason: "Audio file is missing or unreadable"))
        #expect(cloud.kind == .noLocalFile && missing.kind == .fileUnavailable)
        #expect(missing.actionTitle == "Locate File…")
        #expect(UnavailableAudioIssue.summary([cloud]) == "1 track has no local audio file.")
        #expect(UnavailableAudioIssue.summary([missing]) == "1 audio file couldn’t be found or read.")
        #expect(UnavailableAudioIssue.summary([cloud, missing]) == "2 tracks have unavailable audio.")
    }
}
