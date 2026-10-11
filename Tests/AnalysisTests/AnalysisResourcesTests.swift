import Foundation
import Testing
@testable import Analysis

@Suite struct AnalysisResourcesTests {
    @Test func appAndBundledHelperUseTheSameRelocatableModel() {
        let app = URL(fileURLWithPath: "/tmp/An Installed App/Deckhand.app")
        let expected = app.appendingPathComponent("Contents/Resources/Deckhand_Analysis.bundle/SKeyChromaNet.mlmodelc")
        #expect(AnalysisResources.packagedModelURL(bundleURL: app, executableURL: nil) == expected)
        #expect(AnalysisResources.packagedModelURL(bundleURL: app.appendingPathComponent("Contents/MacOS"),
            executableURL: app.appendingPathComponent("Contents/MacOS/deckhand")) == expected)
        #expect(AnalysisResources.packagedModelURL(bundleURL: URL(fileURLWithPath: "/tmp"),
            executableURL: URL(fileURLWithPath: "/tmp/deckhand")) == nil)
    }
}
