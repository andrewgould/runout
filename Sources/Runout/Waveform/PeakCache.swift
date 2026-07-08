import Foundation

/// One min/max pair covering `samplesPerBucket` (at this level) worth of audio.
struct PeakBucket: Equatable {
    var min: Int16
    var max: Int16
}

enum PeakCacheError: Error, LocalizedError {
    case truncatedData
    case badMagic

    var errorDescription: String? {
        switch self {
        case .truncatedData: return "Peak cache file is truncated or corrupt."
        case .badMagic: return "Not a Runout peak cache file."
        }
    }
}

/// Multi-resolution min/max waveform peaks, serialized as `.peaks` files — see docs/DATA_MODEL.md
/// ("Peak cache format") for the exact binary layout this reads and writes.
struct PeakCache: Equatable {
    static let magic = "RPKS"
    static let formatVersion: UInt32 = 1

    /// Samples-per-bucket at `levels[0]` (the finest level). Each subsequent level doubles it.
    let samplesPerBucketAtFinestLevel: Int
    /// Finest level first; each level's bucket count is roughly half of the previous one's.
    let levels: [[PeakBucket]]

    var totalSampleCountEstimate: Int64 {
        guard let finest = levels.first else { return 0 }
        return Int64(finest.count) * Int64(samplesPerBucketAtFinestLevel)
    }

    /// The cached level whose bucket size is the largest one that's still `<=` samplesPerPoint —
    /// i.e. the most detail we can show without drawing more buckets than screen pixels.
    /// Falls back to the coarsest level if every level is finer than one point.
    func level(forSamplesPerPoint samplesPerPoint: Double) -> (bucketSize: Int, buckets: [PeakBucket]) {
        var bucketSize = samplesPerBucketAtFinestLevel
        var best = (bucketSize: bucketSize, buckets: levels.first ?? [])
        for (index, level) in levels.enumerated() {
            let size = samplesPerBucketAtFinestLevel << index
            if Double(size) <= samplesPerPoint {
                best = (size, level)
                bucketSize = size
            } else {
                break
            }
        }
        return best
    }

    func serialized() -> Data {
        var data = Data()
        data.append(contentsOf: Array(Self.magic.utf8))
        Self.appendUInt32LE(Self.formatVersion, to: &data)
        Self.appendUInt32LE(UInt32(samplesPerBucketAtFinestLevel), to: &data)
        Self.appendUInt32LE(UInt32(levels.count), to: &data)
        for level in levels {
            Self.appendUInt32LE(UInt32(level.count), to: &data)
            for bucket in level {
                Self.appendInt16LE(bucket.min, to: &data)
                Self.appendInt16LE(bucket.max, to: &data)
            }
        }
        return data
    }

    static func deserialized(from data: Data) throws -> PeakCache {
        var offset = data.startIndex
        func requireBytes(_ count: Int) throws {
            guard offset + count <= data.endIndex else { throw PeakCacheError.truncatedData }
        }
        func readUInt32() throws -> UInt32 {
            try requireBytes(4)
            let value = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
            offset += 4
            return value
        }
        func readInt16() throws -> Int16 {
            try requireBytes(2)
            let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            offset += 2
            return Int16(bitPattern: bits)
        }

        try requireBytes(4)
        let magicBytes = data[offset..<offset + 4]
        guard String(decoding: magicBytes, as: UTF8.self) == magic else { throw PeakCacheError.badMagic }
        offset += 4

        _ = try readUInt32() // format version — only version 1 exists so far, nothing to branch on
        let samplesPerBucket = try readUInt32()
        let levelCount = try readUInt32()

        var levels: [[PeakBucket]] = []
        levels.reserveCapacity(Int(levelCount))
        for _ in 0..<levelCount {
            let bucketCount = try readUInt32()
            var buckets: [PeakBucket] = []
            buckets.reserveCapacity(Int(bucketCount))
            for _ in 0..<bucketCount {
                let min = try readInt16()
                let max = try readInt16()
                buckets.append(PeakBucket(min: min, max: max))
            }
            levels.append(buckets)
        }

        return PeakCache(samplesPerBucketAtFinestLevel: Int(samplesPerBucket), levels: levels)
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendInt16LE(_ value: Int16, to data: inout Data) {
        let bits = UInt16(bitPattern: value)
        data.append(UInt8(bits & 0xFF))
        data.append(UInt8((bits >> 8) & 0xFF))
    }
}
