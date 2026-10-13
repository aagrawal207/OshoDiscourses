import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_notes", Path(__file__).with_name("build-release-notes.py"))
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ItemsTests(unittest.TestCase):
    def test_bullets_join_wrapped_lines_and_drop_headings(self):
        text = "What's new in 1.8.0:\n\n• Up Next — manage your queue,\n  and jump to any discourse\n\nFixes and improvements:\n\n• Sleep timer stays accurate in the\n  background\n"
        self.assertEqual(notes.items(text), [
            "Up Next — manage your queue, and jump to any discourse",
            "Sleep timer stays accurate in the background",
        ])

    def test_paragraphs_become_items_and_sign_off_is_dropped(self):
        text = "Osho Talks now runs on Apple Watch.\n\nIn the car, CarPlay shows downloads.\n\nThank you for listening."
        self.assertEqual(notes.items(text), ["Osho Talks now runs on Apple Watch.", "In the car, CarPlay shows downloads."])

    def test_a_short_wrapped_tail_is_not_a_heading(self):
        text = "  • Long-press the Denoise button to switch strength on\n    the fly\n  • New section"
        self.assertEqual(notes.items(text), ["Long-press the Denoise button to switch strength on the fly", "New section"])

    def test_section_label_before_bullets_is_dropped(self):
        text = "A big pass.\n\nDownloads\n- Real progress.\n- One at a time.\n\nInterface\n- Clearer names."
        self.assertEqual(notes.items(text), ["A big pass.", "Real progress.", "One at a time.", "Clearer names."])

    def test_a_wrapped_line_ending_in_a_colon_is_kept(self):
        text = "• Three new settings live under\n  Player:\n  speed, sleep and boost"
        self.assertEqual(notes.items(text), ["Three new settings live under Player: speed, sleep and boost"])

    def test_versions_sort_numerically(self):
        self.assertEqual(sorted(["1.9", "1.10.0", "1.9.1"], key=notes.version_key), ["1.9", "1.9.1", "1.10.0"])


if __name__ == "__main__":
    unittest.main()
