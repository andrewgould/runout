import Foundation

enum FlacMetadataError: Error, LocalizedError {
    case notAFlacFile
    case truncatedFile
    case metadataBlockTooLarge(byteCount: Int)

    var errorDescription: String? {
        switch self {
        case .notAFlacFile: return "Not a valid FLAC file (missing \"fLaC\" marker)."
        case .truncatedFile: return "FLAC file is truncated or corrupt."
        case .metadataBlockTooLarge(let byteCount):
            return "A metadata block (\(byteCount) bytes) exceeds FLAC's 16 MB block limit — cover art this large must be downscaled before embedding."
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

    /// How much audio data to move per read/write while splicing — bounds memory regardless of
    /// track length (docs/IMPROVEMENT_PLAN.md P1-2).
    private static let copyChunkSizeInBytes = 4 << 20

    /// Rewrites the FLAC file at `url` in place (via a temp file + atomic replace) to carry
    /// `tags` and, if provided, `picture`. Only the metadata region is ever held in memory; the
    /// audio frames are streamed through a bounded buffer, so a full-side track costs the same
    /// memory as a jingle.
    static func write(tags: Tags, picture: Picture?, to url: URL) throws {
        let (audioFramesOffset, streamInfo) = try parseStreamInfoAndFindAudioOffset(at: url)

        // Assemble (and bounds-check) the entire new metadata region before creating any file,
        // so a failed write can never leave a stray temp file or touch the original.
        var header = Data()
        header.append(contentsOf: Array("fLaC".utf8))

        let vorbisCommentData = makeVorbisCommentBlockData(tags: tags)
        let pictureData = picture.map(makePictureBlockData)

        // STREAMINFO is never the last block here, since our new blocks always follow it.
        header.append(try metadataBlockHeader(type: 0, isLast: false, length: streamInfo.count))
        header.append(streamInfo)

        let isVorbisCommentLast = (pictureData == nil)
        header.append(try metadataBlockHeader(type: 4, isLast: isVorbisCommentLast, length: vorbisCommentData.count))
        header.append(vorbisCommentData)

        if let pictureData {
            header.append(try metadataBlockHeader(type: 6, isLast: true, length: pictureData.count))
            header.append(pictureData)
        }

        let tempURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                throw FlacMetadataError.truncatedFile
            }
            let output = try FileHandle(forWritingTo: tempURL)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }

            try output.write(contentsOf: header)
            try input.seek(toOffset: UInt64(audioFramesOffset))
            while let chunk = try input.read(upToCount: copyChunkSizeInBytes), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    // MARK: - Parsing existing blocks

    /// Walks every existing metadata block via seeks — never reading the audio frames —
    /// returning `STREAMINFO`'s raw data (header stripped, unchanged) and the byte offset where
    /// audio frames begin. Any other existing block — including a `VORBIS_COMMENT` `AVAudioFile`
    /// may already have written — is discarded; Runout always writes its own from scratch rather
    /// than trying to merge into it.
    private static func parseStreamInfoAndFindAudioOffset(at url: URL) throws -> (audioFramesOffset: Int, streamInfo: Data) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        func readExactly(_ count: Int) throws -> Data {
            guard let data = try input.read(upToCount: count), data.count == count else {
                throw FlacMetadataError.truncatedFile
            }
            return data
        }

        guard try readExactly(4).elementsEqual(Array("fLaC".utf8)) else {
            throw FlacMetadataError.notAFlacFile
        }

        var streamInfo: Data?
        while true {
            let blockHeader = try readExactly(4)
            let headerByte = blockHeader[blockHeader.startIndex]
            let isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let length = Int(blockHeader[blockHeader.startIndex + 1]) << 16
                | Int(blockHeader[blockHeader.startIndex + 2]) << 8
                | Int(blockHeader[blockHeader.startIndex + 3])

            if blockType == 0 {
                streamInfo = try readExactly(length)
            } else {
                let next = try input.offset() + UInt64(length)
                try input.seek(toOffset: next)
            }

            if isLast {
                guard let streamInfo else { throw FlacMetadataError.truncatedFile }
                let audioFramesOffset = Int(try input.offset())
                // The offset must actually exist in the file — a length field pointing past EOF
                // is corruption the byte-oriented seek above wouldn't have caught.
                let fileSize = try input.seekToEnd()
                guard UInt64(audioFramesOffset) <= fileSize else { throw FlacMetadataError.truncatedFile }
                return (audioFramesOffset, streamInfo)
            }
        }
    }

    // MARK: - Building new blocks

    /// A block header's length field is 24 bits. Silently bit-masking a larger length would
    /// write a corrupt file (docs/IMPROVEMENT_PLAN.md P0-2), so an oversized block is a thrown
    /// error — reachable in practice via very large cover art, which callers are expected to
    /// downscale first (see CoverArtDownscaler).
    static let maxBlockLength = 0xFFFFFF

    private static func metadataBlockHeader(type: UInt8, isLast: Bool, length: Int) throws -> Data {
        guard length <= Self.maxBlockLength else {
            throw FlacMetadataError.metadataBlockTooLarge(byteCount: length)
        }
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
