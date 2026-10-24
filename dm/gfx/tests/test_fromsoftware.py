"""Synthetic archive fixtures; no game assets or keys required."""
import struct
import os
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import fromsoftware


def compressed(raw):
    packed = zlib.compress(raw)
    header = bytearray(0x4c)
    header[:4] = b'DCX\0'
    header[0x18:0x1c] = b'DCS\0'
    struct.pack_into('>II', header, 0x1c, len(raw), len(packed))
    header[0x24:0x2c] = b'DCP\0DFLT'
    header[0x44:0x48] = b'DCA\0'
    struct.pack_into('>I', header, 0x48, 8)
    return bytes(header) + packed


class Archives(unittest.TestCase):
    def test_glslc_linkage_table_and_contiguous_layout(self):
        os.environ.setdefault('DM_GAME', '01004AB00A260000')
        import shader_split
        for gap in (0, 12):
            control, nctl, ncode = 0x240, 0x880, 0x100
            code = control + nctl + gap
            data = bytearray(code + ncode)
            data[:4] = bytes.fromhex('91688619')
            struct.pack_into('<I', data, 0x44, len(data))
            struct.pack_into('<I', data, 0x94, control)
            struct.pack_into('<II', data, 0xc4, nctl + gap, ncode)
            data[control:control + 4] = shader_split.CTL_MAGIC
            struct.pack_into('<I', data, control + 0x20, nctl)
            struct.pack_into('<I', data, control + 0x704, ncode)
            data[code:code + 4] = shader_split.GFX_MAGIC
            struct.pack_into('<I', data, code + 0x30, 5 << 10)
            shaders = shader_split.glslc_shaders(data, 'fixture')
            self.assertEqual(len(shaders), 1)
            self.assertEqual(shaders[0][1], 'ps')
            self.assertEqual(shaders[0][3], data[code:])
            if gap:
                struct.pack_into('<I', data, 0xc8, ncode + 1)
                self.assertEqual(shader_split.glslc_shaders(data, 'fixture', required=False), [])

    def test_glslc_metadata_is_authoritative_and_bounded(self):
        import shader_split
        control, nctl, gap, ncode = 0x240, 0x880, 0x100, 0x100
        code = control + nctl + gap
        valid = bytearray(code + ncode)
        valid[:4] = bytes.fromhex('91688619')
        struct.pack_into('<I', valid, 0x44, len(valid))
        struct.pack_into('<I', valid, 0x94, control)
        struct.pack_into('<II', valid, 0xc4, nctl + gap, ncode)
        valid[control:control + 4] = shader_split.CTL_MAGIC
        struct.pack_into('<I', valid, control + 0x20, nctl)
        struct.pack_into('<I', valid, control + 0x704, ncode)
        valid[code:code + 4] = shader_split.GFX_MAGIC
        struct.pack_into('<I', valid, code + 0x30, 5 << 10)
        # Decoy control and graphics magic in non-code data must not hide or
        # replace the metadata-selected shader.
        valid[0x100:0x104] = shader_split.CTL_MAGIC
        valid[control + nctl:control + nctl + 4] = shader_split.GFX_MAGIC
        struct.pack_into('<I', valid, control + nctl + 0x30, 1 << 10)
        rows = shader_split.glslc_shaders(valid, 'fixture')
        self.assertEqual(rows[0][1], 'ps')
        self.assertEqual(rows[0][3], valid[code:])
        # Embedded output offsets stay relative to their own header.
        rows = shader_split.glslc_shaders(b'prefix' + valid, 'fixture')
        self.assertEqual(rows[0][3], valid[code:])
        for end in range(len(valid)):
            self.assertEqual(shader_split.glslc_shaders(valid[:end], 'fixture', False), [])
        for offset, value in ((0x44, 0xffffffff), (0x94, 0xfffffff0),
                              (0x94, len(valid) - 4), (0xc4, nctl - 4),
                              (0xc4, 0xffffffff), (0xc8, ncode + 1),
                              (control + 0x20, 0x100),
                              (control + 0x704, ncode - 1)):
            bad = bytearray(valid)
            struct.pack_into('<I', bad, offset, value)
            with self.subTest(offset=offset, value=value):
                self.assertEqual(shader_split.glslc_shaders(bad, 'fixture', False), [])
        # A damaged output must not prevent extracting a following valid one.
        self.assertEqual(len(shader_split.glslc_shaders(bad + valid, 'fixture')), 1)
        with self.assertRaises(SystemExit):
            shader_split.glslc_shaders(b'\x91\x68\x86\x19', 'required')

    def test_glslc_compute_and_short_graphics_code(self):
        import shader_split
        control, nctl = 0x240, 0x880
        for magic, ncode, expected in ((shader_split.CS_MAGIC, 4, 1),
                                        (shader_split.GFX_MAGIC, 4, 0),
                                        (shader_split.GFX_MAGIC, 0x34, 0)):
            code = control + nctl
            data = bytearray(code + ncode)
            data[:4] = bytes.fromhex('91688619')
            struct.pack_into('<I', data, 0x44, len(data))
            struct.pack_into('<I', data, 0x94, control)
            struct.pack_into('<II', data, 0xc4, nctl, ncode)
            data[control:control + 4] = shader_split.CTL_MAGIC
            struct.pack_into('<I', data, control + 0x20, nctl)
            struct.pack_into('<I', data, control + 0x704, ncode)
            data[code:code + 4] = magic
            self.assertEqual(len(shader_split.glslc_shaders(data, 'fixture', False)), expected)

    def test_dcx_and_corrupt_lengths(self):
        raw = b'BND3' + bytes(range(256))
        data = compressed(raw)
        self.assertEqual(fromsoftware.dcx(data), raw)
        self.assertEqual(fromsoftware.dcx(raw), raw)
        with self.assertRaises(ValueError):
            fromsoftware.dcx(data[:-1])
        bad = bytearray(data)
        struct.pack_into('>I', bad, 0x1c, len(raw) + 1)
        with self.assertRaises(ValueError):
            fromsoftware.dcx(bytes(bad))

    def test_bnd3_two_members_and_bounds(self):
        data = bytearray(0x100)
        data[:4] = b'BND3'
        struct.pack_into('<II', data, 0xc, 0x7c, 2)
        for i, (name, payload) in enumerate([(b'vs\\one.vpo\0', b'vertex'), (b'ps\\two.fpo\0', b'pixel')]):
            name_off, offset = 0x60 + i * 0x10, 0x90 + i * 0x10
            struct.pack_into('<IIQIII', data, 0x20 + i * 0x1c, 0x40, len(payload), offset, i, name_off, len(payload))
            data[name_off:name_off + len(name)] = name
            data[offset:offset + len(payload)] = payload
        self.assertEqual(list(fromsoftware.bnd3_members(data)), [('vs/one.vpo', b'vertex'), ('ps/two.fpo', b'pixel')])
        struct.pack_into('<Q', data, 0x28, 0x1000)
        with self.assertRaises(ValueError):
            list(fromsoftware.bnd3_members(data))

    def test_bhd5_offsets_and_truncated_data(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'archive.bdt'
            path.write_bytes(b'BDF3' + b'payload')
            header = bytearray(0x40)
            header[:8] = b'BHD5\xff\0\0\0'
            struct.pack_into('<I', header, 0x10, 1)
            struct.pack_into('<Q', header, 0x18, 0x20)
            struct.pack_into('<IIQ', header, 0x20, 1, 1, 0x30)
            struct.pack_into('<IIQ', header, 0x30, 0x12345678, 7, 4)
            path.with_suffix('.bhd5').write_bytes(header)
            self.assertEqual(list(fromsoftware.bhd5_members(path)), [('12345678', b'payload')])
            path.write_bytes(b'BDF3')
            with self.assertRaises(ValueError):
                list(fromsoftware.bhd5_members(path))


if __name__ == '__main__':
    unittest.main()
