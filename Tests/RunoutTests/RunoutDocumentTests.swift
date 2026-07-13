import AVFoundation
import SwiftUI
import XCTest
@testable import Runout

final class RunoutDocumentTests: XCTestCase {
    private func makeProject() -> Project {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let side = RecordingSide(
            label: "Side A",
            masterFileRelativePath: "side-a.flac",
            peakCacheRelativePath: "side-a.peaks",
            durationSamples: 480_000,
            createdAt: now,
            markers: [Marker(sampleOffset: 200_000), Marker(sampleOffset: 350_000)]
        )
        var project = Project(name: "Test Album", createdAt: now, modifiedAt: now)
        project.sides = [side]
        project.albumMetadata = AlbumMetadata(albumTitle: "Abbey Road", albumArtist: "The Beatles")
        return project
    }

    // MARK: - Core logic (parsePackage / buildPackage), no disk I/O

    func testBuildAndParsePackageRoundTripsProjectAndOtherFiles() throws {
        let project = makeProject()
        let audioWrapper = FileWrapper(regularFileWithContents: Data([1, 2, 3, 4]))
        let peaksWrapper = FileWrapper(regularFileWithContents: Data([5, 6, 7, 8]))
        let otherWrappers = ["side-a.flac": audioWrapper, "side-a.peaks": peaksWrapper]

        let packageWrapper = try RunoutDocument.buildPackage(project: project, otherFileWrappers: otherWrappers)
        XCTAssertTrue(packageWrapper.isDirectory)
        XCTAssertNotNil(packageWrapper.fileWrappers?["manifest.json"])

        let (parsedProject, parsedOthers) = try RunoutDocument.parsePackage(fileWrappers: packageWrapper.fileWrappers!)
        XCTAssertEqual(parsedProject, project)
        XCTAssertEqual(parsedOthers["side-a.flac"]?.regularFileContents, Data([1, 2, 3, 4]))
        XCTAssertEqual(parsedOthers["side-a.peaks"]?.regularFileContents, Data([5, 6, 7, 8]))
        XCTAssertNil(parsedOthers["manifest.json"], "manifest.json should be extracted out, not left in the 'other files' set")
    }

    func testParsePackageThrowsForMissingManifest() {
        let wrappers = ["side-a.flac": FileWrapper(regularFileWithContents: Data())]
        XCTAssertThrowsError(try RunoutDocument.parsePackage(fileWrappers: wrappers)) { error in
            XCTAssertTrue(error is RunoutDocumentError)
        }
    }

    // MARK: - Full round trip through real disk I/O (exercises FileWrapper's actual directory serialization)

    func testFullRoundTripThroughRealDiskIO() throws {
        let project = makeProject()
        let audioWrapper = FileWrapper(regularFileWithContents: Data("fake flac bytes".utf8))
        let packageWrapper = try RunoutDocument.buildPackage(project: project, otherFileWrappers: ["side-a.flac": audioWrapper])

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("runout")
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try packageWrapper.write(to: packageURL, options: [.atomic], originalContentsURL: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("side-a.flac").path))

        let readBackWrapper = try FileWrapper(url: packageURL, options: [.immediate])
        let (readProject, readOthers) = try RunoutDocument.parsePackage(fileWrappers: readBackWrapper.fileWrappers!)

        XCTAssertEqual(readProject, project)
        XCTAssertEqual(readOthers["side-a.flac"]?.regularFileContents, Data("fake flac bytes".utf8))
    }

    // MARK: - Materialize / ingest bridge (used by the M1-M6 session objects)

    func testMaterializedFileURLExtractsRealFile() throws {
        let document = RunoutDocument()
        let data = Data("hello".utf8)
        let scratch = document.scratchFileURL(named: "scratch.flac")
        try data.write(to: scratch)
        try document.ingestFile(at: scratch, asRelativePath: "side-a.flac")

        let materialized = try document.materializedFileURL(forRelativePath: "side-a.flac")
        XCTAssertEqual(try Data(contentsOf: materialized), data)
    }

    func testMaterializedFileURLThrowsForUnknownPath() {
        let document = RunoutDocument()
        XCTAssertThrowsError(try document.materializedFileURL(forRelativePath: "nope.flac")) { error in
            XCTAssertTrue(error is RunoutDocumentError)
        }
    }

    func testIngestFileMakesItAvailableForExport() throws {
        let document = RunoutDocument()
        XCTAssertFalse(document.hasFile(atRelativePath: "artwork.jpg"))

        let scratch = document.scratchFileURL(named: "art.jpg")
        try Data([0xFF, 0xD8]).write(to: scratch)
        try document.ingestFile(at: scratch, asRelativePath: "artwork.jpg")

        XCTAssertTrue(document.hasFile(atRelativePath: "artwork.jpg"))
    }

    /// Confirms the ingest/materialize bridge works with a real FLAC file (what `RecordingWriter`
    /// actually produces), not just synthetic `Data` — a real file round-trips through ingestion
    /// and back out to a materialized URL that `AVAudioFile` can still open correctly.
    func testIngestedRealAudioFileMaterializesBackToAPlayableFile() async throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            return XCTFail("Could not construct format")
        }
        let document = RunoutDocument()
        let scratchAudioURL = document.scratchFileURL(named: "recording-scratch.flac")
        let writer = RecordingWriter()
        try await writer.start(url: scratchAudioURL, sourceFormat: format, bitDepth: 24)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) else {
            return XCTFail("Could not construct buffer")
        }
        buffer.frameLength = 4800
        try await writer.append(buffer)
        await writer.stop()

        try document.ingestFile(at: scratchAudioURL, asRelativePath: "side-a.flac")

        // Note: the scratch file deliberately stays on disk. Ingested wrappers are lazy
        // (docs/IMPROVEMENT_PLAN.md P1-4) and read from their source until the document is
        // saved — the working directory outliving every ingest is part of the contract.
        let materialized = try document.materializedFileURL(forRelativePath: "side-a.flac")
        let readBack = try AVAudioFile(forReading: materialized)
        XCTAssertEqual(readBack.length, 4800)
    }

    // MARK: - Memory / lifecycle (docs/IMPROVEMENT_PLAN.md P1-4)

    private func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    /// The `.immediate` regression guard: ingesting a large recording must reference it lazily,
    /// not pin its bytes in RAM for the document's lifetime.
    func testIngestingALargeFileDoesNotHoldItsBytesInMemory() throws {
        let document = RunoutDocument()
        let scratch = document.scratchFileURL(named: "big-side.flac")
        let sizeInBytes: UInt64 = 200_000_000
        XCTAssertTrue(FileManager.default.createFile(atPath: scratch.path, contents: nil))
        let handle = try FileHandle(forWritingTo: scratch)
        try handle.truncate(atOffset: sizeInBytes)
        try handle.close()

        let before = physFootprint()
        try document.ingestFile(at: scratch, asRelativePath: "big-side.flac")
        let after = physFootprint()

        let deltaMB = Double(after - before) / 1_000_000
        XCTAssertLessThan(deltaMB, 50, "ingest must not read the file into memory (delta was \(deltaMB) MB for a 200 MB file)")
        XCTAssertTrue(document.hasFile(atRelativePath: "big-side.flac"))
    }

    /// A lazily-ingested member must still round-trip intact through a real package write.
    func testLazyIngestedFileSurvivesPackageWrite() throws {
        let document = RunoutDocument()
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let scratch = document.scratchFileURL(named: "payload.bin")
        try payload.write(to: scratch)
        try document.ingestFile(at: scratch, asRelativePath: "payload.bin")

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("runout")
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let wrapper = try RunoutDocument.buildPackage(
            project: makeProject(),
            otherFileWrappers: ["payload.bin": FileWrapper(url: scratch, options: [])]
        )
        try wrapper.write(to: packageURL, options: [.atomic], originalContentsURL: nil)

        XCTAssertEqual(try Data(contentsOf: packageURL.appendingPathComponent("payload.bin")), payload)
    }

    func testWorkingDirectoryIsRemovedWhenDocumentCloses() throws {
        var document: RunoutDocument? = RunoutDocument()
        let workingDirectory = document!.workingDirectory
        let scratch = document!.scratchFileURL(named: "leftover.tmp")
        try Data([1, 2, 3]).write(to: scratch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingDirectory.path))

        document = nil

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workingDirectory.path),
            "scratch working copies must not accumulate after the document closes"
        )
    }
}
