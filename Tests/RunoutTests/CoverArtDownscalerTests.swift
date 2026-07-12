import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Runout

final class CoverArtDownscalerTests: XCTestCase {
    /// Random noise is nearly incompressible, so a large-enough noise image reliably encodes to
    /// a PNG bigger than the FLAC block limit — like a Cover Art Archive original scan.
    private func makeOversizedPNG() throws -> Data {
        let side = 3000
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in pixels.indices {
            // Cheap deterministic PRNG — reproducible test input, no global randomness.
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testSmallImagePassesThroughByteIdentical() throws {
        let small = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]) // content irrelevant when under limit
        let (data, ext) = try CoverArtDownscaler.ensureEmbeddable(small, fileExtension: "png")
        XCTAssertEqual(data, small, "images already under the limit must not be touched, let alone re-encoded")
        XCTAssertEqual(ext, "png")
    }

    func testOversizedImageIsDownscaledToEmbeddableJPEG() throws {
        let oversized = try makeOversizedPNG()
        XCTAssertGreaterThan(oversized.count, CoverArtDownscaler.maxEmbeddableByteCount, "test setup: input must exceed the limit")

        let (data, ext) = try CoverArtDownscaler.ensureEmbeddable(oversized, fileExtension: "png")

        XCTAssertLessThanOrEqual(data.count, CoverArtDownscaler.maxEmbeddableByteCount)
        XCTAssertEqual(ext, "jpg")

        let dimensions = try XCTUnwrap(CoverArtDownscaler.pixelDimensions(of: data))
        XCTAssertLessThanOrEqual(max(dimensions.width, dimensions.height), CoverArtDownscaler.maxPixelSize)
        XCTAssertGreaterThan(min(dimensions.width, dimensions.height), 0)

        // The output must itself be a decodable image, not just small.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testOversizedGarbageThrowsInsteadOfPassingThrough() {
        let garbage = Data(count: CoverArtDownscaler.maxEmbeddableByteCount + 1)
        XCTAssertThrowsError(try CoverArtDownscaler.ensureEmbeddable(garbage, fileExtension: "jpg")) { error in
            XCTAssertTrue(error is CoverArtDownscaleError)
        }
    }

    func testPixelDimensionsReadsEncodedSizeWithoutDecoding() throws {
        let oversized = try makeOversizedPNG()
        let dimensions = try XCTUnwrap(CoverArtDownscaler.pixelDimensions(of: oversized))
        XCTAssertEqual(dimensions.width, 3000)
        XCTAssertEqual(dimensions.height, 3000)
    }
}
