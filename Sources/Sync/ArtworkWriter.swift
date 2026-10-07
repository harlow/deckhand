import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders cover art into the JPEG sizes Pioneer players read.
enum ArtworkWriter {
    /// Browse-list thumbnail and the larger now-playing image.
    static let smallSize = 80
    static let mediumSize = 240

    /// USB-relative path of the small image for `imageId`; the medium one adds "_m".
    static func path(imageId: Int) -> String {
        "/PIONEER/Artwork/\(String(format: "%05d", (imageId - 1) / 1000 + 1))/b\(imageId).jpg"
    }

    static func mediumPath(forSmall path: String) -> String {
        String(path.dropLast(4)) + "_m.jpg"
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns JPEG data for a square image of `size` pixels, or nil if the input isn't a readable image.
    static func jpeg(_ data: Data, size: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
