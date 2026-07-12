import AVFoundation
import Foundation

enum ExportError: Error, LocalizedError {
    case couldNotCreateOutputFile
    case couldNotReadCoverArt(Error)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateOutputFile: return "Couldn't create the output file."
        case .couldNotReadCoverArt(let error): return "Couldn't read the cover art: \(error.localizedDescription)"
        }
    }
}

enum ExportOutcome: Equatable {
    case exported(URL)
    case skipped(URL)
}

/// Slices `[startSample, endSample)` out of a side's master FLAC recording, writes a new FLAC
/// per track via `AVAudioFile`, tags it with `FlacMetadataWriter`, and names it per
/// `FileNameTemplate` — with filename collision handling (never silently overwrite without the
/// caller asking for it, per docs/FEATURES.md §4).
enum ExportPipeline {
    private static let readChunkSizeInFrames: AVAudioFrameCount = 1 << 20

    static func exportTrack(
        _ track: Track,
        from masterRecordingURL: URL,
        album: AlbumMetadata,
        coverArtURL: URL?,
        to destinationFolder: URL,
        fileNameTemplate: String,
        overwriteBehavior: OverwriteBehavior,
        bitDepth: Int,
        fadeDurationSeconds: Double = 0.010,
        declickEnabled: Bool = false
    ) throws -> ExportOutcome {
        let baseName = FileNameTemplate.resolve(fileNameTemplate, track: track, album: album)
        let resolution = try resolveOutputURL(
            baseName: baseName,
            in: destinationFolder,
            overwriteBehavior: overwriteBehavior
        )
        guard let outputURL = resolution else {
            // .skip and the file already exists — nothing to write, but not an error either.
            return .skipped(destinationFolder.appendingPathComponent(baseName).appendingPathExtension("flac"))
        }

        let sourceFile = try AVAudioFile(forReading: masterRecordingURL)
        let format = sourceFile.processingFormat

        let tempURL = destinationFolder.appendingPathComponent(".runout-export-\(UUID().uuidString).flac")
        try writeSlice(
            from: sourceFile,
            format: format,
            startSample: track.startSample,
            endSample: track.endSample,
            to: tempURL,
            bitDepth: bitDepth,
            fadeDurationSeconds: fadeDurationSeconds,
            declickEnabled: declickEnabled
        )

        do {
            let tags = FlacMetadataWriter.Tags(
                title: track.title,
                artist: track.artist ?? album.albumArtist,
                album: album.albumTitle,
                albumArtist: album.albumArtist,
                trackNumber: track.trackNumber,
                discNumber: track.discNumber,
                date: track.year ?? album.year,
                genre: track.genre ?? album.genre,
                comment: track.comment
            )
            let picture = try coverArtURL.map { try loadPicture(from: $0) }
            try FlacMetadataWriter.write(tags: tags, picture: picture, to: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        return .exported(outputURL)
    }

    // MARK: - PCM slicing

    private static func writeSlice(
        from sourceFile: AVAudioFile,
        format: AVAudioFormat,
        startSample: Int64,
        endSample: Int64,
        to url: URL,
        bitDepth: Int,
        fadeDurationSeconds: Double,
        declickEnabled: Bool
    ) throws {
        let settings = FlacSettings.writingSettings(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            bitDepth: bitDepth
        )
        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )

        var channels = try readSlice(from: sourceFile, format: format, startSample: startSample, endSample: endSample)

        if declickEnabled {
            for i in channels.indices {
                channels[i] = Declicker.declick(channels[i]).samples
            }
        }

        let fadeSampleCount = FadeApplier.sampleCount(forDurationSeconds: fadeDurationSeconds, sampleRate: format.sampleRate)
        if fadeSampleCount > 0 {
            for i in channels.indices {
                channels[i] = FadeApplier.applyFades(to: channels[i], fadeSampleCount: fadeSampleCount)
            }
        }

        try writeChannels(channels, format: format, to: outputFile)
    }

    /// Reads `[startSample, endSample)` into one `[Float]` array per channel — small enough
    /// (single tracks, not whole sides) to hold entirely in memory so fades/declick can see the
    /// full waveform rather than working chunk-by-chunk.
    private static func readSlice(
        from sourceFile: AVAudioFile,
        format: AVAudioFormat,
        startSample: Int64,
        endSample: Int64
    ) throws -> [[Float]] {
        sourceFile.framePosition = startSample
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readChunkSizeInFrames) else {
            throw ExportError.couldNotCreateOutputFile
        }

        let channelCount = Int(format.channelCount)
        var channels = [[Float]](repeating: [], count: channelCount)
        let totalFrameCount = endSample - startSample
        for i in channels.indices { channels[i].reserveCapacity(Int(totalFrameCount)) }

        var framesRemaining = totalFrameCount
        while framesRemaining > 0 {
            // Request the exact remaining count rather than always the full chunk size — see
            // docs/ROADMAP.md M3: AVAudioFile.read(into:frameCount:) has been observed to throw
            // rather than clamp when frameCount exceeds what's left to read.
            let framesToRead = AVAudioFrameCount(min(Int64(readChunkSizeInFrames), framesRemaining))
            try sourceFile.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { break }

            let count = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: channelData[channel], count: count))
            }
            framesRemaining -= Int64(buffer.frameLength)
        }
        return channels
    }

    private static func writeChannels(_ channels: [[Float]], format: AVAudioFormat, to outputFile: AVAudioFile) throws {
        guard let totalFrameCount = channels.first?.count, totalFrameCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readChunkSizeInFrames) else {
            throw ExportError.couldNotCreateOutputFile
        }

        var framePosition = 0
        while framePosition < totalFrameCount {
            let framesToWrite = min(Int(readChunkSizeInFrames), totalFrameCount - framePosition)
            guard let channelData = buffer.floatChannelData else { break }
            for (channel, samples) in channels.enumerated() {
                samples.withUnsafeBufferPointer { source in
                    channelData[channel].update(from: source.baseAddress! + framePosition, count: framesToWrite)
                }
            }
            buffer.frameLength = AVAudioFrameCount(framesToWrite)
            try outputFile.write(from: buffer)
            framePosition += framesToWrite
        }
    }

    // MARK: - Cover art

    private static func loadPicture(from url: URL) throws -> FlacMetadataWriter.Picture {
        let rawData: Data
        do {
            rawData = try Data(contentsOf: url)
        } catch {
            throw ExportError.couldNotReadCoverArt(error)
        }

        // User-imported art can be arbitrarily large; anything past FLAC's 16 MB block limit
        // must be downscaled before embedding or the exported file would be corrupt
        // (docs/IMPROVEMENT_PLAN.md P0-2).
        let (data, fileExtension) = try CoverArtDownscaler.ensureEmbeddable(rawData, fileExtension: url.pathExtension)

        // Dimensions come from the final (possibly downscaled) bytes — not the original file —
        // so the PICTURE block's width/height always describe the image actually embedded.
        let dimensions = CoverArtDownscaler.pixelDimensions(of: data)

        return FlacMetadataWriter.Picture(
            mimeType: mimeType(forPathExtension: fileExtension),
            data: data,
            width: dimensions?.width ?? 0,
            height: dimensions?.height ?? 0
        )
    }

    private static func mimeType(forPathExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        default: return "image/jpeg"
        }
    }

    // MARK: - Filename collision handling

    /// Returns `nil` (meaning: skip, don't write) only for `.skip` when the plain filename is
    /// already taken. Otherwise returns the URL to write to.
    private static func resolveOutputURL(
        baseName: String,
        in folder: URL,
        overwriteBehavior: OverwriteBehavior
    ) throws -> URL? {
        let candidate = folder.appendingPathComponent(baseName).appendingPathExtension("flac")
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        switch overwriteBehavior {
        case .overwrite:
            return candidate
        case .skip:
            return nil
        case .appendNumber:
            var counter = 2
            while true {
                let numberedCandidate = folder
                    .appendingPathComponent("\(baseName) (\(counter))")
                    .appendingPathExtension("flac")
                if !FileManager.default.fileExists(atPath: numberedCandidate.path) {
                    return numberedCandidate
                }
                counter += 1
            }
        }
    }
}
