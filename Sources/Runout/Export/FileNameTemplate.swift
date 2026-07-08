import Foundation

/// Resolves the `{trackNumber}`/`{title}`/`{artist}`/`{album}`/`{year}`/`{discNumber}` tokens
/// documented in docs/DATA_MODEL.md against a `Track` + `AlbumMetadata`, then sanitizes for the
/// filesystem. Pulled forward from M6 since M5's metadata screen needs it for the live filename
/// preview; the export pipeline (M6) reuses this unchanged.
enum FileNameTemplate {
    static let defaultTemplate = "{trackNumber} - {title}"

    static func resolve(_ template: String, track: Track, album: AlbumMetadata) -> String {
        var result = template
        for (token, value) in tokenValues(track: track, album: album) {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return sanitizeForFilesystem(result)
    }

    private static func tokenValues(track: Track, album: AlbumMetadata) -> [(String, String)] {
        [
            ("{trackNumber}", String(format: "%02d", track.trackNumber)),
            ("{title}", track.title),
            ("{artist}", track.artist ?? album.albumArtist),
            ("{album}", album.albumTitle),
            ("{year}", track.year ?? album.year ?? ""),
            ("{discNumber}", String(track.discNumber)),
        ]
    }

    /// Strips characters invalid on common filesystems (and a bare "." which would hide the
    /// file or break its extension) so a resolved name is always safe to write directly.
    static func sanitizeForFilesystem(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        // Filter empty components before joining so a run of invalid characters collapses to a
        // single "-" instead of leaving one per character (e.g. "///???" would otherwise become
        // "------" rather than being recognized as effectively empty).
        let collapsed = name.components(separatedBy: invalidCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
