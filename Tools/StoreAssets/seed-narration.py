#!/usr/bin/env python3
"""Build a saved translation on the Mac and copy it into dedicated screenshot simulators.

The simulator cannot run Apple Translation, so NarrationFixture.swift runs the app's own
NarrationService, Apple Translation and a system voice on the Mac with the real transcript.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "com.agraabhi.oshodiscourses"
WORK = ROOT / "build/store-narration"
SOURCES = [f"OshoDiscourses/Services/{name}.swift" for name in (
    "TranslatedNarration", "NativeNarrationSpeechRenderer", "NarrationCache", "TranscriptParser",
    "TranscriptSyncModel", "NarrationService", "AppleNarrationTranslator", "NarrationLanguageSupport",
    "NarrationProgress", "NarrationJournal", "NarrationPacer", "NarrationTimeline",
)] + [f"OshoDiscourses/Resources/{name}.swift" for name in ("AlignmentCatalog", "Catalog", "OshoworldCatalog")]


def simctl(*arguments):
    return subprocess.check_output(["xcrun", "simctl", *arguments], text=True).strip()


def container(udid):
    devices = json.loads(simctl("list", "devices", "--json"))["devices"]
    device = next(d for group in devices.values() for d in group if d["udid"] == udid)
    if not device["name"].startswith("Osho Store ") or device["state"] != "Booted":
        raise SystemExit("Seeding is restricted to booted, dedicated Osho Store simulators")
    return device["name"], Path(simctl("get_app_container", udid, BUNDLE, "data"))


def digest(directory):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(directory.iterdir())}


def build(transcript, target, pace):
    binary = WORK / "bin/NarrationFixture"
    binary.parent.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "6",
                    "-target", "arm64-apple-macosx26.4", "-sdk", sdk, "-module-cache-path", str(WORK / "bin/mc"),
                    *[str(ROOT / s) for s in SOURCES], str(ROOT / "Tools/StoreAssets/NarrationFixture.swift"),
                    "-o", str(binary)], check=True)
    # AlignmentCatalog reads Bundle.main, which is the executable's directory for a command-line tool.
    shutil.copy2(ROOT / "OshoDiscourses/Resources/AlignmentCatalog.json", binary.parent)
    output = WORK / f"{Path(transcript).stem}-{target}-{pace}"
    if output.exists():
        raise SystemExit(f"Remove {output} to rebuild it")
    subprocess.run([str(binary), str(transcript), target, pace, str(output)], check=True)
    return output


def seed(udid, output, transcript):
    name, data = container(udid)
    receipt = json.loads((output / "receipt.json").read_text())
    source = output / "narrations" / receipt["documentID"]
    destination = data / "Library/Application Support/narrations" / receipt["documentID"]
    transcript_destination = data / "Library/Application Support/transcripts" / (receipt["discourseID"] + ".json")
    if destination.exists() and digest(destination) != digest(source):
        raise SystemExit("A different saved translation with this ID already exists")
    if transcript_destination.exists() and json.loads(transcript_destination.read_text())["sourceID"] != receipt["sourceID"]:
        raise SystemExit("The simulator holds a different transcript for this discourse")
    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)
    transcript_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(transcript, transcript_destination)
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, destination)
    print(f"Seeded {name}: {receipt['targetLanguage']} translation of {receipt['discourseID']}, "
          f"{receipt['passages']} passages, voice {receipt['voiceName']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transcript", type=Path, required=True,
                        help="The app's cached transcript JSON for the discourse, copied from a simulator")
    parser.add_argument("--target", default="hi")
    parser.add_argument("--pace", default="osho", choices=["osho", "natural"])
    parser.add_argument("--output", type=Path, help="Reuse an existing NarrationFixture output instead of building")
    parser.add_argument("--udid", action="append", default=[])
    options = parser.parse_args()
    built = options.output or build(options.transcript.resolve(), options.target, options.pace)
    for simulator in options.udid:
        seed(simulator, built.resolve(), options.transcript.resolve())
