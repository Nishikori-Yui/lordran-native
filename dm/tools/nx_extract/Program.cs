// NSP extraction: nx_extract <prod.keys> <base NSP> <update NSP or -> <output dir> [base RomFS dir to compare against]
// Writes <output dir>/ExeFS and <output dir>/RomFS (the merged RomFS when there is an update); with a base RomFS dir, files whose content matches it become APFS clones (no new space).
// Title keys come from the common tickets (.tik) inside the NSPs, so only prod.keys is needed; key values are never printed.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Spl;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.FsSystem.RomFs;
using Path = System.IO.Path;

static class P {
    [DllImport("libc", SetLastError = true)] static extern int clonefile(string src, string dst, uint flags);

    static int Main(string[] a) {
        if (a.Length < 4) { Console.Error.WriteLine("用法 | usage: nx_extract <prod.keys> <base.nsp> <update.nsp|-> <out dir> [base RomFS dir]"); return 2; }
        KeySet ks = ExternalKeyReader.ReadKeyFile(a[0]);
        var basePkg = OpenNsp(ks, a[1]); var updPkg = a[2] == "-" ? null : OpenNsp(ks, a[2]);
        Nca baseProg = Pick(basePkg, NcaContentType.Program) ?? throw new Exception("基础 NSP 里没有程序 NCA | no Program NCA in the base NSP");
        Nca updProg = updPkg == null ? null : Pick(updPkg, NcaContentType.Program) ?? throw new Exception("更新 NSP 里没有程序 NCA | no Program NCA in the update NSP");
        Nca ctrl = Pick(updPkg ?? basePkg, NcaContentType.Control);
        Console.WriteLine($"标题 | title {baseProg.Header.TitleId:x16}" + (updProg != null ? $"，更新 | update {updProg.Header.TitleId:x16}" : ""));
        string outDir = a[3], cmpDir = a.Length > 4 ? a[4] : null;
        if (ctrl != null) {   // control data (NACP): display version and game name; a raw copy goes to <output dir>/control.nacp for naming the app
            byte[] nacp = Nacp(ctrl);
            Console.WriteLine($"显示版本 | display version {System.Text.Encoding.ASCII.GetString(nacp, 0x3060, 0x10).TrimEnd('\0')}");
            Console.WriteLine($"名称 | name {TitleName(nacp)}");
            Directory.CreateDirectory(outDir); File.WriteAllBytes(Path.Combine(outDir, "control.nacp"), nacp);
            var (icon, lang) = Icon(ctrl);   // the game icon for the app icon, saved as <output dir>/icon.jpg (build_ipa.sh picks it up)
            if (icon != null) { File.WriteAllBytes(Path.Combine(outDir, "icon.jpg"), icon); Console.WriteLine($"图标 | icon {lang}（{icon.Length} 字节 | bytes）"); }
            else Console.WriteLine("控制数据里没有图标 | no icon in the control data");
        }
        // Code section: the update's ExeFS is complete; opening it layered over the base gives the same result
        IFileSystem exefs = updProg != null ? baseProg.OpenFileSystemWithPatch(updProg, NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid) : baseProg.OpenFileSystem(NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid);
        Copy(exefs, Path.Combine(outDir, "ExeFS"), null);
        string[] mods = Directory.GetFiles(Path.Combine(outDir, "ExeFS")); Array.Sort(mods, StringComparer.Ordinal);
        foreach (string p in mods) {   // build ID of every NSO module (main, sdk, subsdk*, rtld...)
            if (new FileInfo(p).Length < 0x50) continue;
            byte[] h = new byte[0x50]; using (var f = File.OpenRead(p)) f.ReadExactly(h);
            if (h[0] == 'N' && h[1] == 'S' && h[2] == 'O' && h[3] == '0') Console.WriteLine($"{Path.GetFileName(p)} 构建号 | build id {Convert.ToHexString(h, 0x40, 16).ToLowerInvariant()}");
        }
        IStorage romfs = updProg != null ? baseProg.OpenStorageWithPatch(updProg, NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid) : baseProg.OpenStorage(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        Copy(new RomFsFileSystem(romfs), Path.Combine(outDir, "RomFS"), cmpDir);
        return 0;
    }

    // Open an NSP (PFS0), import its common tickets, list all NCAs
    static List<Nca> OpenNsp(KeySet ks, string path) {
        var pfs = new PartitionFileSystem();
        pfs.Initialize(new LocalStorage(path, FileAccess.Read)).ThrowIfFailure();
        var ncas = new List<Nca>();
        foreach (DirectoryEntryEx e in pfs.EnumerateEntries("*", SearchOptions.Default)) {
            using var f = new UniqueRef<IFile>();
            pfs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            IStorage st = f.Release().AsStorage();
            if (e.Name.EndsWith(".tik", StringComparison.OrdinalIgnoreCase)) {
                byte[] t = new byte[0x2c0]; st.Read(0, t).ThrowIfFailure();
                if (t[0x281] != 0) { Console.Error.WriteLine($"【红】{e.Name} 不是通用票据，标题密钥要另给 | is not a common ticket; supply the title key separately"); continue; }
                ks.ExternalKeySet.Add(new RightsId(t.AsSpan(0x2a0, 0x10)), new AccessKey(t.AsSpan(0x180, 0x10))).ThrowIfFailure();
            } else if (e.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase)) ncas.Add(new Nca(ks, st));
        }
        return ncas;
    }
    static Nca Pick(List<Nca> l, NcaContentType t) { foreach (Nca n in l) if (n.Header.ContentType == t) return n; return null; }

    // Icon: the control data holds one 256x256 JPEG per language (/icon_<language>.dat). Use the English one (American, then British); if neither exists, take the first in NACP language order
    static readonly string[] IconLangs = { "AmericanEnglish", "BritishEnglish", "Japanese", "French", "German", "LatinAmericanSpanish", "Spanish", "Italian",
                                           "Dutch", "CanadianFrench", "Portuguese", "Russian", "Korean", "TraditionalChinese", "SimplifiedChinese", "BrazilianPortuguese" };
    static (byte[], string) Icon(Nca ctrl) {
        IFileSystem fs = ctrl.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        foreach (string lang in IconLangs) {
            using var f = new UniqueRef<IFile>();
            if (fs.OpenFile(ref f.Ref, $"/icon_{lang}.dat".ToU8Span(), OpenMode.Read).IsFailure()) continue;
            f.Get.GetSize(out long n).ThrowIfFailure();
            byte[] v = new byte[n]; f.Get.Read(out _, 0, v, ReadOption.None).ThrowIfFailure();
            return (v, lang);
        }
        return (null, null);
    }
    static byte[] Nacp(Nca ctrl) {   // the whole control.nacp (0x4000 bytes)
        IFileSystem fs = ctrl.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        using var f = new UniqueRef<IFile>();
        fs.OpenFile(ref f.Ref, "/control.nacp".ToU8Span(), OpenMode.Read).ThrowIfFailure();
        f.Get.GetSize(out long n).ThrowIfFailure();
        byte[] v = new byte[n]; f.Get.Read(out _, 0, v, ReadOption.None).ThrowIfFailure();
        return v;
    }
    // Game name: the NACP starts with 16 language entries of 0x300 bytes each (name 0x200 + publisher 0x100); take the first non-empty one (0 = American English); DisplayVersion is at 0x3060
    //   Newer SDKs compress these 0x3000 bytes: a u16 size + raw deflate,
    //   inflating to 32 languages × 0x300. LibHac 0.19 does not know this,
    //   so it is decoded here.
    static string TitleName(byte[] nacp) {
        byte[] t = nacp; int n = nacp[0] | nacp[1] << 8;
        if (n > 0 && n <= 0x2ffe) try {
            using var z = new System.IO.Compression.DeflateStream(new MemoryStream(nacp, 2, n), System.IO.Compression.CompressionMode.Decompress);
            var m = new MemoryStream(); z.CopyTo(m);
            if (m.Length == 0x6000) t = m.ToArray();   // a wrong length means an uncompressed name that happened to inflate
        } catch (InvalidDataException) { }   // not compressed
        for (int i = 0; i < (t == nacp ? 16 : 32); i++) {
            int z = Array.IndexOf(t, (byte)0, i * 0x300, 0x200), len = (z < 0 ? i * 0x300 + 0x200 : z) - i * 0x300;
            if (len > 0) return System.Text.Encoding.UTF8.GetString(t, i * 0x300, len);
        }
        return "";
    }

    // Copy out file by file; files identical to the same path in the compare dir become APFS clones instead
    static void Copy(IFileSystem fs, string dst, string cmpDir) {
        long n = 0, cloned = 0, bytes = 0, written = 0; byte[] buf = new byte[4 << 20], cb = new byte[4 << 20];
        foreach (DirectoryEntryEx e in fs.EnumerateEntries("*", SearchOptions.RecurseSubdirectories)) {
            string rel = e.FullPath.TrimStart('/'), op = Path.Combine(dst, rel);
            if (e.Type == DirectoryEntryType.Directory) { Directory.CreateDirectory(op); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(op)); n++; bytes += e.Size;
            using var f = new UniqueRef<IFile>();
            fs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            string cp = cmpDir == null ? null : Path.Combine(cmpDir, rel);
            if (cp != null && File.Exists(cp) && new FileInfo(cp).Length == e.Size && Same(f.Get, cp, e.Size, buf, cb)) {
                if (File.Exists(op)) File.Delete(op);
                if (!OperatingSystem.IsWindows() && clonefile(cp, op, 0) == 0) { cloned++; continue; }
                if (File.Exists(op)) File.Delete(op);
            }
            using var o = File.Create(op);
            for (long off = 0; off < e.Size;) {
                f.Get.Read(out long got, off, buf.AsSpan(0, (int)Math.Min(buf.Length, e.Size - off)), ReadOption.None).ThrowIfFailure();
                if (got <= 0) throw new IOException($"读不出 | cannot read {e.FullPath} @{off}");
                o.Write(buf, 0, (int)got); off += got;
            }
            written += e.Size;
        }
        Console.WriteLine($"{dst}：{n} 个文件 {bytes / 1048576.0:F1} MB，其中 {cloned} 个与比对目录相同（克隆），新写 {written / 1048576.0:F1} MB | {n} files {bytes / 1048576.0:F1} MB, {cloned} identical to the compare dir (cloned), {written / 1048576.0:F1} MB newly written");
    }
    static bool Same(IFile f, string path, long size, byte[] buf, byte[] cb) {
        using var c = File.OpenRead(path);
        for (long off = 0; off < size;) {
            int want = (int)Math.Min(buf.Length, size - off);
            f.Read(out long got, off, buf.AsSpan(0, want), ReadOption.None).ThrowIfFailure();
            c.ReadExactly(cb, 0, (int)got);
            if (!buf.AsSpan(0, (int)got).SequenceEqual(cb.AsSpan(0, (int)got))) return false;
            off += got;
        }
        return true;
    }
}
