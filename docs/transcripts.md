# Transcripts

How the lyrics-style transcript reader works, what the source provides, and
what was measured while building it.

## Source

oshoworld.com is a Next.js site backed by a JSON API under `/api/server`:

| Call | Returns |
| --- | --- |
| `audio/catalog/{english,hindi}` | series list with `_id`, `title`, `slug`, `count` |
| `audio/get-all-audios-list/{seriesId}` | every audio with `_id`, `slug`, `index`, mp3 `file` path |
| `audio/get-description/{audioId}` | `{"description": "<html>"}` — the full transcript |

The same description is embedded in each page's `__NEXT_DATA__` script, which
`TranscriptFetcher` uses as a fallback if the API changes shape.

The markup is a flat run of text: `<br>` and CRLF line breaks, `<strong>`,
`<q>` or the site's own `<cr>` tag around the quoted question or sutra, an
occasional inline `<i>`, and a trailing `<hr>`. No timestamps, no entities.

`scripts/build-transcript-catalog.py` maps the app's 5,481 discourses onto
the 5,522 audios the site lists:

1. exact mp3 path (4,558)
2. same upload folder + discourse index, only when the folder holds a single
   series (584) — the site renamed files inside many English folders
   ("The Perfect Master Vol 1 01.mp3")
3. normalised series title + index (148), or title + position for `.catalog`
   series whose site numbering has gaps (191) — Hindi spelling drift such as
   Diya/Diye, plus a manual override for "Jyotish"

All 5,481 map to a page (the 2026-09 crawl also added the 92 series the app
lacked, 1,120 discourses). Probing every page's word count found 535 blank
ones (52 English, 483 Hindi), so `TranscriptCatalog.json` lists 4,946
discourses across 317 series. The same run writes `OshoworldCatalog.json`:
the site's mp3 path for every discourse the app's URL patterns get wrong. The shortest real transcript is 481 words; the
median is 8,647.

Nothing else on the web offers per-discourse text in a structured form:
archive.org has Osho books as PDFs/EPUBs and the audio mirror item carries no
text files.

## Sync without timestamps

The highlight is an estimate: a paragraph's share of the characters is its
share of the duration, with a 50-character floor so a one-line sutra keeps a
few seconds. The listener corrects it by tapping a paragraph and choosing
"Audio is here", which pins the middle of that paragraph to the current time.
The map is piecewise linear between pins (`TranscriptSyncModel`). A new anchor
evicts any existing anchor it contradicts (same paragraph, or an earlier
paragraph pinned later, or a later one pinned earlier), so the map stays
monotonic. For iCloud, anchors from two devices are unioned and replayed
oldest-first through the same filter, which converges regardless of order.

Measured on A Bird on the Wing #1 (98 min, 93 paragraphs) against speech
alignment: the raw estimate is early by up to ~45 s through the first
quarter, because the opening question is read slowly, and within ~15 s from
the middle on. One anchor around paragraph 3 removes most of the drift.

## Timing

Paragraph start times come from three sources, in order of preference:

1. `AlignmentCatalog.json`, shipped with the app. `Tools/AlignTranscripts`
   downloads every transcribed discourse (archive mirror first, then
   oshoworld, the same order as the app), runs Apple's on-device recogniser
   over it and aligns the words to the paragraphs with the app's own
   `TranscriptAligner`. One string per discourse:
   `"<paragraphs>;<duration in tenths>;<start deltas in tenths, '-' for none>"`.
   An entry is used only when its paragraph count matches the transcript on
   screen and its duration is within 2.5 s of the file being played, so an
   edited page or a different recording falls back rather than mis-syncs.
2. On iOS 26, `SpeechAlignmentService` running the same recogniser on the
   device, for discourses the catalog does not cover.
3. The text-length estimate above.

"Audio is here" anchors apply on top of all three: an aligned start that
contradicts an anchor (earlier paragraph at a later time, or the reverse) is
dropped and the map bends to the anchor between its surviving neighbours.

With aligned timing the reader also dims every sentence of the current
paragraph except the one being spoken. Position within the paragraph is
interpolated by character share (`TranscriptSentences`), so this is not
shown for the estimate, where a sentence marker would suggest a precision
the timing does not have.

### Display blocks

oshoworld's paragraphs run to 900 characters. Paragraphs over ~360 letters
are shown as blocks of roughly 240 letters cut at sentence boundaries
(`TranscriptBlocks`), with blocks of one paragraph spaced closer than
paragraph breaks. Blocks are presentation only: alignment, read positions
and anchors stay keyed by source paragraph, so shipped timings and synced
state are unaffected. A block's time is interpolated from its character
share of the paragraph; "Play from here" seeks to the block start and
"Audio is here" on a block records `fraction` (the block's midpoint) on the
anchor, which older app versions ignore and read as the paragraph middle.

### Recognisers

English uses `SpeechTranscriber` in `en_IN` (30 locales, no Hindi). Hindi
uses `DictationTranscriber` in `hi_IN`, the keyboard-dictation model family
in the same framework (54 locales), with the `.farField` content hint. Both
return words with audio time ranges. Measured on this Mac:

| talk | recogniser | words heard / in text | paragraphs aligned | time |
|---|---|---|---|---|
| A Bird on the Wing #1 (98 min) | SpeechTranscriber en_IN | 8,799 / 9,204 | 89 / 93 | 41 s |
| Ashtavakra Maha Geeta #5 (85 min) | DictationTranscriber hi_IN | 9,754 / 10,386 | 176 / 218 | 57 s |

The unmatched Hindi paragraphs are the opening Sanskrit sutras (recited,
not spoken Hindi) and one-line paragraphs; both are interpolated between
their neighbours. The text-length estimate drifted up to 148 s on that
talk against 45 s for the English one, so Hindi gains most from alignment.

### Aligner

- tokens are lowercased letters and digits of any script; Latin diacritics
  (U+0300–036F) are dropped, other combining marks (Devanagari matras,
  virama, nukta) are kept because they distinguish words
- word trigrams that occur exactly once in both sequences are landmarks
- the longest chain of landmarks that advances through both sequences
  (patience sort LIS) drops coincidences
- each paragraph's start is the first landmark inside it, walked back to
  the paragraph's first word at the local speaking rate; paragraphs with no
  landmark within 40 words stay unmatched and are interpolated
- fewer than 12 landmarks means the recording is not this transcript, and
  nothing is returned

Notes:

- `AssetInventory.reserve(locale:)` must be called before
  `assetInstallationRequest`, or it fails with "not subscribed to
  transcription.en". The simulator reports no supported speech locales at
  all; test on a device or through the macOS tool.
- Batch throughput on an M-series Mac: ~42 s per discourse sequentially,
  ~18 s with four parallel analyzers; the full catalog takes about a day.
  `align` is resumable (one JSON per discourse in `build/alignments/`),
  `report` summarises, `merge` writes the catalog.
