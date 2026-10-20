"""Static patch parsing, version guards and native-rewriter handoff."""
import argparse
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "dm/tools"))
sys.path.insert(0, str(ROOT / "scripts"))
import cheat_patches as cheats
import build_ipa_from_nsp as native

# Synthetic build and patch data; no game code is stored in these fixtures.
BUILD = "0123456789abcdef" * 4


def options(*argv):
    parser = argparse.ArgumentParser()
    cheats.add_arguments(parser)
    return parser.parse_args(argv)


def ips(offset=0x200, data=b"\x1f\x20\x03\xd5", wide=True, rle=False):
    width = 4 if wide else 3
    record = (offset + 0x100).to_bytes(width, "big")
    record += b"\0\0" + len(data).to_bytes(2, "big") + data[:1] if rle else len(data).to_bytes(2, "big") + data
    return (b"IPS32" if wide else b"PATCH") + record + (b"EEOF" if wide else b"EOF")


class CheatPatchTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.file = self.root / (BUILD[:16] + ".txt")
        self.file.write_text("[Example]\n04000000 00000200 D503201F\n"
                             "[Runtime pointer]\n580F0000 00000200\n", encoding="utf-8")

    def apply(self, args, image=None):
        image = image if image is not None else bytearray(0x800)
        return image, cheats.apply(image, 0x400, 0x500, BUILD, args)

    def test_disabled_by_default_and_no_implicit_enable(self):
        image, (end, audit) = self.apply(options())
        self.assertEqual(image, bytes(0x800))
        self.assertEqual(end, 0x400)
        self.assertEqual(audit["enabled"], [])
        with self.assertRaises(ValueError):
            self.apply(options("--cheat-file", str(self.file)))
        with self.assertRaises(ValueError):
            self.apply(options("--cheat", "Example"))

    def test_explicit_selection_and_endianness(self):
        image, (_, audit) = self.apply(options("--cheat-file", str(self.file), "--cheat", "Example"))
        self.assertEqual(image[0x200:0x204], struct.pack("<I", 0xD503201F))
        self.assertEqual(audit["bytes_written"], 4)
        self.assertEqual(audit["enabled"][0]["name"], "Example")
        for name in ("Runtime pointer", "Unknown"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.apply(options("--cheat-file", str(self.file), "--cheat", name))

    def test_build_filename_guards(self):
        for name in (BUILD[:16].upper(), BUILD[:32], BUILD):
            cheats.check_build(Path(name + ".txt"), BUILD)
        for name in ("arbitrary", "f" * 16, BUILD[:15], BUILD[:16] + "0", "f" * 64):
            with self.subTest(name=name), self.assertRaises(ValueError):
                cheats.check_build(Path(name + ".ips"), BUILD)
        wrong = self.root / ("f" * 16 + ".txt")
        wrong.write_bytes(self.file.read_bytes())
        with self.assertRaises(ValueError):
            self.apply(options("--cheat-file", str(wrong), "--cheat", "Example"))

    def test_ips_and_ips32_offsets_and_rle(self):
        for wide in (False, True):
            for rle in (False, True):
                with self.subTest(wide=wide, rle=rle):
                    data = b"\xaa" * 4
                    self.assertEqual(cheats.ips_writes(ips(data=data, wide=wide, rle=rle)), [(0x200, data)])

    def test_ips_truncation_header_resize_and_empty_rejected(self):
        valid = ips()
        for size in range(len(valid)):
            with self.subTest(size=size), self.assertRaises(ValueError):
                cheats.ips_writes(valid[:size])
        for bad in (valid + b"\0", b"IPS32EEOF", b"PATCHEOF",
                    b"IPS32" + bytes(4) + b"\0\x01xEEOF",
                    b"IPS32" + (0x300).to_bytes(4, "big") + b"\0\0\0\0xEEOF"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                cheats.ips_writes(bad)

    def test_code_cave_extends_scan_without_entering_rodata(self):
        self.file.write_text("[Cave]\n04000000 00000480 D65F03C0\n", encoding="utf-8")
        image, (end, _) = self.apply(options("--cheat-file", str(self.file), "--cheat", "Cave"))
        self.assertEqual(end, 0x484)
        self.assertEqual(image[0x480:0x484], struct.pack("<I", 0xD65F03C0))
        for address in (0, 0x200 + 1, 0x500, 0xFFFFFFFC):
            self.file.write_text(f"[Bad]\n04000000 {address:08X} D503201F\n", encoding="utf-8")
            with self.subTest(address=address), self.assertRaises(ValueError):
                self.apply(options("--cheat-file", str(self.file), "--cheat", "Bad"))

    def test_conflicts_and_invalid_late_writes_are_atomic(self):
        path = self.root / (BUILD[:32] + ".ips")
        path.write_bytes(ips(data=b"\xff" * 4))
        image = bytearray(0x800)
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            self.apply(options("--cheat-file", str(self.file), "--cheat", "Example",
                               "--ips", str(path)), image)
        self.assertEqual(image, bytes(0x800))
        path.write_bytes(ips(offset=0x500))
        with self.assertRaises(ValueError):
            self.apply(options("--cheat-file", str(self.file), "--cheat", "Example",
                               "--ips", str(path)), image)
        self.assertEqual(image, bytes(0x800))
        path.write_bytes(ips())
        _, (_, audit) = self.apply(options("--cheat-file", str(self.file), "--cheat", "Example",
                                          "--ips", str(path)))
        self.assertEqual(audit["bytes_written"], 4)

    def test_duplicate_master_and_empty_sections_rejected(self):
        for text in ("[A]\n[A]\n", "[]\n", "{Master}\n04000000 00000200 D503201F\n"):
            self.file.write_text(text, encoding="utf-8")
            with self.subTest(text=text), self.assertRaises(ValueError):
                cheats.sections(self.file)
        with self.assertRaises(ValueError):
            cheats.static_writes([])

    def test_packer_forwards_patches_only_to_main(self):
        profile = type("Profile", (), {"words": lambda _, key: ["main", "sdk"]})()
        args = native.parse_args(["--cheat-file", str(self.file), "--cheat", "Example",
                                  "--ips", str(self.root / "example.ips"), "--runtime-cheats"])
        output = self.root / "patched"
        output.mkdir()
        (output / "old").touch()
        with patch.object(native, "run") as run, patch.object(native, "say"):
            native.rewrite("python", ROOT, self.root, output, {}, self.root, profile, args)
        forwarded = cheats.arguments(args)
        self.assertEqual(run.call_args_list[0].args[0][-len(forwarded):], forwarded)
        self.assertIn("--runtime-cheats", run.call_args_list[0].args[0])
        self.assertEqual(len(run.call_args_list[1].args[0]), 5)
        self.assertFalse((output / "old").exists())

    def test_runtime_groups_default_off_preserve_original_instructions(self):
        self.file.write_text("[One]\n04000000 00000200 D503201F\n"
                             "[Two]\n04000000 00000204 D65F03C0\n", encoding="utf-8")
        image = bytearray(0x800)
        image[0x200:0x208] = bytes.fromhex("080040f9080440f9")
        original = bytes(image)
        end, sites, audit = cheats.prepare_runtime(
            image, 0x400, 0x500, BUILD, options("--cheat-file", str(self.file), "--runtime-cheats"))
        self.assertEqual(end, 0x400)
        self.assertEqual(image, original)
        self.assertEqual([g["initial"] for g in audit["groups"]], [False, False])
        self.assertEqual(sites[0x200]["original"], 0xF9400008)
        self.assertEqual(sites[0x200]["patched"], 0xD503201F)
        self.assertEqual(sites[0x204]["group"], 1)

    def test_runtime_payload_stays_resident_and_selection_is_explicit(self):
        self.file.write_text("[Payload]\n04000000 00000200 140000A0\n"
                             "04000000 00000480 D65F03C0\n", encoding="utf-8")
        image = bytearray(0x800)
        end, _, audit = cheats.prepare_runtime(image, 0x400, 0x500, BUILD,
            options("--cheat-file", str(self.file), "--cheat", "Payload", "--runtime-cheats"))
        self.assertEqual(end, 0x484)
        self.assertEqual(image[0x480:0x484], struct.pack("<I", 0xD65F03C0))
        self.assertEqual(image[0x200:0x204], bytes(4))
        self.assertTrue(audit["groups"][0]["initial"])

    def test_runtime_initial_selection_includes_ips_group_names(self):
        self.file.write_text("[One]\n04000000 00000200 D503201F\n"
                             "[Two]\n04000000 00000204 D65F03C0\n", encoding="utf-8")
        ips_path = self.root / (BUILD[:32] + ".ips")
        ips_path.write_bytes(ips(offset=0x208))
        args = options("--cheat-file", str(self.file), "--runtime-cheats", "--cheat", "One",
                       "--ips", str(ips_path), "--cheat", f"IPS: {ips_path.stem}")
        _, _, audit = cheats.prepare_runtime(bytearray(0x800), 0x400, 0x500, BUILD, args)
        self.assertEqual([g["initial"] for g in audit["groups"]], [True, False, True])
        with self.assertRaisesRegex(ValueError, "Unknown runtime cheat group"):
            cheats.prepare_runtime(bytearray(0x800), 0x400, 0x500, BUILD,
                                   options("--runtime-cheats", "--ips", str(ips_path), "--cheat", "Missing"))

    def test_runtime_rejects_overlap_data_only_and_invalid_late_input_atomically(self):
        texts = (
            "[A]\n04000000 00000200 D503201F\n[B]\n04000000 00000200 D503201F\n",
            "[A]\n04000000 00000480 D65F03C0\n",
            "[A]\n04000000 00000200 D503201F\n04000000 00000480 D65F03C0\n"
            "[B]\n04000000 00000600 D503201F\n",
            "[A\tname]\n04000000 00000200 D503201F\n",
        )
        for text in texts:
            self.file.write_text(text, encoding="utf-8")
            image = bytearray(0x800)
            with self.subTest(text=text), self.assertRaises(ValueError):
                cheats.prepare_runtime(image, 0x400, 0x500, BUILD,
                    options("--cheat-file", str(self.file), "--runtime-cheats"))
            self.assertEqual(image, bytes(0x800))


if __name__ == "__main__":
    unittest.main()
