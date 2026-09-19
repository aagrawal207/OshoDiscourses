#!/usr/bin/env python3
"""Plan or prepare the 1.16.0 listing after 1.15.0 has released. Never submits a build."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
APP = "6774409039"
VERSION = "1.16.0"
BASE_VERSION = "1.15.0"
ASSETS = ROOT / "docs/app-store/screenshots" / VERSION
RELEASED = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION"}
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"}


def asc(*arguments):
    result = subprocess.run(["asc", "--profile", "personal", "--strict-auth", *map(str, arguments)],
                            cwd=ROOT, capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return json.loads(result.stdout)


def state(version):
    attributes = version["attributes"]
    return attributes.get("appVersionState") or attributes["appStoreState"]


def screenshots(version_id):
    return asc("screenshots", "list", "--version-id", version_id, "--locale", "en-US")


def expected_set(group, sets):
    types = {"APP_IPHONE_67", "APP_IPHONE_69"} if group["family"] == "iphone" else {"APP_IPAD_PRO_3GEN_129"}
    return [entry for entry in sets if entry["set"]["attributes"]["screenshotDisplayType"] in types]


def verify_uploaded(groups, remote):
    for group in groups:
        matching = expected_set(group, remote["sets"])
        if len(matching) != 1:
            return False
        images = matching[0]["screenshots"]
        if [s["attributes"].get("sourceFileChecksum") for s in images] != [f["md5"] for f in group["files"]]:
            return False
        if any(s["attributes"].get("assetDeliveryState", {}).get("state") != "COMPLETE" for s in images):
            return False
    return True


def main(apply):
    manifest = json.loads((ASSETS / "manifest.json").read_text())
    assert (manifest["appID"], manifest["version"], manifest["locale"]) == (APP, VERSION, "en-US")
    for group in manifest["sets"]:
        for file in group["files"]:
            path = (ASSETS / file["file"]).resolve()
            assert path.is_relative_to(ASSETS.resolve())
            assert hashlib.sha256(path.read_bytes()).hexdigest() == file["sha256"]
        validation = asc("screenshots", "validate", "--path", ASSETS / group["family"],
                         "--device-type", group["displayType"])
        assert validation["errorCount"] == 0 and validation["readyFiles"] == len(group["files"])
    metadata = asc("metadata", "validate", "--dir", ROOT / "docs/app-store/metadata")
    assert metadata["valid"]
    versions = asc("versions", "list", "--app", APP, "--platform", "IOS",
                   "--version", f"{BASE_VERSION},{VERSION}")["data"]
    base = next(v for v in versions if v["attributes"]["versionString"] == BASE_VERSION)
    target = next((v for v in versions if v["attributes"]["versionString"] == VERSION), None)
    plan = {"appID": APP, "version": VERSION, "baseVersionState": state(base),
            "targetVersionID": target["id"] if target else None,
            "screenshots": sum(len(g["files"]) for g in manifest["sets"]),
            "mode": "apply" if apply else "plan"}
    if state(base) not in RELEASED:
        plan["blocked"] = "Keep 1.15.0 queued; create 1.16.0 after 1.15.0 releases."
        print(json.dumps(plan, indent=2))
        if apply:
            raise SystemExit(2)
        return
    if target and state(target) not in EDITABLE:
        raise RuntimeError(f"1.16.0 is not editable: {state(target)}")
    if not apply:
        print(json.dumps(plan, indent=2))
        return
    if target is None:
        asc("versions", "create", "--app", APP, "--version", VERSION, "--platform", "IOS",
            "--copyright", "2026 Abhishek Agrawal", "--release-type", "AFTER_APPROVAL",
            "--copy-metadata-from", BASE_VERSION, "--exclude-fields", "whatsNew")
        target = asc("versions", "list", "--app", APP, "--platform", "IOS", "--version", VERSION)["data"][0]
    target_id = target["id"]
    assert target_id != base["id"]
    before = screenshots(target_id)
    source = screenshots(base["id"])
    protected = {s["id"] for group in source["sets"] for s in group["screenshots"]}
    current = {s["id"] for group in before["sets"] for s in group["screenshots"]}
    assert not protected.intersection(current), "Source and target unexpectedly share screenshot resources"
    localization = before["versionLocalizationId"]
    asc("metadata", "push", "--app", APP, "--version", VERSION, "--platform", "IOS",
        "--dir", ROOT / "docs/app-store/metadata", "--dry-run")
    asc("metadata", "push", "--app", APP, "--version", VERSION, "--platform", "IOS",
        "--dir", ROOT / "docs/app-store/metadata")
    backup = ROOT / "build/store-assets-1.16.0-before.json"
    backup.parent.mkdir(parents=True, exist_ok=True)
    backup.write_text(json.dumps(before, indent=2) + "\n")
    for group in manifest["sets"]:
        if verify_uploaded([group], screenshots(target_id)):
            continue
        arguments = ("screenshots", "upload", "--version-localization", localization,
                     "--path", ASSETS / group["family"], "--device-type", group["displayType"], "--replace")
        asc(*arguments, "--dry-run")
        asc(*arguments, "--confirm")
    deadline = time.monotonic() + 120
    while not verify_uploaded(manifest["sets"], screenshots(target_id)):
        if time.monotonic() >= deadline:
            raise RuntimeError("Images have not all reached COMPLETE with the expected checksums and order")
        time.sleep(3)
    # Old optional device sets take precedence over Apple's scaling from the new largest set.
    for group in screenshots(target_id)["sets"]:
        if group["set"]["attributes"]["screenshotDisplayType"] in {"APP_IPHONE_61", "APP_IPHONE_65"}:
            for image in group["screenshots"]:
                assert image["id"] not in protected
                asc("screenshots", "delete", "--id", image["id"], "--confirm")
    final = screenshots(target_id)
    assert verify_uploaded(manifest["sets"], final)
    assert sum(len(g["screenshots"]) for g in final["sets"]) == 18
    print(json.dumps({"version": VERSION, "versionID": target_id, "localizationID": localization,
                      "screenshots": 18, "deliveryState": "COMPLETE", "submitted": False}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Create/update only the editable 1.16.0 listing")
    main(parser.parse_args().apply)
