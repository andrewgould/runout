import Foundation

// Background actor: drains the real-time tap's ring buffer and writes FLAC via AVAudioFile.
// Must never block the audio thread — see docs/ARCHITECTURE.md (Concurrency model).
// Implemented in M1 (PCM) / M2 (native FLAC) — see docs/ROADMAP.md.

