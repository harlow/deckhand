import Testing
@testable import DeckhandApp

@Suite struct USBProgressTests {
    @Test func countersDescribeTheirPhaseAndClampToValidProgress() {
        let copying = USBProgressState(phase: "Copying", done: 6, total: 11)
        #expect(copying.title == "Copying tracks" && copying.count == "6 of 11")
        #expect(copying.fraction == 6.0 / 11.0)
        #expect(USBProgressState(phase: "Copying", done: -1, total: 11).fraction == 0)
        #expect(USBProgressState(phase: "Analyzing", done: 12, total: 11).count == "11 of 11")
        #expect(USBProgressState(phase: "Analyzing", done: 12, total: 11).fraction == 1)
        #expect(USBProgressState(phase: "Analysis files", done: 3, total: 3).title == "Saving analysis")
    }

    @Test func finalPhasesDoNotSuggestThatTrackCompletionMeansSyncCompletion() {
        for (phase, title) in [("Writing library database", "Saving playlists"),
                               ("Committing", "Finishing USB"), ("Checking USB", "Checking USB")] {
            let progress = USBProgressState(phase: phase, done: 11, total: nil)
            #expect(progress.title == title && progress.count == nil && progress.fraction == nil)
        }
        #expect(USBProgressState(phase: "Starting…", done: 0, total: nil).title == "Preparing sync")
        #expect(USBProgressState(phase: "Removing 3 orphaned track(s)", done: 0, total: nil).title == "Removing old files")
        #expect(USBProgressState(phase: "Copying", done: 0, total: 0).fraction == nil)
    }
}
