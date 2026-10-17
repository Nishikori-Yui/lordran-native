"""Read the BHD5/BDT, DCX-DFLT and BND3 layouts used by Dark Souls on Switch.

Archive names are hashes in BHD5; BND3 members retain their original names.
Keep this reader independent of game profiles so malformed-input tests need no dumps.
"""
import struct
import zlib
from pathlib import Path


def dcx(data):
    if not data.startswith(b'DCX\0'):
        return data
    if len(data) < 0x4c or data[0x24:0x2c] != b'DCP\0DFLT':
        raise ValueError('unsupported DCX compression')
    marker = data.find(b'DCA\0', 0x30, 0x60)
    if marker < 0 or marker + 8 > len(data):
        raise ValueError('missing DCX data header')
    size, packed = struct.unpack_from('>II', data, 0x1c)
    start = marker + struct.unpack_from('>I', data, marker + 4)[0]
    if start < marker + 8 or start + packed > len(data):
        raise ValueError('DCX data outside archive')
    raw = zlib.decompress(data[start:start + packed])
    if len(raw) != size:
        raise ValueError('DCX size mismatch')
    return raw


def bnd3_members(data):
    if len(data) < 0x20 or data[:4] != b'BND3' or data[0xc:0x10] not in (b'\x5c\0\0\0', b'\x7c\0\0\0'):
        raise ValueError('unsupported BND3 layout')
    count = struct.unpack_from('<I', data, 0x10)[0]
    if count > (len(data) - 0x20) // 0x1c:
        raise ValueError('BND3 member table outside archive')
    for i in range(count):
        flags, size, offset, ident, name, raw_size = struct.unpack_from('<IIQIII', data, 0x20 + i * 0x1c)
        if offset + size > len(data) or name >= len(data):
            raise ValueError('BND3 member outside archive')
        end = data.find(b'\0', name)
        if end < 0:
            raise ValueError('unterminated BND3 member name')
        yield data[name:end].decode('utf-8', 'replace').replace('\\', '/'), data[offset:offset + size]


def bhd5_members(path):
    path = Path(path)
    header = path.with_suffix('.bhd5').read_bytes()
    if len(header) < 0x20 or header[:8] != b'BHD5\xff\0\0\0':
        raise ValueError('unsupported BHD5 layout')
    count = struct.unpack_from('<I', header, 0x10)[0]
    table = struct.unpack_from('<Q', header, 0x18)[0]
    if table + count * 16 > len(header):
        raise ValueError('BHD5 bucket table outside archive')
    total = path.stat().st_size
    with path.open('rb') as data:
        for i in range(count):
            entries, version, offset = struct.unpack_from('<IIQ', header, table + i * 16)
            if version != 1 or offset + entries * 16 > len(header):
                raise ValueError('unsupported BHD5 bucket')
            for j in range(entries):
                name_hash, size, address = struct.unpack_from('<IIQ', header, offset + j * 16)
                if address + size > total:
                    raise ValueError('BHD5 member outside data file')
                data.seek(address)
                yield f'{name_hash:08x}', data.read(size)
