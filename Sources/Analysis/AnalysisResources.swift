import Foundation

/// Used by release verification to fail explicitly instead of silently falling back to another detector.
public enum AnalysisRuntime {
    public static func verifyModel() throws -> URL {
        guard let url = AnalysisResources.modelURL, let model = SKey.Model.shared,
              model.predict([Array(repeating: 0, count: SKey.bins * SKey.frames)]).first?.count == 24 else {
            throw NSError(domain: "Deckhand.Analysis", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The bundled key-analysis model could not load or predict."])
        }
        return url
    }
}

/// Packaged executables must use their own resources, never a developer's build directory.
enum AnalysisResources {
    static func packagedModelURL(bundleURL: URL, executableURL: URL?) -> URL? {
        let app: URL
        if bundleURL.pathExtension == "app" {
            app = bundleURL
        } else if let directory = executableURL?.deletingLastPathComponent(),
                  directory.lastPathComponent == "MacOS",
                  directory.deletingLastPathComponent().lastPathComponent == "Contents",
                  directory.deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app" {
            app = directory.deletingLastPathComponent().deletingLastPathComponent()
        } else {
            return nil
        }
        return app.appendingPathComponent("Contents/Resources/Deckhand_Analysis.bundle/SKeyChromaNet.mlmodelc")
    }

    static var modelURL: URL? {
        if let packaged = packagedModelURL(bundleURL: Bundle.main.bundleURL,
                                           executableURL: Bundle.main.executableURL) {
            return FileManager.default.fileExists(atPath: packaged.path) ? packaged : nil
        }
        return Bundle.module.url(forResource: "SKeyChromaNet", withExtension: "mlmodelc")
    }
}
