# UI Specification

Four primary screens, navigated via a persistent left-hand icon rail (top-to-bottom: Record, Edit, Tag, Export). This ordering mirrors the actual workflow left-to-right in time, and the rail should reflect which stage the current project is at (e.g. don't let a user jump to Export before any tracks exist). All mockups are wireframes for layout/interaction intent, not final pixel-perfect visual design — colors and exact spacing are a reasonable starting point (dark theme, amber accent, consistent with `assets/icon`), not a locked spec.

Shared visual language across all four screens:
- Background `#1b1c20`, panels `#232429`/`#26272d`, borders `#37383f`.
- Primary text `#e9eaed`, muted/secondary text `#9a9ba3`.
- Accent color (primary actions, active nav item, waveform trace): amber `#e8a33d`.
- Destructive/warning (record button, clip indicator): red `#d9534f`.
- Success (completed export rows): green `#6fbf73`.
- Monospace font for filenames/templates (visually distinguishes literal output text from labels).

## Screen 1 — Recording

![Recording screen mockup](../assets/mockups/01-recording.png)

**Purpose**: capture one side of a record to a lossless master file, with enough real-time feedback to catch gain problems before they're baked in.

Layout:
- Top bar: current side name ("New Recording — Side A"), input device picker (dropdown of enumerated devices), a read-only format badge showing the active sample rate/bit depth/channel count (set once per project in a settings sheet, not re-editable mid-recording).
- Left-center: two vertical level meters (L/R), each with a numeric dB peak readout below it and tick marks at 0/-12/-24/-48 dBFS. A small clip indicator dot next to the meters lights up (and latches) if either channel hits 0dBFS.
- Center: large circular Record button (red), Pause and Stop buttons beside it, and a large elapsed-time readout above them.
- Bottom: a scrolling live waveform preview strip showing roughly the last ~30 seconds of audio, with a playhead-style marker at the current position — gives a sense of what's being captured without being the full editable waveform (that's Screen 2).
- Bottom status bar: Side A / Side B tab selector (switches which side is being recorded/reviewed — a project can have multiple sides, see `DATA_MODEL.md`), and free-disk-space / estimated-remaining-time readout.

States to design for: idle (nothing recorded yet), recording, paused, and "side already has a recording" (offer re-record with a confirm, since master recordings are precious — see Features §7 in the "hadn't thought of" list).

## Screen 2 — Waveform Editor (splitting into tracks)

![Waveform editor mockup](../assets/mockups/02-waveform-editor.png)

**Purpose**: turn one continuous side recording into discrete tracks by placing markers.

Layout:
- Top toolbar: zoom control, "Snap to Zero-Crossing" toggle (default on), "Auto-Detect Tracks" button (runs silence detection, see Features §2, and proposes markers for review — it should not silently commit them), "+ Add Marker" button (adds one at the current playhead position).
- Main waveform canvas: renders the full (or zoomed) waveform for the active side, using the precomputed peak cache (`DATA_MODEL.md`) for performance rather than decoding the whole FLAC on every frame. Marker positions are drawn as vertical lines with a small flag/handle at the top (draggable). Regions between markers are tinted with a subtle alternating background so adjacent tracks are visually distinct at a glance. A dashed vertical line shows the current playhead during playback, independent of markers.
- Below the canvas: a track list showing each detected track segment (auto-numbered) with its duration, kept in sync with marker positions live as they're edited.
- Bottom: transport scrubber (draggable position, synced to the waveform/playhead) with elapsed/total time and a play button.

Interactions to design for: dragging a marker (live-updates the shaded regions and the track list durations), deleting a marker (confirm if it would merge two tracks that both already have non-default metadata, to avoid silently discarding typed-in data), and reviewing auto-detected proposed markers before they're committed (e.g. shown in a distinct color until accepted).

## Screen 3 — Track & Album Metadata

![Metadata screen mockup](../assets/mockups/03-metadata.png)

**Purpose**: enter (or fetch) title/artist/etc. for the album and each track before export.

Layout:
- Left panel: track list (same list as Screen 2's tracks), click to select and edit that track's fields on the right.
- Right panel, top section ("Album"): Album Title, Album Artist, Year, Genre fields, plus a cover-art drop zone (accepts drag-and-drop, paste, or click-to-browse). An "Apply Album Info to All Tracks" button and a "Look Up on MusicBrainz" button (Phase 2/stretch — should be visually present but can be disabled/hidden until that milestone ships) sit below the album fields.
- Right panel, bottom section ("Track N"): Title, Artist (placeholder text shows it'll inherit the album artist if left blank), Track #, Disc #.
- Bottom of the form: a live, monospace filename preview reflecting the current filename template applied to this track's current metadata (e.g. `01 - Come Together.flac`), so the user sees real output before ever reaching the export screen.

## Screen 4 — Export

![Export screen mockup](../assets/mockups/04-export.png)

**Purpose**: write final tagged FLAC files to disk.

Layout:
- Destination folder field + "Choose…" button.
- Filename template field (editable, monospace) with clickable token chips (`{artist}`, `{album}`, `{year}`, etc. — see `DATA_MODEL.md` for the full token table) that insert themselves at the cursor when clicked.
- A read-only format summary card ("FLAC · lossless, 24-bit / 96 kHz, passthrough, no re-encode") — reassurance that nothing lossy is happening, not a configurable control.
- A track list with one row per track: resolved filename, and a status column (Queued / in-progress with a per-row progress bar / ✓ Done / an error state if a write fails).
- Footer: overall progress ("2 of 5 tracks exported"), an overall progress bar, and a prominent "Export All" button.

Error state to design for: if a single track fails to write (disk full, permission denied), that row should show a clear failed state without blocking the rest of the batch, and the footer should summarize "4 of 5 exported, 1 failed" rather than a bare success/fail toggle.
