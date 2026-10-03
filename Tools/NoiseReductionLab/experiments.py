#!/usr/bin/env python3
"""Controlled real-speech mixtures and native post-filter one-variable experiments.

Human references: Open Speech Repository, voiptroubleshooter.com/open_speech.
Its recordings permit research, development, copying and modification with attribution.
The Hindi reference is macOS Lekha synthetic speech, not a human recording.
"""

import argparse
import ctypes
import json
import math
import pathlib
import subprocess
import time
import urllib.request

import numpy as np
from scipy import signal
from scipy.io import wavfile

from analyze import db, read, score

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAB = ROOT / "build/noise-lab"
RATE = 22050


def write(path, samples, rate=RATE):
    wavfile.write(path, rate, np.asarray(samples, np.float32))


def mixtures():
    output = LAB / "mixtures"
    output.mkdir(exist_ok=True)
    inputs = []
    for voice, file in [("male", "0030"), ("female", "0010")]:
        path = LAB / f"sources/osr-{voice}.wav"
        url = f"https://www.voiptroubleshooter.com/open_speech/american/OSR_us_000_{file}_8k.wav"
        if not path.exists():
            with urllib.request.urlopen(url, timeout=60) as response:
                path.write_bytes(response.read())
        rate, audio = read(path)
        audio = audio[:rate * 24]
        divisor = math.gcd(rate, RATE)
        clean = signal.resample_poly(audio, RATE // divisor, rate // divisor)
        # The same scale applies to clean speech and every noisy mixture.
        clean *= 0.5 / max(abs(clean))
        clean = np.pad(clean, (RATE * 2, RATE))
        inputs.append((voice, clean, {"source": "Open Speech Repository", "url": url, "originalRate": rate}))

    hindi = LAB / "sources/hindi-reference.wav"
    if hindi.exists():
        rate, audio = read(hindi)
        divisor = math.gcd(rate, RATE)
        clean = signal.resample_poly(audio[:rate * 24], RATE // divisor, rate // divisor)
        clean *= 0.5 / max(abs(clean))
        inputs.append(("hindi-tts", np.pad(clean, (RATE * 2, RATE)), {"source": "macOS Lekha TTS", "synthetic": True}))

    manifest = []
    for voice, clean, origin in inputs:
        write(output / f"{voice}-clean.wav", clean)
        origin["peakScale"] = 0.5
        origin["durationSeconds"] = len(clean) / RATE
        (output / f"{voice}-source.json").write_text(json.dumps(origin, indent=2))
        rng = np.random.default_rng(57138)
        time_axis = np.arange(len(clean)) / RATE
        noises = {
            "hiss": signal.sosfilt(signal.butter(2, 100, "highpass", fs=RATE, output="sos"), rng.standard_normal(len(clean))),
            "hum": np.sin(2 * np.pi * 50 * time_axis) + 0.5 * np.sin(2 * np.pi * 100 * time_axis) + 0.2 * np.sin(2 * np.pi * 150 * time_axis) + 0.08 * rng.standard_normal(len(clean)),
            "aircraft": signal.sosfilt(signal.butter(2, [140, 800], "bandpass", fs=RATE, output="sos"), rng.standard_normal(len(clean))) * (0.7 + 0.3 * np.sin(2 * np.pi * 0.09 * time_axis)),
        }
        manifest.append({"name": f"{voice}-clean", "reference": f"{voice}-clean.wav", "input": f"{voice}-clean.wav"})
        for label, noise in noises.items():
            noise *= np.sqrt(np.mean(clean ** 2) / np.mean(noise ** 2)) * 10 ** (-10 / 20)
            name = f"{voice}-{label}-10dB"
            write(output / f"{name}.wav", clean + noise)
            manifest.append({"name": name, "reference": f"{voice}-clean.wav", "input": f"{name}.wav", "globalSNRDb": 10})
        # Low-level speech checks absolute-level gates, including trailing sounds.
        name = f"{voice}-quiet"
        write(output / f"{name}.wav", clean * 10 ** (-24 / 20))
        manifest.append({"name": name, "reference": f"{name}.wav", "input": f"{name}.wav"})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"Wrote {len(manifest)} controlled cases to {output}")


def render(name):
    exe = LAB / name / "NoiseReductionLab"
    output = LAB / name / "mixtures"
    output.mkdir(exist_ok=True)
    manifest = json.loads((LAB / "mixtures/manifest.json").read_text())
    report = {}
    for item in manifest:
        rate, reference = read(LAB / "mixtures" / item["reference"])
        _, noisy = read(LAB / "mixtures" / item["input"])
        report[item["name"]] = {"input": score(reference, noisy, rate)}
        for mode in ("rnnoise", "deepFilterNet"):
            target = output / f"{item['name']}-{mode}.wav"
            process = subprocess.run([str(exe), str(LAB / "mixtures" / item["input"]), str(target), mode, "12", "focus", "0", str(len(noisy) / rate)], check=True, capture_output=True, text=True)
            _, enhanced = read(target)
            scores = score(reference, enhanced, rate)
            scores["runtime"] = json.loads(process.stdout)
            report[item["name"]][mode] = scores
            print(f"{name} {item['name']} {mode}: SI-SDR {scores['siSDR']:.2f}; STOI {scores.get('stoi', 0):.4f}", flush=True)
    (output / "report.json").write_text(json.dumps(report, indent=2))


def model_filter(samples, sample_rate, attenuation, beta):
    lib = ctypes.CDLL(str(ROOT / "native/deepfilter-bridge/target/aarch64-apple-darwin/release/libdeepfilter_bridge.dylib"))
    ptr = ctypes.POINTER(ctypes.c_float)
    lib.dfb_create.argtypes = [ctypes.c_char_p, ctypes.c_float]
    lib.dfb_create.restype = ctypes.c_void_p
    lib.dfb_destroy.argtypes = [ctypes.c_void_p]
    lib.dfb_set_post_filter_beta.argtypes = [ctypes.c_void_p, ctypes.c_float]
    lib.dfb_process_frame.argtypes = [ctypes.c_void_p, ptr, ptr, ctypes.c_size_t, ptr]
    handle = lib.dfb_create(str(ROOT / "OshoDiscourses/Resources/DeepFilterNet3_onnx.tar.gz").encode(), attenuation)
    if not handle:
        raise RuntimeError("Model failed to load")
    lib.dfb_set_post_filter_beta(handle, beta)
    divisor = math.gcd(sample_rate, 48000)
    model_in = signal.resample_poly(samples, 48000 // divisor, sample_rate // divisor).astype(np.float32)
    model_in = np.pad(model_in, (0, (-len(model_in)) % 480 + 480 * 20))
    result = np.zeros_like(model_in)
    try:
        for offset in range(0, len(model_in), 480):
            code = lib.dfb_process_frame(handle, model_in[offset:].ctypes.data_as(ptr), result[offset:].ctypes.data_as(ptr), 480, None)
            if code != 0:
                raise RuntimeError(code)
    finally:
        lib.dfb_destroy(handle)
    return signal.resample_poly(result, sample_rate // divisor, 48000 // divisor)


def post_filter():
    output = LAB / "post-filter"
    output.mkdir(exist_ok=True)
    report = {}
    manifest = json.loads((LAB / "mixtures/manifest.json").read_text())
    for item in manifest:
        rate, reference = read(LAB / "mixtures" / item["reference"])
        _, noisy = read(LAB / "mixtures" / item["input"])
        report[item["name"]] = {}
        for beta in (0, 0.01, 0.02, 0.05):
            target = output / f"{item['name']}-beta-{beta}.wav"
            if target.exists():
                _, enhanced = read(target)
            else:
                enhanced = model_filter(noisy, rate, 12, beta)
                write(target, enhanced)
            scores = score(reference, enhanced, rate)
            report[item["name"]][str(beta)] = scores
            print(f"{item['name']} beta {beta}: SI-SDR {scores['siSDR']:.2f}; STOI {scores.get('stoi', 0):.4f}", flush=True)
        (output / "report.json").write_text(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["mixtures", "render", "post-filter"])
    parser.add_argument("--name", default="current")
    args = parser.parse_args()
    if args.action == "mixtures":
        mixtures()
    elif args.action == "render":
        render(args.name)
    else:
        post_filter()


if __name__ == "__main__":
    main()
