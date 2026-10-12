#!/usr/bin/env python3
"""Compile the native probe and save bounded, independent CLI observations."""

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "narration-translation-probe"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def run(command, name, timeout):
    started = time.monotonic()
    timed_out = False
    with (OUT / f"{name}.stdout.jsonl").open("wb") as stdout, (OUT / f"{name}.stderr.log").open("wb") as stderr:
        try:
            process = subprocess.run(command, cwd=ROOT, stdout=stdout, stderr=stderr, timeout=timeout, check=False)
            code = process.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            code = None
    result = {
        "command": [str(argument) for argument in command],
        "exitCode": code,
        "externalTimeout": timed_out,
        "hardDeadlineExceeded": code == 124,
        "timeoutSeconds": timeout,
        "elapsedSeconds": round(time.monotonic() - started, 3),
        "stdout": str(OUT / f"{name}.stdout.jsonl"),
        "stderr": str(OUT / f"{name}.stderr.log"),
    }
    events = []
    for line in (OUT / f"{name}.stdout.jsonl").read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)
    completed = next((event for event in reversed(events) if event.get("event") == "completed"), None)
    if completed is not None:
        result["report"] = str(OUT / f"{name}.json")
        result["outcome"] = completed["outcome"]
        write_json(OUT / f"{name}.json", completed)
    elif name.startswith("compile") and code == 0:
        result["outcome"] = "compiled"
    else:
        result["outcome"] = "timeout" if timed_out or code == 124 else "no-completed-native-report"
    if events:
        result["lastEvent"] = events[-1] if completed is None else {"event": "completed"}
    write_json(OUT / f"{name}.process.json", result)
    print(f"{name}: {result['outcome']} (exit={code}, {result['elapsedSeconds']}s)", flush=True)
    return result, completed


def compiler_command(sources, binary, sdk):
    return [
        "xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "6",
        "-strict-concurrency=complete", "-warnings-as-errors", "-target", "arm64-apple-macosx26.4",
        "-sdk", sdk, "-module-cache-path", str(OUT / "ModuleCache"),
        *[str(source) for source in sources], "-o", str(binary),
    ]


def compact_summary(summary):
    for entry in summary["inventories"]:
        pairs = entry.pop("installedPairs", None)
        if pairs is not None:
            entry["installedPairCount"] = len(pairs)
            entry["installedTargetsFromEnglish"] = [pair["targetLanguage"] for pair in pairs if pair["sourceLanguage"] == "en"]
            entry["installedTargetsFromHindi"] = [pair["targetLanguage"] for pair in pairs if pair["sourceLanguage"] == "hi"]
    if summary["compilation"]["exitCode"] == 0:
        summary["compilation"]["outcome"] = "compiled"
        write_json(OUT / "compile.process.json", summary["compilation"])
    write_json(OUT / "summary.json", summary)


def speech():
    summary = json.loads((OUT / "summary.json").read_text())
    compact_summary(summary)
    sources = [
        ROOT / "OshoDiscourses/Services" / name for name in (
            "TranslatedNarration.swift", "NativeNarrationSpeechRenderer.swift", "NarrationCache.swift",
            "TranscriptParser.swift", "TranscriptSyncModel.swift",
        )
    ]
    before = {str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
    bridge = ROOT / "Tools/NarrationTranslationProbe/SpeechProbe.swift"
    binary = OUT / "NarrationTranslationSpeechProbe"
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True, timeout=15).strip()
    compilation, _ = run(compiler_command(sources + [bridge], binary, sdk), "compile-speech", 120)
    after = {str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
    provenance = {
        "readOnlyAppSourcesSHA256": before,
        "stableDuringCompilation": before == after,
        "bridgeSHA256": hashlib.sha256(bridge.read_bytes()).hexdigest(),
        "compilation": compilation,
        "scope": "Previously recorded real native Translation output -> production renderer and cache; no injected translator.",
    }
    write_json(OUT / "speech-production-sources.json", provenance)
    if compilation["exitCode"] != 0 or before != after:
        raise SystemExit("Speech bridge build failed or app sources changed; inspect compile-speech.stderr.log and provenance.")
    summary["speech"] = []
    for entry in summary["translations"]:
        result = entry["result"]
        if result is None or result["outcome"] != "translated" or entry["source"] not in ("en", "hi"):
            continue
        name = f"speech-{entry['strategy']}-{entry['source']}-{entry['target']}"
        process, report = run([str(binary), entry["process"]["report"], str(OUT / name)], name, 55)
        summary["speech"].append({"process": process, "result": report})
    summary["speechFinishedAt"] = datetime.now(timezone.utc).isoformat()
    compact_summary(summary)


def pipeline(ui_fixture=None, target="es"):
    OUT.mkdir(parents=True, exist_ok=True)
    sources = [
        ROOT / "OshoDiscourses/Services" / name for name in (
            "TranslatedNarration.swift", "NativeNarrationSpeechRenderer.swift", "NarrationCache.swift",
            "TranscriptParser.swift", "TranscriptSyncModel.swift", "NarrationService.swift",
            "AppleNarrationTranslator.swift", "NarrationLanguageSupport.swift",
        )
    ] + [ROOT / "OshoDiscourses/Resources" / name for name in ("Catalog.swift", "OshoworldCatalog.swift")]
    before = {str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
    probe = ROOT / "Tools/NarrationTranslationProbe/PipelineProbe.swift"
    binary = OUT / "NarrationTranslationPipelineProbe"
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True, timeout=15).strip()
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    compilation, _ = run(compiler_command(sources + [probe], binary, sdk), "compile-pipeline", 120)
    after_compile = {str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
    provenance = {
        "runID": run_id,
        "platform": platform.platform(),
        "compiler": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True, stderr=subprocess.STDOUT, timeout=15).strip(),
        "sdk": sdk,
        "readOnlyAppSourcesSHA256": before,
        "stableDuringCompilation": before == after_compile,
        "probeSHA256": hashlib.sha256(probe.read_bytes()).hexdigest(),
        "runnerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "compilation": compilation,
        "scope": "Real macOS NarrationService + AppleNarrationTranslator + NativeNarrationSpeechRenderer + NarrationCache. No app UI or physical iPhone execution.",
        "expectedParagraphCount": 9,
        "expectedTranslationBatchSizes": [4, 4, 1],
        "uiFixtureDiscourseID": ui_fixture,
        "targetLanguage": target,
        "inventoryRerun": False,
    }
    write_json(OUT / "pipeline-production-sources.json", provenance)
    if compilation["exitCode"] != 0 or before != after_compile:
        raise SystemExit("Pipeline build failed or app sources changed; inspect compile-pipeline.stderr.log and provenance.")
    command = [str(binary), str(OUT / f"pipeline-{run_id}")]
    command.extend(["--target", target])
    if ui_fixture is not None:
        command.extend(["--ui-fixture", ui_fixture])
    process, report = run(command, "pipeline", 200)
    after_run = {str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
    provenance["stableThroughExecution"] = before == after_run
    provenance["process"] = process
    provenance["finishedAt"] = datetime.now(timezone.utc).isoformat()
    write_json(OUT / "pipeline-production-sources.json", provenance)
    write_json(OUT / f"pipeline-{run_id}.provenance.json", provenance)
    if report is not None:
        write_json(OUT / f"pipeline-{run_id}.json", report)
    if process["exitCode"] != 0 or report is None or report["outcome"] != "pipeline-passed" or before != after_run:
        raise SystemExit("Native pipeline did not pass; inspect pipeline.process.json and native output.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--pipeline", action="store_true", help="Verify nine original test paragraphs through the production native pipeline.")
    mode.add_argument("--speech", action="store_true", help="Render previously recorded native translation output.")
    parser.add_argument(
        "--ui-fixture", metavar="CATALOG_DISCOURSE_ID",
        help="With --pipeline, label the test cache with a real Catalog ID for manual simulator seeding; text remains original test material.",
    )
    parser.add_argument("--target", default="es", help="Target language for the native pipeline (default: es).")
    arguments = parser.parse_args()
    if arguments.ui_fixture is not None and (not arguments.pipeline or not arguments.ui_fixture.strip()):
        parser.error("--ui-fixture requires --pipeline and a nonempty catalog discourse ID")
    if arguments.pipeline:
        pipeline(arguments.ui_fixture, arguments.target)
        return
    if arguments.speech:
        speech()
        return
    OUT.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True, timeout=15).strip()
    interface = Path(sdk) / "System/Library/Frameworks/Translation.framework/Modules/Translation.swiftmodule/arm64e-apple-macos.swiftinterface"
    shutil.copyfile(interface, OUT / "Translation.swiftinterface")
    metadata = {
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "macOS": subprocess.check_output(["sw_vers"], text=True, timeout=15).strip(),
        "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True, timeout=15).strip(),
        "compiler": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True, stderr=subprocess.STDOUT, timeout=15).strip(),
        "sdk": sdk,
        "interface": str(interface),
        "restrictions": {
            "sessionInitializer": "installedSource only",
            "assetDownloadsRequested": False,
            "prepareTranslationCalled": False,
            "permissionOrEntitlementChanges": False,
            "simulatorUsed": False,
            "xcodebuildUsed": False,
            "appSourcesCompiled": False,
            "audioInput": False,
            "sample": "Original philosophical test text, not an Osho quotation.",
            "network": "No network APIs in this probe; text is passed only to Apple's on-device Translation framework.",
        },
        "publicDocumentation": [
            "https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:preferredstrategy:)",
            "https://developer.apple.com/documentation/translation/languageavailability/status",
            "https://developer.apple.com/documentation/translation/translationsession/strategy",
        ],
    }
    write_json(OUT / "environment.json", metadata)
    binary = OUT / "NarrationTranslationProbe"
    command = compiler_command([ROOT / "Tools/NarrationTranslationProbe/main.swift"], binary, sdk)
    compilation, _ = run(command, "compile", 120)
    if compilation["exitCode"] != 0:
        raise SystemExit(f"Compilation failed: {compilation['stderr']}")
    summary = {"environment": str(OUT / "environment.json"), "compilation": compilation, "inventories": [], "translations": []}
    for strategy in ("lowLatency", "highFidelity"):
        process, report = run([str(binary), "inventory", strategy], f"inventory-{strategy}", 85)
        entry = {"strategy": strategy, "process": process}
        if report:
            entry["supportedLanguages"] = report["supportedLanguages"]
            entry["statusCounts"] = report["statusCounts"]
            entry["installedPairs"] = [pair for pair in report["pairs"] if pair["status"] == "installed"]
            entry["requestedPairs"] = [
                pair for pair in report["pairs"]
                if pair["sourceLanguage"] in ("en", "hi", "es") and pair["targetLanguage"] in ("en", "hi", "es")
            ]
        summary["inventories"].append(entry)
        compact_summary(summary)
    for strategy in ("lowLatency", "highFidelity"):
        for source, target in (("en", "hi"), ("hi", "en"), ("en", "es"), ("hi", "es")):
            process, report = run(
                [str(binary), "translate", strategy, source, target], f"translate-{strategy}-{source}-{target}", 35
            )
            summary["translations"].append({"strategy": strategy, "source": source, "target": target, "process": process, "result": report})
            compact_summary(summary)
    summary["finishedAt"] = datetime.now(timezone.utc).isoformat()
    summary["successfulNativeTranslations"] = sum(
        entry["result"] is not None and entry["result"].get("outcome") == "translated"
        for entry in summary["translations"]
    )
    compact_summary(summary)
    print(f"Native translations succeeded: {summary['successfulNativeTranslations']}; evidence: {OUT / 'summary.json'}", flush=True)


if __name__ == "__main__":
    main()
