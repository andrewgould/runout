import Foundation

// Slices PCM per track's [startSample, endSample) range from a side's master FLAC, writes a new
// FLAC per track via AVAudioFile, then runs FlacMetadataWriter, then names the file per
// FileNameTemplate. Implemented in M6 — see docs/ROADMAP.md.

