import Foundation

enum TrackExportStatus: Equatable {
    case queued
    case exporting
    case done(URL)
    case skipped(URL)
    case failed(String)
}

/// Coordinates a batch export behind Screen 4 (docs/UI_SPEC.md). A failed track never blocks
/// the rest of the batch — see docs/FEATURES.md §4.
@MainActor
final class ExportSession: ObservableObject {
    @Published var destinationFolder: URL
    @Published var fileNameTemplate: String = FileNameTemplate.defaultTemplate
    @Published var overwriteBehavior: OverwriteBehavior = .appendNumber
    /// Short fade-in/out at each track's start/end (docs/FEATURES.md §2) — a second line of
    /// defense against clicks at cut points, independent of zero-crossing snapping in the editor.
    @Published var fadeDurationMilliseconds: Double = 10
    /// Optional, off by default (docs/ROADMAP.md M10) — a small declick pass over the whole
    /// track, distinct from the boundary fades above.
    @Published var declickEnabled: Bool = false
    @Published private(set) var statuses: [UUID: TrackExportStatus] = [:]
    @Published private(set) var isExporting = false
    @Published private(set) var errorMessage: String?

    let recordingURL: URL
    let bitDepth: Int
    let tracks: [Track]
    let albumMetadata: AlbumMetadata
    let coverArtURL: URL?

    init(recordingURL: URL, bitDepth: Int, tracks: [Track], albumMetadata: AlbumMetadata, coverArtURL: URL?) {
        self.recordingURL = recordingURL
        self.bitDepth = bitDepth
        self.tracks = tracks
        self.albumMetadata = albumMetadata
        self.coverArtURL = coverArtURL

        let musicDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let albumFolderName = albumMetadata.albumTitle.isEmpty ? "Untitled Album" : albumMetadata.albumTitle
        self.destinationFolder = musicDirectory.appendingPathComponent("Runout", isDirectory: true).appendingPathComponent(albumFolderName, isDirectory: true)

        for track in tracks { statuses[track.id] = .queued }
    }

    func status(for track: Track) -> TrackExportStatus {
        statuses[track.id] ?? .queued
    }

    var completedCount: Int {
        statuses.values.filter {
            switch $0 {
            case .done, .skipped, .failed: return true
            case .queued, .exporting: return false
            }
        }.count
    }

    func exportAll() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't create the destination folder: \(error.localizedDescription)"
            return
        }

        for track in tracks {
            statuses[track.id] = .exporting
            let recordingURL = recordingURL
            let album = albumMetadata
            let coverArtURL = coverArtURL
            let destinationFolder = destinationFolder
            let template = fileNameTemplate
            let behavior = overwriteBehavior
            let bitDepth = bitDepth
            let fadeDurationSeconds = fadeDurationMilliseconds / 1000
            let declickEnabled = declickEnabled

            do {
                // Export is blocking file I/O — run it off the main thread so the UI (including
                // other tracks' progress) doesn't stall for the duration of one track's export.
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try ExportPipeline.exportTrack(
                        track,
                        from: recordingURL,
                        album: album,
                        coverArtURL: coverArtURL,
                        to: destinationFolder,
                        fileNameTemplate: template,
                        overwriteBehavior: behavior,
                        bitDepth: bitDepth,
                        fadeDurationSeconds: fadeDurationSeconds,
                        declickEnabled: declickEnabled
                    )
                }.value
                switch outcome {
                case .exported(let url): statuses[track.id] = .done(url)
                case .skipped(let url): statuses[track.id] = .skipped(url)
                }
            } catch {
                statuses[track.id] = .failed(error.localizedDescription)
            }
        }
    }
}
