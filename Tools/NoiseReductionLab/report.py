#!/usr/bin/env python3
"""Render a fixed recording matrix and export safe native/matched-level auditions."""

import argparse
import csv
import json
import pathlib
import subprocess

import numpy as np
from scipy import signal
from scipy.io import wavfile

from analyze import align, db, read, score

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAB = ROOT / "build/noise-lab"
RECORDINGS = {
    "maha-aircraft": (130, [("maha-aircraft-40m15s", 20, 30), ("maha-fading-41m30s", 95, 20)]),
    "maha-quiet": (40, [("maha-10m00s", 5, 30)]),
    "bird-opening": (35, [("bird-05m05s", 5, 25)]),
    "wisdom-hiss": (40, [("wisdom-10m00s", 5, 30)]),
}


def true_peak(samples):
    return float(np.max(np.abs(signal.resample_poly(samples, 4, 1))))


def masks(reference, rate):
    frame = int(rate * 0.02)
    n = len(reference) // frame
    levels = np.mean(reference[:n * frame].reshape(n, frame) ** 2, axis=1)
    high = np.repeat(levels >= np.quantile(levels, 0.65), frame)
    low = np.repeat(levels <= np.quantile(levels, 0.15), frame)
    return np.pad(high, (0, len(reference) - len(high))), np.pad(low, (0, len(reference) - len(low)))


def render():
    for version in ("baseline", "current"):
        for recording, (seconds, _) in RECORDINGS.items():
            for mode in ("rnnoise", "deepFilterNet"):
                suffix = "rn" if mode == "rnnoise" else "dfn"
                target = LAB / version / f"{recording}-{suffix}.wav"
                result = subprocess.run([
                    str(LAB / version / "NoiseReductionLab"),
                    str(LAB / "sources" / f"{recording}.wav"), str(target),
                    mode, "12", "focus", "0", str(seconds)
                ], check=True, capture_output=True, text=True)
                data = json.loads(result.stdout)
                print(f"{version} {recording} {mode}: RTF={data['realTimeFactor']:.3f}, peak={data['peak']:.4f}, clips={data['samplesAtOrOverFullScale']}", flush=True)


def summarize():
    evidence = LAB / "evidence"
    evidence.mkdir(exist_ok=True)
    report = {
        "listeningPerformed": False,
        "strength": {"deepFilterAttenuationDb": 12, "voiceFocus": "focus", "rnnoiseWetMix": 0.5, "outputBoost": 1},
        "interpretation": {
            "recordings": "No clean target exists. High/low-energy source windows are proxies, not a speech/noise separation or SNR estimate.",
            "controlled": "OSR male/female recordings are human speech at 8 kHz, resampled to 22.05 kHz; Hindi is explicitly synthetic. Added noise has 10 dB global SNR. SI-SDR is scale-invariant but phase/EQ-sensitive; STOI is an intelligibility proxy, not listening preference.",
            "auditions": "Each group shares headroom. Matched versions equalize RMS only on the same high-energy source windows; native versions retain actual relative levels. Estimated 4x true peaks are below -1 dBFS. Existing source clipping cannot be undone.",
            "performance": "Offline macOS release build; model loading and file I/O excluded. Phone thermals, 2x playback and sustained realtime scheduling require device validation.",
            "allocation": "The Swift streaming/buffering path is preallocated and uses try-locks. The existing native tract runtime creates tensors/ndarrays during inference, so the complete DeepFilter path is not strictly heap-allocation-free.",
        },
        "limits": [
            "The 32 kHz Bird excerpt has approximately -6 dB RNNoise gain in both high- and low-energy windows; there the effect is mainly a level reduction. Speech fidelity improvements must not be presented as universal noise cancellation.",
            "DeepFilter's steady-state quality on these recordings is broadly similar before and after. Its improvements are rate-conversion fidelity, configuration correctness and stream reliability.",
            "No blind listening results, on-device thermal measurements or target-speaker extraction claims are included."
        ],
        "recordings": {}, "clips": {},
    }
    rows = []
    for recording, (seconds, clips) in RECORDINGS.items():
        rate, reference = read(LAB / "sources" / f"{recording}.wav")
        reference = reference[:int(rate * seconds)]
        variants = {"raw": reference}
        report["recordings"][recording] = {}
        for version in ("baseline", "current"):
            for suffix in ("rn", "dfn"):
                name = f"{version}-{suffix}"
                path = LAB / version / f"{recording}-{suffix}.wav"
                _, output = read(path)
                stats = score(reference, output, rate)
                stats["runtime"] = json.loads(path.with_suffix(".wav.json").read_text())
                stats["estimated4xTruePeakDbFS"] = db(true_peak(output) ** 2)
                report["recordings"][recording][name] = stats
                _, aligned, _ = align(reference, output, rate)
                variants[name] = aligned

        for name, start, duration in clips:
            low = int(start * rate)
            high = int((start + duration) * rate)
            audio = {key: data[low:high] for key, data in variants.items()}
            speech, quiet = masks(audio["raw"], rate)
            raw_speech = np.mean(audio["raw"][speech] ** 2)
            raw_quiet = np.mean(audio["raw"][quiet] ** 2)
            target = LAB / "audition" / name
            target.mkdir(parents=True, exist_ok=True)
            report["clips"][name] = {}
            native_headroom = 0.85 / max(true_peak(data) for data in audio.values())
            matched = {key: data * np.sqrt(raw_speech / max(np.mean(data[speech] ** 2), 1e-30)) for key, data in audio.items()}
            matched_headroom = 0.85 / max(true_peak(data) for data in matched.values())
            for key, data in audio.items():
                speech_gain = db(np.mean(data[speech] ** 2) / raw_speech)
                quiet_gain = db(np.mean(data[quiet] ** 2) / raw_quiet)
                item = {
                    "highEnergyGainDb": speech_gain,
                    "lowEnergyGainDb": quiet_gain,
                    "highMinusLowGainDb": speech_gain - quiet_gain,
                    "nativeHeadroomDb": db(native_headroom ** 2),
                    "matchedHeadroomDb": db(matched_headroom ** 2),
                }
                for level, samples in [("native", data * native_headroom), ("matched", matched[key] * matched_headroom)]:
                    path = target / f"{key}-{level}.wav"
                    samples = samples.astype(np.float32)
                    wavfile.write(path, rate, samples)
                    peak = true_peak(samples)
                    if peak >= 1 or not np.isfinite(samples).all():
                        raise RuntimeError(f"Unsafe audition output: {path}")
                    item[f"{level}File"] = str(path.relative_to(ROOT))
                    item[f"{level}EstimatedTruePeakDbFS"] = db(peak ** 2)
                report["clips"][name][key] = item
                rows.append({"clip": name, "variant": key, **{k: item[k] for k in ("highEnergyGainDb", "lowEnergyGainDb", "highMinusLowGainDb")}})
        if recording == "maha-aircraft":
            windows = {"clearSpeech-41m37.10-37.28": (102.10, 102.28), "fadingSpeech-41m37.35-37.55": (102.35, 102.55)}
            report["documentedMahaGeetaSpeechWindows"] = {}
            for name, (start, end) in windows.items():
                low, high = int(start * rate), int(end * rate)
                reference_energy = np.mean(reference[low:high] ** 2)
                report["documentedMahaGeetaSpeechWindows"][name] = {
                    key: db(np.mean(data[low:high] ** 2) / reference_energy) for key, data in variants.items()
                }
    for key in ("baseline", "current"):
        path = LAB / key / "mixtures/report.json"
        if path.exists():
            report[f"{key}ControlledMixtures"] = json.loads(path.read_text())
        path = LAB / key / "resampler.json"
        if path.exists():
            report[f"{key}Resampler"] = json.loads(path.read_text())
    post_filter = LAB / "post-filter/report.json"
    if post_filter.exists():
        report["postFilterExperiment"] = json.loads(post_filter.read_text())
    for name, key in [("current/reset-latency.json", "resetLatency"), ("evidence/validation.json", "validation")]:
        path = LAB / name
        if path.exists():
            report[key] = json.loads(path.read_text())
    (evidence / "report.json").write_text(json.dumps(report, indent=2))
    with (evidence / "recording-window-gains.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    print(f"Report: {evidence / 'report.json'}")
    print(f"Auditions: {LAB / 'audition'}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--render", action="store_true")
    args = parser.parse_args()
    if args.render:
        render()
    summarize()


if __name__ == "__main__":
    main()
