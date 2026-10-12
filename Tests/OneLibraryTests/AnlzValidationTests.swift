import Foundation
import Testing
import DeckhandCore
@testable import OneLibrary

@Suite struct AnlzValidationTests {
    private let audioPath = "/Contents/Deckhand/音楽.mp3"

    private func fixture(payloadSize: Int = 64, includePath: Bool = true) -> Data {
        var w = BinaryWriter()
        w.ascii("PMAI"); w.u32(28); w.u32(0); w.zeros(16)
        w.ascii("PWAV"); w.u32(12); w.u32(UInt32(12 + payloadSize)); w.zeros(payloadSize)
        if includePath {
            let pathLength = (audioPath.utf16.count + 1) * 2
            w.ascii("PPTH"); w.u32(16); w.u32(UInt32(16 + pathLength)); w.u32(UInt32(pathLength))
            w.utf16BE(audioPath); w.u16(0)
        }
        w.ascii("PWV5"); w.u32(12); w.u32(UInt32(12 + payloadSize)); w.zeros(payloadSize)
        w.patchU32(at: 8, UInt32(w.data.count))
        return w.data
    }

    private func withFile(_ data: Data, check: (URL) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("anlz-validation-\(UUID()).DAT")
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        try check(path)
    }

    @Test func skipsLargeWaveformsButChecksEverySectionAndThePath() throws {
        let data = fixture(payloadSize: 4 * 1024 * 1024)
        var bytesRead = 0
        let issue = OneLibraryValidator.checkAnlz(length: data.count, expectedPath: audioPath) { offset, count in
            bytesRead += count
            return data.subdata(in: offset..<(offset + count))
        }
        #expect(issue == nil)
        #expect(bytesRead < 256, "Validation must not read the 8 MB waveform payload")
        try withFile(data) { file in
            let fileIssue = try OneLibraryValidator.checkAnlz(file, expectedPath: audioPath)
            let after = try Data(contentsOf: file)
            #expect(fileIssue == nil)
            #expect(after == data) // Read-only validation.
        }
    }

    @Test func fileAndMemoryValidationRejectTheSameMalformedFiles() throws {
        let good = fixture()
        let pathOffset = 28 + 12 + 64
        func patched(_ offset: Int, _ value: UInt32) -> Data {
            var w = BinaryWriter()
            w.bytes(good)
            w.patchU32(at: offset, value)
            return w.data
        }
        var wrongMagic = good; wrongMagic[0] = 0
        var noTerminator = good; noTerminator[pathOffset + 16 + (audioPath.utf16.count + 1) * 2 - 1] = 1
        var trailingHeader = BinaryWriter()
        trailingHeader.bytes(good); trailingHeader.ascii("PWAV")
        trailingHeader.patchU32(at: 8, UInt32(trailingHeader.data.count))
        let cases = [
            Data(good.prefix(8)), wrongMagic, patched(8, 0), patched(4, 4),
            patched(4, UInt32(good.count + 1)), patched(36, 11), patched(36, UInt32.max),
            patched(pathOffset + 8, 12), patched(pathOffset + 12, 3),
            patched(pathOffset + 12, UInt32.max), noTerminator,
            fixture(includePath: false), trailingHeader.data,
        ]
        for data in cases {
            let memoryIssue = OneLibraryValidator.checkAnlz(data, expectedPath: audioPath)
            #expect(memoryIssue != nil)
            try withFile(data) { file in
                let fileIssue = try OneLibraryValidator.checkAnlz(file, expectedPath: audioPath)
                #expect(fileIssue == memoryIssue)
            }
        }
        try withFile(good) { file in
            let wrongPath = "/Contents/different.mp3"
            let fileIssue = try OneLibraryValidator.checkAnlz(file, expectedPath: wrongPath)
            #expect(fileIssue == OneLibraryValidator.checkAnlz(good, expectedPath: wrongPath))
            #expect(fileIssue != nil)
        }
    }

    @Test func trustedUnchangedAnalysisStillRequiresFilesAndValidReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent(String(audioPath.dropFirst()))
        let directory = AnlzPath.directory(forAudioPath: audioPath)
        let anlz = root.appendingPathComponent(String(directory.dropFirst()))
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: anlz, withIntermediateDirectories: true)
        try Data([0]).write(to: audio)
        for ext in ["DAT", "EXT", "2EX"] { try fixture().write(to: anlz.appendingPathComponent("ANLZ0000." + ext)) }
        let track = ExportTrack(contentId: 1, title: "Test", durationSeconds: 180,
                                usbPath: audioPath, fileSize: 1, fileType: .mp3,
                                bitrateKbps: 320, sampleRate: 44100,
                                analysisPath: directory + "/ANLZ0000.DAT")
        let database = root.appendingPathComponent("exportLibrary.db")
        try OneLibraryDatabase.write(.init(tracks: [track], playlists: []), to: database)
        #expect(try OneLibraryValidator.validate(database: database, volumeRoot: root).isEmpty)
        try Data([0]).write(to: anlz.appendingPathComponent("ANLZ0000.DAT"))
        #expect(try !OneLibraryValidator.validate(database: database, volumeRoot: root).isEmpty)
        #expect(try OneLibraryValidator.validate(database: database, volumeRoot: root, analysisDirectoriesToInspect: []).isEmpty)
        #expect(try !OneLibraryValidator.validate(database: database, volumeRoot: root,
                                                analysisDirectoriesToInspect: [directory]).isEmpty)
        try FileManager.default.removeItem(at: anlz.appendingPathComponent("ANLZ0000.EXT"))
        let missing = try OneLibraryValidator.validate(database: database, volumeRoot: root, analysisDirectoriesToInspect: [])
        #expect(missing.contains { $0.hasPrefix("Missing EXT analysis") })
        try FileManager.default.removeItem(at: audio)
        let missingAudio = try OneLibraryValidator.validate(database: database, volumeRoot: root, analysisDirectoriesToInspect: [])
        #expect(missingAudio.contains { $0.hasPrefix("Audio file missing") })
    }
}
