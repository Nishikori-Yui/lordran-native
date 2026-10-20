"""Explicit, build-bound static code patches applied before native rewriting."""
import argparse
import hashlib
import re
import struct
from pathlib import Path


def add_arguments(parser):
    parser.add_argument("--cheat-file", type=Path,
                        help="Local Atmosphere text file named after the main NSO build ID")
    parser.add_argument("--cheat", action="append", default=[], metavar="NAME",
                        help="Enable one exact [section name]; repeat to select more (default: none)")
    parser.add_argument("--ips", action="append", default=[], type=Path, metavar="FILE",
                        help="Import a build-ID-named IPS/IPS32 ExeFS patch; repeat for more")
    parser.add_argument("--runtime-cheats", action="store_true",
                        help="Compile imported groups for live switching; all start off unless selected with --cheat")


def arguments(args):
    """Forward only explicit selections to the main module's rewriter."""
    result = []
    if args.cheat_file:
        result += ["--cheat-file", str(args.cheat_file)]
    for name in args.cheat:
        result += ["--cheat", name]
    for path in args.ips:
        result += ["--ips", str(path)]
    if getattr(args, "runtime_cheats", False):
        result += ["--runtime-cheats"]
    return result


def check_build(path, build_id):
    stem = Path(path).stem.lower()
    if (not re.fullmatch(r"(?:[0-9a-f]{16}|[0-9a-f]{32}|[0-9a-f]{64})", stem)
            or not build_id.lower().startswith(stem)):
        raise ValueError("Patch filename must match the main NSO build ID (16, 32 or 64 hex digits)")


def parse_sections(text):
    groups = {}
    current = None
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(("#", "//")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            if not current or current in groups:
                raise ValueError(f"Empty or duplicate cheat section at line {number}")
            groups[current] = []
        elif current is None:
            raise ValueError(f"Expected a [cheat section] at line {number}; master codes are unsupported")
        else:
            groups[current].append((number, line))
    return groups


def sections(path):
    return parse_sections(Path(path).read_text(encoding="utf-8-sig"))


def static_writes(rows):
    if not rows:
        raise ValueError("Selected cheat section is empty")
    result = []
    for number, line in rows:
        match = re.fullmatch(r"04000000\s+([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})", line)
        if not match:
            raise ValueError(f"Unsupported cheat at line {number}: only 04000000 static main writes are supported")
        offset, value = (int(x, 16) for x in match.groups())
        if offset % 4:
            raise ValueError(f"Unaligned static code write at line {number}")
        result.append((offset, struct.pack("<I", value)))
    return result


def ips_writes(contents):
    if contents[:5] == b"PATCH":
        width, end = 3, b"EOF"
    elif contents[:5] == b"IPS32":
        width, end = 4, b"EEOF"
    else:
        raise ValueError("Expected an IPS or IPS32 header")
    pos, result = 5, []

    def take(size):
        nonlocal pos
        if pos + size > len(contents):
            raise ValueError("Truncated IPS record or missing terminator")
        value = contents[pos:pos + size]
        pos += size
        return value

    while contents[pos:pos + width] != end:
        offset = int.from_bytes(take(width), "big") - 0x100
        size = int.from_bytes(take(2), "big")
        if size:
            data = take(size)
        else:
            count = int.from_bytes(take(2), "big")
            value = take(1)
            if not count:
                raise ValueError("Empty IPS RLE record")
            data = value * count
        # Atmosphere's ExeFS offsets include the NSO's 0x100-byte header.
        if offset < 0:
            raise ValueError("IPS record modifies the NSO header")
        result.append((offset, data))
    take(width)
    if pos != len(contents):
        raise ValueError("IPS resize trailers and trailing bytes are unsupported")
    if not result:
        raise ValueError("IPS patch contains no writes")
    return result


def apply(image, text_end, ro_off, build_id, args):
    """Validate every write before mutating; return text extent and private audit."""
    if args.cheat and not args.cheat_file:
        raise ValueError("--cheat requires --cheat-file")
    groups = {}
    cheat_hash = None
    if args.cheat_file:
        check_build(args.cheat_file, build_id)
        data = args.cheat_file.read_bytes()
        groups = parse_sections(data.decode("utf-8-sig"))
        cheat_hash = hashlib.sha256(data).hexdigest()
        if not args.cheat:
            raise ValueError("--cheat-file requires at least one explicit --cheat selection")
    plans, audit = [], []
    for name in dict.fromkeys(args.cheat):
        if name not in groups:
            raise ValueError(f"Unknown cheat section: {name!r}")
        plans.extend(static_writes(groups[name]))
        audit.append(dict(kind="cheat", name=name, sha256=cheat_hash))
    for path in args.ips:
        check_build(path, build_id)
        data = path.read_bytes()
        plans.extend(ips_writes(data))
        audit.append(dict(kind="ips", sha256=hashlib.sha256(data).hexdigest()))

    writes = {}
    extent = text_end
    for offset, data in plans:
        if offset < 0x100 or offset + len(data) > ro_off or offset + len(data) > len(image):
            raise ValueError("Static patches must target main text or its padding before rodata")
        for address, value in enumerate(data, offset):
            if address in writes and writes[address] != value:
                raise ValueError(f"Conflicting patches at main+{address:#x}")
            writes[address] = value
        extent = max(extent, (offset + len(data) + 3) & ~3)
    if extent > ro_off:
        raise ValueError("Patched instruction range crosses rodata")
    for address, value in writes.items():
        image[address] = value
    return extent, dict(schema=1, build_id=build_id, enabled=audit, bytes_written=len(writes))


def prepare_runtime(image, text_end, ro_off, build_id, args):
    """Keep original instructions and compile every imported group, initially off."""
    groups = []
    selected = set(args.cheat)
    if args.cheat_file:
        check_build(args.cheat_file, build_id)
        data = args.cheat_file.read_bytes()
        parsed = parse_sections(data.decode("utf-8-sig"))
        sha = hashlib.sha256(data).hexdigest()
        for name, rows in parsed.items():
            groups.append(dict(name=name, initial=name in selected, sha256=sha, writes=static_writes(rows)))
    for path in args.ips:
        check_build(path, build_id)
        data = path.read_bytes()
        groups.append(dict(name=f"IPS: {path.stem}", initial=f"IPS: {path.stem}" in selected,
                           sha256=hashlib.sha256(data).hexdigest(), writes=ips_writes(data)))
    names = [group["name"] for group in groups]
    if len(set(names)) != len(names):
        raise ValueError("Runtime cheat group names must be unique")
    unknown = selected - set(names)
    if unknown:
        raise ValueError(f"Unknown runtime cheat group: {sorted(unknown)!r}")
    if not 1 <= len(groups) <= 256:
        raise ValueError("Runtime cheats require between 1 and 256 imported groups")

    occupied, sites, payload = {}, {}, {}
    extent = text_end
    for index, group in enumerate(groups):
        name = group["name"]
        if len(name.encode("utf-8")) > 511 or any(ord(c) < 32 or ord(c) == 127 for c in name):
            raise ValueError("Runtime cheat names must be at most 511 UTF-8 bytes without control characters")
        words = {}
        for offset, data in group.pop("writes"):
            if offset % 4 or len(data) % 4:
                raise ValueError("Runtime code patches require aligned whole instructions")
            if offset < 0x100 or offset + len(data) > min(ro_off, len(image)):
                raise ValueError("Runtime patches must target main text or its padding before rodata")
            for pos in range(0, len(data), 4):
                address, word = offset + pos, data[pos:pos + 4]
                if address in words and words[address] != word:
                    raise ValueError(f"Conflicting runtime writes at main+{address:#x}")
                words[address] = word
        for address, word in words.items():
            if address in occupied:
                raise ValueError("Runtime groups must not overlap; import only one copy of a patch")
            occupied[address] = index
            if address >= text_end:
                if image[address:address + 4] != bytes(4):
                    raise ValueError("Runtime payload must occupy unused zero-filled text padding")
                payload[address] = word
                extent = max(extent, address + 4)
            else:
                if address + 4 > text_end:
                    raise ValueError("Runtime instruction crosses the original text boundary")
                sites[address] = dict(group=index, original=struct.unpack_from("<I", image, address)[0],
                                      patched=struct.unpack("<I", word)[0])
        if not any(site["group"] == index for site in sites.values()):
            raise ValueError("Each runtime group needs an instruction in original text to switch")
    # Payload stays resident so disabling a group cannot invalidate in-flight calls.
    for address, word in payload.items():
        image[address:address + 4] = word
    audit = dict(schema=2, build_id=build_id, runtime=True, groups=groups, bytes_written=len(occupied) * 4)
    return extent, sites, audit


def main():
    parser = argparse.ArgumentParser(description="List local Atmosphere cheat sections; nothing is enabled.")
    parser.add_argument("file", type=Path)
    args = parser.parse_args()
    try:
        for name, rows in sections(args.file).items():
            try:
                count = len(static_writes(rows))
                status = f"{count} static writes"
            except ValueError:
                status = "unsupported format"
            print(f"[{name}] ({status})")
    except (ValueError, OSError, UnicodeError) as error:
        parser.exit(1, f"Cheat inspection failed: {error}\n")


if __name__ == "__main__":
    main()
