# FLAC Metadata Writing Spec

`AVAudioFile` (via Core Audio's native FLAC support, available since macOS 11 / iOS 14) writes correct FLAC audio data plus a mandatory `STREAMINFO` metadata block — but it does not give us an API to write our own tag data (title, artist, cover art). This document specifies exactly how to add that metadata as a **post-processing pass** on an already-written FLAC file. Implement this in `FlacIO/FlacMetadataWriter.swift`. It should be unit-testable byte-for-byte with no dependency on real audio (a tiny synthetic FLAC fixture is enough — see "Testing" below).

Read this whole document before writing any code. The format has one specific gotcha (endianness — see below) that is easy to get backwards.

## FLAC file structure (relevant parts only)

```
"fLaC"                       — 4-byte magic number, ASCII, no null terminator
<metadata block>             — one or more, see below
<metadata block>
...
<frame data...>               — the actual compressed audio, opaque to us — never touch this
```

### Metadata block header (applies to every metadata block, including STREAMINFO)

Each metadata block starts with a 4-byte header:

```
Byte 0:      bit 7     = "last metadata block" flag (1 = this is the last metadata block before audio frames start)
             bits 6-0  = block type (7-bit unsigned)
Bytes 1-3:   length of the block's data that follows, as a 24-bit BIG-ENDIAN unsigned integer
                  (i.e. bytes[1] is most-significant, bytes[3] is least-significant)
```

Block types we care about:

| Type | Name | Notes |
|---|---|---|
| 0 | `STREAMINFO` | Written by `AVAudioFile` already. Mandatory, must be first, we do not modify its *contents*, only (possibly) its "last block" flag bit. |
| 4 | `VORBIS_COMMENT` | Title/artist/album/etc. tags. We construct this ourselves. |
| 6 | `PICTURE` | Cover art. We construct this ourselves. |

## The gotcha: endianness

FLAC's container format (block headers, `PICTURE` block fields) is **big-endian**, but the `VORBIS_COMMENT` block's internal length-prefixed strings are **little-endian** (inherited as-is from the Ogg Vorbis comment spec). This is the single most common mistake when hand-rolling a FLAC tag writer — a big-endian `VORBIS_COMMENT` block will produce a file that most players silently fail to read tags from (or crash on). Follow the byte order specified per-field below exactly; do not assume one endianness for the whole file.

## `VORBIS_COMMENT` block data (block type 4)

All integers in this block's *data* (not its 4-byte block header, which is big-endian per the header spec above) are **32-bit little-endian unsigned integers**.

```
UInt32 LE  — vendor_length (byte length of vendor_string)
bytes      — vendor_string, UTF-8, not null-terminated (recommend: "Runout <version>")
UInt32 LE  — user_comment_list_length (number of tag entries that follow)
for each entry:
    UInt32 LE  — length of this entry's string
    bytes      — the string itself, UTF-8, format "KEY=VALUE" (see field names below), not null-terminated
```

Field names (use these exact, uppercase, standard Vorbis comment keys so other players/tools read them correctly):

| Key | From |
|---|---|
| `TITLE` | `Track.title` |
| `ARTIST` | `Track.artist ?? AlbumMetadata.albumArtist` |
| `ALBUM` | `AlbumMetadata.albumTitle` |
| `ALBUMARTIST` | `AlbumMetadata.albumArtist` |
| `TRACKNUMBER` | `Track.trackNumber`, as plain decimal string, no zero-padding |
| `DISCNUMBER` | `Track.discNumber`, as plain decimal string |
| `DATE` | `Track.year ?? AlbumMetadata.year` |
| `GENRE` | `Track.genre ?? AlbumMetadata.genre` |
| `COMMENT` | `Track.comment`, only written if non-nil |

Omit any key whose resolved value is nil/empty rather than writing an empty value.

## `PICTURE` block data (block type 6)

All integers here **are big-endian** (this block follows the container's general endianness, unlike `VORBIS_COMMENT`).

```
UInt32 BE  — picture type. Use 3 ("Cover (front)").
UInt32 BE  — mime_length
bytes      — mime string, e.g. "image/jpeg" or "image/png", not null-terminated
UInt32 BE  — description_length
bytes      — description string, UTF-8 (can be empty, length 0)
UInt32 BE  — width in pixels (0 if unknown — acceptable to just read the actual image dimensions)
UInt32 BE  — height in pixels
UInt32 BE  — color depth in bits per pixel (24 for standard JPEG/PNG is a safe default)
UInt32 BE  — number of colors used for indexed-color images, or 0 if not indexed (always 0 for JPEG/PNG)
UInt32 BE  — picture_data_length
bytes      — the raw image file bytes themselves (the whole JPEG/PNG file, as-is)
```

## Write algorithm

Given a FLAC file already written by `AVAudioFile` (containing `"fLaC"` + `STREAMINFO` block with its last-block flag currently set to 1, + audio frames):

1. Read the file's first 4 bytes, confirm `"fLaC"`.
2. Read the `STREAMINFO` block header (4 bytes) immediately after. Confirm block type is 0. Read its declared length, and note the byte offset where its data ends — this is where the audio frames currently begin.
3. Build the new `VORBIS_COMMENT` block bytes (header + data, as specified above).
4. Build the new `PICTURE` block bytes (header + data), only if cover art is present for this export.
5. Assemble the output file as:
   - `"fLaC"`
   - `STREAMINFO` header **with the last-block flag bit cleared** (since more blocks now follow) + its unchanged data
   - `VORBIS_COMMENT` block header (last-block flag = 1 only if no `PICTURE` block follows) + data
   - `PICTURE` block header (last-block flag = 1) + data, if present
   - the original audio frame bytes, copied unmodified from the source file starting at the offset noted in step 2
6. Write this assembled output to a temporary file, then atomically move it into place over the original (never write in-place over a file that's still being read, and never leave a half-written file at the final path — see the error-handling rule in `ARCHITECTURE.md`).

This whole operation is a single pass: read small header portions into memory, build the two new blocks (they're tiny, a few KB at most even with a 1-2MB cover image), then stream-copy the (potentially large) audio frame section without loading it fully into memory.

## Testing

This module should have unit tests that don't require any real vinyl recording:

1. Generate a tiny synthetic FLAC file (a few milliseconds of silence or a sine tone is enough) using `AVAudioFile` directly in the test, exactly the way the real recording pipeline will.
2. Run `FlacMetadataWriter` against it with a known set of tags + a small test image.
3. Re-parse the output file's metadata blocks by hand (or with a second, independent read path) and assert the exact tag values and picture bytes round-trip correctly.
4. Assert the audio frame bytes are byte-for-byte identical before and after (metadata writing must never touch the audio data).
5. If available in the CI environment, also verify the output file is readable by an independent tool (e.g. `metaflac --list` from the `flac` command-line package, if installed on the CI runner) as a second opinion beyond our own parser — this catches bugs where our writer and our own test-reader share the same mistaken assumption.
