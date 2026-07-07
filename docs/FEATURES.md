# Feature Specification

## Assumption on record

The target setup is a turntable feeding a **separate phono preamp** into a Mac/iPad's line/USB audio input. This means the signal Runout receives is already line-level and RIAA-equalized before it ever reaches the app — Runout does not need to apply RIAA (or any other historical EQ curve) itself. If this assumption is ever wrong for a given source (e.g. a very old shellac 78 pressed with a non-RIAA curve, played through gear with no correction), that's a source-side problem to solve with different hardware, not a feature to build into the app. This is called out explicitly so nobody re-derives it differently later.

## 1. Recording

- **Input device selection**: enumerate available audio input devices (see `ARCHITECTURE.md` platform differences), let the user pick one, remember the last choice per project.
- **Format selection**: sample rate (44.1/48/96/192 kHz) × bit depth (16/24-bit) × channel count (mono/stereo, auto-detected from the device but overridable). Default 24-bit/96kHz/stereo.
- **Level metering**: real-time peak meters (L/R independently) with numeric dB readout and a **clip indicator** that latches (stays lit until manually cleared) if 0dBFS is hit, so a brief clip during a 20-minute recording isn't missed just because the meter moved on.
- **Pre-roll monitoring**: let the user watch levels and adjust preamp/turntable gain *before* pressing record, without committing to a take.
- **Transport**: Record / Pause / Resume / Stop. Pausing and resuming must not create a gap or a new file — it's one continuous master recording per side.
- **Side management**: a project has one or more `RecordingSide`s (typically "Side A" / "Side B", renameable, and extensible to multi-disc box sets — see Data Model). Each side is recorded, edited, and exported somewhat independently but shares one project's album metadata.
- **Prevent system sleep during recording** (see `ARCHITECTURE.md` platform table) — a record side is commonly 15-25 minutes; the OS must not nap or sleep partway through.
- **Disk space guard**: before starting, estimate the recording's size from format × an assumed max duration (e.g. 30 min) and warn if free space is tight. Continuously re-check during recording and warn/stop gracefully rather than crash if space actually runs out.
- **Crash-safe autosave**: flush the in-progress master recording to disk periodically (e.g. every few seconds, via normal `AVAudioFile` writes — it already writes incrementally, just make sure nothing buffers an unreasonable amount in memory) so a crash or force-quit mid-recording loses at most a few seconds, not the whole side.

## 2. Waveform editing / splitting

- **Zoom**: from "whole side at a glance" down to sample-accurate.
- **Scrub playback** of the master recording, synced with a playhead over the waveform.
- **Add a marker**: either by clicking/tapping directly on the waveform, or a "split at playhead" button during playback (useful for splitting by ear while listening, without having to eyeball silence in the waveform).
- **Move a marker**: drag its handle; snaps to the nearest zero-crossing when "Snap to Zero-Crossing" is enabled (default on) to avoid an audible click at the cut point.
- **Delete a marker**: merges the two tracks it separated into one (explicit, undoable action, not silent).
- **Auto-detect track breaks**: scan for gaps below a configurable silence threshold (dBFS) lasting longer than a configurable minimum duration, and propose markers at the midpoint of each gap. This is a *proposal* the user reviews/accepts/adjusts, not a silent automatic split — vinyl often has run-in/run-out noise and between-track silences that aren't perfectly clean, so full automation would mis-split often enough to be untrustworthy without review.
- **Fades at split boundaries**: apply a short (default ~10ms, configurable) fade-in/fade-out at each track's start/end during export, independent of zero-crossing snapping, as a second line of defense against clicks at cut points.
- **Undo/redo** for all marker and metadata edits, backed by the standard `UndoManager` SwiftUI integration.

## 3. Track & album metadata

- Per-track fields: Title, Artist (optional override of album artist), Track #, Disc #, Genre (optional override), Year (optional override), Composer, Comment.
- Album-level fields: Album Title, Album Artist, Year, Genre, Disc Count, Cover Art.
- **"Apply to all tracks"** for album-level fields, to avoid re-typing artist/album/year on every track.
- **Cover art**: import via file picker, drag-and-drop, or paste from clipboard. Store one image per project (in the package, see `DATA_MODEL.md`), embedded into every exported track's `PICTURE` block.
- **Live filename preview** per track, reflecting the current filename template + that track's metadata, so the user sees exactly what will be written before exporting.
- **(Phase 2 / stretch, not MVP) MusicBrainz + Cover Art Archive lookup**: search by album/artist, pull back a track listing and cover art to pre-fill metadata instead of typing every field by hand. Keyless, free APIs; must respect MusicBrainz's 1 request/second rate limit. This is genuinely one of the highest-value additions once the MVP works, since typing out a full tracklist by hand is the most tedious part of the whole workflow — see `ROADMAP.md` M9.

## 4. Export

- Destination folder picker.
- Filename template with token substitution (see `DATA_MODEL.md` for the token table), with a sensible default and live preview.
- Format is fixed: FLAC, at the project's recording sample rate/bit depth, lossless passthrough (no re-encoding, no lossy step, no quality slider — there's nothing to trade off, so don't build a control for it).
- Batch export with per-track progress and an overall progress bar.
- **Collision handling**: `skip` / `overwrite` / `append a number` — never silently overwrite an existing file with no setting governing that choice.
- Write a short export log/report (which files were written, to where) so a large batch export is auditable after the fact.
- After export, the project (with its master recordings) is kept by default — never deleted automatically — so the user can revisit splits/tags and re-export later without re-recording the physical record.

## 5. Cross-cutting

- **Document-based, non-destructive project files** (`.runout` packages, see `DATA_MODEL.md`) — the source of truth for "what have I recorded and how is it split/tagged" always exists independently of any exported FLACs.
- **iCloud Drive / Files app integration "for free"** via `DocumentGroup` — no custom sync code, see `ARCHITECTURE.md`.
- **Accessibility**: VoiceOver labels on all controls (meters, transport, markers), Dynamic Type support in text fields.
- **Keyboard shortcuts (macOS)**: space = play/pause, arrow keys = nudge selected marker by a small increment, Cmd+click on waveform = add marker at click point, Cmd+Z/Shift+Cmd+Z = undo/redo.
- **Code signing & notarization**: since this ships outside the Mac App Store (GitHub Releases), the macOS build must be signed with a Developer ID certificate and notarized, or Gatekeeper will block it on other people's Macs. This needs an Apple Developer Program membership even for open-source/free distribution. Document this clearly in `CONTRIBUTING.md`/release notes since it's a real recurring cost the maintainer needs to be aware of, not a one-time setup step.

## 6. Legal/ethical framing

Runout is for personal archival of vinyl records the user owns — the same use case as any CD/tape ripping tool. State this plainly in the README, both to set expectations for contributors and users, and because "vinyl ripping tool" without context can read as ambiguous. No feature here (format, metadata, or otherwise) is designed around circumventing copy protection, since vinyl has none to circumvent — this is a straightforward analog-capture tool.

---

## Things you probably hadn't thought of

These aren't in the original ask but came up while designing the recording/editing/export pipeline, and are folded into the feature list and roadmap above rather than treated as afterthoughts:

1. **Clip-safe gain workflow** — a latching clip indicator during recording (§1), plus a non-destructive digital gain trim available before export if a recording turns out hotter than ideal. This can't undo real analog clipping, but it stops a slightly-hot digital level from being compounded by any later processing.
2. **Silence-based auto-split proposals** (§2) — reviewed, not automatic — the single biggest time-saver over manually eyeballing every gap on a 20-track LP box set.
3. **Zero-crossing snap + short fades at every cut point** (§2) — the difference between a rip that sounds professionally split and one with audible ticks at every track boundary.
4. **Disk space guard before recording** (§1) — a 24-bit/96kHz stereo side is roughly 1GB per 20 minutes; worth checking before, not discovering after, a side is fully recorded.
5. **Prevented sleep during recording** (§1) — an unattended Mac/iPad napping mid-side is an easy way to lose a take.
6. **Crash-safe autosave of in-progress recordings** (§1) — protects the one part of the workflow that's expensive to redo (physically re-recording the record).
7. **Non-destructive project format, master recording always retained** (§4, `DATA_MODEL.md`) — re-splitting or re-tagging later never requires re-recording.
8. **MusicBrainz/Cover Art Archive lookup** (§3, Phase 2) — saves hand-typing a full tracklist; flagged as a high-value stretch goal.
9. **Filename collision handling** (§4) — an explicit policy instead of an implicit overwrite.
10. **Multi-disc support** (`Track.discNumber`, `AlbumMetadata.discCount`) — double LPs and box sets are common enough in vinyl collecting to design in from the start rather than retrofit.
11. **Mono source handling** — many older, especially pre-1968, pressings (and most 45s/78s) are genuinely mono; the app should detect and preserve the source channel count rather than forcing stereo.
12. **Non-RIAA equalization curves** — explicitly out of scope given the confirmed hardware setup (separate preamp), but documented here as a known assumption so it's a deliberate decision, not a gap someone finds by surprise later.
13. **Accessibility & keyboard shortcuts** (§5) — often skipped in v1 of hobby apps, cheap to build in from the start, expensive to retrofit.
14. **Code signing & notarization cost** (§5) — a real, recurring practical requirement for shipping a Mac app outside the App Store that's easy to not think about until the first "Apple can't check this app for malicious software" report from a user.
15. **Export log/report** (§4) — makes a large batch export auditable after the fact (which files went where).
16. **Additional lossless export formats (ALAC/WAV) as a possible future option** — not built for the MVP per the original brief (FLAC only), but worth noting the export pipeline's architecture (`ExportPipeline` slices PCM, then hands off to a format-specific writer) makes adding a second lossless output format later a small, contained change rather than a redesign, if ever wanted.
