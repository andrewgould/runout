import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var runoutProject: UTType {
        UTType(exportedAs: "com.andrewgould.runout.project")
    }
}

enum RunoutDocumentError: Error, LocalizedError {
    case corruptPackage
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .corruptPackage: return "This doesn't look like a valid Runout project."
        case .missingFile(let path): return "Missing expected file in project package: \(path)"
        }
    }
}

/// A `.runout` project package — see docs/DATA_MODEL.md ("Project package layout") for the exact
/// on-disk structure this reads and writes.
///
/// Audio/peak files are kept as `FileWrapper`s and only re-read/rewritten when actually replaced
/// via `ingestFile(at:asRelativePath:)`, since they can be tens to hundreds of MB — exactly what
/// `ReferenceFileDocument` (as opposed to value-type `FileDocument`) exists for.
///
/// The editing code from M1-M6 (`RecordingSession`, `EditorSession`, `MetadataSession`,
/// `ExportPipeline`) all operates on plain file URLs, unchanged. `materializedFileURL(forRelativePath:)`
/// extracts a package member to a scratch temp location on demand, and
/// `ingestFile(at:asRelativePath:)` brings a changed/new scratch file back into the package. This
/// keeps the already-hardware-verified audio code as-is, with the document format layered on top
/// rather than threaded through all of it.
final class RunoutDocument: ReferenceFileDocument {
    typealias Snapshot = Project

    static var readableContentTypes: [UTType] { [.runoutProject] }
    static var writableContentTypes: [UTType] { [.runoutProject] }

    @Published var project: Project

    /// Every package member except manifest.json, keyed by relative path (e.g. "side-a.flac").
    private var fileWrappers: [String: FileWrapper]

    /// Where this document's members get materialized to real files on demand. Unique per
    /// document instance so multiple open documents never collide.
    let workingDirectory: URL

    init() {
        let now = Date()
        project = Project(name: "New Recording", createdAt: now, modifiedAt: now)
        fileWrappers = [:]
        workingDirectory = Self.makeWorkingDirectory()
    }

    required init(configuration: ReadConfiguration) throws {
        guard let wrappers = configuration.file.fileWrappers else {
            throw RunoutDocumentError.corruptPackage
        }
        (project, fileWrappers) = try Self.parsePackage(fileWrappers: wrappers)
        workingDirectory = Self.makeWorkingDirectory()
    }

    private static func makeWorkingDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunoutWorkingCopies", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func snapshot(contentType: UTType) throws -> Project {
        project
    }

    func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        try Self.buildPackage(project: snapshot, otherFileWrappers: fileWrappers)
    }

    // MARK: - Core read/write logic
    //
    // Pulled out of the ReferenceFileDocument protocol methods above (which SwiftUI's opaque
    // ReadConfiguration/WriteConfiguration types make impossible to unit test directly) so it's
    // fully testable: construct a `[String: FileWrapper]` by hand, or round-trip through a real
    // FileWrapper written to and read back from disk.

    /// Parses a package's top-level file wrappers into a `Project` (from `manifest.json`) and
    /// every other member, keyed by relative path.
    static func parsePackage(fileWrappers wrappers: [String: FileWrapper]) throws -> (Project, [String: FileWrapper]) {
        guard let manifestWrapper = wrappers["manifest.json"], let manifestData = manifestWrapper.regularFileContents else {
            throw RunoutDocumentError.corruptPackage
        }
        let project = try JSONDecoder().decode(Project.self, from: manifestData)
        var otherWrappers = wrappers
        otherWrappers.removeValue(forKey: "manifest.json")
        return (project, otherWrappers)
    }

    /// Assembles a package directory `FileWrapper` from a `Project` (serialized to
    /// `manifest.json`) plus every other already-known member.
    static func buildPackage(project: Project, otherFileWrappers: [String: FileWrapper]) throws -> FileWrapper {
        let manifestData = try JSONEncoder().encode(project)
        let manifestWrapper = FileWrapper(regularFileWithContents: manifestData)
        manifestWrapper.preferredFilename = "manifest.json"

        var children = otherFileWrappers
        children["manifest.json"] = manifestWrapper

        return FileWrapper(directoryWithFileWrappers: children)
    }

    // MARK: - Bridging to plain file URLs for the existing (M1-M6) session objects

    /// Extracts a package member to a real file on disk, if it isn't already there, and returns
    /// that URL.
    func materializedFileURL(forRelativePath path: String) throws -> URL {
        let localURL = workingDirectory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        guard let wrapper = fileWrappers[path], let data = wrapper.regularFileContents else {
            throw RunoutDocumentError.missingFile(path)
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
        return localURL
    }

    /// Brings a scratch file (already on disk — e.g. a just-finished recording, a rebuilt peak
    /// cache, or new cover art) into the package as `path`, replacing any existing member there.
    func ingestFile(at localURL: URL, asRelativePath path: String) throws {
        let wrapper = try FileWrapper(url: localURL, options: .immediate)
        wrapper.preferredFilename = (path as NSString).lastPathComponent
        fileWrappers[path] = wrapper
    }

    /// Whether a given package-relative path currently has a member (already-materialized or not).
    func hasFile(atRelativePath path: String) -> Bool {
        fileWrappers[path] != nil
    }

    /// A scratch location under this document's working directory, for files that don't yet have
    /// a package-relative path decided (e.g. a side being recorded for the first time).
    func scratchFileURL(named name: String) -> URL {
        workingDirectory.appendingPathComponent(name)
    }
}
