# Architecture

## Goals

- One codebase, two targets: macOS (native window) and iPadOS. Both share almost all logic; only a thin platform layer differs (audio device enumeration, file picking chrome).
- No mandatory third-party dependencies for the MVP. Every core capability (recording, FLAC read/write, waveform data) is available natively via Apple frameworks. This keeps the build simple for whoever is implementing it, and keeps the project easy for outside contributors to build with a stock Xcode install.
- Everything is lossless end-to-end. The app never re-encodes or lossily transcodes audio. It captures PCM, writes PCM into FLAC containers, and slices PCM losslessly at export. The only lossy step in the whole signal chain is the analog-to-digital conversion in the user's turntable/preamp, which is outside the app's control.
- Non-destructive by design: the full-side recording is always preserved. Splitting, tagging, and exporting are all derived, repeatable operations against that master, never in-place edits to it.

## Non-goals (out of scope for MVP)

- Audio restoration DSP (click/pop removal, noise reduction). See `FEATURES.md` for why this is a stretch goal, not core.
- RIAA equalization curve selection. This project assumes the signal reaching the app is already line-level and RIAA-corrected by the user's turntable or phono preamp (confirmed as the target user's setup). A note for other curves (e.g. pre-1954 non-RIAA pressings) is included in `FEATURES.md` as a documented assumption, not a built feature.
- Streaming service integration, library management, or playback of the user's wider music collection. This is a ripping/splitting/tagging tool, not a player or library manager.

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| Language | Swift, **language mode 5** (not Swift 6 strict concurrency) | Swift 6's strict concurrency checking is a common source of hard-to-diagnose build errors for less experienced implementers. Ship the MVP in Swift 5 mode; revisit Swift 6 migration as a later, isolated task once the app works. |
| UI | SwiftUI, multiplatform target | One `App`/`Scene`/view hierarchy shared between macOS and iPadOS, with `#if os(iOS)` / `#if os(macOS)` branches only where a platform API genuinely differs (see below). |
| Project structure | Single Xcode project, one multiplatform app target | Do not create separate macOS and iPadOS targets. Use a single "Multiplatform App" target (Xcode's own template for this exists and is the right starting point). |
| Audio capture & playback | `AVFoundation` (`AVAudioEngine`, `AVAudioInputNode`, `AVAudioFile`) | Native, no dependency. Works the same way conceptually on both platforms. |
| FLAC read/write | `AVAudioFile` with `AVAudioFormat` format ID `kAudioFormatFLAC` | Apple's Core Audio has supported native FLAC encode/decode since macOS 11 / iOS 14. This means **no vendored libFLAC, no C interop, no build script complexity.** This is the single most important architectural simplification in this project — do not reach for a third-party FLAC library. |
| FLAC tag writing (Vorbis comments + cover art) | Hand-rolled, in `FlacIO/` | `AVAudioFile` writes valid FLAC audio + `STREAMINFO` but does not expose an API for writing FLAC's `VORBIS_COMMENT`/`PICTURE` metadata blocks. See `FLAC_METADATA_SPEC.md` for the exact, byte-precise post-processing step that patches these blocks into an already-written FLAC file. This is a self-contained, testable module — treat it as its own milestone (see `ROADMAP.md` M2/M6). |
| Waveform data | Precomputed peak (min/max) cache, custom format, rendered with SwiftUI `Canvas` | See "Waveform pipeline" below. |
| Persistence | Document-based app (`DocumentGroup` in SwiftUI, backed by `FileDocument`/`ReferenceFileDocument`) | Gets iCloud Drive sync, Files app integration, and Mac↔iPad continuity for free — see "Cross-device continuity" below. |
| Metadata lookup (Phase 2, not MVP) | `URLSession` calls to MusicBrainz + Cover Art Archive REST APIs | Free, keyless (rate-limited to 1 req/sec — must be respected), no SDK needed. |
| CI | GitHub Actions, macOS runner, `xcodebuild build` + `xcodebuild test` | See `ROADMAP.md` M0. |

## Module breakdown

```
Runout/
  App/                     — App entry point, DocumentGroup scene, top-level navigation
  AudioEngine/
    AudioInputManager.swift       — protocol: device enumeration, level metering, start/stop capture
    AudioInputManager+macOS.swift — Core Audio device enumeration (AVAudioEngine inputNode + AudioObjectID device list)
    AudioInputManager+iOS.swift   — AVAudioSession route/category handling
    LevelMeter.swift               — running peak/RMS calculation from tapped buffers
    RecordingWriter.swift          — background actor: ring buffer -> AVAudioFile (FLAC) writer
  Waveform/
    PeakCacheBuilder.swift   — generates multi-resolution min/max peak data from a recorded file
    WaveformView.swift       — SwiftUI Canvas-based renderer, zoom/scroll
    SilenceDetector.swift    — auto-marker suggestion (Phase 2/stretch, see ROADMAP M8)
  Model/
    Project.swift, RecordingSide.swift, Marker.swift, Track.swift, AlbumMetadata.swift, AudioSettings.swift, ExportSettings.swift
    — see DATA_MODEL.md for full field definitions
  Persistence/
    ProjectDocument.swift    — FileDocument/ReferenceFileDocument conformance, package format read/write
  FlacIO/
    FlacMetadataWriter.swift — Vorbis comment + PICTURE block injection (see FLAC_METADATA_SPEC.md)
    FlacMetadataWriterTests.swift
  Export/
    ExportPipeline.swift     — slices master recording per track markers, calls FlacIO, applies filename template
    FileNameTemplate.swift
  MetadataLookup/             — Phase 2 / stretch, not MVP
    MusicBrainzClient.swift
    CoverArtArchiveClient.swift
  UI/
    Recording/   — matches assets/mockups/01-recording
    Editor/      — matches assets/mockups/02-waveform-editor
    Metadata/    — matches assets/mockups/03-metadata
    Export/      — matches assets/mockups/04-export
    Shared/      — reusable components (level meter view, transport controls, nav rail)
  Utilities/
```

## Data flow (high level)

```
Input device (turntable → preamp → USB/line-in)
  → AVAudioEngine input tap (real-time audio thread)
      → LevelMeter (peak/RMS for UI)
      → ring buffer → RecordingWriter actor (background thread)
          → AVAudioFile writing FLAC directly to the project's master recording file
  → on stop: PeakCacheBuilder scans the finished master file, writes peak cache
  → Editor: user places/adjusts Markers against the waveform (from peak cache + on-demand PCM reads for zoomed-in accuracy)
  → Metadata screen: user fills in Track/AlbumMetadata, attaches cover art
  → ExportPipeline: for each Track, reads the PCM sample range [startSample, endSample) from the master FLAC,
      writes a new FLAC file via AVAudioFile, then FlacMetadataWriter patches in VORBIS_COMMENT + PICTURE blocks,
      then names the file per the FileNameTemplate
```

## Concurrency model

The audio input tap callback (`AVAudioInputNode.installTap`) runs on a **real-time priority audio thread**. Rules for anything that happens inside that callback:

- No memory allocation, no locks, no UI calls, no disk I/O directly on that thread.
- The tap callback's only job is to copy the incoming buffer into a lock-free ring buffer (or hand it to a pre-allocated buffer pool) and return immediately.
- A separate background `actor` (`RecordingWriter`) drains the ring buffer and performs the actual `AVAudioFile` disk write and the level-meter math.
- The UI reads level-meter values via a `@Published`/`@Observable` property updated from the background actor at a UI-friendly rate (e.g. 20-30 Hz), not at audio-buffer rate.

This is the single most important correctness rule in the audio path — violating it causes audible glitches/dropouts during recording, which for a "rip a physical record one time" tool is a very expensive bug (the user has to flip the record and re-record the whole side).

## Platform differences (macOS vs. iPadOS)

| Concern | macOS | iPadOS |
|---|---|---|
| Input device enumeration | Core Audio HAL (`AudioObjectID` device list) or simply `AVAudioEngine.inputNode` if only one device is expected at a time | `AVAudioSession` category `.record`, route/port list via `AVAudioSession.sharedInstance().availableInputs` |
| Connecting an external USB turntable/interface | Standard USB or Thunderbolt, appears as a normal Core Audio device | Requires USB-C (or Lightning + Camera Connection Kit on older iPads); once connected, appears as a standard `AVAudioSessionPortDescription` |
| Preventing sleep during a long recording | `ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason:)` | `UIApplication.shared.isIdleTimerDisabled = true` |
| File access / destination picking | `NSOpenPanel`/`NSSavePanel` (or SwiftUI `.fileExporter`) | `UIDocumentPickerViewController` (or SwiftUI `.fileExporter`) — both wrapped behind one `PlatformFilePicker` abstraction |
| Keyboard shortcuts | Full keyboard shortcut set expected (space = play/pause, arrows = nudge marker, etc.) | Touch-first interactions (drag handles, tap-and-hold), keyboard shortcuts as a bonus when a hardware keyboard is attached |

Keep all of the above behind the `AudioInputManager` protocol and a small number of platform-conditional files, listed in the module breakdown above. The rest of the app (waveform, editor, metadata, export) is 100% shared code with no platform branching.

## Cross-device continuity

Rather than build custom sync, use SwiftUI's `DocumentGroup` with a project file stored as a **file package** (a directory with a single extension, e.g. `.runout`, that Finder/Files treats as one file). Store it in iCloud Drive (or any user-chosen location) and it syncs between Mac and iPad automatically, the same way Pages/Keynote documents do. No custom networking or sync code needed. See `DATA_MODEL.md` for the package's internal layout.

## Error handling

- Recording: if the input device disappears mid-recording (USB unplugged), stop gracefully, flush what's been written so far, and surface a clear alert — never crash or silently produce a truncated file with no explanation.
- Export: if a write fails partway (disk full, permissions), stop the batch, leave already-exported files in place, and report exactly which tracks succeeded/failed. Never leave a corrupt/partial FLAC file at a final destination path — write to a temp path first, then move into place on success.
- Disk space: check available space against the estimated recording size (from sample rate/bit depth/channel count × expected duration headroom) before starting a recording, and warn if it's tight.
