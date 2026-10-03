#!/usr/bin/env python3
"""Run DSP tests on macOS without touching the app's Xcode/simulator build."""

import argparse
import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAB = ROOT / "build/noise-lab"


def remove_function(text, name):
    start = text.index(f"    @Test func {name}(")
    if text[:start].endswith("    @MainActor\n"):
        start -= len("    @MainActor\n")
    brace = text.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[:start] + text[end:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sanitize", choices=["address"])
    parser.add_argument("--filter")
    args = parser.parse_args()
    package = LAB / "tests"
    source = package / "Tests"
    source.mkdir(parents=True, exist_ok=True)
    service_names = [
        "UserSettings", "PeakLimiter", "VoiceFocusChain", "PolyphaseResampler",
        "DenoiserStream", "RNNoiseProcessor", "DeepFilterProcessor", "NoiseReductionProcessor",
        "NoiseReductionStream", "NoiseReductionTapContext", "SourceAudioTimeline"
    ]
    for name in service_names:
        shutil.copy2(ROOT / f"OshoDiscourses/Services/{name}.swift", source)
    test_names = [
        "NoiseReductionProcessorTests", "PolyphaseResamplerTests", "DenoiserStreamTests",
        "DeepFilterLifecycleTests", "DeepFilterNetTests", "VolumeBoostTests", "NoiseDiscontinuityTests",
        "NoiseTapGenerationTests", "SourceAudioTimelineTests"
    ]
    for name in test_names:
        text = (ROOT / f"OshoDiscoursesTests/{name}.swift").read_text()
        text = text.replace("@testable import OshoDiscourses\n", "")
        if name == "DeepFilterNetTests":
            # This one assertion depends on the iOS AVPlayer service's setting enum.
            # All actual DSP/model tests still run against the real implementation.
            text = remove_function(text, "strengthMapsToAttenuationLimitNotWetMix")
        if name == "VolumeBoostTests":
            text = remove_function(text, "theBoostCeilingIsReachableThroughTheService")
        (source / f"{name}.swift").write_text(text)
    bridge = ROOT / "native/deepfilter-bridge"
    flags = [
        "-import-objc-header", str(ROOT / "OshoDiscourses/Bridging/OshoDiscourses-Bridging-Header.h"),
        "-I", str(ROOT / "OshoDiscourses/RNNoise/include"), "-I", str(bridge / "include")
    ]
    links = [str(bridge / "target/aarch64-apple-darwin/release/libdeepfilter_bridge.a"), str(LAB / "current/librnnoise.dylib")]
    manifest = f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OshoDSPTests", platforms: [.macOS("26.5")],
    targets: [.testTarget(name: "OshoDSPTests", path: "Tests",
        swiftSettings: [.unsafeFlags({json.dumps(flags)})],
        linkerSettings: [.unsafeFlags({json.dumps(links)})])]
)
'''
    (package / "Package.swift").write_text(manifest)
    options = ["--package-path", str(package), "-c", "release", "-j", "4"]
    if args.sanitize:
        options += ["--sanitize", args.sanitize, "--scratch-path", str(package / f".build-{args.sanitize}")]
    subprocess.run(["swift", "build", "--build-tests", *options], check=True)
    bin_path = pathlib.Path(subprocess.check_output(["swift", "build", "--show-bin-path", *options], text=True).strip())
    model = ROOT / "OshoDiscourses/Resources/DeepFilterNet3_onnx.tar.gz"
    shutil.copy2(model, bin_path)
    for bundle in bin_path.glob("*.xctest"):
        resources = bundle / "Contents/Resources"
        resources.mkdir(parents=True, exist_ok=True)
        shutil.copy2(model, resources)
    filters = ["--filter", args.filter] if args.filter else []
    subprocess.run(["swift", "test", "--skip-build", "--no-parallel", *options, *filters], check=True)


if __name__ == "__main__":
    main()
