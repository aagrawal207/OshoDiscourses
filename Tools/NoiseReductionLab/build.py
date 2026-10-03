#!/usr/bin/env python3
"""Build the actual Swift DSP and vendored models as an offline macOS executable."""

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="current")
    parser.add_argument("--from-snapshot", help="Compile the Swift snapshot saved by a previous named build")
    args = parser.parse_args()
    output = ROOT / "build" / "noise-lab" / args.name
    if args.name == "baseline" and (output / "NoiseReductionLab").exists() and not args.from_snapshot:
        raise SystemExit("Preserving the baseline. Use --from-snapshot baseline to rebuild it.")
    output.mkdir(parents=True, exist_ok=True)
    bridge = ROOT / "native/deepfilter-bridge"
    library = bridge / "target/aarch64-apple-darwin/release/libdeepfilter_bridge.a"
    subprocess.run(["cargo", "build", "--release", "--locked", "--target", "aarch64-apple-darwin"], cwd=bridge, check=True)
    rn = ROOT / "OshoDiscourses/RNNoise"
    rnlib = output / "librnnoise.dylib"
    subprocess.run([
        "clang", "-O3", "-dynamiclib", "-fPIC", "-o", str(rnlib),
        "-I", str(rn / "include"), "-I", str(rn / "src"),
        *map(str, sorted((rn / "src").glob("*.c")))
    ], check=True)
    service = ROOT / "build/noise-lab" / args.from_snapshot / "source" if args.from_snapshot else ROOT / "OshoDiscourses/Services"
    sources = [service / name for name in [
        "UserSettings.swift", "PeakLimiter.swift", "VoiceFocusChain.swift",
        "PolyphaseResampler.swift", "DeepFilterProcessor.swift", "NoiseReductionProcessor.swift"
    ]]
    for name in ("RNNoiseProcessor.swift", "DenoiserStream.swift", "NoiseReductionStream.swift", "NoiseReductionTapContext.swift", "SourceAudioTimeline.swift"):
        if (service / name).exists():
            sources.append(service / name)
    sources.append(service / "main.swift" if args.from_snapshot else ROOT / "Tools/NoiseReductionLab/main.swift")
    snapshot = output / "source"
    snapshot.mkdir(exist_ok=True)
    for source in sources:
        if source.resolve() != (snapshot / source.name).resolve():
            shutil.copy2(source, snapshot / source.name)
    shutil.copy2(ROOT / "OshoDiscourses/Resources/DeepFilterNet3_onnx.tar.gz", output)
    command = [
        "swiftc", "-O", "-swift-version", "6", "-parse-as-library", "-module-name", "OshoDiscourses",
        "-target", "arm64-apple-macosx26.5",
        "-import-objc-header", str(ROOT / "OshoDiscourses/Bridging/OshoDiscourses-Bridging-Header.h"),
        "-I", str(rn / "include"), "-I", str(bridge / "include"),
        "-framework", "AVFoundation", "-framework", "Accelerate",
        *map(str, sources), str(library), str(rnlib),
        "-o", str(output / "NoiseReductionLab")
    ]
    subprocess.run(command, check=True)
    fingerprints = {source.name: hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
    fingerprints["nativeLibrary"] = hashlib.sha256(library.read_bytes()).hexdigest()
    fingerprints["model"] = hashlib.sha256((output / "DeepFilterNet3_onnx.tar.gz").read_bytes()).hexdigest()
    (output / "source-info.json").write_text(json.dumps(fingerprints, indent=2))
    print(output / "NoiseReductionLab")


if __name__ == "__main__":
    main()
