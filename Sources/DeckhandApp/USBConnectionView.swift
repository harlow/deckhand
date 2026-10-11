import SwiftUI

/// USB setup is occasional. It never changes the library or resets an existing drive.
struct USBConnectionView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let drive = library.activeDrive {
                Text(drive.isReading ? "Sync \(drive.volume.name)" : drive.readError != nil ? "Can’t Sync \(drive.volume.name)" : drive.manifest == nil ? "Set Up \(drive.volume.name)" : library.canAdoptDrive(drive) ? "Sync \(drive.volume.name)" : "\(drive.volume.name) uses a different library")
                    .font(.title2.weight(.semibold))
                if drive.isReading {
                    HStack { ProgressView().controlSize(.small); Text("Checking this USB…").foregroundStyle(.secondary) }
                    HStack { Spacer(); Button("Done") { library.showingUSBConnection = false }.keyboardShortcut(.cancelAction) }
                } else if let error = drive.readError {
                    Text("Couldn't read this USB. Check that it's connected and allow Deckhand access if macOS asks.")
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Done") { library.showingUSBConnection = false }.keyboardShortcut(.cancelAction)
                        Button("Try Again") { Task { await library.refreshDrive(drive.id) } }
                    }
                } else if drive.manifest == nil {
                    Text("Use this USB for your Deckhand playlists. Check playlists in the sidebar, then Sync.")
                    Text("Setup does not format the drive. Syncing replaces its Rekordbox export database; other files stay on the drive.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !drive.volume.formatIsSupported {
                        Text("This drive needs FAT32 or exFAT for DJ players. Use a compatible USB to continue.")
                            .font(.callout).foregroundStyle(Color.pending)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { library.showingUSBConnection = false }.keyboardShortcut(.cancelAction)
                        Button("Set Up USB") { library.initializeDrive(drive) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!library.sourceCanChange || drive.isReading || !drive.volume.formatIsSupported)
                    }
                } else {
                    Text("This USB was last synced from a different library.")
                    if library.canAdoptDrive(drive) {
                        Text("Its music and playlists are already here. Review the changes before syncing from your current library.")
                            .foregroundStyle(.secondary)
                        if drive.manifest?.entireLibrary == true {
                            Text("This USB is set to include All Tracks. The next sync will include all \(library.allIds.count.formatted()) tracks in Deckhand.")
                                .font(.callout).foregroundStyle(Color.pending)
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") { library.showingUSBConnection = false }.keyboardShortcut(.cancelAction)
                            Button("Sync") {
                                library.showingUSBConnection = false; library.requestSync()
                            }.buttonStyle(.borderedProminent).disabled(!library.sourceCanChange)
                        }
                    } else {
                        if let missing = library.usbLibraryMissingItems(for: drive) {
                            Text(missing).foregroundStyle(.secondary)
                        }
                        Text("Add its original music and playlists to Deckhand, then sync again.")
                            .foregroundStyle(.secondary)
                        Text("The USB hasn't been changed.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Done") { library.showingUSBConnection = false }.keyboardShortcut(.cancelAction)
                            Button("Add Music…") { library.showingUSBConnection = false; library.choosingSource = true }
                                .buttonStyle(.borderedProminent).disabled(!library.sourceCanChange)
                        }
                    }
                }
            } else {
                Text("Connect a USB drive to continue.")
                Button("Done") { library.showingUSBConnection = false }
            }
        }.padding(24).frame(width: 500)
    }
}
