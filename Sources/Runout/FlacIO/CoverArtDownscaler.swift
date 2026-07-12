import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CoverArtDownscaleError: Error, LocalizedError {
    case unreadableImage
    case reencodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The cover art image couldn't be read."
        case .reencodingFailed: return "The cover art image couldn't be resized for embedding."
        }
    }
}

/// A FLAC metadata block's length field is 24 bits, so a PICTURE block can never exceed
/// ~16.7 MB — but Cover Art Archive serves original scans well past that, and users can import
/// arbitrarily large files. Anything bigger must be downscaled before embedding or the exported
/// file would be corrupt (see docs/IMPROVEMENT_PLAN.md P0-2).
enum CoverArtDownscaler {
    /// Comfortably under the 0xFFFFFF block-length ceiling, leaving room for the PICTURE block's
    /// own leading fields.
    static let maxEmbeddableByteCount = 15_000_000
    /// Long-edge cap when re-encoding — far more resolution than any player renders for cover
    /// art, and a 2048px JPEG is reliably a couple of MB, nowhere near the block limit.
    static let maxPixelSize = 2048

    /// Returns `(data, fileExtension)` unchanged when the image already fits in a FLAC PICTURE
    /// block; otherwise re-encodes it as a JPEG capped at `maxPixelSize` on its long edge.
    static func ensureEmbeddable(_ data: Data, fileExtension: String) throws -> (data: Data, fileExtension: String) {
        guard data.count > maxEmbeddableByteCount else { return (data, fileExtension) }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else {
            throw CoverArtDownscaleError.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CoverArtDownscaleError.reencodingFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.count > 0 else {
            throw CoverArtDownscaleError.reencodingFailed
        }
        guard output.count <= maxEmbeddableByteCount else {
            // Unreachable for a 2048px JPEG in practice — backstop so a pathological image can
            // never smuggle an oversized block through to the writer.
            throw CoverArtDownscaleError.reencodingFailed
        }
        return (output as Data, "jpg")
    }

    /// Pixel dimensions of encoded image data, without fully decoding it.
    static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
