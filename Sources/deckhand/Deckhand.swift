import ArgumentParser
import Foundation

@main
struct Deckhand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deckhand",
        abstract: "Sync Apple Music playlists to Pioneer/AlphaTheta DJ USB drives.",
        subcommands: [
            PlaylistsCommand.self, DevicesCommand.self, InitCommand.self, AnalyzeCommand.self, SyncCommand.self,
            StatusCommand.self, ValidateCommand.self, EjectCommand.self, ImportPlaylistsCommand.self, CleanupCommand.self, RatingsCommand.self, DebugCommands.self,
        ]
    )

    static func main() {
        // Line-buffer stdout even when it's a pipe, so the Mac app's sync sheet shows progress as it happens.
        setvbuf(stdout, nil, _IOLBF, 0)
        main(nil)
    }
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
