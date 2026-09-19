#!/usr/bin/env python3
"""Populate a dedicated, signed-out screenshot simulator with demonstration data."""

import argparse
from datetime import datetime, timedelta
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid


ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "com.agraabhi.oshodiscourses"
RECORDINGS = [
    {
        "id": "english-A_Bird_on_the_Wing__-1",
        "series": "A Bird on the Wing",
        "number": 1,
        "source": "build/noise-lab/sources/english-A_Bird_on_the_Wing__-1.mp3",
        "duration": 5901.912,
        "position": 1405.0,
    },
    {
        "id": "hindi-Maha_Geeta-5",
        "series": "Ashtavakra Maha Geeta",
        "number": 5,
        "source": "build/noise-lab/sources/hindi-Maha_Geeta-5.mp3",
        "duration": 5125.250612,
        "position": 1248.0,
    },
    {
        "id": "english-Wisdom_Of_The_Sands-3",
        "series": "Wisdom of The Sands",
        "number": 3,
        "source": "build/speech-probes/english-Wisdom_Of_The_Sands-3-oshoworld.mp3",
        "duration": 5387.389388,
        "position": 861.0,
    },
]


def simctl(*arguments):
    return subprocess.check_output(["xcrun", "simctl", *arguments], text=True).strip()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def target(udid):
    devices = json.loads(simctl("list", "devices", "--json"))["devices"]
    device = next(d for group in devices.values() for d in group if d["udid"] == udid)
    if not device["name"].startswith("Osho Store "):
        raise SystemExit("Seeding is restricted to dedicated Osho Store simulators")
    container = Path(simctl("get_app_container", udid, BUNDLE, "data"))
    return device, container


def seed(udid):
    device, container = target(udid)
    documents = container / "Documents"
    support = container / "Library/Application Support"
    manifest_path = support / ".download_manifest.json"
    if manifest_path.exists() or (documents / "bookmarks.json").exists():
        raise SystemExit("Use a fresh screenshot simulator; existing app data is preserved")

    catalog = json.loads((ROOT / "OshoDiscourses/Resources/TranscriptCatalog.json").read_text())
    for recording in RECORDINGS:
        assert recording["id"] in catalog
        assert (ROOT / recording["source"]).stat().st_size > 20_000_000

    manifest = {}
    for recording in RECORDINGS:
        relative = f"{recording['series']}/{recording['series']} - #{recording['number']}.mp3"
        destination = documents / "Osho Discourses" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / recording["source"], destination)
        manifest[recording["id"]] = "Osho Discourses/" + relative
    write_json(manifest_path, manifest)

    completed = [f"english-Ancient_Music_In_The_Pines-{n}" for n in range(1, 10)]
    completed += [f"hindi-Maha_Geeta-{n}" for n in range(1, 4)]
    preferences = {
        "settings.appearance": "dark",
        "settings.accentTheme": "purple",
        "settings.dailyAccentShuffle": False,
        "settings.languageFilter": "Both",
        "settings.smartDownload": False,
        "settings.smartDelete": False,
        "settings.autoPlayNext": False,
        "settings.noiseReduction": False,
        "settings.noiseReductionMode": "deepFilterNet",
        "settings.denoiseStrength": "medium",
        "settings.voiceFocusPreset": "lift",
        "settings.volumeBoost": 2.0,
        "settings.transcriptSentenceLayout": True,
        "settings.transcriptFontSize": 21.0,
        "settings.transcriptSpeechSync": False,
        "recentlyPlayed": [r["id"] for r in RECORDINGS],
        "completedDiscourseIDs": completed,
        "listenedCompletedIDs": completed[-2:],
        "allPlayedDiscourseIDs": [r["id"] for r in RECORDINGS] + completed,
    }
    for recording in RECORDINGS:
        preferences["playbackPosition_" + recording["id"]] = recording["position"]
        preferences["playbackDuration_" + recording["id"]] = recording["duration"]
    preferences_path = container / "Library/Preferences" / f"{BUNDLE}.plist"
    preferences_path.parent.mkdir(parents=True, exist_ok=True)
    with preferences_path.open("wb") as destination:
        plistlib.dump(preferences, destination, fmt=plistlib.FMT_BINARY)

    now = datetime.now()
    reference_time = now.timestamp() - 978307200
    bookmarks = []
    examples = [
        (0, 683, "Re-listen", "Listen again this weekend"),
        (0, 1405, "Meditation", "A reminder for my morning practice"),
        (1, 1248, "Profound", "Return to this section"),
        (2, 2104, "Custom", "Keep this for my next listen"),
    ]
    for index, (recording_index, timestamp, category, note) in enumerate(examples):
        recording = RECORDINGS[recording_index]
        bookmarks.append({
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"osho-store-assets/bookmark/{index}")),
            "discourseID": recording["id"],
            "seriesName": recording["series"],
            "title": f"{recording['series']} - #{recording['number']}",
            "timestamp": timestamp,
            "note": note,
            "category": category,
            "customCategory": "My notes" if category == "Custom" else None,
            "createdAt": reference_time - index * 3600,
        })
    write_json(documents / "bookmarks.json", bookmarks)

    entries = []
    for days_ago in range(29, -1, -1):
        if days_ago in (7, 14, 21):
            continue
        minutes = [32, 47, 24, 36, 42, 27, 38][days_ago % 7]
        entries.append({"date": (now - timedelta(days=days_ago)).strftime("%Y-%m-%d"),
                        "seconds": minutes * 60})
    write_json(support / "listening_stats.json", entries)
    write_json(container / ".osho-store-demo.json", {
        "purpose": "Screenshot demonstration data, not a real listener's history",
        "created": now.isoformat(),
        "recordings": [{k: v for k, v in r.items() if k != "source"} for r in RECORDINGS],
    })
    print(f"Seeded {device['name']}: three real recordings, sample bookmarks and listening history")


def repair_downloads(udid):
    device, container = target(udid)
    if not (container / ".osho-store-demo.json").exists():
        raise SystemExit("Only this tool's demonstration data can be repaired")
    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)
    manifest = {}
    for recording in RECORDINGS:
        relative = f"Osho Discourses/{recording['series']}/{recording['series']} - #{recording['number']}.mp3"
        assert (container / "Documents" / relative).stat().st_size > 20_000_000
        manifest[recording["id"]] = relative
    write_json(container / "Library/Application Support/.download_manifest.json", manifest)
    print(f"Verified download paths for {device['name']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", action="append", required=True)
    parser.add_argument("--repair-downloads", action="store_true")
    options = parser.parse_args()
    for simulator in options.udid:
        (repair_downloads if options.repair_downloads else seed)(simulator)
