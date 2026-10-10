import CoreServices
import Foundation

/// Apple Events to Music sent directly (`NSAppleEventDescriptor.sendEvent`, i.e. AESendMessage): thread-safe, unlike
/// NSAppleScript, which is main-thread-only and fails or reorders when called concurrently. Sending never launches
/// Music: with Music not running every call fails with `notRunning`.
///
/// In a process without AppKit the first Apple Event sent from a background thread can hang, so the CLI calls these
/// on its main thread; the app sends every one from a single serial queue (`MusicBridge`).
public enum MusicEvents {
    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        public let status: Int32

        public init(_ status: Int32) { self.status = status }

        public static let notPermitted: Int32 = -1743   // errAEEventNotPermitted
        public static let wouldPrompt: Int32 = -1744    // errAEEventWouldRequireUserConsent
        public static let timedOut: Int32 = -1712       // errAETimeout
        public static let noSuchObject: Int32 = -1728   // errAENoSuchObject
        public static let notRunning: Int32 = -600      // procNotFound
        public static let connectionInvalid: Int32 = -609
        /// The library changed between the columns of one read (Deckhand's own code).
        public static let changedDuringRead: Int32 = 1

        public var isNotRunning: Bool { status == Self.notRunning || status == Self.connectionInvalid }

        public var description: String {
            switch status {
            case Self.notPermitted:
                "Deckhand isn't allowed to control Music (System Settings → Privacy & Security → Automation)"
            case Self.wouldPrompt: "Music access hasn't been granted yet"
            case Self.timedOut: "Music didn't answer in time"
            case Self.noSuchObject: "Music couldn't find the track"
            case Self.notRunning, Self.connectionInvalid: "Music isn't running"
            case Self.changedDuringRead: "the library changed while it was being read"
            default: "Music returned error \(status)"
            }
        }
    }

    public enum Access: Sendable, Equatable {
        case granted
        /// Automation access was refused (System Settings → Privacy & Security → Automation).
        case denied
        /// Not decided yet; asking would show the consent prompt.
        case undecided
        case notRunning
        case other(Int32)
    }

    /// Whether this process may send Music events, without sending one. With `ask`, shows the consent prompt if the
    /// user hasn't decided yet (and blocks until they answer).
    public static func access(ask: Bool) -> Access {
        var addr = AEAddressDesc()
        let created = bundleId.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &addr) }
        guard created == noErr else { return .other(Int32(created)) }
        defer { AEDisposeDesc(&addr) }
        let status = AEDeterminePermissionToAutomateTarget(&addr, code("core"), code("getd"), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(Failure.notPermitted): return .denied
        case OSStatus(Failure.wouldPrompt): return .undecided
        case OSStatus(Failure.notRunning): return .notRunning
        default: return .other(status)
        }
    }

    /// `get <property> of every file track of library playlist 1`: one value per file track, in library order.
    /// `prompt`: allow the consent prompt if access isn't decided yet.
    public static func column(_ property: String, prompt: Bool = true) throws -> NSAppleEventDescriptor {
        try send("core", "getd", direct: objSpec("prop", allFileTracks, "prop", NSAppleEventDescriptor(typeCode: code(property))),
                 prompt: prompt)
    }

    /// Sets a library track's star rating (0–5; 0 clears it). Matching nothing isn't an error here: read the rating
    /// back with `rating(trackId:)`, which throws `noSuchObject`.
    public static func setRating(_ stars: Int, trackId: String) throws {
        let spec = objSpec("prop", tracks(withId: trackId), "prop", NSAppleEventDescriptor(typeCode: code("pRte")))
        let value = NSAppleEventDescriptor(int32: Int32(max(0, min(5, stars)) * 20))
        _ = try send("core", "setd", direct: spec, params: [code("data"): value], prompt: false)
    }

    /// A library track's star rating as the user set it (0–5; computed ratings read as 0).
    public static func rating(trackId: String) throws -> Int {
        let base = tracks(withId: trackId)
        let ratings = try send("core", "getd", direct: objSpec("prop", base, "prop", NSAppleEventDescriptor(typeCode: code("pRte"))),
                               prompt: false)
        let kinds = try send("core", "getd", direct: objSpec("prop", base, "prop", NSAppleEventDescriptor(typeCode: code("pRtk"))),
                             prompt: false)
        guard let rating = MusicLive.list(ratings).first, let kind = MusicLive.list(kinds).first else {
            throw Failure(Failure.noSuchObject)
        }
        return MusicLive.stars(rating: rating, kind: kind)
    }

    // MARK: Descriptors

    static let bundleId = "com.apple.Music"

    static func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }

    static func objSpec(_ want: String, _ from: NSAppleEventDescriptor, _ form: String, _ seld: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor {
        let r = NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        r.setDescriptor(from, forKeyword: code("from"))
        r.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        r.setDescriptor(seld, forKeyword: code("seld"))
        return r.coerce(toDescriptorType: code("obj "))!
    }

    static var libraryPlaylist: NSAppleEventDescriptor {
        objSpec("cLiP", .null(), "indx", NSAppleEventDescriptor(int32: 1))
    }

    static var allFileTracks: NSAppleEventDescriptor {
        var all = code("all ")
        return objSpec("cFlT", libraryPlaylist, "indx", NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)!)
    }

    /// `every track of library playlist 1 whose persistent ID is <id>`.
    static func tracks(withId id: String) -> NSAppleEventDescriptor {
        let examined = NSAppleEventDescriptor(descriptorType: code("exmn"), data: nil)!
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(NSAppleEventDescriptor(enumCode: code("=   ")), forKeyword: code("relo"))
        comparison.setDescriptor(objSpec("prop", examined, "prop", NSAppleEventDescriptor(typeCode: code("pPIS"))), forKeyword: code("obj1"))
        comparison.setDescriptor(NSAppleEventDescriptor(string: id), forKeyword: code("obj2"))
        return objSpec("cTrk", libraryPlaylist, "test", comparison.coerce(toDescriptorType: code("cmpd"))!)
    }

    static func send(_ eventClass: String, _ eventId: String, direct: NSAppleEventDescriptor,
                     params: [FourCharCode: NSAppleEventDescriptor] = [:], prompt: Bool, timeout: TimeInterval = 30) throws
        -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: code(eventClass), eventID: code(eventId),
                                                      targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleId),
                                                      returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(direct, forKeyword: code("----"))
        for (key, value) in params { event.setParam(value, forKeyword: key) }
        // kAEDoNotPromptForUserConsent: fail with -1744 instead of showing the Automation prompt.
        let options: NSAppleEventDescriptor.SendOptions = prompt
            ? [.waitForReply, .canInteract] : [.waitForReply, .neverInteract, .init(rawValue: 0x0002_0000)]
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: options, timeout: timeout)
        } catch {
            throw Failure(Int32((error as NSError).code))
        }
        if let err = reply.paramDescriptor(forKeyword: code("errn")), err.int32Value != 0 { throw Failure(err.int32Value) }
        return reply.paramDescriptor(forKeyword: code("----")) ?? .null()
    }
}
