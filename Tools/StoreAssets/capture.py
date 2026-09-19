#!/usr/bin/env python3
"""Inspect and capture real UI on dedicated Osho Store simulators."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "com.agraabhi.oshodiscourses"
# This is Cameron Cooke's simulator AXe, not the unrelated command on the host PATH.
AXE = ROOT / "build/store-capture-tools/axe"


def run(*args, check=True):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=60)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr}")
    return result.stdout


class Capture:
    def __init__(self, udid, output, replace=False):
        self.udid = udid
        self.output = Path(output)
        self.replace = replace
        devices = json.loads(run("xcrun", "simctl", "list", "devices", "--json"))["devices"]
        self.device = next(d for group in devices.values() for d in group if d["udid"] == udid)
        if not self.device["name"].startswith("Osho Store "):
            raise ValueError("Only dedicated Osho Store simulators can be used")
        app = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "app").strip())
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.app_version = f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"

    def tree(self):
        return json.loads(run(AXE, "describe-ui", "--udid", self.udid))

    def elements(self):
        tree = self.tree()
        bounds = tree[0]["frame"]
        stack = list(tree)
        result = []
        while stack:
            node = stack.pop()
            stack.extend(reversed(node.get("children", [])))
            frame = node.get("frame", {})
            label = node.get("AXLabel")
            identifier = node.get("AXUniqueId")
            if not (label or identifier) or frame.get("width", 0) <= 0 or frame.get("height", 0) <= 0:
                continue
            if frame["y"] + frame["height"] <= 0 or frame["y"] >= bounds["height"]:
                continue
            if frame["x"] + frame["width"] <= 0 or frame["x"] >= bounds["width"]:
                continue
            result.append({"type": node["type"], "label": label, "id": identifier,
                           "value": node.get("AXValue"), "frame": frame})
        return result

    def wait(self, *, label=None, identifier=None, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any((label is not None and e["label"] == label)
                   or (identifier is not None and e["id"] == identifier) for e in self.elements()):
                return
            time.sleep(0.4)
        raise RuntimeError(f"UI did not show {label or identifier}")

    def tap(self, *, label=None, identifier=None, element_type=None, largest=False):
        self.wait(label=label, identifier=identifier)
        matches = [e for e in self.elements()
                   if (e["id"] == identifier if identifier else e["label"] == label)
                   and (element_type is None or e["type"] == element_type)]
        if largest and matches:
            area = max(e["frame"]["width"] * e["frame"]["height"] for e in matches)
            matches = [e for e in matches if e["frame"]["width"] * e["frame"]["height"] == area]
        locations = {tuple(e["frame"][key] for key in ("x", "y", "width", "height")) for e in matches}
        if len(locations) != 1:
            raise ValueError(f"Expected one UI location for {label or identifier}: {matches}")
        x, y, width, height = locations.pop()
        fraction = 0.93 if matches[0]["type"] == "Switch" else 0.5
        run(AXE, "tap", "-x", x + width * fraction, "-y", y + height / 2,
            "--tap-style", "physical", "--post-delay", "0.7", "--udid", self.udid)

    def launch(self, *arguments):
        run("xcrun", "simctl", "terminate", self.udid, BUNDLE, check=False)
        run("xcrun", "simctl", "launch", self.udid, BUNDLE, *arguments)

    def capture(self, name, replace=None):
        self.output.mkdir(parents=True, exist_ok=True)
        destination = self.output / f"{name}.png"
        if destination.exists() and not (self.replace if replace is None else replace):
            raise FileExistsError(destination)
        time.sleep(0.7)
        run("xcrun", "simctl", "io", self.udid, "screenshot", destination)
        metadata = {"name": name, "device": self.device["name"], "udid": self.udid,
                    "capturedAt": datetime.now(timezone.utc).isoformat(), "appBuild": self.app_version}
        destination.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
        print(f"Captured {self.device['name']}: {destination.name}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--output", default="build/store-captures")
    parser.add_argument("--tap-label")
    parser.add_argument("--tap-id")
    parser.add_argument("--type")
    parser.add_argument("--largest", action="store_true")
    parser.add_argument("--name")
    parser.add_argument("--replace", action="store_true")
    options = parser.parse_args()
    capture = Capture(options.udid, options.output)
    if options.tap_label or options.tap_id:
        capture.tap(label=options.tap_label, identifier=options.tap_id,
                    element_type=options.type, largest=options.largest)
    if options.name:
        capture.capture(options.name, replace=options.replace)
    else:
        print(json.dumps(capture.elements(), ensure_ascii=False, indent=2))
