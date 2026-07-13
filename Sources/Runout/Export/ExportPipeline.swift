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
        declickEnabled: Bool = false,
        /// Total tracks on `track`'s disc, for the TRACKTOTAL tag (docs/IMPROVEMENT_PLAN.md
        /// P2-2) — the caller's job since only it knows the full track list; omitted (no
        /// TRACKTOTAL tag) when not positive.
        trackTotal: Int = 0
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
                comment: track.comment,
                composer: track.composer,
                trackTotal: trackTotal > 0 ? trackTotal : nil,
                discTotal: album.discCount > 0 ? album.discCount : nil
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

    /// Streams `[startSample, endSample)` from the source to the output in bounded chunks —
    /// never the whole track in memory (docs/IMPROVEMENT_PLAN.md P1-2). Fades touch only a
    /// chunk's overlap with the track's first/last `fadeSampleCount` samples, and declicking
    /// goes through `StreamingDeclicker`, whose output is byte-identical to the whole-array
    /// form but lags input by at most one threshold block.
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
        // The client format's own commonFormat — not the settings dict's bitDepth — is what
        // actually determines the encoded bit depth (docs/IMPROVEMENT_PLAN.md P1-7): a real
        // 16-bit file needs an Int16 client format, quantized just before each write.
        let outputCommonFormat: AVAudioCommonFormat = bitDepth == 16 ? .pcmFormatInt16 : .pcmFormatFloat32
        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: outputCommonFormat,
            interleaved: format.isInterleaved
        )

        let channelCount = Int(format.channelCount)
        let totalFrameCount = endSample - startSample
        let fadeSampleCount = FadeApplier.sampleCount(forDurationSeconds: fadeDurationSeconds, sampleRate: format.sampleRate)
        let declickers: [StreamingDeclicker]? = declickEnabled ? (0..<channelCount).map { _ in StreamingDeclicker() } : nil

        sourceFile.framePosition = startSample
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readChunkSizeInFrames) else {
            throw ExportError.couldNotCreateOutputFile
        }

        var framesWritten: Int64 = 0
        var framesRemaining = totalFrameCount
        while framesRemaining > 0 {
            // Request the exact remaining count rather than always the full chunk size — see
            // docs/ROADMAP.md M3: AVAudioFile.read(into:frameCount:) has been observed to throw
            // rather than clamp when frameCount exceeds what's left to read.
            let framesToRead = AVAudioFrameCount(min(Int64(readChunkSizeInFrames), framesRemaining))
            try sourceFile.read(into: readBuffer, frameCount: framesToRead)
            guard readBuffer.frameLength > 0, let channelData = readBuffer.floatChannelData else { break }
            let count = Int(readBuffer.frameLength)
            framesRemaining -= Int64(readBuffer.frameLength)

            var chunk = (0..<channelCount).map { channel in
                Array(UnsafeBufferPointer(start: channelData[channel], count: count))
            }
            if let declickers {
                chunk = zip(declickers, chunk).map { declicker, samples in declicker.process(samples) }
            }
            framesWritten += try writeProcessedChunk(
                &chunk, format: format, to: outputFile, outputCommonFormat: outputCommonFormat,
                outputOffset: framesWritten, totalFrameCount: totalFrameCount, fadeSampleCount: fadeSampleCount
            )
        }

        if let declickers {
            var tail = declickers.map { $0.flush() }
            framesWritten += try writeProcessedChunk(
                &tail, format: format, to: outputFile, outputCommonFormat: outputCommonFormat,
                outputOffset: framesWritten, totalFrameCount: totalFrameCount, fadeSampleCount: fadeSampleCount
            )
        }
    }

    /// Applies fades (positioned by `outputOffset` within the whole track) and writes one
    /// processed chunk, quantizing to Int16 first when `outputCommonFormat` calls for it.
    /// Returns the number of frames written.
    private static func writeProcessedChunk(
        _ channels: inout [[Float]],
        format: AVAudioFormat,
        to outputFile: AVAudioFile,
        outputCommonFormat: AVAudioCommonFormat,
        outputOffset: Int64,
        totalFrameCount: Int64,
        fadeSampleCount: Int
    ) throws -> Int64 {
        guard let frameCount = channels.first?.count, frameCount > 0 else { return 0 }

        if fadeSampleCount > 0 {
            for i in channels.indices {
                FadeApplier.applyFades(
                    to: &channels[i],
                    chunkStartIndex: outputOffset,
                    totalSampleCount: totalFrameCount,
                    fadeSampleCount: fadeSampleCount
                )
            }
        }

        if outputCommonFormat == .pcmFormatInt16 {
            guard let clientFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: AVAudioFrameCount(frameCount)),
                  let channelData = buffer.int16ChannelData
            else {
                throw ExportError.couldNotCreateOutputFile
            }
            for (channel, samples) in channels.enumerated() {
                let quantized = PCMQuantizer.quantizeToInt16(samples)
                quantized.withUnsafeBufferPointer { source in
                    channelData[channel].update(from: source.baseAddress!, count: frameCount)
                }
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            try outputFile.write(from: buffer)
            return Int64(frameCount)
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData
        else {
            throw ExportError.couldNotCreateOutputFile
        }
        for (channel, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                channelData[channel].update(from: source.baseAddress!, count: frameCount)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        try outputFile.write(from: buffer)
        return Int64(frameCount)
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
