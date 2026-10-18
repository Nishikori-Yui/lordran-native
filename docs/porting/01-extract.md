# 01 — Extracting an NSP

## Keys

- Needs the user's own `prod.keys` and the title key from the NSP's ticket. Keep both under the work folder, e.g. `$W/build/keys/.switch/{prod,title}.keys`, and run hactool with `HOME` pointed there so it never reads anything else:

  ```bash
  # $W/build/keys/ht — hactool with a private key home
  HOME="$(cd "$(dirname "$0")" && pwd)" exec "$(dirname "$0")/../../tools/hactool/hactool" --disablekeywarns "$@"
  ```

- Dumped `prod.keys` files may contain malformed lines (seen: 33 `*master_kek_source_*` lines with the wrong length) that make hactool refuse the whole file. Drop lines whose value length is wrong for the key type; keep a backup of the original.
- Title key: the NSP carries `<rights id>.tik`. For a common ticket the encrypted title key is the first 16 bytes of the title-key block at 0x180; append `<rights id> = <key hex>` to `title.keys`. Never print the value.

## NSP → NCA → ExeFS / RomFS

```bash
ht -t pfs0 --outdir=$W/build/nsp game.nsp > $W/build/nsp.log         # NSP is a PFS0: NCAs + cnmt + tik/cert
ht -t nca $W/build/nsp/<id>.nca | head -40                             # identify the Program NCA (content type Program, has ExeFS + RomFS)
ht -t nca --listromfs $W/build/nsp/<program>.nca > romfs_list.txt     # quick look before extracting 3+ GB
ht -t nca --exefsdir=$W/data/v0/ExeFS --romfsdir=$W/data/v0/RomFS $W/build/nsp/<program>.nca
```

- The target title's ExeFS holds `main.npdm`, `rtld`, `main`, `sdk` and `subsdk0`. The profile loads the last three modules; the host replaces `rtld`.
- Update NSPs: the update's Program NCA is a patch NCA; extract it with `--basenca=<base program nca>` so RomFS is the merged view. Keep base and update in separate directories (`data/v0`, `data/v<ver>`); the rewriter and the host take one ExeFS at a time.
- If hactool stops with `Invalid BKTR layout!`, use `dm/tools/nx_extract` (C#, LibHac 0.19): `nx_extract <prod.keys> <base.nsp> <update.nsp> <out dir> [<base RomFS dir>]`. It reads the NCAs straight out of both NSPs, imports the common tickets itself, prints the display version and module build IDs, and with a base RomFS dir writes identical files as APFS clones.
- After an update, register its module build IDs in the profile. The rewriter rejects unknown module builds and applies no game-specific code cuts. Carry any fixed host addresses (`->base + 0x…`) over with `dm/tools/nso_fnmap.py <old.orig.bin> <new.orig.bin> 0x…`: it matches functions with address bits masked and maps globals through their `adrp` references; check each result by disassembly (`sdis.py`). Also diff the imported SDK symbols: new imports that reach a system service need host implementations, or the real SDK aborts after connecting to `sm:`.
- Decompressed NSO images for analysis: `dm/tools/nso.py <nso> <out.bin>` (lz4; use a venv that has `lz4`). `dm/tools/nso2elf.py` makes an ELF for Ghidra / REA / objdump.

## Manual workspace layout

Keep the NSP folder under the Git-ignored `game/` directory. Manual builds use
`$W` = `<NSP folder>/01004AB00A260000-work`, with the layout below. The IPA
packer uses a separate `01004AB00A260000_build/` directory beside it, with
extracted files under `extract/` rather than `data/`.

```text
game/01004AB00A260000/01004AB00A260000-work/
  build/nsp/            NCAs + tik/cert + nsp.log
  data/v0/{ExeFS,RomFS} extracted base game (v<ver> for updates)
  probe/                decompressed images (main.orig.bin, sdk.orig.bin), small experiments
  elf/                  nso2elf output
  census/               survey tables (imports, svc, NVN slots)
  build/patched_v0/     rewriter output (what the host loads)
  shader/               shader package directory + map + facts produced by shader_split.py
  build/cache/metal_shader_cache/b-<chain version>/   translated metallibs
  build/gfx/dmsh_xlate/ the shader translator build
  ghidra/proj           persistent Ghidra project (analysis takes ~35 min for a 28 MB main)
  run/                  boot.sh, logs, saves, screenshots
  dbg/                  lldb scripts
```

## Compressed RomFS content

- Newer EPD titles store most files as `*.zs` (plain zstd, no dictionary in Mario; Zelda TotK needs `ZsDic.pack` dictionaries). Check for `*dic*` files before assuming plain zstd.
- Older EPD titles (Super Mario 3D World + Bowser's Fury, a Wii U port) store almost everything as `*.szs`: Yaz0-compressed SARC. `shader_split.py` decompresses Yaz0 itself (`yaz0`, pure Python, about 20–45 MB/s per core; the whole 4.7 GB decompressed RomFS scans in about a minute). One of its SARCs (`SystemData/LayoutShader.szs`) is big-endian (BOM `FE FF`), which the SARC reader does not handle; it holds no shader container the game uses.
- `*.sarc` / `*.pack` / `*.blarc` / `*.bfarc` are SARC archives; `*.byml` / `*.bgyml` are BYML (version 7 in Mario). A minimal reader for both is short enough to write inline when needed (see `shader_split.py` for SARC). Unity titles: `dm/gfx/tools/unityfs.py` reads UnityFS bundles, serialized files and objects by type tree (`bundle_files`, `serialized_objects`).
