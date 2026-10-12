#!/usr/bin/env python3
"""Seed verified native narration into a task-owned simulator, preserving other data."""

import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("narration_reader", Path(__file__).with_name("check-reader.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", choices=reader.TARGETS, required=True)
    parser.add_argument("--report", type=Path, default=ROOT / "build/narration-translation-probe/pipeline.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    native, source, hashes = reader.load_fixture(args.report.resolve())
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "--json"))["devices"]
    device = next(d for group in devices.values() for d in group if d["udid"] == args.udid)
    reader.require(device["name"] == reader.TARGETS[args.udid] and device["state"] == "Booted", "Wrong or unbooted simulator")
    app = Path(run("xcrun", "simctl", "get_app_container", args.udid, reader.BUNDLE, "app"))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    project = (ROOT / "project.yml").read_text()
    version = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', project).group(1)
    build = re.search(r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', project).group(1)
    reader.require(info["CFBundleShortVersionString"] == version and info["CFBundleVersion"] == build, "Wrong app build")
    built = ROOT / "build/TranslationDerivedData/Build/Products/Debug-iphonesimulator/OshoDiscourses.app"
    reader.require(built.is_dir() and reader.sha256(app / info["CFBundleExecutable"]) == reader.sha256(built / info["CFBundleExecutable"]),
                   "Installed app does not match the verified Debug build")
    data = Path(run("xcrun", "simctl", "get_app_container", args.udid, reader.BUNDLE, "data"))
    marker_path = data / ".osho-store-demo.json"
    manifest_path = data / "Library/Application Support/.download_manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    marker = json.loads(marker_path.read_text()) if marker_path.exists() else {}
    reader.require(not manifest or marker.get("purpose") == "Screenshot demonstration data, not a real listener's history",
                   "Refusing to modify downloads without a test marker")
    document = native["document"]
    relative = "Osho Discourses/Narration Test/Original test audio.wav"
    reader.require(document["discourseID"] not in manifest or manifest[document["discourseID"]] == relative,
                   "Refusing to replace a different original recording")
    audio = data / "Documents" / relative
    transcript = data / "Library/Application Support/transcripts" / (document["discourseID"] + ".json")
    destination = data / "Library/Application Support/narrations" / document["id"]
    for path in [audio, transcript, destination, marker_path, manifest_path]:
        reader.require(path.resolve().is_relative_to(data.resolve()), "Fixture path escapes the app container")
    reader.require(not args.output.resolve().is_relative_to(data.resolve()), "Evidence must be outside the app container")
    if destination.exists():
        reader.require(reader.fingerprints(destination) == hashes, "A different cached rendition already exists")
    if audio.exists():
        with wave.open(str(audio)) as file:
            reader.require(file.getnframes() == 180 * 16000 and file.getframerate() == 16000, "Unexpected test audio")
    args.output.mkdir(parents=True, exist_ok=False)
    for path in [marker_path, manifest_path]:
        if path.exists(): shutil.copy2(path, args.output / path.name)
    subprocess.run(["xcrun", "simctl", "terminate", args.udid, reader.BUNDLE], capture_output=True)
    if transcript.exists(): shutil.copy2(transcript, args.output / "previous-transcript.json")
    transcript.parent.mkdir(parents=True, exist_ok=True)
    transcript.write_text(json.dumps(native["sourceTranscript"]))
    audio.parent.mkdir(parents=True, exist_ok=True)
    if not audio.exists():
        with wave.open(str(audio), "wb") as file:
            file.setnchannels(1)
            file.setsampwidth(2)
            file.setframerate(16000)
            for _ in range(180): file.writeframes(b"\0" * 32000)
    with wave.open(str(audio)) as file:
        reader.require(file.getnframes() == 180 * 16000 and file.getframerate() == 16000, "Unexpected test audio")
    manifest[document["discourseID"]] = relative
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest))
    recordings = [entry for entry in marker.get("recordings", []) if entry.get("id") != document["discourseID"]]
    recordings.append({"id": document["discourseID"], "duration": 180})
    marker.update(purpose="Screenshot demonstration data, not a real listener's history",
                  sampleAttribution=native["sampleAttribution"], recordings=recordings)
    marker_path.write_text(json.dumps(marker))
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, destination)
    reader.require(reader.fingerprints(destination) == hashes, "Copied narration failed verification")
    receipt = {"device": device["name"], "udid": args.udid, "renditionID": document["id"],
               "discourseID": document["discourseID"], "segmentIndex": 2,
               "segmentStart": sum(s["duration"] for s in document["segments"][:2]),
               "sourceReport": str(args.report.resolve()), "cacheHashes": hashes,
               "attribution": native["sampleAttribution"]}
    (args.output / "seed.json").write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
