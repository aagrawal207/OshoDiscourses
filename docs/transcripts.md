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

## Speech alignment (experimental)

`SpeechAlignmentService` runs Apple's on-device `SpeechTranscriber` (iOS 26)
over the downloaded mp3 and aligns the recognised words to the transcript:

- tokens are lowercased ASCII letters and digits only
- word trigrams that occur exactly once in both sequences are landmarks
- the longest chain of landmarks that advances through both sequences
  (patience sort LIS) drops coincidences
- each paragraph's start is the first landmark inside it, walked back to
  the paragraph's first word at the local speaking rate; paragraphs with no
  landmark stay nil and are interpolated by the sync model

On an M-series Mac the 98-min recording was recognised in 39 s (8,799 words)
and 89 of 93 paragraphs matched with zero ordering violations. Alignment
results stay device-local (derived data, a few KB each, and the iCloud KVS is
capped at 1 MB).

Two traps:

- `AssetInventory.reserve(locale:)` must be called before
  `assetInstallationRequest`, otherwise the framework reports
  "not subscribed to transcription.en".
- The iOS simulator reports no supported locales. Test on a device, or with
  a macOS command-line harness compiled from the same sources.

Hindi is not possible with Apple frameworks: `SpeechTranscriber` has no Hindi
model and `SFSpeechRecognizer` `hi-IN` is server-side only in one-minute
requests. Options if it matters later: vendor whisper.cpp (150–500 MB models)
or align offline and ship timestamps as data.

## Storage and sync

- Text: `Application Support/transcripts/<discourseID>.json`, ~50–60 KB each,
  excluded from backup, fetched behind each committed download and deleted
  with it. Existing downloads are backfilled a few seconds after launch, one
  at a time, stopping after three consecutive network failures.
- State: `transcript_state.json` holds anchors, the last-read paragraph, the
  alignment, and the paragraph count the data refers to. A re-fetched
  transcript with a different split drops anchors and alignment.
- iCloud: anchors and read positions for the 300 most recently active
  discourses ride in `CloudSnapshot.transcripts`. "Following the audio again"
  is stored as a timestamped tombstone (`paragraph = -1`) so it beats a stale
  position from another device instead of being resurrected by it.
