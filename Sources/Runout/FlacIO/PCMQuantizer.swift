import Foundation

/// Converts float samples in `[-1, 1]` to 16-bit signed integer PCM — round to nearest, clamp
/// rather than wrap on out-of-range input (docs/IMPROVEMENT_PLAN.md P1-7). Used when the client
/// audio format itself must be `.pcmFormatInt16` to make Core Audio's FLAC encoder actually
/// produce a 16-bit file: passing 16-bit-depth `settings` with a float32 client format has no
/// effect on the encoded output — the client format is what determines real stored precision.
enum PCMQuantizer {
    static func quantizeToInt16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let scaled = (Double(sample) * 32767.0).rounded()
            let clamped = max(-32768.0, min(32767.0, scaled))
            return Int16(clamped)
        }
    }
}
