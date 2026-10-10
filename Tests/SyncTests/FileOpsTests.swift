import Foundation
import Testing
@testable import Sync

@Suite struct FileOpsTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileops-\(UUID().uuidString)")

    func names(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    @Test func writeCreatesDirectoriesAndOverwrites() throws {
        let file = dir.appendingPathComponent("P001/0000ABCD/ANLZ0000.DAT")
        try FileOps.write(Data([1, 2, 3, 4]), to: file)
        try FileOps.write(Data([5]), to: file)
        #expect(try Data(contentsOf: file) == Data([5]))
        #expect(try names(file.deletingLastPathComponent()) == ["ANLZ0000.DAT"])
    }

    @Test func writeAtomicallyReplacesWithoutLeftovers() throws {
        let file = dir.appendingPathComponent("manifest.json")
        try FileOps.writeAtomically(Data("old".utf8), to: file)
        try FileOps.writeAtomically(Data("new".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        #expect(try names(dir) == ["manifest.json"])
    }

    @Test func copyDataReplacesExistingFile() throws {
        let src = dir.appendingPathComponent("src.mp3"), dst = dir.appendingPathComponent("out/dst.mp3")
        try FileOps.write(Data(repeating: 7, count: 5 << 20), to: src)
        try FileOps.write(Data([0]), to: dst)
        try FileOps.copyData(from: src, to: dst)
        #expect(try Data(contentsOf: dst) == Data(repeating: 7, count: 5 << 20))
        #expect(try names(dst.deletingLastPathComponent()) == ["dst.mp3"])
    }

    @Test func copyDataFailureLeavesNoTemporaryFile() throws {
        let dst = dir.appendingPathComponent("dst.mp3")
        #expect(throws: (any Error).self) { try FileOps.copyData(from: dir.appendingPathComponent("missing.mp3"), to: dst) }
        let left = FileManager.default.fileExists(atPath: dir.path) ? try names(dir) : []
        #expect(left.isEmpty)
    }
}
