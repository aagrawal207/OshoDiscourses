#!/usr/bin/env python3
"""Verify the real reader with a native synthetic fixture on dedicated demo simulators."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import plistlib
import re
import shutil
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/StoreAssets"))
from capture import AXE, BUNDLE, Capture, run


TARGETS = {
    "49212C17-1A13-4E93-B30F-4920D40E5AC6": "Osho Support iPhone mini",
    "AFA24F21-9192-4999-9105-82B0C82EA276": "Osho Support iPhone Pro Max",
    "9B09CCCD-3FEF-4666-8F78-FD9B97C51811": "Osho Support iPad mini",
}
SCOPE = "Synthetic native-translation fixture, not Osho quotations and not store artwork."


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def read_json(path):
    return json.loads(path.read_text())


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fingerprints(directory):
    require(directory.is_dir() and not directory.is_symlink(), f"Expected a real cache directory: {directory}")
    files = sorted(directory.iterdir())
    require(all(p.is_file() and not p.is_symlink() for p in files), "Cache entries must contain only regular files")
    return {p.name: sha256(p) for p in files}


def load_fixture(path):
    report = read_json(path)
    require(report.get("operation") == "production-pipeline" and report.get("outcome") == "pipeline-passed",
            "Use a successful production-pipeline report")
    fixture, document = report.get("uiFixture", {}), report["document"]
    attribution = report.get("sampleAttribution", "")
    require(fixture.get("enabled") is True and fixture.get("catalogDiscourseID") == document["discourseID"],
            "The native report must be generated with --ui-fixture for a catalog discourse")
    require("not Osho quotations" in attribution and fixture.get("sampleAttribution") == attribution,
            "The report must explicitly attribute its synthetic test paragraphs")
    require(re.fullmatch(r"[0-9a-f]{64}", document["id"]), "Invalid rendition ID")
    require(len(document["segments"]) == document["expectedSegmentCount"] >= 3,
            "Reader checks need a completed multi-passage narration")
    require([s["index"] for s in document["segments"]] == list(range(document["expectedSegmentCount"])),
            "The fixture's segment indices must be contiguous")
    require(math.isfinite(document["duration"]) and document["duration"] > 0 and document.get("audioFileName"),
            "The native narration has no completed audio")
    cache = Path(report["cacheEntryDirectory"]).expanduser()
    if not cache.is_absolute():
        cache = path.parent / cache
    require(cache.name == document["id"], "Cache directory and rendition ID differ")
    hashes = report["fileSHA256AfterReuse"]
    require(fingerprints(cache) == hashes, "Native cache files differ from the report's SHA-256 inventory")
    require(read_json(cache / "manifest.json")["document"] == document, "Manifest and reported document differ")
    return report, cache, hashes


def ax_nodes(tree):
    for node in tree:
        yield node
        yield from ax_nodes(node.get("children", []))


def scroll_frames(tree, identifier=None, enclosing=None):
    for node in tree:
        frame = node.get("frame")
        bars = [child["frame"] for child in node.get("children", []) if child.get("frame")
                and child.get("type") == "Slider" and (child.get("AXLabel") or "").startswith("Vertical scroll bar,")]
        scrolling = bool(bars) or node.get("type") in ("ScrollView", "ScrollArea", "CollectionView", "Table", "TableView")
        if frame and bars:
            # AXe can expose a SwiftUI List as a group whose direct children include its scroll indicators.
            top = max(frame["y"], min(bar["y"] for bar in bars))
            bottom = min(frame["y"] + frame["height"], max(bar["y"] + bar["height"] for bar in bars))
            frame = {**frame, "y": top, "height": bottom - top}
        current = frame if scrolling else enclosing
        if frame and (node.get("AXUniqueId") == identifier if identifier else scrolling):
            # SwiftUI can attach a container identifier to its text children.
            yield current or frame
        yield from scroll_frames(node.get("children", []), identifier, current)


def edges(frame):
    return frame["x"], frame["y"], frame["x"] + frame["width"], frame["y"] + frame["height"]


def inside(frame, bounds):
    x, y, right, bottom = edges(frame)
    bx, by, br, bb = edges(bounds)
    return right > x and bottom > y and bx <= x < right <= br and by <= y < bottom <= bb


def find(elements, *, identifier=None, label=None, value=None, element_type=None):
    types = (element_type,) if isinstance(element_type, str) else element_type
    matches = [e for e in elements if (identifier is None or e["id"] == identifier)
               and (label is None or e["label"] == label) and (value is None or e["value"] == value)
               and (types is None or e["type"] in types)]
    locations = {tuple(e["frame"][key] for key in ("x", "y", "width", "height")): e for e in matches}
    require(len(locations) <= 1, f"Ambiguous AX target: {identifier or label}: {matches}")
    return next(iter(locations.values()), None)


def clock_seconds(value):
    if not re.fullmatch(r"\d+:\d{2}(?::\d{2})?", str(value)):
        return None
    seconds = 0
    for component in value.split(":"):
        seconds = seconds * 60 + int(component)
    return seconds


def clock_values(element):
    values = re.findall(r"\d+:\d{2}(?::\d{2})?", str(element.get("value", ""))) if element else []
    if len(values) != 2:
        return None
    return [clock_seconds(value) for value in values]


class ReaderCheck(Capture):
    def launch(self, *arguments):
        super().launch("-settings.smartDownload", "0", "-settings.smartDelete", "0",
                       "-settings.defaultPlaybackRate", "1", *arguments)

    def __init__(self, options):
        native, source, hashes = load_fixture(options.report)
        super().__init__(options.udid, options.output, expected_device_name=TARGETS[options.udid])
        require(self.device["name"] == TARGETS[options.udid], "Simulator name differs from the dedicated target")
        require(self.device["state"] == "Booted", "Boot and install the demo simulator before running this tool")
        project = (ROOT / "project.yml").read_text()
        version = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', project).group(1)
        build = re.search(r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', project).group(1)
        expected = f"{version} ({build})"
        require(self.app_version == expected, f"Expected Osho Talks {expected}, found {self.app_version}")
        self.data = Path(run("xcrun", "simctl", "get_app_container", self.udid, BUNDLE, "data").strip())
        marker = read_json(self.data / ".osho-store-demo.json")
        require(marker.get("purpose") == "Screenshot demonstration data, not a real listener's history",
                "Missing or unrecognized demo marker")
        self.document = native["document"]
        self.original = next((r for r in marker["recordings"] if r["id"] == self.document["discourseID"]), None)
        require(self.original is not None, "The demo marker does not include this discourse's original recording")
        manifest = read_json(self.data / "Library/Application Support/.download_manifest.json")
        original_path = (self.data / "Documents" / manifest[self.document["discourseID"]]).resolve()
        require(original_path.is_relative_to((self.data / "Documents").resolve()) and original_path.is_file()
                and original_path.suffix.lower() in (".mp3", ".m4a", ".wav") and original_path.stat().st_size > 0,
                "The demo's original audio must already be present")
        require(not self.output.resolve().is_relative_to(self.data.resolve()), "Capture output must be outside the app container")
        self.source, self.hashes = source, hashes
        self.latest_tree = []
        self.ui_started = False
        self.accessibility_restore = {}
        self.large_text = options.large_text
        self.library_only = getattr(options, "library_only", False)
        self.follow_only = getattr(options, "follow_only", False)
        self.evidence = {
            "outcome": "running", "scope": SCOPE, "storeArtwork": False,
            "verificationScope": "reader-follow-position" if self.follow_only else
                                 "library-row-center" if self.library_only else "full-reader-workflow",
            "sampleAttribution": native["sampleAttribution"], "device": self.device["name"],
            "udid": self.udid, "appBuild": self.app_version, "largeText": self.large_text,
            "driverSHA256": sha256(Path(__file__)), "axeVersion": run(AXE, "--version").strip(),
            "nativeReport": str(options.report), "nativeReportSHA256": sha256(options.report),
            "cacheEntryDirectory": str(source), "cacheFileSHA256": hashes,
            "renditionID": self.document["id"], "catalogDiscourseID": self.document["discourseID"],
            "catalogTitle": native["uiFixture"]["catalogTitle"], "selection": self.document["selection"],
            "duration": self.document["duration"], "originalAudio": str(original_path),
            "demoMarker": marker, "steps": [],
            "scopeLimits": "Cached macOS-generated AAC playback; no simulator Translation, audible-quality or idle-timer assertion.",
        }
        self.output.mkdir(parents=True, exist_ok=False)
        self.record("preflight")

    def record(self, name, **observed):
        self.evidence["steps"].append({"step": name, "at": datetime.now(timezone.utc).isoformat(), **observed})
        (self.output / "reader-report.json").write_text(json.dumps(self.evidence, indent=2, ensure_ascii=False) + "\n")

    def seed(self):
        parent = self.data / "Library/Application Support/narrations"
        require(not parent.is_symlink(), "Narration cache root must not be a symlink")
        destination = parent / self.document["id"]
        require(destination.resolve().is_relative_to(self.data.resolve()), "Cache destination escapes the app container")
        existed = destination.exists()
        if existed:
            require(fingerprints(destination) == self.hashes, f"Existing rendition differs; preserved: {destination}")
        print(f"{SCOPE}\n{self.evidence['sampleAttribution']}", flush=True)
        run("xcrun", "simctl", "terminate", self.udid, BUNDLE, check=False)
        if not existed:
            parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(self.source, destination)
        require(fingerprints(destination) == self.hashes, "Seeded cache failed SHA-256 verification")
        self.record("seed", action="verified-existing" if existed else "copied", destination=str(destination))

    def tree(self):
        self.latest_tree = super().tree()
        return self.latest_tree

    def accessibility_preferences(self):
        exported = run("xcrun", "simctl", "spawn", self.udid, "defaults", "export", "com.apple.Accessibility", "-")
        return plistlib.loads(exported.encode())

    def enable_accessibility(self):
        preferences = self.accessibility_preferences()
        keys = ("AccessibilityEnabled", "ApplicationAccessibilityEnabled")
        require(all(type(preferences.get(key)) in (bool, int) for key in keys), "Unrecognized simulator AX preferences")
        for key in keys:
            if not preferences[key]:
                self.accessibility_restore[key] = preferences[key]
                self.record("accessibility-enable-request", restoreValues=dict(self.accessibility_restore))
                run("xcrun", "simctl", "spawn", self.udid, "defaults", "write", "com.apple.Accessibility", key, "-bool", "true")
        observed = self.accessibility_preferences()
        require(all(observed.get(key) for key in keys), "Simulator application accessibility did not enable")
        self.record("accessibility-ready", originalValues={key: preferences[key] for key in keys})

    def restore_accessibility(self):
        if not self.accessibility_restore:
            return
        for key, value in self.accessibility_restore.items():
            kind = "-bool" if type(value) is bool else "-int"
            argument = str(value).lower()
            run("xcrun", "simctl", "spawn", self.udid, "defaults", "write", "com.apple.Accessibility", key, kind, argument)
        observed = self.accessibility_preferences()
        require(all(type(observed.get(key)) is type(value) and observed[key] == value
                    for key, value in self.accessibility_restore.items()), "Simulator AX preferences did not restore")
        self.record("accessibility-restored", values=dict(self.accessibility_restore))
        self.accessibility_restore.clear()

    def launch(self, *arguments):
        self.ui_started = True
        super().launch(*arguments)
        self.record("launch", arguments=list(arguments))

    def until(self, description, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate(self.elements())
            if result:
                return result
            time.sleep(0.3)
        raise RuntimeError(f"Unmet UI expectation: {description}")

    def expect(self, **selector):
        element = self.until(str(selector), lambda elements: find(elements, **selector))
        self.record("expect", selector=selector, observed=element)
        return element

    def tap(self, *, require_whitespace=False, **selector):
        element = self.expect(**selector)
        frame = element["frame"]
        cx, cy = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
        if require_whitespace:
            require(element["id"], "Whitespace checks require an identified parent control")
            owners = [node for node in ax_nodes(self.latest_tree)
                      if node.get("AXUniqueId") == element["id"] and node.get("frame") == frame]
            labels = [node["frame"] for owner in owners for node in ax_nodes(owner.get("children", []))
                      if node.get("type") in ("StaticText", "Heading", "Image") and not node.get("children")
                      and node.get("frame") and inside(node["frame"], frame)]
            require(labels, f"No label frames exposed inside {element['id']}")
            require(not any(x <= cx <= right and y <= cy <= bottom for x, y, right, bottom in map(edges, labels)),
                    "The row center overlaps label content; it would not verify the whitespace hit area")
            self.record("row-center-whitespace-target", identifier=element["id"], rowFrame=frame,
                        tapPoint={"x": cx, "y": cy}, labelFrames=labels)
        require(inside(frame, self.latest_tree[0]["frame"]), f"Tap target is clipped: {element}")
        run(AXE, "tap", "-x", cx, "-y", cy,
            "--tap-style", "physical", "--post-delay", "0.4", "--udid", self.udid)
        self.record("tap", target=element, tapFrame=frame, tapPoint={"x": cx, "y": cy})

    def viewport(self, container=None):
        elements = self.elements()
        bounds = self.latest_tree[0]["frame"]
        container_id = container if container != "downloads" else None
        candidates = list(scroll_frames(self.latest_tree, container_id))
        require(candidates, f"No scroll container exposed by AX: {container or 'current page'}")
        frame = max(candidates, key=lambda f: f["width"] * f["height"])
        x, y, right, bottom = edges(frame)
        bx, by, br, bb = edges(bounds)
        x, y, right, bottom = max(x, bx) + 12, max(y, by) + 12, min(right, br) - 12, min(bottom, bb) - 30
        if container in ("downloads", "narration.library"):
            for node in ax_nodes(self.latest_tree):
                if node.get("frame") and (node.get("role_description") or "").casefold() == "nav bar":
                    y = max(y, node["frame"]["y"] + node["frame"]["height"] + 8)
        for element in elements:
            _, ey, _, eb = edges(element["frame"])
            if container in ("narration.reader", "narration.preparation") and element["id"] == "narration.done":
                y = max(y, eb + 8)
            if container == "narration.reader" and element["id"] in ("narration.playbackProgress", "narration.followPlayback"):
                bottom = min(bottom, ey - 12)
            if container in ("downloads", "narration.library"):
                if element["type"] == "NavigationBar":
                    y = max(y, eb + 8)
                if (element["id"] == "player.mini" or (element["type"] in ("RadioButton", "Button")
                        and element["label"] in ("Home", "Library", "Downloads", "Settings")
                        and ey > by + bounds["height"] / 2)):
                    bottom = min(bottom, ey - 12)
        require(right - x > 100 and bottom - y > 100, "No safe content area for a drag")
        return {"x": x, "y": y, "width": right - x, "height": bottom - y}

    def drag_content(self, container=None, upward=True):
        frame = self.viewport(container)
        x = frame["x"] + frame["width"] * 0.6
        start = frame["y"] + frame["height"] * (0.8 if upward else 0.2)
        end = frame["y"] + frame["height"] * (0.2 if upward else 0.8)
        run(AXE, "drag", "--start-x", x, "--start-y", start, "--end-x", x, "--end-y", end,
            "--duration", "0.6", "--steps", "60", "--post-delay", "0.5", "--udid", self.udid)
        self.record("drag", container=container, viewport=frame, upward=upward)

    def reveal(self, *, container=None, upward=True, **selector):
        direction = upward
        for _ in range(10):
            element = find(self.elements(), **selector)
            if element:
                frame = element["frame"]
                bounds = self.latest_tree[0]["frame"]
                if not inside(frame, bounds):
                    direction = frame["y"] >= bounds["y"]
                elif container is None:
                    return element
                else:
                    x, y, right, bottom = edges(self.viewport(container))
                    cx, cy = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
                    if x <= cx <= right and y <= cy <= bottom:
                        return element
                    direction = cy >= y
            self.drag_content(container, upward=direction)
        raise RuntimeError(f"Unreachable UI control: {selector}")

    def snapshot(self, name):
        name = "synthetic-native-fixture-" + name
        super().capture(name)
        path = self.output / f"{name}.json"
        metadata = {**read_json(path), "scope": SCOPE, "storeArtwork": False,
                    "sampleAttribution": self.evidence["sampleAttribution"], "renditionID": self.document["id"],
                    "verificationScope": self.evidence["verificationScope"]}
        path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n")
        (self.output / f"{name}.ax.json").write_text(json.dumps(self.tree(), indent=2, ensure_ascii=False) + "\n")
        self.record("capture", screenshot=f"{name}.png", accessibility=f"{name}.ax.json")

    def progress(self, *, identifier="narration.playbackProgress", label=None, duration=None, minimum=0, maximum=math.inf):
        duration = self.document["duration"] if duration is None else duration

        def ready(elements):
            element = find(elements, identifier=identifier, label=label)
            values = clock_values(element)
            if values and abs(values[1] - duration) <= 2 and minimum <= values[0] <= maximum:
                return {"elapsed": values[0], "duration": values[1], "accessibility": element}

        observed = self.until(f"Playback clock for {duration:.2f}s audio, elapsed in [{minimum}, {maximum}]", ready)
        self.record("progress", **observed)
        return observed["elapsed"]

    def pause_narration(self):
        self.tap(identifier="narration.togglePlayback", label="Pause narration")
        self.expect(identifier="narration.togglePlayback", label="Play narration")

    def original_progress(self):
        def ready(elements):
            slider = find(elements, label="Playback position", element_type="Slider")
            right = find(elements, label="Time remaining", element_type="Button") or find(elements, label="Total time", element_type="Button")
            if not slider or not right:
                return None
            elapsed_labels = [e for e in elements if e["type"] == "StaticText"
                              and abs(e["frame"]["x"] - slider["frame"]["x"]) < 2
                              and abs(e["frame"]["y"] - right["frame"]["y"]) < 2
                              and clock_seconds(e["label"]) is not None]
            if len(elapsed_labels) != 1 or clock_seconds(right["value"]) is None:
                return None
            elapsed = clock_seconds(elapsed_labels[0]["label"])
            duration = clock_seconds(right["value"]) + (elapsed if right["label"] == "Time remaining" else 0)
            if abs(duration - self.original["duration"]) > 2:
                return None
            # AXe exposes UIKit sliders as numeric fractions, separately from the visible clocks.
            fraction = slider["value"]
            require(isinstance(fraction, (float, int)) and abs(fraction * duration - elapsed) <= 2,
                    "The original slider and its visible time labels disagree")
            return {"elapsed": elapsed, "duration": duration, "slider": slider,
                    "elapsedLabel": elapsed_labels[0], "rightLabel": right}

        observed = self.until("Original recording clock and slider", ready)
        self.record("original-progress", **observed)

    def open_saved(self):
        self.expect(identifier="narration.done")
        self.reveal(identifier="narration.play." + self.document["id"], container="narration.preparation")
        started = time.monotonic()
        self.tap(identifier="narration.play." + self.document["id"])
        self.pause_narration()
        return time.monotonic() - started

    def assert_follow_position(self, index, phase):
        start = sum(segment["duration"] for segment in self.document["segments"][:index])
        end = start + self.document["segments"][index]["duration"]
        last = {}

        def ready(elements):
            nonlocal last
            row = find(elements, identifier=f"narration.segment.{index}")
            done = find(elements, identifier="narration.done")
            following = find(elements, identifier="narration.followPlayback")
            progress = find(elements, identifier="narration.playbackProgress")
            paused = find(elements, identifier="narration.togglePlayback", label="Play narration")
            clock = clock_values(progress)
            bars = [node["frame"] for node in ax_nodes(self.latest_tree) if node.get("frame")
                    and (node.get("role_description") or "").casefold() == "nav bar"
                    and any(child.get("AXUniqueId") == "narration.done" for child in ax_nodes(node.get("children", [])))]
            toolbar_bottom = max([edges(done["frame"])[3]] + [edges(frame)[3] for frame in bars]) if done else None
            last = {"phase": phase, "segmentIndex": index, "segmentStartSeconds": start,
                    "rowFrame": row["frame"] if row else None, "doneFrame": done["frame"] if done else None,
                    "navigationBarFrames": bars, "toolbarBottom": toolbar_bottom,
                    "followValue": following["value"] if following else None, "clock": clock,
                    "visibleSegmentIDs": [e["id"] for e in elements if (e["id"] or "").startswith("narration.segment.")]}
            if not (row and done and bars and following and progress and paused and clock):
                return None
            top = row["frame"]["y"]
            last["topClearance"] = top - toolbar_bottom
            last["footerTop"] = progress["frame"]["y"]
            if (following["value"] == "On" and math.floor(start) <= clock[0] <= math.floor(end)
                    and top >= toolbar_bottom and top + min(44, row["frame"]["height"]) <= progress["frame"]["y"]):
                return dict(last)

        try:
            observed = self.until(f"Segment {index} below the toolbar after {phase}", ready)
        except RuntimeError:
            self.record("follow-position-failed", **last)
            raise
        self.record("follow-position-verified", **observed)
        self.snapshot("follow-" + phase)

    def resume_following(self):
        following = self.expect(identifier="narration.followPlayback")
        if following["value"] == "Off":
            self.tap(identifier="narration.followPlayback")
        self.expect(identifier="narration.followPlayback", value="On")

    def exercise_follow(self):
        require(len(self.document["segments"]) >= 9, "Follow checks require the nine-passage native fixture")
        # Half speed leaves time to pause a cold resume within the final short passage; the launch override is temporary.
        launch_options = ["-settings.defaultPlaybackRate", "0.5"]
        if self.large_text:
            launch_options += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        self.launch("-debugNarration", self.document["discourseID"], *launch_options)
        self.open_saved()
        self.reveal(identifier="narration.segment.0", container="narration.reader", upward=False)
        self.tap(identifier="narration.segment.0")
        self.progress(maximum=1)
        self.resume_following()
        self.assert_follow_position(0, "zero-after-seek")

        self.drag_content("narration.reader")
        self.expect(identifier="narration.followPlayback", value="Off")
        self.resume_following()
        self.assert_follow_position(0, "zero-after-follow")

        self.tap(identifier="narration.segment.1")
        first_end = self.document["segments"][0]["duration"]
        self.progress(minimum=math.floor(first_end), maximum=math.ceil(first_end))
        self.assert_follow_position(1, "one-after-tap-seek")

        self.reveal(identifier="narration.segment.8", container="narration.reader")
        self.tap(identifier="narration.segment.8")
        late_start = sum(segment["duration"] for segment in self.document["segments"][:8])
        self.progress(minimum=math.floor(late_start), maximum=math.ceil(late_start))
        self.resume_following()
        self.assert_follow_position(8, "eight-after-seek")

        self.drag_content("narration.reader", upward=False)
        self.expect(identifier="narration.followPlayback", value="Off")
        self.resume_following()
        self.assert_follow_position(8, "eight-after-follow")

        preferences_path = self.data / "Library/Preferences" / f"{BUNDLE}.plist"
        saved = plistlib.loads(preferences_path.read_bytes()).get("narration.position." + self.document["id"])
        require(type(saved) in (int, float) and math.isfinite(saved), "No persisted narration position in the app sandbox")
        require(late_start - 0.1 <= saved < self.document["duration"], "The deliberate near-end seek was not saved")
        previous_pid = self.latest_tree[0].get("pid")
        self.record("cold-near-end-resume-start", savedSeconds=saved, previousPID=previous_pid)
        self.launch("-debugNarration", self.document["discourseID"], *launch_options)
        self.open_saved()
        current_pid = self.latest_tree[0].get("pid")
        require(previous_pid and current_pid and current_pid != previous_pid, "Near-end resume did not use a fresh app process")
        self.record("cold-near-end-new-process", previousPID=previous_pid, currentPID=current_pid)
        self.assert_follow_position(8, "eight-cold-resume")

    def exercise(self):
        launch_options = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] if self.large_text else []
        self.launch("-debugNarration", self.document["discourseID"], *launch_options)
        self.open_saved()
        self.expect(identifier="narration.followPlayback", value="On")
        self.snapshot("reader-paused")

        self.reveal(identifier="narration.segment.0", container="narration.reader", upward=False)
        self.tap(identifier="narration.segment.0")
        if self.expect(identifier="narration.followPlayback")["value"] == "Off":
            self.tap(identifier="narration.followPlayback")
        self.expect(identifier="narration.followPlayback", value="On")
        self.tap(identifier="narration.segment.0")
        self.expect(identifier="narration.followPlayback", value="On")
        self.progress(maximum=1)
        self.record("passage-tap-retains-following", segment=0, expectedStartSeconds=0)
        self.snapshot("passage-tap-follow-on")

        self.drag_content("narration.reader")
        self.expect(identifier="narration.followPlayback", value="Off")
        self.snapshot("manual-scroll-follow-off")
        self.tap(identifier="narration.followPlayback")
        self.expect(identifier="narration.followPlayback", value="On")
        self.expect(identifier="narration.segment.0")
        self.snapshot("follow-restored")

        size = self.expect(identifier="narration.textSize")["value"]
        match = re.fullmatch(r"(\d+) points", str(size))
        require(match, f"No text-size AX value: {size}")
        self.tap(identifier="narration.textSize")
        menu = self.until("Text-size choices", lambda elements: find(elements, label=f"{match[1]} pt")
                          or find(elements, label="Text size", element_type=("Button", "MenuItem")))
        if menu["label"] == "Text size":
            self.tap(label="Text size", element_type=("Button", "MenuItem"))
        self.expect(label=f"{match[1]} pt")
        choices = {e["label"] for e in self.elements() if re.fullmatch(r"\d+ pt", e["label"] or "")}
        require(len(choices) >= 2, "The text-size menu did not expose its choices")
        self.snapshot("text-size-menu")
        self.tap(label=f"{match[1]} pt")
        self.expect(identifier="narration.textSize", value=size)
        self.record("text-size-menu-choice-preserved", choice=size, availableChoices=sorted(choices))

        before = self.progress()
        self.tap(identifier="narration.togglePlayback", label="Play narration")
        self.expect(identifier="narration.togglePlayback", label="Pause narration")
        self.progress(minimum=before + 3)
        self.pause_narration()
        saved_position = self.progress()
        self.snapshot("playback-progress")

        self.tap(identifier="narration.returnToOriginal")
        self.until("Narration sheet dismissed", lambda elements: not find(elements, identifier="narration.done"))
        self.tap(identifier="pause.fill", label="Pause", element_type="Button")
        self.tap(identifier="player.mini")
        self.reveal(label="Playback position")
        self.original_progress()
        self.reveal(identifier="player.audioEnhancement")
        self.expect(label="Add bookmark", element_type="Button")
        self.snapshot("return-to-original")

        self.reveal(identifier="player.translate", upward=False)
        self.tap(identifier="player.translate")
        playback_window = self.open_saved()
        resumed = self.progress()
        # The clock rounds to seconds, and playback can run at 2× before the pause reaches the player.
        require(saved_position - 1 <= resumed <= saved_position + 2 * playback_window + 2,
                "Reopening the saved rendition did not resume its own playback position")
        self.record("saved-position-resumed", savedSeconds=saved_position, resumedSeconds=resumed,
                    playbackWindowSeconds=playback_window)
        self.snapshot("saved-rendition-reopened")

        self.exercise_library()

    def exercise_library(self):
        launch_options = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] if self.large_text else []
        self.launch(*launch_options)
        self.tap(label="Downloads", element_type=("RadioButton", "Button"))
        self.reveal(identifier="downloads.translatedNarrations", container="downloads")
        self.tap(identifier="downloads.translatedNarrations")
        self.reveal(identifier="narration.library." + self.document["id"], container="narration.library")
        self.snapshot("library-before-row-center-tap")
        self.tap(identifier="narration.library." + self.document["id"], require_whitespace=True)
        self.expect(identifier="narration.startPlayback")
        passage = self.expect(identifier="narration.segment.0")
        require(" ".join(self.document["segments"][0]["text"].split()) in " ".join(passage["label"].split()),
                "The library opened different text than the selected native fixture")
        self.record("library-row-center-opened-selected-document", renditionID=self.document["id"],
                    discourseID=self.document["discourseID"], matchedSegmentIndex=0)
        self.snapshot("library-row-center-opened-document")
        self.tap(identifier="narration.startPlayback")
        self.pause_narration()
        self.progress()
        self.snapshot("library-reader-reopened")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", choices=TARGETS, required=True)
    parser.add_argument("--report", type=Path, default=ROOT / "build/narration-translation-probe/pipeline.json")
    parser.add_argument("--output", type=Path, required=True, help="A new output directory; existing captures are preserved")
    parser.add_argument("--large-text", action="store_true", help="Use the app's temporary accessibility-size launch argument")
    focused = parser.add_mutually_exclusive_group()
    focused.add_argument("--library-only", action="store_true", help="Only verify saved-row center/whitespace activation and the selected cached narration")
    focused.add_argument("--follow-only", action="store_true", help="Verify passage/toolbar clearance after following, seeking and a cold near-end resume")
    options = parser.parse_args()
    options.report = options.report.expanduser().resolve()
    options.output = options.output.expanduser().resolve()
    check = None
    try:
        check = ReaderCheck(options)
        check.seed()
        check.enable_accessibility()
        if options.follow_only:
            check.exercise_follow()
        elif options.library_only:
            check.exercise_library()
        else:
            check.exercise()
        check.restore_accessibility()
        check.evidence["outcome"] = "passed"
        check.record("completed")
    except (Exception, KeyboardInterrupt) as error:
        message = str(error) or type(error).__name__
        if check is not None:
            check.evidence["outcome"] = "failed"
            check.record("failed", error=message)
            if check.ui_started:
                try:
                    check.snapshot("failure")
                except Exception as capture_error:
                    check.record("failure-capture-unavailable", error=str(capture_error))
                run("xcrun", "simctl", "terminate", check.udid, BUNDLE, check=False)
            try:
                check.restore_accessibility()
            except Exception as restore_error:
                check.record("accessibility-restore-failed", error=str(restore_error))
        raise SystemExit(message) from error


if __name__ == "__main__":
    main()
