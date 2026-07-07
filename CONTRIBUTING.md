# Contributing

Runout is built following the milestone plan in [`docs/ROADMAP.md`](docs/ROADMAP.md). If you're picking up work, find the next unchecked milestone there, read the relevant doc it references (`ARCHITECTURE.md`, `DATA_MODEL.md`, `FLAC_METADATA_SPEC.md`, `FEATURES.md`, `UI_SPEC.md`), and implement to that milestone's acceptance criteria before moving to the next one.

## Ground rules

- **`Runout.xcodeproj` is generated, not committed.** Run `xcodegen generate` after cloning and after every change to `project.yml` or to the source tree structure (new/moved files). Add new source files on disk under the paths already listed in `project.yml`'s `sources`, then regenerate — don't hand-edit the `.xcodeproj`.
- **No new third-party dependencies without discussion first** (open an issue). The MVP is deliberately built entirely on native Apple frameworks — see `ARCHITECTURE.md` for why. Adding a dependency is a real, ongoing maintenance cost for an open-source project with no dedicated build team, not a free convenience.
- **Match the existing module structure** in `ARCHITECTURE.md` rather than introducing a new one — if a change doesn't fit cleanly into an existing module, that's worth a note in the PR description, not a silent new top-level folder.
- **Don't touch the audio real-time path casually.** Anything running on the audio tap callback (`AudioEngine/`) has hard constraints (no allocation, no locks, no I/O) documented in `ARCHITECTURE.md`'s concurrency section — changes there need extra scrutiny and, ideally, a real recording test on physical hardware, not just a simulator/CI pass.
- **FLAC output must stay round-trip lossless.** Any change touching `FlacIO/` or `Export/` should be checked against `FLAC_METADATA_SPEC.md`'s testing section (byte-identical audio before/after, tags round-trip correctly).

## Filing issues

Bug reports and feature requests are both welcome as GitHub issues. For bugs, include: macOS/iPadOS version, input device/interface used, and — if possible — the smallest project file that reproduces the issue.

## License

By contributing, you agree your contributions are licensed under this project's [MIT license](LICENSE).
