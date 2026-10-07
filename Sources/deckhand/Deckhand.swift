import ArgumentParser
import Foundation

@main
struct Deckhand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deckhand",
        abstract: "Sync Apple Music playlists to Pioneer/AlphaTheta DJ USB drives.",
        subcommands: [
            PlaylistsCommand.self, DevicesCommand.self, InitCommand.self, AnalyzeCommand.self, SyncCommand.self,
            StatusCommand.self, ValidateCommand.self, EjectCommand.self, ImportPlaylistsCommand.self, DebugCommands.self,
        ]
    )
}

/// Prints to stderr.
func warn(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func printJSON<T: Encodable>(_ value: T) throws {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    print(String(decoding: try e.encode(value), as: UTF8.self))
}
