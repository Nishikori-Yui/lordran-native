#!/usr/bin/env python3
"""Extract Dark Souls: Remastered NVN shaders into the offline package format.

Dark Souls stores its GLSLC outputs in BND3 binders inside BHD5/BDT archives.
The executable also contains a small set of GLSLC outputs in its read-only image.
No other game's shader container formats belong in this repository.
"""
import collections
import concurrent.futures as cf
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.join(TOOLS, '../../games'))
import game as _game

if sys.platform == 'win32':
    # Keep progress output and generated tables UTF-8 on Windows locales such
    # as GBK; the parent packager preserves the complete output in UTF-8 logs.
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

GAME = _game.load()
GROUPS, NOTE = GAME.pairs('shader_groups'), GAME.get('shader_note')
SEPARABLE = GAME.get('shader_separable', 'off') == 'on'

CTL_MAGIC = bytes.fromhex('34127698')
GFX_MAGIC = bytes.fromhex('78563412')
CS_MAGIC = bytes.fromhex('79563412')
SPH_STAGE = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}
ZH = {'vs': '顶点', 'hs': '外壳', 'ds': '域', 'gs': '几何', 'ps': '像素', 'cs': '计算'}


def red(msg):
    sys.exit('【红】' + msg)


def ctl_len(ctl):
    """Return the fixed 0x880-byte control-section key length used by D2R."""
    n = struct.unpack_from('<I', ctl, 0x20)[0]
    return n if 0x760 <= n < 0x880 else 0x880


def skey(ctl, code):
    return hashlib.sha256(ctl[:ctl_len(ctl)] + code).hexdigest()[:16]


def check(where, st, ctl, code):
    """Validate the control section and code area used by one GLSLC output."""
    if ctl[:4] != CTL_MAGIC or len(ctl) < ctl_len(ctl):
        return '控制段异常'
    if st == 'cs':
        if code[:4] == GFX_MAGIC:
            return '代码区头魔数与阶段不符'
    elif code[:4] != GFX_MAGIC:
        return '代码区头魔数与阶段不符'
    if struct.unpack_from('<I', ctl, 0x704)[0] != len(code):
        return '控制段 +0x704 与代码区长不符'
    return None


def glslc_shaders(data, label, required=True):
    """Extract D2R GLSLC outputs, including SDK 4.5 linkage-table layouts."""
    out = []
    for magic in re.finditer(b'\x91\x68\x86\x19', data):
        header = magic.start()
        # A magic match may be arbitrary data or a truncated final header.
        if len(data) - header < 0xcc:
            continue
        size = struct.unpack_from('<I', data, header + 0x44)[0]
        if not 0xcc <= size <= len(data) - header:
            continue
        output = memoryview(data)[header:header + size]
        control_off = struct.unpack_from('<I', output, 0x94)[0]
        code_off, ncode = struct.unpack_from('<II', output, 0xc4)
        if not 0xcc <= control_off <= size - 0x880:
            continue
        nctl = struct.unpack_from('<I', output, control_off + 0x20)[0]
        if not 0x880 <= nctl <= size - control_off:
            continue
        # Code offsets are relative to the control section, not the output.
        # Linkage bytes can themselves look like shader magic: never scan them.
        if code_off < nctl or code_off > size - control_off:
            continue
        code_start = control_off + code_off
        if not 4 <= ncode <= size - code_start:
            continue
        ctl = bytes(output[control_off:control_off + nctl])
        code = bytes(output[code_start:code_start + ncode])
        if code[:4] == CS_MAGIC:
            stage = 'cs'
        elif code[:4] == GFX_MAGIC and len(code) >= 0x80:
            stage = SPH_STAGE.get((struct.unpack_from('<I', code, 0x30)[0] >> 10) & 0xf)
        else:
            stage = None
        if not stage or check(label, stage, ctl, code):
            continue
        out.append((f'{label}#GLSLC@{header:#x}', stage, ctl, code))
    if required and not out:
        red(f'{label}：档案没有有效的 GLSLC 输出')
    return out


def fromsoftware_shaders(path, label):
    """Extract GLSLC stages from the D2R BHD5/BDT archive pair."""
    import fromsoftware

    out = []
    for name, packed in fromsoftware.bhd5_members(path):
        data = fromsoftware.dcx(packed)
        if data[:4] != b'BND3' or b'\x91\x68\x86\x19' not in data:
            continue
        for member, blob in fromsoftware.bnd3_members(data):
            if member.lower().endswith(('.vpo', '.fpo', '.gpo', '.cpo')):
                out.extend(glslc_shaders(fromsoftware.dcx(blob), f'{label}/{name}/{member}'))
    return out


def group(label):
    """Return the profile-defined source group for a shader label."""
    if label.startswith('main'):
        return 'main'
    for key, source_group in GROUPS:
        if key in label:
            return source_group
    return 'other'


def ps_inputs(code):
    """Return the SPH attribute locations read by a pixel shader."""
    return {
        i for i in range(32)
        if struct.unpack_from('<I', code, 0x30 + 4 * (6 + (i >> 2)))[0] >> ((i & 3) * 8) & 0xff
    }


def separable_pairs(keys):
    """Build cover pairs for D2R's single-stage GLSLC programs."""
    inputs = {key: ps_inputs(value[3]) for key, value in keys.items() if value[1] == 'ps'}
    remaining, cover = set().union(*inputs.values()) if inputs else set(), []
    while remaining:
        key = min(inputs, key=lambda item: (-len(inputs[item] & remaining), item))
        cover.append(key)
        remaining -= inputs[key]
    return {
        (vertex, pixel)
        for vertex in keys if keys[vertex][1] == 'vs'
        for pixel in cover
    }, cover


def var_pairs(found):
    """Return vertex/pixel pairs from labels that carry a variation marker."""
    variants = collections.defaultdict(dict)
    for where, stage, ctl, code in found:
        if '#var' in where:
            variants[where][stage] = skey(ctl, code)
    return {
        (value['vs'], value['ps']) for value in variants.values()
        if 'vs' in value and 'ps' in value
    }


def scan_file(args):
    """Scan one D2R BDT archive; non-BDT files are intentionally ignored."""
    path, relative = args
    if not path.endswith('.bdt'):
        return relative, {}, set(), {}
    found = fromsoftware_shaders(path, '/' + relative)
    unique = {skey(ctl, code): (where, stage, ctl, code) for where, stage, ctl, code in found}
    return relative, unique, var_pairs(found), {}


def nso_image(path):
    """Decompress the three segments of an ExeFS NSO image."""
    import lz4.block

    data = open(path, 'rb').read()
    flags = struct.unpack_from('<I', data, 0xc)[0]
    segments = [struct.unpack_from('<III', data, 0x10 + i * 0x10) for i in range(3)]
    compressed_sizes = struct.unpack_from('<III', data, 0x60)
    image = bytearray(segments[2][1] + segments[2][2])
    for i, (file_offset, memory_offset, size) in enumerate(segments):
        raw = data[file_offset:file_offset + compressed_sizes[i]]
        image[memory_offset:memory_offset + size] = (
            lz4.block.decompress(raw, uncompressed_size=size) if flags >> i & 1 else raw
        )
    return bytes(image)


def main():
    romfs_list, main_list, package_dir, mapout, factsout = sys.argv[1:6]
    pairsout = sys.argv[6] if len(sys.argv) > 6 else None
    romfs_versions, main_versions = romfs_list.split(','), main_list.split(',')
    if len(romfs_versions) != len(main_versions):
        red(f'RomFS {len(romfs_versions)} 个、main {len(main_versions)} 个，要一一对应')

    files, results = [], []
    for index, (romfs, main_nso) in enumerate(zip(romfs_versions, main_versions)):
        tag = os.path.basename(os.path.dirname(os.path.abspath(romfs))) if index else ''
        files += sorted(
            (os.path.join(directory, name), (tag + '/' if tag else '') + os.path.relpath(os.path.join(directory, name), romfs))
            for directory, _, names in os.walk(romfs)
            for name in names
            if name.endswith('.bdt') and os.path.isfile(os.path.join(directory, os.path.splitext(name)[0] + '.bhd5'))
        )
        image = nso_image(main_nso)
        label = 'main' + ('@' + tag if tag else '')
        found = glslc_shaders(image, label)
        results.append(('main', {skey(ctl, code): (where, stage, ctl, code) for where, stage, ctl, code in found}, var_pairs(found), {}))

    workers = int(os.environ.get('J', '8'))
    with cf.ProcessPoolExecutor(workers) as executor:
        results += list(executor.map(scan_file, files, chunksize=16))

    keys, pairs = {}, set()
    for _, unique, source_pairs, _ in results:
        pairs |= source_pairs
        for key, value in unique.items():
            if key in keys:
                if keys[key][2] != value[2] or keys[key][3] != value[3]:
                    red(f'键 {key} 相同而控制段或代码区不同（{value[0]} / {keys[key][0]}）')
                continue
            keys[key] = value

    if SEPARABLE:
        single_stage_pairs, cover = separable_pairs(keys)
        pairs |= single_stage_pairs
        print(f'单阶段程序：每个顶点着色器配 {len(cover)} 个像素着色器作覆盖（{" ".join(cover)}） | single-stage programs: every vertex shader is paired with a cover of {len(cover)} pixel shader(s)')

    os.makedirs(package_dir, exist_ok=True)
    for name in os.listdir(package_dir):
        if name.endswith('.bin'):
            os.unlink(os.path.join(package_dir, name))

    records = collections.defaultdict(list)
    rows, facts, stats, per_source = [], {}, collections.Counter(), collections.Counter()
    for key in sorted(keys, key=lambda item: (group(keys[item][0]), keys[item][0], item)):
        where, stage, ctl, code = keys[key]
        filename = f'{stage}_{group(where)}.bin'
        record = bytearray(b'BTCDBTCD' + bytes(0x30))
        struct.pack_into('<2I', record, 0x28, len(ctl), len(code))
        record += code + ctl
        if record.find(CTL_MAGIC) != 0x38 + len(code):
            red(f'键 {key}：代码区里出现控制段魔数，dmsh_build 会切错')
        if record.count(b'BTCDBTCD') != 1:
            red(f'键 {key}：记录内出现记录分隔符')
        rows.append((filename, len(records[filename]), ZH[stage], key, where))
        records[filename].append(bytes(record))
        stats[stage] += 1
        per_source[group(where)] += 1
        if stage == 'cs':
            x, y, z = struct.unpack_from('<3I', ctl, 0x748)
            shared = struct.unpack_from('<I', ctl, 0x754)[0]
            if not x * y * z:
                red(f'计算着色器 {key} 控制段 +0x748 线程组为 0（{where}）')
            facts[key] = {'local': [x, y, z], 'shared': (shared + 15) // 16 * 16}

    for name, records_for_file in records.items():
        with open(os.path.join(package_dir, name), 'wb') as output:
            output.write(b''.join(records_for_file))

    with open(mapout, 'w', encoding='utf-8', newline='\n') as output:
        output.write(f'# kind: evidence  {NOTE}（RomFS + main 里的 GLSLC）→ 控制段 + 代码区键（dm/gfx/tools/shader_split.py）\n')
        output.write('# 第 5 列记每个键首次出现的位置；本作没有 PC 版配对\n')
        output.write('package\tindex\tstage\tdm_ctl_sha16\tsource\n')
        for row in rows:
            output.write('\t'.join(map(str, row)) + '\n')

    manual = GAME.table('shader_facts_manual.tsv')
    if os.path.exists(manual):
        for line in open(manual, encoding='utf-8'):
            if line.strip() and not line.startswith('#'):
                key, value = line.rstrip('\n').split('\t', 1)
                facts[key] = {**facts.get(key, {}), **json.loads(value)}
    with open(factsout, 'w', encoding='utf-8', newline='\n') as output:
        output.write('# 翻译查询的作答表（dm/gfx/tools/shader_split.py 生成，勿手改）：键 <TAB> 事实 JSON。本作没有 PC 版配对：只有计算着色器的线程组 / 共享内存（取自控制段），其余查询按翻译器缺省\n')
        for key in sorted(facts):
            output.write(key + '\t' + json.dumps(facts[key], sort_keys=True, separators=(',', ':')) + '\n')

    if pairsout:
        with open(pairsout, 'w', encoding='utf-8', newline='\n') as output:
            output.write('# kind: evidence  BNSH 变体里的顶点 / 像素着色器配对（shader_split.py generated; D2R uses single-stage cover pairs）\n')
            for vertex, pixel in sorted(pairs):
                output.write(f'{vertex}\t{pixel}\n')

    counts = '，'.join(f'{ZH[stage]} {count}' for stage, count in sorted(stats.items()))
    sources = '，'.join(f'{source} {count}' for source, count in per_source.most_common())
    print(f'着色器 {len(rows)} 个（{counts}）；来源 {sources}；计算着色器作答 {len(facts)} 行' + (f'；变体配对 {len(pairs)} 对' if pairsout else ''))


if __name__ == '__main__':
    main()
