import DeckhandAppCore
import Foundation
import Sync
import Testing

@Suite struct JobLineTests {
    /// The line as `deckhand sync` prints it (sorted keys, summary included).
    private func resultLine(clean: Bool, pending: Int) throws -> String {
        var summary = ChangeSet.Summary()
        summary.tracks = 12
        summary.clean = 12 - pending
        summary.pending = pending
        summary.records = pending
        summary.total = pending
        summary.drive = [.databaseChanged]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let summaryJSON = String(decoding: try encoder.encode(summary), as: UTF8.self)
        return "@result {\"analysisFailed\":0,\"analyzed\":1,\"clean\":\(clean),\"copied\":2,\"generation\":28,\"pending\":\(pending),"
            + "\"removed\":0,\"summary\":\(summaryJSON),\"tracks\":12,\"wroteDatabase\":true}"
    }

    @Test func parsesTheSyncResult() throws {
        guard case .result(let r)? = JobLine.parse(try resultLine(clean: false, pending: 1)) else {
            Issue.record("not parsed")
            return
        }
        #expect(r.generation == 28)
        #expect(!r.clean)
        #expect(r.pending == 1)
        #expect(r.copied == 2)
        #expect(r.wroteDatabase == true)
        #expect(r.summary?.records == 1)
        #expect(r.summary?.drive == [.databaseChanged])
    }

    @Test func parsesTheLiveWarning() {
        let line = #"@live {"live":false,"reason":"Music didn't answer in time","status":-1712}"#
        #expect(JobLine.parse(line) == .live(LiveWarning(live: false, status: -1712, reason: "Music didn't answer in time")))
    }

    @Test func ignoresOtherLines() throws {
        #expect(JobLine.parse("@progress\tCopying\t1\t3") == nil)
        #expect(JobLine.parse("Done. 12 tracks in 2 playlists on DECKHAND.") == nil)
        #expect(JobLine.parse("@result not json") == nil)
        #expect(JobLine.parse("  ! @result {}") == nil)
        // A minimal line from an older CLI still parses.
        #expect(JobLine.parse(#"@result {"generation":3,"clean":true,"pending":0}"#) == .result(SyncReport(generation: 3, clean: true, pending: 0)))
    }
}

extension LiveWarning {
    init(live: Bool, status: Int32, reason: String) {
        let json = #"{"live":\#(live),"status":\#(status),"reason":"\#(reason)"}"#
        self = try! JSONDecoder().decode(LiveWarning.self, from: Data(json.utf8))
    }
}
