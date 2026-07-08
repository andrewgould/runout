import Foundation

enum FlacMetadataError: Error, LocalizedError {
    case notAFlacFile
    case truncatedFile

    var errorDescription: String? {
        switch self {
        case .notAFlacFile: return "Not a valid FLAC file (missing \"fLaC\" marker)."
        case .truncatedFile: return "FLAC file is truncated or corrupt."
        }
    }
}

/// Injects `VORBIS_COMMENT` (tags) and `PICTURE` (cover art) metadata blocks into a FLAC file
/// already written by `AVAudioFile`, which itself only writes `STREAMINFO` (plus, as discovered
/// during M2's real-hardware testing, its own minimal auto-generated `VORBIS_COMMENT` — see the
/// correction note in docs/FLAC_METADATA_SPEC.md). Exact byte-level format implemented here is
/// specified in that document.
enum FlacMetadataWriter {
    struct Tags {
        var title: String
        var artist: String
        var album: String
        var albumArtist: String
        var trackNumber: Int
        var discNumber: Int
        var date: String?
        var genre: String?
        var comment: String?
    }

    struct Picture {
        var mimeType: String
        var data: Data
        var width: Int
        var height: Int
        var colorDepth: Int = 24
    }

    /// Rewrites the FLAC file at `url` in place (via a temp file + atomic replace) to carry
    /// `tags` and, if provided, `picture`.
    static func write(tags: Tags, picture: Picture?, to url: URL) throws {
        let sourceData = try Data(contentsOf: url)
        let (audioFramesOffset, streamInfo) = try parseStreamInfoAndFindAudioOffset(in: sourceData)

        var output = Data()
        output.append(contentsOf: Array("fLaC".utf8))

        let vorbisCommentData = makeVorbisCommentBlockData(tags: tags)
        let pictureData = picture.map(makePictureBlockData)

        // STREAMINFO is never the last block here, since our new blocks always follow it.
        output.append(metadataBlockHeader(type: 0, isLast: false, length: streamInfo.count))
        output.append(streamInfo)

        let isVorbisCommentLast = (pictureData == nil)
        output.append(metadataBlockHeader(type: 4, isLast: isVorbisCommentLast, length: vorbisCommentData.count))
        output.append(vorbisCommentData)

        if let pictureData {
            output.append(metadataBlockHeader(type: 6, isLast: true, length: pictureData.count))
            output.append(pictureData)
        }

        output.append(sourceData[audioFramesOffset...])

        let tempURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try output.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    // MARK: - Parsing existing blocks

    /// Walks every existing metadata block, returning `STREAMINFO`'s raw data (header stripped,
    /// unchanged) and the byte offset where audio frames begin. Any other existing block —
    /// including a `VORBIS_COMMENT` `AVAudioFile` may already have written — is discarded;
    /// Runout always writes its own from scratch rather than trying to merge into it.
    private static func parseStreamInfoAndFindAudioOffset(in data: Data) throws -> (audioFramesOffset: Int, streamInfo: Data) {
        let magic = Array("fLaC".utf8)
        guard data.count >= magic.count, data[data.startIndex..<data.startIndex + magic.count].elementsEqual(magic) else {
            throw FlacMetadataError.notAFlacFile
        }

        var offset = data.startIndex + magic.count
        var streamInfo: Data?

        while true {
            guard offset + 4 <= data.endIndex else { throw FlacMetadataError.truncatedFile }
            let headerByte = data[offset]
            let isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let blockDataStart = offset + 4
            guard blockDataStart + length <= data.endIndex else { throw FlacMetadataError.truncatedFile }

            if blockType == 0 {
                streamInfo = data.subdata(in: blockDataStart..<blockDataStart + length)
            }

            offset = blockDataStart + length
            if isLast { break }
        }

        guard let streamInfo else { throw FlacMetadataError.truncatedFile }
        return (offset, streamInfo)
    }

    // MARK: - Building new blocks

    private static func metadataBlockHeader(type: UInt8, isLast: Bool, length: Int) -> Data {
        var header = Data(capacity: 4)
        header.append((isLast ? UInt8(0x80) : 0) | (type & 0x7F))
        header.append(UInt8((length >> 16) & 0xFF))
        header.append(UInt8((length >> 8) & 0xFF))
        header.append(UInt8(length & 0xFF))
        return header
    }

    /// All integers inside a VORBIS_COMMENT block's *data* are little-endian — unlike every
    /// other part of the FLAC container, including this same block's own 4-byte header. This is
    /// the classic gotcha documented in docs/FLAC_METADATA_SPEC.md; get it backwards and most
    /// players silently fail to read the tags.
    private static func makeVorbisCommentBlockData(tags: Tags) -> Data {
        var data = Data()
        let vendor = "Runout"
        appendUInt32LE(UInt32(vendor.utf8.count), to: &data)
        data.append(contentsOf: Array(vendor.utf8))

        var comments: [String] = [
            "TITLE=\(tags.title)",
            "ARTIST=\(tags.artist)",
            "ALBUM=\(tags.album)",
            "ALBUMARTIST=\(tags.albumArtist)",
            "TRACKNUMBER=\(tags.trackNumber)",
            "DISCNUMBER=\(tags.discNumber)",
        ]
        if let date = tags.date, !date.isEmpty { comments.append("DATE=\(date)") }
        if let genre = tags.genre, !genre.isEmpty { comments.append("GENRE=\(genre)") }
        if let comment = tags.comment, !comment.isEmpty { comments.append("COMMENT=\(comment)") }

        appendUInt32LE(UInt32(comments.count), to: &data)
        for comment in comments {
            let bytes = Array(comment.utf8)
            appendUInt32LE(UInt32(bytes.count), to: &data)
            data.append(contentsOf: bytes)
        }
        return data
    }

    /// Unlike VORBIS_COMMENT, the PICTURE block's integers are big-endian, matching the rest of
    /// the container.
    private static func makePictureBlockData(_ picture: Picture) -> Data {
        var data = Data()
        appendUInt32BE(3, to: &data) // picture type 3 = "Cover (front)"
        let mimeBytes = Array(picture.mimeType.utf8)
        appendUInt32BE(UInt32(mimeBytes.count), to: &data)
        data.append(contentsOf: mimeBytes)
        appendUInt32BE(0, to: &data) // description length: none
        appendUInt32BE(UInt32(picture.width), to: &data)
        appendUInt32BE(UInt32(picture.height), to: &data)
        appendUInt32BE(UInt32(picture.colorDepth), to: &data)
        appendUInt32BE(0, to: &data) // colors used: 0 (not a palette/indexed image)
        appendUInt32BE(UInt32(picture.data.count), to: &data)
        data.append(picture.data)
        return data
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
