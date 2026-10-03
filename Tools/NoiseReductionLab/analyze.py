#!/usr/bin/env python3
"""Delay- and gain-aware comparison; never treats a quieter waveform as cleaner."""

import argparse
import json
import pathlib

import numpy as np
from scipy import signal
from scipy.io import wavfile


def read(path):
    rate, audio = wavfile.read(path)
    if np.issubdtype(audio.dtype, np.integer):
        audio = audio.astype(np.float64) / (np.iinfo(audio.dtype).max + 1)
    else:
        audio = audio.astype(np.float64)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    return rate, audio


def align(reference, output, rate, maximum_seconds=0.15):
    length = min(len(reference), len(output), int(rate * 20))
    x, y = reference[:length], output[:length]
    corr = signal.correlate(y, x, mode="full", method="fft")
    lags = signal.correlation_lags(len(y), len(x))
    valid = (lags >= 0) & (lags <= int(maximum_seconds * rate))
    lag = int(lags[valid][np.argmax(corr[valid])])
    length = min(len(reference), len(output) - lag)
    return reference[:length], output[lag:lag + length], lag


def db(value):
    return float(10 * np.log10(max(float(value), 1e-30)))


def score(reference, output, rate):
    reference, output, lag = align(reference, output, rate)
    # Ignore startup adaptation and the synthetic flush, not speech pauses.
    reference, output = reference[int(rate):], output[int(rate):]
    reference = reference - reference.mean()
    output = output - output.mean()
    scale = np.dot(output, reference) / max(np.dot(reference, reference), 1e-30)
    target = scale * reference
    error = output - target
    result = {
        "lagSamples": lag, "lagMs": lag / rate * 1000,
        "siSDR": db(np.dot(target, target) / max(np.dot(error, error), 1e-30)),
        "referenceProjectionGainDb": db(scale ** 2),
        "rmsChangeDb": db(np.mean(output ** 2) / max(np.mean(reference ** 2), 1e-30)),
        "peakDbFS": db(np.max(np.abs(output)) ** 2),
        "samplesAtOrAboveFullScale": int(np.count_nonzero(np.abs(output) >= 1)),
    }
    try:
        from pystoi import stoi
        result["stoi"] = float(stoi(reference, output, rate, extended=False))
    except ImportError:
        pass
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=pathlib.Path)
    parser.add_argument("outputs", type=pathlib.Path, nargs="+")
    parser.add_argument("--report", type=pathlib.Path)
    args = parser.parse_args()
    rate, reference = read(args.reference)
    report = {"reference": str(args.reference), "sampleRate": rate, "outputs": {}}
    for path in args.outputs:
        output_rate, output = read(path)
        if output_rate != rate:
            raise ValueError(f"Rate mismatch {path}: {output_rate} != {rate}")
        report["outputs"][str(path)] = score(reference, output, rate)
    text = json.dumps(report, indent=2)
    if args.report:
        args.report.write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
