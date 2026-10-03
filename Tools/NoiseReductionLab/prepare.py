#!/usr/bin/env python3
"""Fetch catalog-selected public audio and deterministic reference-quality probes."""

import argparse
import json
import pathlib
import urllib.parse
import urllib.request

import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    output = ROOT / "build/noise-lab/sources"
    output.mkdir(parents=True, exist_ok=True)
    if args.download:
        catalog = json.loads((ROOT / "OshoDiscourses/Resources/ArchiveCatalog.json").read_text())
        wanted = [("Maha_Geeta", "5"), ("A_Bird_on_the_Wing__", "1")]
        for suffix, number in wanted:
            matching = [(key, entry) for key, entry in catalog.items() if key.endswith(suffix)]
            if len(matching) != 1:
                raise ValueError(f"Catalog match for {suffix}: {len(matching)}")
            key, entry = matching[0]
            path = entry["folder"] + "/" + entry["files"][number]
            url = "https://archive.org/download/osho-audio-discourses-collection/" + urllib.parse.quote(path, safe="/")
            target = output / f"{key}-{number}.mp3"
            if not target.exists():
                print(f"Downloading {url}", flush=True)
                with urllib.request.urlopen(url, timeout=120) as response:
                    target.write_bytes(response.read())
            target.with_suffix(".source.json").write_text(json.dumps({"url": url, "discourseId": f"{key}-{number}"}, indent=2))

    rate = 48000
    n = rate * 5
    t = np.arange(n) / rate
    rng = np.random.default_rng(575)
    samples = np.zeros(n, np.float32)
    samples[rate:rate * 4] = rng.uniform(-0.08, 0.08, rate * 3)
    wavfile.write(output / "alignment-noise-48k.wav", rate, samples)
    pitches = np.array([150, 232, 191, 305, 168, 264, 212, 143, 287, 176])
    phase = np.cumsum(2 * np.pi * pitches[(t / 0.5).astype(int) % len(pitches)] / rate)
    envelope = np.maximum(0, np.minimum(1, np.minimum((t % 0.5) / 0.03, (0.35 - t % 0.5) / 0.03)))
    syllables = 0.25 * envelope * (np.sin(phase) + 0.5 * np.sin(2 * phase))
    wavfile.write(output / "alignment-syllables-48k.wav", rate, syllables.astype(np.float32))
    wavfile.write(output / "alignment-syllables-22k.wav", 22050, resample_poly(syllables, 147, 320).astype(np.float32))
    for frequency in (300, 5000, 8000, 10000, 12000, 14000):
        wavfile.write(output / f"tone-{frequency}-48k.wav", rate, (0.2 * np.sin(2 * np.pi * frequency * t)).astype(np.float32))


if __name__ == "__main__":
    main()
