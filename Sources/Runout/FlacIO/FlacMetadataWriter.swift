import Foundation

// Post-processes an AVAudioFile-written FLAC to inject VORBIS_COMMENT + PICTURE metadata blocks.
// Exact byte-level format, including the little-endian gotcha inside VORBIS_COMMENT, is specified
// in docs/FLAC_METADATA_SPEC.md. Implemented in M6 — see docs/ROADMAP.md.

