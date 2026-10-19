#!/usr/bin/env python3
"""Write unsigned Guest.framework without an Apple compiler or linker.

Adapted from d2r-mobile's MIT-licensed dm/tools/guest_dylib.py.
Copyright (c) 2026 jhaizhou. See ../LICENSE.
The section names and page layout match dm/ios/tools/gen_embed.py.
"""
import hashlib
import plistlib
import re
import struct
from pathlib import Path

PAGE = 0x4000


def align(n):
    return (n + PAGE - 1) & -PAGE


def name16(name):
    value = name.encode("ascii")
    if len(value) > 16:
        raise ValueError(f"Mach-O name exceeds 16 bytes: {name}")
    return value.ljust(16, b"\0")


def segment(name, offset, size, protection, sections, filesize=None):
    data = struct.pack("<II16sQQQQiiII", 0x19, 72 + 80 * len(sections),
                       name16(name), offset, size, offset,
                       size if filesize is None else filesize,
                       protection, protection, len(sections), 0)
    for section, start, length, flags in sections:
        data += struct.pack("<16s16sQQIIIIIIII", name16(section), name16(name),
                            start, length, start, 14, 0, 0, flags, 0, 0, 0)
    return data


def dependency(command, name):
    value = name.encode() + b"\0"
    value = value.ljust((len(value) + 7) & -8, b"\0")
    return struct.pack("<IIIIII", command, 24 + len(value), 24, 2, 0x10000, 0x10000) + value


def build(patched, modules):
    text, writable = [], []
    for name in modules:
        if not re.fullmatch(r"[A-Za-z0-9_]+", name):
            raise ValueError(f"Invalid module name: {name}")
        root = Path(patched)
        header = dict(line[2:].split() for line in
                      (root / f"{name}.fixups.tsv").read_text(encoding="utf-8").splitlines()
                      if line.startswith("# "))
        image = (root / f"{name}.patched.bin").read_bytes()
        start, end = align(int(header["TEXT_END"], 16)), align(len(image))
        patch = int(header["PATCH_OFF"], 16)
        key, key_size = int(header["KEY_PAGE_OFF"], 16), int(header["KEY_PAGE_SIZE"], 16)
        split = int(header["FILE_IMAGE_LEN"], 16) if patch < 0 else patch
        if (not 0 < start <= split < end or split % PAGE or patch % PAGE or
                key % PAGE or key_size != PAGE or
                (patch >= 0 and not start <= key < key + key_size <= patch) or
                (patch < 0 and key < split)):
            raise ValueError(f"Invalid rewritten module layout: {name}")
        cut = lambda lo, hi: image[lo:hi].ljust(hi - lo, b"\0")
        text += [(f"__dm{name}x0", cut(0, start)),
                 (f"__dm{name}x1", cut(split, end))]
        writable.append((f"__DM{name}W", cut(start, split)))
    offset, sections, body = PAGE, [], bytearray()
    for name, data in text:
        sections.append((name, offset, len(data), 0x80000400))
        body.extend(data)
        offset += len(data)
    commands = [segment("__TEXT", 0, offset, 5, sections)]
    for name, data in writable:
        commands.append(segment(name, offset, len(data), 3, [("__img", offset, len(data), 0)]))
        body.extend(data)
        offset += len(data)
    strings = b"\0" * 8
    commands += [
        segment("__LINKEDIT", offset, PAGE, 1, [], len(strings)),
        dependency(0xD, "@rpath/Guest.framework/Guest"),
        struct.pack("<II10I", 0x80000022, 48, *([0] * 10)),
        struct.pack("<IIIIII", 2, 24, offset, 0, offset, len(strings)),
        struct.pack("<II18I", 0xB, 80, *([0] * 18)),
        struct.pack("<II16s", 0x1B, 24, hashlib.sha256(body).digest()[:16]),
        struct.pack("<IIIIII", 0x32, 24, 2, 26 << 16, 26 << 16, 0),
        dependency(0xC, "/usr/lib/libSystem.B.dylib"),
    ]
    load_commands = b"".join(commands)
    if 32 + len(load_commands) > PAGE:
        raise ValueError("Mach-O load commands exceed the reserved header page")
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 6,
                         len(commands), len(load_commands), 0x00100085, 0)
    return (header + load_commands).ljust(PAGE, b"\0") + body + strings


def write(patched, destination, modules, bundle_id):
    framework = Path(destination) / "Guest.framework"
    framework.mkdir(parents=True, exist_ok=True)
    (framework / "Guest").write_bytes(build(patched, modules))
    info = dict(CFBundleExecutable="Guest", CFBundleIdentifier=bundle_id,
                CFBundleInfoDictionaryVersion="6.0", CFBundleName="Guest",
                CFBundlePackageType="FMWK", CFBundleShortVersionString="1.0",
                CFBundleVersion="1", MinimumOSVersion="26.0",
                CFBundleSupportedPlatforms=["iPhoneOS"])
    (framework / "Info.plist").write_bytes(plistlib.dumps(info))
    return framework
