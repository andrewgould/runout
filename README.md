# Runout

Rip vinyl records to FLAC on macOS and iPadOS — record a side, split it into tracks on a waveform, tag each track, export lossless FLAC files.

![Recording screen](assets/mockups/01-recording.png)

Runout is for personal archival of vinyl you own, the same use case as any CD-ripping tool. It captures line-level audio from a turntable/phono preamp, writes it losslessly, and never re-encodes or lossily transcodes anything along the way.

## Features

- Record straight to a lossless master file (native FLAC via Core Audio, up to 24-bit/192kHz), with real-time level metering and clip warning.
- Split a full side into individual tracks by placing markers on the waveform, with zero-crossing snapping and optional silence-based split suggestions.
- Per-track and album-level metadata (title, artist, album, year, genre, track/disc number, cover art), with a live filename preview.
- Batch export to individually tagged, lossless FLAC files.
- Non-destructive project format — the original full-side recording is always kept, so re-splitting or re-tagging later never requires re-recording the record.
- One project file syncs between Mac and iPad via iCloud Drive/Files, no custom sync code.

See [`docs/FEATURES.md`](docs/FEATURES.md) for the full feature spec, including a section on things worth knowing about that aren't obvious from the initial ask.

## Screens

| Record | Split into tracks |
|---|---|
| ![Recording](assets/mockups/01-recording.png) | ![Waveform editor](assets/mockups/02-waveform-editor.png) |

| Tag | Export |
|---|---|
| ![Metadata](assets/mockups/03-metadata.png) | ![Export](assets/mockups/04-export.png) |

(These are layout wireframes used to drive implementation, not final screenshots — see [`docs/UI_SPEC.md`](docs/UI_SPEC.md). Once the app is running, this section should be updated with real screenshots.)

## Status

This repository currently contains the design docs and visual assets only — no Xcode project yet. Setting one up per [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is milestone M0 in [`docs/ROADMAP.md`](docs/ROADMAP.md), which also lists every milestone after it with acceptance criteria.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — tech stack, module breakdown, data flow, platform differences
- [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) — project file format and all data types
- [`docs/FLAC_METADATA_SPEC.md`](docs/FLAC_METADATA_SPEC.md) — exact byte-level spec for writing FLAC tags/cover art
- [`docs/FEATURES.md`](docs/FEATURES.md) — full functional spec
- [`docs/UI_SPEC.md`](docs/UI_SPEC.md) — screen-by-screen UI spec
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — phased build plan with acceptance criteria per milestone

## Requirements

- macOS 14+ and/or iPadOS 17+
- Xcode 16+
- A turntable feeding a line-level, RIAA-corrected signal into a Core Audio input device (e.g. via a USB turntable or a turntable through a separate phono preamp)

## Building

No Xcode project exists yet — see "Status" above. Once M0 is done: open `Runout.xcodeproj` in Xcode, select the Runout scheme, and run. No external dependencies to install — FLAC read/write is native via Core Audio (see `docs/ARCHITECTURE.md` for why).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT — see [`LICENSE`](LICENSE).
