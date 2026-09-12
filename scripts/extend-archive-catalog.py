#!/usr/bin/env python3
"""Add Archive.org mirror entries for app series that ArchiveCatalog.json lacks.

The archive item `osho-audio-discourses-collection` mirrors oshoworld.com and
downloads ~12x faster, so every series the app can map to it should be. This
script matches unmapped app series to archive folders by title and pairs
files to discourse numbers, then merges the new entries into the existing
JSON without touching entries already there.

Pairing rules, most exact first:
  1. the folder holds exactly `count` mp3s -> sorted order is 1..count
     (the archive renumbered gappy series contiguously, as the site did)
  2. the app series is "… Vol N" and the folder's files carrying volume N
     (…-N_01.mp3 / …_N_01.mp3) number exactly `count`
Anything else stays unmapped and falls back to oshoworld.com.

Usage:
  scripts/extend-archive-catalog.py [--archive-files PATH] [--dry-run]

--archive-files defaults to build/transcript-crawl/archive-files.json, the
response of https://archive.org/metadata/osho-audio-discourses-collection/files
(fetched if missing). Stdlib only.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_SWIFT = os.path.join(REPO, "OshoDiscourses", "Resources", "Catalog.swift")
ARCHIVE_JSON = os.path.join(REPO, "OshoDiscourses", "Resources", "ArchiveCatalog.json")
DEFAULT_FILES = os.path.join(REPO, "build", "transcript-crawl", "archive-files.json")
METADATA_URL = "https://archive.org/metadata/osho-audio-discourses-collection/files"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import util as _util  # noqa: E402

_spec = _util.spec_from_file_location("builder", os.path.join(os.path.dirname(__file__), "build-transcript-catalog.py"))
builder = _util.module_from_spec(_spec)
_spec.loader.exec_module(builder)


# App series name -> archive folder title, where the archive shortened the name.
FOLDER_ALIASES = {
    "The Book of Nothing: Hsin Hsin Ming": "Hsin Hsin Ming",
    "This, This, A Thousand Times This": "This A Thousand Times",
    "The Zen Manifesto: Freedom From Oneself": "The Zen Manifesto",
    "Zen: The Mystery and the Poetry of the Beyond": "Zen The Mystery and Poetry",
    "Zen: The Quantum Leap From Mind to No Mind": "Zen The Quantum Leap",
    "Zen: The Solitary Bird, Cuckoo of the Forest": "Zen The Solitary Bird",
    "The Path of Paradox": "Zen The Path of Paradox",
    "The Sun Rises in the Evening": "The Sun Rises in Evening",
    "Jesus Crucified Again": "Jesus Crucified Again 01",
}

# This mirror contains 293 seconds of audio despite a 91-minute MP3 header;
# the oshoworld original is complete and matches its transcript.
UNUSABLE_AUDIO = {"english-Wisdom_Of_The_Sands-3"}


def remove_unusable_audio(archive: dict) -> list[str]:
    removed = []
    for discourse_id in sorted(UNUSABLE_AUDIO):
        sid, number = discourse_id.rsplit("-", 1)
        entry = archive.get(sid)
        if entry and entry["files"].pop(number, None) is not None:
            removed.append(discourse_id)
    return removed


def norm(title: str) -> str:
    t = re.sub(r"^\d{3}-", "", title)                 # "162-Swarn Pakhi …"
    t = t.replace("– Osho World", "").replace("- Osho World", "")
    return builder.norm_title(t)


def volume_of(name: str) -> str | None:
    m = re.search(r"vol\s*(\d+)", name, re.I)
    return m.group(1) if m else None


def files_for_volume(files: list[str], vol: str) -> list[str]:
    pat = re.compile(rf"[-_]{re.escape(vol)}_\d{{2,3}}\.mp3$")
    return [f for f in files if pat.search(os.path.basename(f))]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--archive-files", default=DEFAULT_FILES)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.archive_files):
        os.makedirs(os.path.dirname(args.archive_files), exist_ok=True)
        with urllib.request.urlopen(METADATA_URL, timeout=120) as r, open(args.archive_files, "wb") as f:
            f.write(r.read())
    entries = json.load(open(args.archive_files, encoding="utf-8"))["result"]
    mp3s = sorted(e["name"] for e in entries if e["name"].endswith(".mp3"))
    pngs = {e["name"] for e in entries if e["name"].endswith(".png") and "_spectrogram" not in e["name"]}
    by_folder: dict[str, list[str]] = collections.defaultdict(list)
    for name in mp3s:
        by_folder[os.path.dirname(name)].append(name)
    folders_by_title: dict[str, list[str]] = collections.defaultdict(list)
    for folder in by_folder:
        folders_by_title[norm(os.path.basename(folder))].append(folder)

    archive = json.load(open(ARCHIVE_JSON, encoding="utf-8"))
    app_series = builder.parse_app_series(CATALOG_SWIFT)
    added: dict[str, dict] = {}
    skipped = []
    for s in app_series:
        sid = f"{s['language']}-{s['filePrefix']}"
        if sid in archive:
            continue
        count = int(s["count"])
        key = norm(FOLDER_ALIASES.get(s["name"], s["name"]))
        vol = volume_of(s["name"])
        cands = folders_by_title.get(key, [])
        if not cands and vol:
            # "The Discipline of Transcendence Vol 3" lives in ".../The Discipline of Transcendence 01-42"
            base = norm(re.sub(r"\s*vol\s*\d+\s*$", "", s["name"], flags=re.I))
            cands = folders_by_title.get(base, [])
        if len(cands) != 1:
            skipped.append((s["name"], f"{len(cands)} folder candidates"))
            continue
        folder = cands[0]
        files = by_folder[folder]
        chosen: list[str] | None = None
        if len(files) == count:
            chosen = files
        elif vol:
            sub = files_for_volume(files, vol)
            if len(sub) == count:
                chosen = sub
        if chosen is None:
            skipped.append((s["name"], f"folder has {len(files)} files for {count} discourses"))
            continue
        first_png = os.path.splitext(chosen[0])[0] + ".png"
        added[sid] = {
            "folder": folder.rstrip("/"),
            "cover": os.path.basename(first_png) if first_png in pngs else None,
            "files": {str(i + 1): os.path.basename(f) for i, f in enumerate(chosen)},
        }
        if added[sid]["cover"] is None:
            del added[sid]["cover"]

    print(f"unmapped app series: {len(added) + len(skipped)}; mapped now: {len(added)} "
          f"({sum(len(e['files']) for e in added.values())} discourses)", file=sys.stderr)
    for name, why in skipped:
        print(f"  skipped {name!r}: {why}", file=sys.stderr)
    archive.update(added)
    removed = remove_unusable_audio(archive)
    for discourse_id in removed:
        print(f"  excluded damaged mirror {discourse_id}", file=sys.stderr)
    if args.dry_run or not (added or removed):
        return 0
    with open(ARCHIVE_JSON, "w", encoding="utf-8") as f:
        json.dump(archive, f, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    print(f"wrote {ARCHIVE_JSON}: {len(archive)} series", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
