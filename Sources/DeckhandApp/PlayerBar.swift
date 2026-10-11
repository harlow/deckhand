import DeckhandCore
import SwiftUI

struct PlayerBar: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 16) {
            nowPlaying.frame(width: 240, alignment: .leading)
            transport
            waveform
            Text("\(formatTime(player.time)) / \(formatTime(player.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            if let t = player.current {
                addToPlaylist(t)
            } else {
                Color.clear.frame(width: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 84)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            Group {
                if let art = player.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.06))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if let t = player.current {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).fontWeight(.semibold).lineLimit(1)
                    Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        KeyChip(key: t.key)
                        Text(t.bpmText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .draggable(TrackDrag.encode([t.id]))
            } else {
                Text("Nothing playing").foregroundStyle(.secondary)
            }
        }
    }

    /// Adds the playing track to a playlist; the last-used playlist comes first, and playlists that
    /// already have the track are checked and disabled.
    private func addToPlaylist(_ t: TrackRow) -> some View {
        let lists = library.playlists.filter { !$0.isFolder }
        let recent = lists.first { $0.id == library.lastPlaylistId }
        return Menu {
            if let recent { item(recent, t) }
            if recent != nil { Divider() }
            ForEach(lists.filter { $0.id != recent?.id }) { p in item(p, t) }
        } label: {
            Image(systemName: "text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add to Playlist")
    }

    @ViewBuilder private func item(_ p: SourcePlaylist, _ t: TrackRow) -> some View {
        if p.trackIds.contains(t.id) {
            Label(p.name, systemImage: "checkmark").disabled(true)
        } else {
            Button(p.name) { Task { await library.add([t.id], to: p) } }
        }
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                .help("Previous")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white))
                    .foregroundStyle(.black)
            }
            .help(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                .help("Next")
                .disabled(player.queue.isEmpty)
        }
        .buttonStyle(.plain)
        .font(.body)
    }

    private var waveform: some View { PlayerWaveform(player: player) }
}

/// The playing track's waveform with hot-cue flags (click to jump) and the section strip below.
struct PlayerWaveform: View {
    var player: Player
    var waveHeight: CGFloat = 44
    var phraseHeight: CGFloat = 12
    var keyboardCueLimit = 5

    var body: some View {
        if let d = player.detail {
            VStack(spacing: 3) {
                ZStack(alignment: .topLeading) {
                    WaveformView(overview: d.overview, progress: player.progress, showCues: false)
                        .onClickPosition { player.seek(to: $0) }
                    GeometryReader { geo in
                        ForEach(d.hotCues, id: \.letter) { c in
                            Button { player.seek(to: c.position) } label: {
                                Text(c.letter)
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .frame(width: 14, height: 14)
                                    .background(Color(rgb: c.rgb), in: RoundedRectangle(cornerRadius: 3))
                            }
                            .buttonStyle(.plain)
                            .help("\(c.letter) · \(c.name)" + (c.slot <= keyboardCueLimit ? " · key \(c.slot)" : ""))
                            .offset(x: c.position * geo.size.width - 7, y: -6)
                        }
                    }
                }
                .frame(height: waveHeight)
                GeometryReader { geo in
                    ForEach(Array(d.phrases.enumerated()), id: \.offset) { _, p in
                        Text(p.kind.rawValue.capitalized)
                            .font(.system(size: phraseHeight > 14 ? 11 : 8, weight: .bold))
                            .foregroundStyle(.black.opacity(0.8))
                            .lineLimit(1)
                            .padding(.leading, 3)
                            .frame(width: max(0, (p.end - p.start) * geo.size.width - 1), height: phraseHeight, alignment: .leading)
                            .background(Color.phrase(p.kind))
                            .offset(x: p.start * geo.size.width)
                    }
                }
                .frame(height: phraseHeight)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04))
                if player.current != nil {
                    Text("No analysis for this track").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: waveHeight + phraseHeight + 3)
            .frame(maxWidth: .infinity)
            .onClickPosition { player.seek(to: $0) }
        }
    }
}
