#!/usr/bin/env python3
"""Capture the listing's navigation and playback scenes through the real UI."""

import argparse
from capture import Capture


ENGLISH = "english-A_Bird_on_the_Wing__-1"
HINDI = "hindi-Maha_Geeta-5"


def home(capture):
    capture.launch("-settings.appearance", "dark")
    capture.wait(label="Continue Listening")


def activity(capture):
    home(capture)
    capture.tap(label="Downloads", element_type="RadioButton")
    capture.wait(label="98.8 MB used on this device")
    assert not any(e["label"] == "No Downloads" for e in capture.elements())
    capture.capture("downloads")
    capture.tap(label="Listening Stats", element_type="StaticText")
    capture.wait(label="Streak")
    capture.capture("stats")
    home(capture)
    capture.tap(label="Downloads", element_type="RadioButton")
    capture.tap(label="Bookmarks, 4 saved", element_type="Button")
    capture.wait(label="Listen again this weekend")
    capture.capture("bookmarks")


def open_player(capture, discourse=ENGLISH, appearance="dark", noise=False, position="499"):
    capture.launch("-debugTranscript", discourse, "-debugPlayer", "-debugTranscriptFollow",
                   "-settings.appearance", appearance, "-settings.noiseReduction", "1" if noise else "0",
                   "-playbackPosition_" + discourse, position)
    capture.wait(identifier="player.audioEnhancement")
    capture.tap(label="Pause", element_type="Button", largest=True)


def player(capture):
    open_player(capture)
    capture.capture("player")
    capture.tap(identifier="player.transcript")
    capture.wait(label="Search transcript")
    capture.capture("transcript-english")


def hindi(capture):
    open_player(capture, HINDI, appearance="light", position="1248")
    capture.tap(identifier="player.transcript")
    capture.wait(label="Search transcript")
    capture.capture("transcript-hindi")


def denoise(capture):
    open_player(capture, noise=True, position="1405")
    capture.tap(identifier="player.audioEnhancement")
    capture.wait(identifier="audioEnhancement.enabled")
    assert any(e["id"] == "audioEnhancement.enabled" and str(e["value"]) == "1"
               for e in capture.elements())
    capture.capture("denoise")


def sleep(capture):
    open_player(capture)
    capture.tap(label="Sleep timer", element_type="Button")
    capture.wait(label="End of discourse")
    capture.capture("sleep-timer")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--scene", choices=["activity", "player", "hindi", "denoise", "sleep"], required=True)
    parser.add_argument("--replace", action="store_true")
    options = parser.parse_args()
    globals()[options.scene](Capture(options.udid, options.output, replace=options.replace))
