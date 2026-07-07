# Roadmap

Milestones are ordered so each one is small, single-purpose, and independently testable — built and verified in this order, not in parallel. This ordering is deliberate for an implementer working with a less capable model: get the highest-risk, hardest-to-verify-by-reading-code piece (real-time audio capture) working and tested early, before investing in UI polish around it.

Each milestone lists **acceptance criteria** — a milestone isn't done until these are true, not just "the code compiles."

## M0 — Project scaffolding
- Single Xcode "Multiplatform App" target, SwiftUI, Swift language mode 5, builds and runs a blank window on both macOS and iPadOS (simulator is fine for iPadOS at this stage).
- Folder structure matches `ARCHITECTURE.md`'s module breakdown (empty files/stubs are fine).
- `AppIcon.appiconset` wired up using `assets/icon/AppIcon.appiconset` (regenerate via Xcode's asset catalog if the provided `Contents.json` doesn't match the actual project's icon asset configuration — treat the provided PNGs as the source art, not a mandatory literal file layout).
- GitHub Actions CI workflow: `xcodebuild build` on a macOS runner, on every push/PR.
- **Acceptance**: CI passes on a trivial commit; app launches to a blank window on both platforms.

## M1 — Device enumeration + level metering + basic recording
- `AudioInputManager` protocol + macOS and iOS implementations (device list, current device selection).
- Live level metering UI (peak/RMS, clip indicator) wired to a real input device, no recording yet — just monitoring.
- Recording to a plain PCM file (WAV or CAF — not FLAC yet, that's M2) via `AVAudioFile`, Record/Pause/Resume/Stop working correctly with no gaps introduced by pause/resume.
- **Acceptance**: record ~1 minute of real audio from a connected input device on a physical Mac (and ideally a physical iPad with a USB audio interface), play the resulting file back in an external player (e.g. QuickTime/Music), confirm no glitches, dropouts, or gaps — especially across a pause/resume.

## M2 — Native FLAC master recording
- Switch `RecordingWriter` to write FLAC directly (`kAudioFormatFLAC` via `AVAudioFile`) instead of the M1 intermediate format.
- **Acceptance**: a recorded FLAC file opens correctly in an external tool (e.g. `afinfo`/`metaflac` on macOS, or any standard FLAC-capable player) and is bit-for-bit losslessly decodable — verify by decoding back to PCM and comparing sample counts/checksums against what was captured.

## M3 — Waveform rendering
- `PeakCacheBuilder` generates the `.peaks` file format from `DATA_MODEL.md` for a finished recording.
- `WaveformView` (SwiftUI `Canvas`) renders from the peak cache, supports zoom and horizontal scroll, performs acceptably on a full ~20-25 minute side.
- **Acceptance**: open a real recorded side, scroll/zoom across its full length without stutter; waveform shape visually matches what's heard on playback (loud passages look tall, quiet/silent passages look flat).

## M4 — Marker placement & editing
- Add/move/delete markers on the waveform (click/tap, drag handles, "split at playhead" button).
- Snap-to-zero-crossing toggle.
- Undo/redo for marker edits.
- **Acceptance**: split a real recorded side into multiple tracks by ear, confirm marker positions are sample-accurate and persist correctly in the project manifest across an app relaunch.

## M5 — Track & album metadata UI
- Screen 3 per `UI_SPEC.md`: per-track fields, album-level fields, "apply to all", cover art import (file/drag/paste), live filename preview.
- **Acceptance**: fully tag a multi-track project, quit and relaunch the app, confirm all entered metadata reloads correctly from the project file.

## M6 — Export pipeline
- `ExportPipeline`: slice PCM per track's `[startSample, endSample)` range from the master FLAC, write a new FLAC via `AVAudioFile`, then run `FlacMetadataWriter` (per `FLAC_METADATA_SPEC.md`) to inject `VORBIS_COMMENT` + `PICTURE` blocks, then name the file per the template (`DATA_MODEL.md` token table), with collision handling.
- Screen 4 UI per `UI_SPEC.md`: destination/template controls, per-track progress, error handling for a failed individual track not blocking the batch.
- `FlacMetadataWriter` unit tests per the testing section of `FLAC_METADATA_SPEC.md`.
- **Acceptance**: export a real multi-track project, confirm every output file (a) plays back correctly with no audio corruption, (b) shows correct tags (title/artist/album/track#/cover art) in an external player/tag reader (e.g. Music.app, or `metaflac --list`), and (c) the audio is losslessly identical to the corresponding slice of the master recording.

## M7 — Project persistence & document integration
- `ReferenceFileDocument` conformance, `.runout` package read/write, `DocumentGroup` scene wiring, recent-documents/Files app integration.
- **Acceptance**: create a project on one device, place it in iCloud Drive, open and edit it (add a marker, change a tag) from the other platform (Mac ↔ iPad), confirm changes sync and don't corrupt the package.

## M8 — Auto-detect track breaks (stretch)
- `SilenceDetector`: configurable dBFS threshold + minimum gap duration, proposes markers for review (not auto-committed).
- **Acceptance**: run against a real recorded side with obvious gaps between tracks, confirm proposed markers land within a reasonable tolerance (e.g. within 0.5s) of the actual gaps, and that reviewing/rejecting a proposal works cleanly.

## M9 — MusicBrainz + Cover Art Archive lookup (stretch)
- `MusicBrainzClient`/`CoverArtArchiveClient`: search by artist/album, pull track listing + cover art, respecting the 1 req/sec rate limit.
- **Acceptance**: search a real, well-known album, confirm fetched track titles/count match the physical record, cover art downloads and attaches correctly, and hitting the API repeatedly doesn't exceed the rate limit (verify with logging, not just "it seemed to work").

## M10 — Audio polish (stretch)
- Fades at track boundaries (already partially covered in M4/M6 — this milestone is about tuning/exposing the fade duration as a setting and validating audibility).
- Optional click/pop reduction — explicitly a stretch goal, scope it small (e.g. a single well-tested declick algorithm) rather than building a general restoration suite.
- **Acceptance**: A/B comparison (by ear) of exported tracks with and without fades at a deliberately non-zero-crossing cut point, confirming the fade removes an audible click.

## M11 — Release polish
- Accessibility pass (VoiceOver labels, Dynamic Type, keyboard shortcuts per `FEATURES.md` §5).
- Code signing + notarization pipeline for macOS releases (Developer ID cert required — see `FEATURES.md` §5 for why this has a real ongoing cost).
- GitHub Actions release workflow (tag → build → notarize → attach DMG to a GitHub Release).
- README screenshots updated to real app screenshots (replacing the wireframe mockups referenced during earlier milestones).
- **Acceptance**: a tagged release produces a notarized DMG that opens without a Gatekeeper warning on a clean Mac that never had Xcode installed.
