import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("archive_builder", Path(__file__).with_name("extend-archive-catalog.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class UnusableMirrorTests(unittest.TestCase):
    def test_corrupt_recording_is_removed_without_losing_other_tracks_or_artwork(self):
        series_id = "english-Wisdom_Of_The_Sands"
        entry = {"folder": "folder", "cover": "cover.png",
                 "files": {"1": "one.mp3", "3": "truncated.mp3", "4": "four.mp3"}}
        archive = {series_id: entry}
        self.assertEqual(builder.remove_unusable_audio(archive), [f"{series_id}-3"])
        self.assertEqual(entry, {"folder": "folder", "cover": "cover.png",
                                 "files": {"1": "one.mp3", "4": "four.mp3"}})
        self.assertEqual(builder.remove_unusable_audio(archive), [])

    def test_missing_series_is_not_created(self):
        archive = {}
        self.assertEqual(builder.remove_unusable_audio(archive), [])
        self.assertEqual(archive, {})


if __name__ == "__main__":
    unittest.main()
