#!/usr/bin/env python3
"""Build Resources/TranscriptCatalog.json: app discourse id -> oshoworld audio id.

oshoworld.com serves every discourse page from a JSON API. This script maps the
app's static catalog onto that API and records, for each discourse that has a
real transcript, the oshoworld audio `_id` (used to fetch the text) and page
slug (fallback when the API changes). Discourses whose page has no transcript
are left out so the app can show availability offline.

Matching happens in three tiers, most exact first:
  1. the discourse's oshoworld mp3 path equals the audio's `file`
  2. same upload folder, discourse number equals the audio `index`
     (the site renamed files inside many folders, e.g. "... Vol 1 01.mp3")
  3. normalised series title equals, discourse number equals `index`
     (Hindi spelling drift such as Diya/Diye, plus MANUAL_TITLE_OVERRIDES)

Usage:
  scripts/build-transcript-catalog.py [--cache-dir DIR] [--workers N] [--out PATH]

Descriptions are cached under --cache-dir so re-runs only fetch what is new.
Stdlib only; takes ~20 minutes on the first run (~4,300 description requests).
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_SWIFT = os.path.join(REPO, "OshoDiscourses", "Resources", "Catalog.swift")
DEFAULT_OUT = os.path.join(REPO, "OshoDiscourses", "Resources", "TranscriptCatalog.json")
API = "https://oshoworld.com/api/server"
USER_AGENT = "OshoDiscourses-catalog-builder/1.0 (+https://github.com/agraabhi)"
# Pages whose description is shorter than this are blank or a stray "Osho".
# The shortest real transcript seen in sampling was ~1,100 words.
MIN_WORDS = 100

# App series name -> oshoworld series title, for names tier 3 cannot normalise.
MANUAL_TITLE_OVERRIDES = {
    "Jyotish": "Jyotish # 01-02",
}


# --- App catalog ---------------------------------------------------------------

def parse_app_series(path: str) -> list[dict]:
    src = open(path, encoding="utf-8").read()
    field = re.compile(r'(\w+):\s*(?:"([^"]*)"|\.(\w+)|(\d+))')
    series = []
    for m in re.finditer(r"SeriesInfo\(([^\n]*?)\)\s*,?\s*\n", src):
        kv = {k: (a or b or c) for k, a, b, c in field.findall(m.group(1))}
        if {"name", "filePrefix", "count", "language", "urlType"} <= kv.keys():
            series.append(kv)
    return series


def trim_separators(s: str) -> str:
    return re.sub(r"[_-]+$", "", s)


def app_audio_path(s: dict, n: int) -> str:
    """Mirror of Catalog.swift buildAudioURL, path component only."""
    count = int(s["count"])
    num = str(n).zfill(3 if count >= 100 else 2)
    t = s["urlType"]
    if t == "underscore":
        base = s.get("folderName") or trim_separators(s["filePrefix"])
        sep = "" if s["filePrefix"][-1] in "_-" else "_"
        return f"/wp-content/uploads/newAudios/{base}_({count})/{s['filePrefix']}{sep}{num}.mp3"
    if t == "slug":
        return f"/wp-content/uploads/newAudios/{s['slug']}/{s['fileTitle']} {num}.mp3"
    if t == "oshoPrefix":
        lang = "Hindi Audio" if s["language"] == "hindi" else "English Audio"
        return f"/wp-content/uploads/2020/11/{lang}/OSHO-{s['filePrefix']}_{num}.mp3"
    raise ValueError(t)


def discourse_id(s: dict, n: int) -> str:
    return f"{s['language']}-{s['filePrefix']}-{n}"


# --- oshoworld API -------------------------------------------------------------

def get_json(url: str, retries: int = 4):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": USER_AGENT,
                "Content-type": "application/json",
            })
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            last = e
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"failed {url}: {last}")


def cached_json(cache_dir: str, key: str, url: str):
    path = os.path.join(cache_dir, key + ".json")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    data = get_json(url)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)
    return data


def fetch_site_audios(cache_dir: str, workers: int) -> tuple[dict, list]:
    series = []
    for lang in ("english", "hindi"):
        cat = cached_json(cache_dir, f"catalog-{lang}", f"{API}/audio/catalog/{lang}")
        series += cat["series"]
    print(f"oshoworld series: {len(series)}", file=sys.stderr)

    def fetch(s):
        return cached_json(cache_dir, f"series-{s['_id']}", f"{API}/audio/get-all-audios-list/{s['_id']}")

    audios = []
    with concurrent.futures.ThreadPoolExecutor(workers) as ex:
        for lst in ex.map(fetch, series):
            if isinstance(lst, list):
                audios += lst
    print(f"oshoworld audios: {len(audios)}", file=sys.stderr)
    return {s["_id"]: s for s in series}, audios


def fetch_word_count(cache_dir: str, audio_id: str) -> int:
    d = cached_json(cache_dir, f"desc-{audio_id}", f"{API}/audio/get-description/{audio_id}")
    desc = d.get("description") if isinstance(d, dict) else None
    if not isinstance(desc, str):
        return 0
    text = html.unescape(re.sub(r"<[^>]+>", " ", desc))
    return len(text.split())


# --- Matching ------------------------------------------------------------------

def norm_path(p: str) -> str:
    return urllib.parse.unquote(p or "").strip().lower()


def norm_title(t: str) -> str:
    t = re.sub(r"\([^)]*\)", " ", t)              # (Devanagari) / (Vol 1)
    t = re.sub(r"#?\s*\d+\s*-\s*\d+\s*$", " ", t)  # trailing "# 1-10" / "01-91"
    t = t.lower().replace("&", "and").replace("volume", "vol")
    t = re.sub(r"[^a-z0-9]+", " ", t)
    words = [w for w in t.split() if w not in {"the", "a", "an", "of", "by", "osho"}]
    return " ".join(words)


def match(app_series: list[dict], site_series: dict, audios: list) -> tuple[dict, list]:
    by_file = {norm_path(a.get("file")): a for a in audios}
    # Folder+index is only meaningful for folders that hold a single series;
    # "2020/11/Hindi Audio" holds every Hindi series and must not be used.
    folder_series: dict[str, set] = collections.defaultdict(set)
    for a in audios:
        folder_series[os.path.dirname(norm_path(a.get("file")))].add(a["series_id"])
    by_folder_index: dict[tuple[str, int], dict] = {}
    by_series_index: dict[tuple[str, int], dict] = {}
    for a in audios:
        try:
            idx = int(a.get("index"))
        except (TypeError, ValueError):
            continue
        folder = os.path.dirname(norm_path(a.get("file")))
        if len(folder_series[folder]) == 1:
            by_folder_index.setdefault((folder, idx), a)
        by_series_index.setdefault((a["series_id"], idx), a)

    titles: dict[str, list[str]] = collections.defaultdict(list)
    for sid, s in site_series.items():
        titles[norm_title(s["title"])].append(sid)
    for app_name, site_title in MANUAL_TITLE_OVERRIDES.items():
        titles[norm_title(app_name)] = [sid for sid, s in site_series.items() if s["title"] == site_title]

    mapping: dict[str, dict] = {}
    report = []
    for s in app_series:
        count = int(s["count"])
        tiers = collections.Counter()
        for n in range(1, count + 1):
            path = norm_path(app_audio_path(s, n))
            a = by_file.get(path)
            tier = "file"
            if a is None:
                a = by_folder_index.get((os.path.dirname(path), n))
                tier = "folder"
            if a is None:
                cands = titles.get(norm_title(s["name"]), [])
                if len(cands) == 1:
                    a = by_series_index.get((cands[0], n))
                    tier = "title"
            if a is None:
                tiers["unmatched"] += 1
                continue
            if a.get("language") != s["language"]:
                tiers["language-mismatch"] += 1
                continue
            tiers[tier] += 1
            mapping[discourse_id(s, n)] = {"id": a["_id"], "slug": a["slug"], "tier": tier}
        report.append((s["name"], s["language"], count, dict(tiers)))
    return mapping, report


# --- Main ----------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache-dir", default=os.path.join(REPO, "build", "transcript-crawl"))
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--skip-descriptions", action="store_true",
                    help="only match; assume every matched page has a transcript")
    args = ap.parse_args()
    os.makedirs(args.cache_dir, exist_ok=True)

    app_series = parse_app_series(CATALOG_SWIFT)
    total = sum(int(s["count"]) for s in app_series)
    print(f"app series: {len(app_series)}, discourses: {total}", file=sys.stderr)

    site_series, audios = fetch_site_audios(args.cache_dir, args.workers)
    mapping, report = match(app_series, site_series, audios)
    print(f"matched pages: {len(mapping)}/{total}", file=sys.stderr)
    print("  by tier:", dict(collections.Counter(m["tier"] for m in mapping.values())), file=sys.stderr)
    for name, lang, count, tiers in report:
        if tiers.get("unmatched") or tiers.get("language-mismatch"):
            print(f"  incomplete [{lang}] {name} ({count}): {tiers}", file=sys.stderr)

    words: dict[str, int] = {}
    if not args.skip_descriptions:
        ids = sorted({m["id"] for m in mapping.values()})
        print(f"fetching {len(ids)} descriptions with {args.workers} workers...", file=sys.stderr)
        started = time.time()
        done = 0

        def fetch(aid):
            try:
                return aid, fetch_word_count(args.cache_dir, aid)
            except Exception as e:  # keep going; missing ones just fall out of the catalog
                print(f"  ! {aid}: {e}", file=sys.stderr)
                return aid, -1

        with concurrent.futures.ThreadPoolExecutor(args.workers) as ex:
            for aid, n in ex.map(fetch, ids):
                words[aid] = n
                done += 1
                if done % 250 == 0:
                    print(f"  {done}/{len(ids)} ({time.time() - started:.0f}s)", file=sys.stderr)

    out: dict[str, dict] = {}
    blank = collections.Counter()
    for did, m in mapping.items():
        n = words.get(m["id"], MIN_WORDS if args.skip_descriptions else 0)
        if n < MIN_WORDS:
            blank[did.split("-", 1)[0]] += 1
            continue
        out[did] = {"id": m["id"], "slug": m["slug"], "words": n}

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        f.write("\n")

    per_lang = collections.Counter(did.split("-", 1)[0] for did in out)
    app_per_lang = collections.Counter()
    for s in app_series:
        app_per_lang[s["language"]] += int(s["count"])
    print(f"\nwrote {args.out}: {len(out)} discourses with transcripts", file=sys.stderr)
    for lang in ("english", "hindi"):
        print(f"  {lang}: {per_lang[lang]}/{app_per_lang[lang]} "
              f"(matched page but blank: {blank[lang]})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
