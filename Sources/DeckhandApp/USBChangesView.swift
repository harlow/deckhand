import SwiftUI

/// A read-only preview uses the same sync evaluator as the track and playlist indicators.
struct USBChangesView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let drive = library.activeDrive, library.canPreviewDrive(drive) {
                let needsAssociation = !library.driveMatchesSource(drive)
                Text(needsAssociation ? "Link \(drive.volume.name) to this library?" : "Sync to \(drive.volume.name)")
                    .font(.title2.weight(.semibold))
                if needsAssociation {
                    Text("This USB was last synced from an earlier Deckhand library. Deckhand will verify its music, link it to this library, and sync your selected playlists.")
                        .foregroundStyle(.secondary)
                    Text("This library will be used for future syncs to this USB.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(library.selectedUSBPlaylists.count) \(library.selectedUSBPlaylists.count == 1 ? "playlist" : "playlists") selected").font(.headline)
                    if library.entireLibraryOnDrive {
                        Text("All Tracks is also selected: every track in Deckhand will be included.")
                            .font(.callout).foregroundStyle(Color.pending)
                    }
                    if !library.selectedUSBPlaylists.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(library.selectedUSBPlaylists) { p in
                                    Label(p.name, systemImage: "checkmark.square.fill")
                                        .font(.callout).lineLimit(1).help(p.name)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: min(120, CGFloat(library.selectedUSBPlaylists.count) * 26))
                    } else if !library.entireLibraryOnDrive {
                        Text(library.wouldClearUSB ? "Syncing will remove all Deckhand playlists and audio from this USB. Your Deckhand library stays saved on this computer." : "Check playlists in the sidebar to include them.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Divider()
                if let status = library.driveStatus {
                    if needsAssociation && status.complete && status.pendingCount == 0 && status.summary.unknown == 0 {
                        Text("No music or playlist changes.").font(.headline)
                        Text("Link once to use this library for future syncs to this USB.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Next sync: \(status.pendingCount.formatted()) \(status.pendingCount == 1 ? "change" : "changes")").font(.headline)
                    }
                    if status.summary.unknown > 0 {
                        Text("Sync checks \(status.summary.unknown) tracks before copying. Their changes aren't counted yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !status.details.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(status.details.enumerated()), id: \.offset) { _, detail in
                                    Text(detail).font(.callout)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: min(200, CGFloat(status.details.count) * 44))
                    }
                } else { ProgressView().controlSize(.small) }
                if let error = library.usbAssociationError {
                    Text(error).font(.callout).foregroundStyle(Color.pending)
                }
                HStack {
                    if library.associatingUSB { ProgressView().controlSize(.small); Text("Checking music…").font(.caption) }
                    Spacer()
                    Button("Done") { library.showingUSBChanges = false }.keyboardShortcut(.cancelAction)
                    if needsAssociation {
                        let linkOnly = library.driveStatus.map { $0.complete && $0.pendingCount == 0 && $0.summary.unknown == 0 } == true
                        Button(linkOnly ? "Link library" : "Link and Sync") {
                            Task {
                                await library.syncWithCurrentLibrary(drive)
                            }
                        }.buttonStyle(.borderedProminent).disabled(!library.sourceCanChange)
                    } else {
                        Button(library.wouldClearUSB ? "Remove from USB" : "Sync", role: library.wouldClearUSB ? .destructive : nil) {
                            library.showingUSBChanges = false; library.sync(drive)
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(!library.sourceCanChange || !drive.canSync || library.pendingWontFit)
                    }
                }
            } else {
                Text("This USB is no longer available for this library.").font(.headline)
                Button("Done") { library.showingUSBChanges = false }
            }
        }.padding(24).frame(width: 540)
    }
}
