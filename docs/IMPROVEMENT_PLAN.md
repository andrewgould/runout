# Improvement Plan (post-M11 audit, 2026-07-11)

Findings from a full-code audit after the M0–M11 roadmap completed, ordered by priority. Each item
follows `ROADMAP.md`'s convention: it isn't done until its **acceptance** criteria hold, not just
when the code compiles. Priorities: **P0** = data-integrity bug, fix before any release tag;
**P1** = real-world reliability/scalability; **P2** = promised in `FEATURES.md` but not built;
**P3** = polish.

## P0-1 — Recording buffer ordering is not guaranteed

`RecordingSession.startRecording` hands each tapped buffer to the writer via a new unstructured
`Task { try? await self.writer.append(copy) }`. Swift makes **no ordering guarantee** between
separate unstructured tasks, and actors don't drain their mailbox FIFO — under CPU pressure two
pending appends can execute out of order, silently writing audio chunks into the master recording
in the wrong order. It will almost always work, which is exactly what makes it dangerous: the
failure is rare, silent, and permanently corrupts a take that can't be re-recorded.

The same line also swallows every write error (`try?`), so a disk-full mid-recording is silently
ignored — `FEATURES.md` §1 explicitly requires warning/stopping gracefully instead.

**Fix**: replace the per-buffer `Task` with an `AsyncStream<AVAudioPCMBuffer>` — the tap callback
yields into the stream's continuation (synchronous, ordered, RT-safe), and a single long-lived
consumer task appends to the writer in order. Surface append errors to `lastError` and stop the
recording cleanly.

**Acceptance**: a stress test (e.g. tap-simulation appending thousands of sequence-numbered
buffers under artificial load) proves order preservation; a forced write failure (e.g. writer
pointed at a full/removed volume) visibly stops the recording with an error rather than silently
producing a truncated file.

**Discovered while fixing this** (real-hardware verification of the fix flushed out three more
members of the same "recording fails silently" bug class, all addressed in the same PR):
- The app never requested microphone permission — an unauthorized install "records" a header-only
  empty file with no error. Fixed: `AVCaptureDevice.requestAccess` before starting.
- Explicitly setting the input device (`kAudioOutputUnitProperty_CurrentDevice`, and equally
  `AUAudioUnit.setDeviceID`) stops tap delivery entirely on macOS 26 — even re-selecting the
  system default. Fixed for the default-device case: when the chosen device *is* the system
  default, the engine's own default-tracking aggregate is left alone (and the picker now
  preselects the true system default, not whichever device enumerates first). **Selecting a
  non-default device on this macOS version remains broken at the OS/AUHAL level** — see P1-5.
- No detection of an input that delivers nothing (dead device, revoked permission, the above OS
  bug): a 2-second frames-written watchdog now stops the recording with an actionable error
  instead of letting it "record" nothing indefinitely.

## P1-5 — Non-default input device selection is broken on macOS 26

Verified on real hardware (2026-07-12): any explicit device set on the engine's input unit — via
the legacy property or `AUAudioUnit.setDeviceID`, before `prepare()`/`start()`, to any device —
results in zero tap callbacks on this OS version, while the untouched default-device aggregate
captures fine. The P0-1 watchdog makes this loud (error within ~2s) rather than a silent empty
side, and the default device works, but users can't record from a non-default input without
changing the system default in System Settings (macOS's own Sound settings can do this).

**Fix directions to investigate**: reproduce on a release macOS (is it specific to this beta?);
try building an explicit `AVAudioSourceNode`/AUHAL capture unit outside `AVAudioEngine.inputNode`;
file a Feedback with Apple; as a stopgap, surface "switch the default input in System Settings"
guidance in the recording UI when a non-default device is chosen.

**Acceptance**: recording from a deliberately non-default input device captures real audio, or —
where the OS genuinely can't — the UI explains the limitation and the workaround before the user
wastes a take.

## P1-6 — pause()/resume() may not reliably resume frame delivery on this macOS build

Discovered while verifying P2-3's continuous stall monitor (2026-07-13): in one real-hardware
run, `pauseRecording()` followed by `resumeRecording()` on the system-default device resulted in
zero further frames reaching the writer — the recording's final decoded length matched *exactly*
the pre-pause duration, with `state` staying `.recording` (the monitor correctly caught this as a
stall a few seconds later, rather than silently producing a truncated file). This looks like the
same family of issue as P1-5 (`AVAudioEngine` input reliability on this specific OS build), not a
new independent bug, and wasn't reproducible on demand in a follow-up isolated run within this
session (the follow-up test runs hung indefinitely instead, for reasons that look like this
sandboxed environment's TCC prompt handling rather than the app itself — see the note in P2-3's
verification below).

**Fix directions to investigate**: reproduce deliberately on real (non-sandboxed) hardware with a
person at the keyboard; if confirmed, consider dropping `engine.pause()`/`engine.start()` in favor
of tearing down and reinstalling the tap on resume (mirroring what `startRecording` already does),
which sidesteps whatever state `pause()` leaves the input unit in.

**Acceptance**: pause then resume a real recording several times in a row; every segment
continues capturing real audio with no gap beyond the intended pause, confirmed by ear and by
inspecting the waveform around each pause point.

## P1-7 — The bit-depth setting has no effect on the encoded file

Discovered while fixing the P3 "read the real bit depth from STREAMINFO" item (2026-07-13):
`AVLinearPCMBitDepthKey` in `FlacSettings.writingSettings` turns out to have **zero effect** on
Core Audio's FLAC encoder when the source is float32 PCM (which every write in this app is —
`RecordingWriter` and `ExportPipeline` both use `commonFormat: .pcmFormatFloat32` throughout).
Proven directly: two files written through the exact same `RecordingWriter` path, one requesting
16-bit and one requesting 24-bit, are **byte-for-byte identical**, and both decode as 24-bit in
`STREAMINFO`. This means the 16-bit option in the M2-era `AudioSettings.bitDepth` field, the
recording format picker added in P2-1, and the export bit-depth plumbing have never actually
produced a 16-bit file — every recording and export has always been 24-bit regardless of what the
user picked, silently.

This is more than a labeling bug (unlike the STREAMINFO-reading fix, which is correct and stays):
the feature itself doesn't work. `readBitDepth` in this same PR now honestly reports "24" in both
cases rather than trusting a wrong guess, which is strictly better than before, but doesn't make
16-bit recording real.

**Fix directions to investigate**: Core Audio's FLAC encoder likely picks subframe bit depth from
the *input* format, not the output settings dict, for a float source — try writing with
`commonFormat: .pcmFormatInt16` (pre-quantized integer buffers) when `bitDepth == 16` instead of
always `.pcmFormatFloat32`. This ripples: `Declicker` and `FadeApplier` currently assume `[Float]`
throughout the export pipeline, so either they'd need an Int16 path too, or the quantization step
would need to happen only at the final write (after fades/declick run on float data, immediately
before handing buffers to `AVAudioFile`) — the latter is probably the smaller change. Scope this
as its own milestone with real A/B file-size and `metaflac`-reported-bit-depth verification, not a
drive-by fix.

**Acceptance**: a recording made with "16-bit" selected produces a file that `metaflac --list`
(or equivalent) reports as 16 bits per sample, and is meaningfully smaller on disk than the same
audio at 24-bit for a source that doesn't need the extra precision.

## P0-2 — FLAC metadata block length silently overflows at 16 MB

A FLAC metadata block header's length field is 24 bits (max 16,777,215 bytes).
`FlacMetadataWriter.metadataBlockHeader` masks the length to 24 bits without checking, so a
`PICTURE` block over ~16 MB writes a wrong length and produces a **corrupt FLAC file**. Cover Art
Archive serves original scans that routinely exceed 16 MB, and M9 feeds those bytes straight
through — this is reachable by a user clicking "Use This Release" on the wrong album.

**Fix**: throw a descriptive error from `metadataBlockHeader`/`write` when any block exceeds the
limit, and downscale/re-encode oversized cover art (both at Cover Art Archive fetch time and at
export time) to something sane like ≤ 2048×2048 JPEG, which also keeps per-track file sizes
reasonable given the art is embedded in every track.

**Acceptance**: a unit test proves an oversized picture throws rather than writing; a downscaled
image round-trips through `metaflac --export-picture-to` intact.

## P1-1 — Multi-side projects are recordable but not editable

`ContentView` has no UI to switch between sides: `selectedSideID` is set only to the first side on
open or the just-finished side after recording. Record Side A, then Side B, and Side A can never
be reopened in the editor/metadata/export screens without hand-editing the package. Sides also
can't be renamed (`FEATURES.md` §1 says "renameable"), and `RecordingView.slugAndLabel` clamps at
index 25, so side 27+ all get the slug `side-z` — `ingestFile` then **silently overwrites side
26's audio**.

**Fix**: a side picker (probably in the rail or a header menu) bound to `selectedSideID`, side
rename UI, and unbounded slugs (`side-aa`… or the side's UUID). Guard `ingestFile` against
overwriting an existing member with a different side's data.

**Acceptance**: record two sides, edit/tag/export each independently, rename one, and confirm the
package contains both sides' audio intact.

## P1-2 — Export loads entire tracks (and the whole file, twice more) into memory

M10 changed `ExportPipeline.writeSlice` to read the full track slice into `[[Float]]` even when
fades are 0 and declick is off. A markerless side (one track) at 96 kHz/24-bit stereo/25 min is
~2.3 GB of `Float` arrays — on top of which `FlacMetadataWriter.write` then loads the whole
written FLAC into `Data` and builds a second full copy for output. iPads will jetsam long before
that completes.

**Fix**: stream the slice chunk-by-chunk again (as M6 did) as the default path; apply fades to
only the first/last chunk (a fade needs ≤ 100 ms of samples); make declick a windowed streaming
pass with chunk overlap of `windowRadius`. Rewrite `FlacMetadataWriter` to splice via streamed
file I/O (read header region, write new blocks, copy audio frames through a bounded buffer).

**Acceptance**: exporting a synthetic 25-minute 96/24 stereo single-track side keeps peak memory
under a few hundred MB (measure with `xctrace`/Instruments or a `ProcessInfo` high-water check)
and produces byte-identical audio to the current implementation with the same settings.

## P1-3 — Declicker is too slow for real sides

`Declicker.declick` computes a sorted median over ±12 neighbors for **every sample** —
O(n·w log w). A 25-minute 96 kHz stereo side is ~276 M samples; at realistic throughput this is
minutes-to-tens-of-minutes per track with the UI showing only a spinner. It also runs on the
whole track even though clicks are sparse.

**Fix**: two-phase detection — cheap global pass first (deviation > some multiple of a per-block
percentile computed once per ~4096-sample block), exact local check only on candidates. This
drops the median computation from per-sample to per-block. Keep the existing tests green;
add a throughput test (e.g. ≥ 20× realtime on CI hardware).

**Acceptance**: declick-enabled export of a full synthetic side completes in seconds, not
minutes, with identical click-fix results on the existing test fixtures.

## P1-4 — Document holds every side's audio in RAM

`RunoutDocument.ingestFile` uses `FileWrapper(url:options:.immediate)` and
`materializedFileURL` round-trips through `wrapper.regularFileContents` — both fully in-memory.
Open a two-sided 96/24 project and the document holds ~2+ GB of `Data` for its whole lifetime.

**Fix**: lazy file wrappers (no `.immediate`) where the source URL outlives the wrapper, and/or
`FileHandle`-based copy in `materializedFileURL`. Also delete `workingDirectory` in `deinit` so
scratch copies don't accumulate in the container's tmp across sessions.

**Acceptance**: instrument a two-side project open + edit session; document-held memory stays
proportional to metadata, not audio; scratch dirs from closed documents are gone.

## P2-1 — Recording format selection & per-project device memory

`AudioSettings` (sample rate / bit depth / channel count / input device UID) exists in the model
and manifest but: the recording screen offers no format UI (`FEATURES.md` §1 promises
44.1/48/96/192 kHz × 16/24-bit × mono/stereo, default 24/96); the session just follows the
device's native format except bit depth; and the selected device is never written back to
`project.audioSettings.inputDeviceUID` nor restored on reopen ("remember the last choice per
project").

**Acceptance**: pick 44.1/16 on a device whose native rate is 48 kHz and get a 44.1/16 FLAC
(via `AVAudioConverter` or an explicit tap format); reopen the project and the same input device
is preselected.

## P2-2 — Per-track metadata fields missing from UI and FLAC output

`Track` carries `genre`, `year`, `composer`, `comment` but `MetadataView`'s track section only
exposes Title/Artist/Track #/Disc # — the other fields are only reachable by the "Apply Album
Info" *clearing* them. Worse, `FlacMetadataWriter.Tags` has no composer field at all, so
`Track.composer` can never reach an exported file. `TRACKTOTAL`/`DISCTOTAL` tags (expected by
most players; `AlbumMetadata.discCount` already exists) are also never written.

**Acceptance**: every `Track` field is editable in the UI and visible in `metaflac --list` output
of an exported track, including `COMPOSER`, `TRACKTOTAL`, and `DISCTOTAL`.

## P2-3 — Disk space and device loss during recording

`FEATURES.md` §1: "Continuously re-check during recording and warn/stop gracefully." Today disk
space is checked once, on screen appear, against `.defaultSettings` rather than the actual
format. Nothing observes `AVAudioEngineConfigurationChange`, so unplugging the USB interface
mid-recording just silently stops delivering buffers while the UI keeps counting.

**Fix**: fold a periodic disk check into the existing 20 Hz UI timer (cheap statfs, maybe every
5 s), auto-stop with a clear error when space crosses a hard floor; observe engine-configuration
and route-change notifications to pause with an error when the input device disappears.

**Acceptance**: simulated low-disk (small quota volume / injected check) stops the recording
gracefully with the partial file intact and playable; unplugging the input device mid-recording
surfaces an error within a second instead of recording silence.

## P3 — Smaller items, roughly in order of value

1. **MusicBrainz query escaping**: `search` interpolates raw user text into a Lucene query;
   an album title containing `"` (e.g. *"Heroes"*) or `:` breaks the query. Escape Lucene special
   characters before building `query`.
2. **"FLAC · lossless · N-bit — passthrough, no re-encode" label is wrong**: export decodes and
   re-encodes, and the default 10 ms fade means output isn't bit-identical at track edges. Reword
   (e.g. "FLAC · lossless · N-bit") and note fades. Also `ExportView.load` falls back to 24-bit
   when `AVLinearPCMBitDepthKey` is absent — verify the key actually exists for FLAC sources or
   read bit depth from STREAMINFO instead, so a 16-bit master can't silently export as 24-bit.
3. **`Project.modifiedAt` never updates** — set it in `RunoutDocument.snapshot(contentType:)` so
   saved manifests carry a truthful timestamp.
4. **Filename hygiene**: `FileNameTemplate.sanitizeForFilesystem` allows a leading `.` (hidden
   file) and has no length cap (HFS+/APFS: 255 UTF-8 bytes per component). Strip leading dots,
   truncate safely on a character boundary.
5. **README `## Status` is stale** (still says "M0-M7 are done") and the mockups note still
   promises real screenshots — update alongside the pending screenshot swap; consider adding
   done-markers to `ROADMAP.md`.
6. **Empty-tag noise**: `FlacMetadataWriter` writes `TITLE=`/`ARTIST=`/`ALBUM=` even when the
   value is empty — skip empty required-ish fields like the optional ones already do.
7. **Real-time-path hardening** (deliberate trade-offs today, documented here so they're not
   re-discovered): `LevelMeter` takes an `NSLock` on the tap thread (contended only by 20 Hz UI
   reads; a lock-free single-writer snapshot would be stricter), and `MarkerSnapping` re-opens
   the audio file synchronously on the main thread per marker gesture (cache one `AVAudioFile`
   per editor session).
8. **Device list is static** — no CoreAudio device-added/removed listener on macOS; the picker
   only refreshes on screen appear.

## Suggested sequencing

P0-1 and P0-2 first (small, isolated, high stakes) as one PR each. P1-2 + P1-3 travel well
together (same file/pipeline). P1-1 is UI-shaped and independent. P2 items are each a
mini-milestone with the usual real-hardware verification. P3 items can ride along with whatever
PR touches the neighborhood.
