import DeckhandCore
import Testing
@testable import Analysis

@Suite struct FileTagsTests {
    @Test(arguments: [
        ("8A", MusicalKey(tonic: 9, mode: .minor)),
        ("03A", MusicalKey(tonic: 10, mode: .minor)),
        ("12B", MusicalKey(tonic: 4, mode: .major)),
        ("1m", MusicalKey(tonic: 9, mode: .minor)),
        ("1d", MusicalKey(tonic: 0, mode: .major)),
        ("F#m", MusicalKey(tonic: 6, mode: .minor)),
        ("Bbmaj", MusicalKey(tonic: 10, mode: .major)),
        ("A minor", MusicalKey(tonic: 9, mode: .minor)),
        ("Amin", MusicalKey(tonic: 9, mode: .minor)),
        ("Energy", nil),
    ])
    func keys(text: String, expected: MusicalKey?) {
        #expect(FileTagReader.parseKey(text) == expected)
    }

    @Test func mixedInKeyComment() {
        #expect(FileTagReader.keyFromComment("12A - Energy 6") == MusicalKey(tonic: 1, mode: .minor))
        #expect(FileTagReader.energyFromComment("12A - Energy 6") == 6)
        #expect(FileTagReader.keyFromComment("Purchased at Beatport.com") == nil)
    }

    @Test func bpm() {
        #expect(FileTagReader.parseBPM("124") == 124)
        #expect(FileTagReader.parseBPM("123,5") == 123.5)
        #expect(FileTagReader.parseBPM("0") == nil)
    }
}
