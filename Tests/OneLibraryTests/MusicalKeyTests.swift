import DeckhandCore
import Testing

@Suite struct MusicalKeyTests {
    @Test(arguments: [
        (9, MusicalKey.Mode.minor, "Am", "8A"),
        (0, .major, "C", "8B"),
        (4, .minor, "Em", "9A"),
        (7, .major, "G", "9B"),
        (6, .minor, "F#m", "11A"),
        (11, .minor, "Bm", "10A"),
        (1, .minor, "C#m", "12A"),
        (10, .major, "Bb", "6B"),
        (3, .major, "Eb", "5B"),
    ])
    func notation(tonic: Int, mode: MusicalKey.Mode, classic: String, camelot: String) {
        let key = MusicalKey(tonic: tonic, mode: mode)
        #expect(key.classic == classic)
        #expect(key.alphanumeric == camelot)
        #expect(MusicalKey(parsing: classic) == key)
        #expect(MusicalKey(parsing: camelot) == key)
    }
}
