# nxnative

[中文说明](#中文说明)

Play your own copy of Dark Souls: Remastered natively on Apple platforms. Bring the game (its NSP files) and your `prod.keys`; one script turns it into an unsigned IPA that you sideload.

It is not an emulator: the game's own code runs directly on the Apple chip, with Switch graphics rebuilt on Metal. Nothing from any game is in this repository, and the project is not affiliated with Nintendo or any game publisher.

## Acknowledgements

This project is built on other people's work:

- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)** (MIT) developed this native-execution approach, for Diablo II: Resurrected. nxnative (first called smbw-mobile) started as a copy of its generic parts: the NSO rewriter, the host that stands in for Horizon, the NVN-on-Metal layer and the iOS app shell. Fixes go both ways.
- **Ryujinx** (MIT): its shader translator (`Ryujinx.Graphics.Shader`, `Ryujinx.Common` and `Spv.Generator` 1.3.2, unmodified in `dm/third_party/ryujinx`) turns the games' Maxwell shaders into SPIR-V. Its emulation of the kernel and system services is also a reference when the host's behaviour is in doubt.
- **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)**: its kernel, mesosphère, is the reference for Horizon's synchronization semantics (address arbiter, condition variables).
- **yuzu**: Maxwell instruction encodings for the shader reference tool, and a cross-check for kernel behaviour.
- **[LibHac](https://github.com/Thealexbarney/LibHac)**: reads NSPs and layers updates over the base game in `dm/tools/nx_extract`. **hactool** did the first extractions.
- **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**: SPIR-V to Metal Shading Language.
- **deko3d** (zlib): its texture layout size algorithm is ported in `dm/gfx/nvn/nvn_tex.c`.
- **libvpx** (VP9 movies), **stb_vorbis** (movie sound), **libdeflate**, **bcdec** and **NVIDIA FLIP** ship in `dm/third_party` with their licenses ([list](dm/third_party/README.md)).
- **Capstone**, **lz4**, **fontTools** and **XcodeGen** are used by the build.

## Game

This repository currently supports one title:

| Game | NSPs to put in the folder | IPA | Notes |
|---|---|---|---|
| Dark Souls: Remastered | base game + update 1.0.3 | profile-defined | Mac bring-up is the primary target; the IPA is unsigned |

Needs iOS / iPadOS 26 or later for the IPA. The Mac host is also used for graphics, audio and input bring-up.

## Pack an IPA

**1. Get nxnative and its tools** (once, on a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835) and [Homebrew](https://brew.sh)):

```
git clone https://github.com/Nishikori-Yui/nxnative.git && cd nxnative
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m pip install lz4 capstone fonttools
```

**2. Put one game's NSPs in a folder**, base game and update (and any DLC):

```
  ~/Games/DarkSoulsRemastered/
  Dark Souls Remastered [01004AB00A260000][v0].nsp
  Dark Souls Remastered [01004AB00A260800][v196608].nsp
```

**3. Run the script:**

```
python3 scripts/build_ipa_from_nsp.py ~/Games/DarkSoulsRemastered -k ~/keys/prod.keys
```

The unsigned IPA appears in the same folder. The first build takes time to extract and translate the shader set; later builds reuse the work folder. You need free disk space of about twice the NSPs' size plus 10 GB. Options such as `-o` (output path) and `--app-name` are listed by `-h`.

**4. Install** the IPA with your sideloading tool (AltStore, Sideloadly, LiveContainer, …). The app gets the game's name and icon.

## Play

**Touch controls.** The iOS shell keeps the standard virtual controller. On the Mac, use a DualSense or the PC-style keyboard and mouse mapping.

```
 ZL  L3*        [−]  2D/3D  [+]        R3*  ZR
 L                                           R
                                         X
  ( L stick )                          Y   A
             ✚ D-pad*   ( R stick )*     B
                                  * 3D layout only
```

A connected game controller hides the touch controls and keeps every button.

- **Performance display (iOS):** the panel near the top shows actual display FPS and frame time. Tap it to collapse or expand game FPS, GPU time, memory, resolution and thermal state. Add `DM_HUD=0` to `Documents/env.txt` and restart to hide it.
- **Game language** is English by default. For Chinese, add the line `DM_LANG=zh-Hans` to `Documents/env.txt`.
- **Saves and logs** are in the Files app, under the app's name: `save/` and `log.txt`. When something goes wrong, send `log.txt` (the previous run is `log.prev.txt`).
- **Export diagnostics (iOS):** tap **Export / 导出** beside the performance panel, then use the share sheet to save or send `DarkSouls-diagnostics.txt`. It contains the current and previous app logs, device/GPU information and a performance snapshot; each log is limited to its last 8 MiB. After an interrupted foreground session, the next launch offers export before starting the game again. The export button remains available when the performance panel is hidden. The report is also in `diagnostics/` in the Files app. It does not collect saves, game files or system crash reports.
- **Short stutters** the first time a new scene appears are normal: the app compiles graphics for it once and remembers them for the next launch.
- **Reinstalling:** some sideloading tools give a reinstalled app a new data folder. Copy `save/` and `pso_user.tsv` over from the old one to keep your progress.
- **Settings without rebuilding:** put lines like `DM_OPMODE=0` (handheld mode: lower resolution, higher frame rate) in `Documents/env.txt`.

## Known issues

- No amiibo and no online features.
- Some graphics paths and water effects are still under active investigation on the Mac build.

## For developers

How it works, the script's options, running games on the Mac, adding a game, and per-game notes: [docs/development.md](docs/development.md). In-depth bring-up and debugging notes: [docs/agents](docs/agents/README.md).

## License

MIT (see [LICENSE](LICENSE)). Third-party code keeps its own license; see [dm/third_party](dm/third_party/README.md).

---

# 中文说明

在 Apple 平台原生运行你自己的《黑暗之魂：重制版》。准备好游戏（NSP 文件）和你的 `prod.keys`，一个脚本就能把它打包成未签名 IPA，再侧载安装。

这不是模拟器：游戏自己的代码直接跑在苹果芯片上，Switch 的图形在 Metal 上重建。本仓库不含任何游戏内容，项目与任天堂及各游戏发行商无关。

## 致谢

本项目建立在他人的工作之上：

- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)**（MIT）为《暗黑破坏神 II：狱火重生》开发了这套原生运行方法。nxnative（最初叫 smbw-mobile）从它的通用部分起步：NSO 改写器、代替 Horizon 的宿主、Metal 上的 NVN 层和 iOS 应用外壳。修正双向共享。
- **Ryujinx**（MIT）：它的着色器翻译器（`Ryujinx.Graphics.Shader`、`Ryujinx.Common` 和 `Spv.Generator` 1.3.2，原样放在 `dm/third_party/ryujinx`）把游戏的 Maxwell 着色器转成 SPIR-V。宿主行为拿不准时，它对内核和系统服务的模拟也是参考。
- **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)**：它的内核 mesosphère 是 Horizon 同步语义（地址仲裁器、条件变量）的参考。
- **yuzu**：着色器参考工具用到的 Maxwell 指令编码，以及内核行为的交叉核对。
- **[LibHac](https://github.com/Thealexbarney/LibHac)**：在 `dm/tools/nx_extract` 里读取 NSP、把更新叠到本体上。最早的解包用的是 **hactool**。
- **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**：SPIR-V 转 Metal 着色语言。
- **deko3d**（zlib）：`dm/gfx/nvn/nvn_tex.c` 移植了它的贴图布局尺寸算法。
- **libvpx**（VP9 影片）、**stb_vorbis**（影片声音）、**libdeflate**、**bcdec** 和 **NVIDIA FLIP** 连同许可证放在 `dm/third_party`（[清单](dm/third_party/README.md)）。
- 构建时用到 **Capstone**、**lz4**、**fontTools** 和 **XcodeGen**。

## 游戏

这个仓库目前只支持一个标题：

| 游戏 | 文件夹里放的 NSP | IPA | 备注 |
|---|---|---|---|
| 黑暗之魂：重制版 | 本体 + 1.0.3 更新 | 由档案决定 | 主要目标是 Mac 端移植；IPA 未签名 |

IPA 需要 iOS / iPadOS 26 或更高版本。Mac 宿主用于图形、声音和输入适配。

## 打包 IPA

**1. 获取 nxnative 和所需工具**（只需一次，在装有 [Xcode](https://apps.apple.com/app/xcode/id497799835) 和 [Homebrew](https://brew.sh) 的 Mac 上）：

```
git clone https://github.com/Nishikori-Yui/nxnative.git && cd nxnative
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m pip install lz4 capstone fonttools
```

**2. 把一个游戏的 NSP 放进一个文件夹**，本体和更新（有 DLC 也放进去）：

```
~/Games/DarkSoulsRemastered/
  Dark Souls Remastered [01004AB00A260000][v0].nsp
  Dark Souls Remastered [01004AB00A260800][v196608].nsp
```

**3. 运行脚本：**

```
python3 scripts/build_ipa_from_nsp.py ~/Games/DarkSoulsRemastered -k ~/keys/prod.keys
```

未签名 IPA 会出现在同一个文件夹里。第一次打包要先解包并翻译着色器，之后会复用工作目录。需要的空闲磁盘空间约为 NSP 大小的两倍再加 10 GB。`-o`（输出路径）、`--app-name` 等选项用 `-h` 查看。

**4. 安装**：用你的侧载工具（AltStore、Sideloadly、LiveContainer 等）安装 IPA。App 会带上游戏的名字和图标。

## 游玩

**触屏按键。** iOS 外壳保留标准虚拟手柄。Mac 端可以使用 DualSense，或按 PC 布局使用键盘和鼠标。

```
 ZL  L3*        [−]  2D/3D  [+]        R3*  ZR
 L                                           R
                                         X
  ( 左摇杆 )                           Y   A
             ✚ 十字键*   ( 右摇杆 )*      B
                                  * 只在 3D 布局里
```

连上游戏手柄后，触屏按键会隐藏，手柄上的所有按键都能用。

- **性能显示（iOS）：** 顶部附近的浮层显示实际上屏 FPS 和帧时间。点击可收起或展开游戏 FPS、GPU 耗时、内存、分辨率和温控状态。在 `Documents/env.txt` 加上 `DM_HUD=0`，重启后可隐藏浮层。
- **游戏语言**默认英文。想用中文，在 `Documents/env.txt` 里加一行 `DM_LANG=zh-Hans`。
- **存档和日志**在「文件」App 里，App 名字对应的文件夹下：`save/` 和 `log.txt`。出问题时请发 `log.txt`（上一次运行的是 `log.prev.txt`）。
- **导出诊断（iOS）：** 点击性能浮层旁的 **Export / 导出**，通过系统分享面板保存或发送 `DarkSouls-diagnostics.txt`。报告包含本次与上次运行日志、设备与 GPU 信息、性能快照，每份日志最多保留末尾 8 MiB。前台运行异常中断后，下次打开会先提供导出入口，再由你选择是否启动游戏；隐藏性能浮层后仍可导出。报告也能在「文件」App 的 `diagnostics/` 文件夹中找到。不收集存档、游戏文件或系统崩溃报告。
- **第一次进新场景时短暂卡顿**是正常的：App 会为它编译一次图形，下次启动就记住了。
- **重装：** 有些侧载工具重装后会给 App 一个新的数据文件夹。把旧文件夹里的 `save/` 和 `pso_user.tsv` 拷过去，进度就不会丢。
- **不重新打包也能改设置：** 在 `Documents/env.txt` 里写一行一个设置，例如 `DM_OPMODE=0`（掌机模式：分辨率更低、帧率更高）。

## 已知问题

- 没有 amiibo，也没有联网功能。
- Mac 构建中的部分图形路径和水面效果仍在持续定位。

## 开发者

工作原理、脚本的全部选项、在 Mac 上运行游戏、添加新游戏、各游戏的技术笔记：[docs/development.md](docs/development.md)。更深入的移植和调试笔记：[docs/agents](docs/agents/README.md)。

## 许可证

MIT（见 [LICENSE](LICENSE)）。第三方代码保留各自的许可证，见 [dm/third_party](dm/third_party/README.md)。
