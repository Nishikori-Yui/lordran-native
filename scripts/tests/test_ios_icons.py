"""Windows packaging must embed valid icons and matching iOS declarations."""
from io import BytesIO
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ios_icons


class IosIconTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name) / "base"
        self.update = Path(self.temp.name) / "update"
        self.base.mkdir()
        self.update.mkdir()

    def test_prefers_packaged_icon_and_falls_back_to_base(self):
        Image.new("RGB", (256, 256), "red").save(self.base / "icon.jpg")
        Image.new("RGB", (256, 256), "blue").save(self.update / "icon.jpg")
        for expected in (2, 0):
            files = {"Assets.car": b"existing public resources"}
            original = {"CFBundleIconName": "StaleAsset", "CFBundleIdentifier": "dev.example.game",
                        "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "StaleAsset"}}}
            result = ios_icons.add_extracted_icons(original, files, self.update, self.base)
            self.assertNotIn("CFBundleIconName", result)
            self.assertEqual(original["CFBundleIconName"], "StaleAsset")
            self.assertEqual(result["CFBundleIdentifier"], "dev.example.game")
            self.assertEqual(files["Assets.car"], b"existing public resources")
            for key, icons in (("CFBundleIcons", ios_icons.PHONE_ICONS),
                               ("CFBundleIcons~ipad", ios_icons.IPAD_ICONS)):
                declaration = result[key]["CFBundlePrimaryIcon"]
                self.assertNotIn("CFBundleIconName", declaration)
                self.assertEqual(declaration["CFBundleIconFiles"], [name for name, _ in icons])
                for name, size in icons:
                    with Image.open(BytesIO(files[name + ".png"])) as image:
                        self.assertEqual(image.size, (size, size))
                        self.assertEqual(image.mode, "RGB")
                        self.assertEqual(image.format, "PNG")
                        self.assertGreater(image.getpixel((0, 0))[expected], 240)
            if (self.update / "icon.jpg").exists():
                (self.update / "icon.jpg").unlink()

    def test_missing_or_corrupt_icon_fails_without_modifying_resources(self):
        files = {}
        with self.assertRaisesRegex(ValueError, "No extracted game icon"):
            ios_icons.add_extracted_icons({}, files, self.update, self.base)
        (self.update / "icon.jpg").write_bytes(b"invalid JPEG")
        Image.new("RGB", (256, 256), "red").save(self.base / "icon.jpg")
        with self.assertRaisesRegex(ValueError, "Could not read extracted game icon"):
            ios_icons.add_extracted_icons({}, files, self.update, self.base)
        self.assertEqual(files, {})

    def test_missing_pillow_has_actionable_error(self):
        with patch.dict(sys.modules, {"PIL": None}), self.assertRaisesRegex(ValueError, "pip install Pillow"):
            ios_icons.check_pillow()


if __name__ == "__main__":
    unittest.main()
