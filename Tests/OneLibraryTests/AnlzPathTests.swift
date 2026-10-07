import Testing
@testable import OneLibrary

@Suite struct AnlzPathTests {
    // Reference values from directories written by Rekordbox exports.
    @Test(arguments: [
        ("/Contents/Leo Portela/Bon Vibrant - Leo Portela.flac", "/PIONEER/USBANLZ/P00E/000281CE"),
        ("/Contents/Daniela Cast/Jazzy - Daniela Cast.flac", "/PIONEER/USBANLZ/P00A/0000CC9C"),
    ])
    func matchesRekordbox(path: String, expected: String) {
        #expect(AnlzPath.directory(forAudioPath: path) == expected)
    }
}
