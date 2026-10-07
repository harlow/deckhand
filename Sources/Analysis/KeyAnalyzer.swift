import CKeyFinder
import DeckhandCore
import Foundation

public enum KeyAnalyzer {
    /// Key via libKeyFinder.
    public static func analyze(_ audio: DecodedAudio) -> MusicalKey? {
        let index = audio.samples.withUnsafeBufferPointer {
            kf_key($0.baseAddress, Int32($0.count), Int32(audio.sampleRate))
        }
        guard (0..<24).contains(index) else { return nil }
        return key(fromKeyFinderIndex: Int(index))
    }

    /// libKeyFinder numbering: A major, A minor, Bb major, Bb minor, ... (major/minor alternate).
    static func key(fromKeyFinderIndex i: Int) -> MusicalKey {
        MusicalKey(tonic: 9 + i / 2, mode: i % 2 == 0 ? .major : .minor)
    }
}
