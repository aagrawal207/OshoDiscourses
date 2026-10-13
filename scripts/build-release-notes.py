#!/usr/bin/env python3
"""Build OshoDiscourses/Resources/ReleaseNotes.json from App Store Connect.

Each released version's en-US "What's New" text becomes a list of plain items,
newest first, for the in-app What's New screen. Versions not yet released can be
added from the repo's metadata drafts with --include-version, and hand-written
highlights for any version come from docs/app-store/whats-new-highlights.json.

The shipped notes vary in style (bullets, paragraphs, wrapped lines, headings), so
formatting is normalized; the wording is kept as it shipped.

Usage:
  scripts/build-release-notes.py [--include-version 1.17.0] [--cache DIR] [--offline]

--cache keeps the App Store Connect responses (default build/release-notes-cache);
--offline builds only from that cache. Requires the `asc` CLI with the `personal`
profile. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "6774409039"
OUTPUT = ROOT / "OshoDiscourses/Resources/ReleaseNotes.json"
HIGHLIGHTS = ROOT / "docs/app-store/whats-new-highlights.json"
METADATA = ROOT / "docs/app-store/metadata/version"
RELEASED_STATES = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE"}
FIRST_RELEASE = ["The first release of Osho Talks."]

BULLET = re.compile(r"^\s*(?:[•\-–*]|\d+[.)])\s+")
HEADER = re.compile(r"^\s*what'?s\s+new(\s+in\s+[\d.]+)?\s*:?\s*$", re.IGNORECASE)
SIGN_OFF = re.compile(r"^\s*thank you for listening\.?\s*$", re.IGNORECASE)


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def is_heading(line: str, previous: str, following: str) -> bool:
    """A short label such as "Downloads" or "Fixes and improvements:" that starts a new group.

    It must follow a blank line and precede a bullet; otherwise a wrapped line's last
    word or two ("background") would be mistaken for one.
    """
    text = line.strip()
    if not text or BULLET.match(line) or len(text) > 40 or re.search(r"[.!?]$", text.rstrip(":")):
        return False
    starts_group = not previous.strip()
    precedes_items = not following.strip() or bool(BULLET.match(following))
    return starts_group and precedes_items and (text.endswith(":") or bool(BULLET.match(following)))


def items(text: str) -> list[str]:
    """Split shipped notes into items: one per bullet, or per paragraph when unbulleted."""
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").split("\n")]
    result: list[str] = []
    current: list[str] = []

    def close() -> None:
        if current:
            item = re.sub(r"\s+", " ", " ".join(current)).strip()
            if item:
                result.append(item)
            current.clear()

    for index, line in enumerate(lines):
        if not line.strip():
            close()
            continue
        previous = lines[index - 1] if index > 0 else ""
        following = lines[index + 1] if index + 1 < len(lines) else ""
        if HEADER.match(line) or SIGN_OFF.match(line) or is_heading(line, previous, following):
            close()
            continue
        if BULLET.match(line):
            close()
            current.append(BULLET.sub("", line, count=1))
        else:
            # A wrapped continuation joins its item; an unbulleted paragraph starts one.
            current.append(line.strip())
    close()
    return result


def asc(*args: str) -> dict:
    output = subprocess.run(
        ["asc", "--profile", "personal", "--strict-auth", *args, "--output", "json"],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(output)


def fetch(cache: Path, offline: bool) -> dict[str, str]:
    cache.mkdir(parents=True, exist_ok=True)
    versions_file = cache / "versions.json"
    if not offline:
        versions_file.write_text(json.dumps(
            asc("versions", "list", "--app", APP_ID, "--platform", "IOS", "--paginate"), indent=1))
    notes: dict[str, str] = {}
    for version in json.loads(versions_file.read_text())["data"]:
        attributes = version["attributes"]
        if attributes.get("appVersionState") not in RELEASED_STATES:
            continue
        number = attributes["versionString"]
        local = cache / f"{number}.json"
        if not offline:
            local.write_text(json.dumps(asc("localizations", "list", "--version", version["id"]), indent=1))
        localizations = json.loads(local.read_text()).get("data", [])
        english = next((x["attributes"] for x in localizations if x["attributes"].get("locale") == "en-US"), {})
        notes[number] = english.get("whatsNew") or ""
    return notes


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--include-version", action="append", default=[], help="unreleased version from metadata drafts")
    parser.add_argument("--cache", type=Path, default=ROOT / "build/release-notes-cache")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()

    notes = fetch(args.cache, args.offline)
    for version in args.include_version:
        draft = json.loads((METADATA / version / "en-US.json").read_text())
        notes[version] = draft.get("whatsNew") or ""
    highlights = json.loads(HIGHLIGHTS.read_text()) if HIGHLIGHTS.exists() else {}

    releases = []
    for version in sorted(notes, key=version_key, reverse=True):
        entry: dict = {"version": version, "items": items(notes[version]) or FIRST_RELEASE}
        if version in highlights:
            entry["highlights"] = highlights[version]
        releases.append(entry)
    OUTPUT.write_text(json.dumps({"releases": releases}, ensure_ascii=False, indent=1) + "\n")
    print(f"Wrote {len(releases)} releases to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
