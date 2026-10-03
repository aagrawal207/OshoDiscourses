#!/usr/bin/env python3
"""Compare one continuous excerpt across the discontinuity-handling change."""

import json
import pathlib
import subprocess

import numpy as np
from scipy.io import wavfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAB = ROOT / "build/noise-lab"


def main():
    output = LAB / "discontinuity/continuity-check"
    output.mkdir(parents=True, exist_ok=True)
    report = {}
    for mode in ("rnnoise", "deepFilterNet"):
        audio = []
        for version in ("current", "discontinuity"):
            path = output / f"{mode}-{version}.wav"
            subprocess.run([
                str(LAB / version / "NoiseReductionLab"),
                str(LAB / "sources/maha-aircraft.wav"), str(path),
                mode, "12", "focus", "100", "10"
            ], check=True, capture_output=True)
            rate, samples = wavfile.read(path)
            audio.append(samples)
        difference = float(np.max(np.abs(audio[0].astype(np.float64) - audio[1].astype(np.float64))))
        peak = float(np.max(np.abs(audio[1])))
        report[mode] = {"maximumSampleDifference": difference, "peak": peak, "sampleRate": rate}
        assert difference == 0, report[mode]
        assert np.isfinite(audio[1]).all() and peak <= 1, report[mode]
    text = json.dumps(report, indent=2)
    (output / "report.json").write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
