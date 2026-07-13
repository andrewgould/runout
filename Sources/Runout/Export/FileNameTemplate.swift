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

    /// Well under APFS/HFS+'s 255-UTF-8-byte-per-component limit, leaving headroom for the
    /// `.flac` extension and a " (N)" collision suffix appended later (docs/IMPROVEMENT_PLAN.md
    /// P3) — a base name at the actual limit would push the final filename over it.
    static let maxFilenameBytes = 200

    /// Strips characters invalid on common filesystems, a leading "." (which would make the
    /// file hidden), and caps length, so a resolved name is always safe to write directly.
    static func sanitizeForFilesystem(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        // Filter empty components before joining so a run of invalid characters collapses to a
        // single "-" instead of leaving one per character (e.g. "///???" would otherwise become
        // "------" rather than being recognized as effectively empty).
        let collapsed = name.components(separatedBy: invalidCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        var trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        trimmed = truncated(trimmed, toMaxUTF8Bytes: maxFilenameBytes)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Truncates on a `Character` (grapheme cluster) boundary, never mid-character, so a
    /// multi-byte Unicode character at the cut point is dropped whole rather than corrupted.
    private static func truncated(_ string: String, toMaxUTF8Bytes maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var result = ""
        var byteCount = 0
        for character in string {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}
