# Lordran Native

[English](README.md) | [简体中文](README.zh-CN.md)

Lordran Native 将 **《黑暗之魂：重制版》**（`01004AB00A260000`）原生带到 Apple 平台。游戏的 ARM64 代码直接在 Apple 硬件上执行，改写器适配依赖内核的指令，宿主提供 Horizon 系统服务，图形层通过 Metal 实现 NVN。

本项目基于 [seedds/nxnative](https://github.com/seedds/nxnative)，现独立维护，专注于《黑暗之魂：重制版》的移植。

**项目仍处于实验阶段。** 当前主要在 Mac 上进行移植和调试；iOS 构建可生成用于 iPhone 和 iPad 的未签名 IPA，图形表现和设备兼容性仍需验证。本仓库目前只支持《黑暗之魂：重制版》（`01004AB00A260000`）。

你需要自行准备游戏 NSP 和 `prod.keys`。仓库不含游戏文件或密钥，项目与任天堂及游戏发行商无关。

## 准备条件

- 一台 Apple 芯片 Mac，安装 Xcode 和 Homebrew，用于构建移植版本。
- 游戏本体 NSP 和 **1.0.3 更新**（`v196608`）。即使打包本体版本，也需要这两份文件来提取着色器。
- 你自己的 `prod.keys`。
- 如需使用 IPA：运行 **iOS / iPadOS 26 或更高版本**的 iPhone 或 iPad，以及侧载工具。
- 空闲磁盘空间约为 NSP 总大小的两倍，再加 10 GB。

## 构建未签名 IPA

### 1. 安装构建工具

```sh
git clone https://github.com/Nishikori-Yui/lordran-native.git lordran-native
cd lordran-native
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m pip install lz4 capstone fonttools
```

构建还需要 .NET 10 SDK 和 Xcode 的 Metal 编译器。如果 Python 要求使用虚拟环境，请在虚拟环境中安装 Python 依赖，并使用该环境执行后续构建命令。

### 2. 准备游戏文件

把 NSP 和密钥放在 `game/` 下的游戏私有工作目录中；该目录已被 Git 忽略。例如：

```text
game/01004AB00A260000/
  prod.keys
  [01004AB00A260000][v0].nsp
  [01004AB00A260800][v196608].nsp
```

### 3. 运行打包脚本

在仓库根目录执行：

```sh
python3 scripts/build_ipa_from_nsp.py game/01004AB00A260000 -k game/01004AB00A260000/prod.keys -o game/01004AB00A260000/LordranNative.ipa
```

此命令输出 `game/01004AB00A260000/LordranNative.ipa`；不指定 `-o` 时，输出文件名由游戏配置档案决定。中间文件、着色器缓存和构建日志都保存在 NSP 旁的 `01004AB00A260000_build/` 中。首次构建需要解包游戏并翻译着色器，后续构建会复用缓存。构建成功后会删除解包文件；若要保留，请加上 `--keep-extracted`。

运行 `python3 scripts/build_ipa_from_nsp.py -h` 可查看选项，包括用 `-o` 指定输出路径、用 `--app-name` 指定主屏幕名称。版本选择和 Mac 手动构建步骤见[开发文档](docs/development.md)。

如需在 Apple 芯片 Mac 上构建实验性的 iOS 模拟器版本，请参照[模拟器构建步骤](docs/development.md#build-for-ios-simulator-apple-silicon)。此版本输出独立的 `.app.zip`，与真机 IPA 分开。

### 在 Windows 上打包（无需 Xcode）

Actions 仅在手动运行或推送 tag 时构建不含游戏内容的未签名 iOS「壳」。从对应的工作流产物或 Release 下载 `LordranNative-shell-build-input.zip`。Windows 需要 Python 3.12 或更高版本、.NET 10 SDK、`zstd`，以及 `spirv-cross` 1.4.357.0（Vulkan SDK 标签 `vulkan-sdk-1.4.357.0`）。把游戏本体 NSP、1.0.3 更新 NSP 和你自己的 `prod.keys` 放在 `game/` 下的私有文件夹中（该目录已被 Git 忽略）。

安装 Python 依赖并运行：

```powershell
py -3 -m pip install lz4 capstone
py -3 scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip
```

壳和源码必须来自同一个 Release。脚本会校验游戏标题及档案登记的模块构建号，在本机改写游戏模块并生成未签名 IPA。NSP、密钥、解包文件和生成的 IPA 都不会上传。此无 Xcode 流程会把着色器源码放进 IPA，首次启动时由 iPhone 编译；首次进入场景可能需要等待数分钟。Mac 的常规流程仍会预先编译着色器。壳 ZIP 只是打包输入，不是可安装 App；请对最终生成的 IPA 进行签名和侧载。依赖与故障排查见 [Windows 打包说明](docs/windows-packaging.zh-CN.md)。

### 4. 侧载 IPA

使用你的侧载工具签名并安装未签名 IPA。App 会采用 NSP 中的游戏名称和图标。

## 操作方式

- **触屏：** 左摇杆控制移动。3D 布局下，在屏幕空白处滑动可转动视角，手指停下或抬起即停止。**触控与手柄 → 触屏视角** 中可分别设置横轴、纵轴反转，并将灵敏度调整为 0.25～3 倍，默认 1 倍。这些设置同时作用于滑屏和右侧虚拟摇杆，立即生效，并在下次启动时保留。按钮触摸独立处理，R3 用于锁定目标。
- **悬浮菜单：** 点按吸附在屏幕边缘的半透明悬浮球，可打开帧率开关、带时间戳的日志导出和输入设置。进入 **调整按键** 后，拖动带外框的按键可移动位置，拖动右下角手柄可缩放，点画面中央的 **确定** 保存退出。旋转、透明度和形状在当前按键的设置中调整。
- **手柄：** 连接实体手柄后，触屏按键默认隐藏，手柄提供完整按键布局。菜单中可以选择当前手柄、自动识别任天堂/Xbox 按键映射，并调整摇杆死区。
- **Mac：** 可使用 DualSense 手柄，或 PC 风格的键盘和鼠标映射。启动宿主时设置 `DM_WINDOW=1`，即可打开游戏窗口。

## 设置与存档

在 iOS 的「文件」App 中打开本应用的文件夹。语言、运行模式、帧率显示和其他输入设置都在半透明悬浮菜单中修改。语言和运行模式修改后会二次确认并退出应用，下一次启动时游戏会加载新设置。其他诊断开关仍可写入 `Documents/env.txt`，每行填写一个 `KEY=VALUE`。

语言、运行模式和性能浮层由悬浮菜单管理，请不要再把这三个值写入 `env.txt`。

性能浮层显示实际上屏 FPS 和帧时间。点击可展开或收起游戏 FPS、GPU 耗时、内存、分辨率和温控状态。

存档位于 `save/`。重装前请备份 `save/` 和 `pso_user.tsv`：部分侧载工具会创建新的应用数据目录。恢复这两项即可保留存档和管线预热清单。

首次进入新场景时，Metal 编译新管线可能造成短暂卡顿。应用会将这些管线记录到 `pso_user.tsv`，供后续启动时预热。

## 排查问题

如果游戏无法启动、意外退出或画面异常，请导出诊断报告：

1. 打开半透明悬浮菜单，点击 **Export log / 导出日志**。隐藏性能浮层后，菜单仍可使用。
2. 通过系统分享面板保存或发送带时间戳的诊断报告（`*-diagnostics-<UTC 时间戳>-<ID>.txt`）。应用的 `diagnostics/` 文件夹中也会保留一份。
3. 附上设备型号、系统版本，以及触发问题的操作步骤。

前台运行异常中断后，下次启动会先提供诊断导出入口，再启动游戏。报告包含本次和上次运行日志、设备与 GPU 信息、性能快照，每份日志最多保留末尾 8 MiB。报告不包含存档、游戏文件或系统崩溃报告。

也可以直接从应用文件夹中获取 `log.txt` 和 `log.prev.txt`。新日志使用精确到毫秒的 UTC 时间戳，旧版本保留的日志维持原文。构建失败时，请查看 NSP 旁的 `01004AB00A260000_build/logs/`。

## 已知限制

- 不支持联网功能和 amiibo。
- Mac 端部分图形路径和水面效果仍在排查。
- Mac 测试通过或 IPA 构建成功，并不代表已验证 iPhone 或 iPad 真机兼容性。已完成的验证和待解决问题见[移植记录](dm/games/01004AB00A260000/bringup.md)。

## 开发资料

- [文档索引](docs/README.md)：用户文档、开发文档和实现参考的导航。
- [开发文档](docs/development.md)：架构、打包选项、手动构建和回归检查。
- [移植与调试指南](docs/porting/README.md)：解包、宿主启动、图形和诊断。
- [游戏配置档案](dm/games/README.md)：支持的版本、游戏专用设置和着色器数据。
- [图形层](dm/gfx/README.md)：NVN 到 Metal 的实现与工具。

## 致谢

本项目建立在他人的工作之上：

- **[seedds/nxnative](https://github.com/seedds/nxnative)**：Lordran Native 基于该项目开发。感谢 seedds 及其贡献者的工作，为本项目的移植工作提供了基础。
- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)**（MIT）：开发了原生运行方案，nxnative 的基础工作参考了这一方案。
- **Ryujinx**（MIT）：它的着色器翻译器（`Ryujinx.Graphics.Shader`、`Ryujinx.Common` 和 `Spv.Generator` 1.3.2，原样放在 `dm/third_party/ryujinx`）把游戏的 Maxwell 着色器转成 SPIR-V。宿主行为拿不准时，它对内核和系统服务的模拟也是参考。
- **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)**：它的内核 mesosphère 是 Horizon 同步语义（地址仲裁器、条件变量）的参考。
- **yuzu**：着色器参考工具用到的 Maxwell 指令编码，以及内核行为的交叉核对。
- **[LibHac](https://github.com/Thealexbarney/LibHac)**：在 `dm/tools/nx_extract` 里读取 NSP、把更新叠到本体上。最早的解包用的是 **hactool**。
- **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**：SPIR-V 转 Metal 着色语言。
- **deko3d**（zlib）：`dm/gfx/nvn/nvn_tex.c` 移植了它的贴图布局尺寸算法。
- **libvpx**（VP9 影片）、**stb_vorbis**（影片声音）、**libdeflate**、**bcdec** 和 **NVIDIA FLIP** 连同许可证放在 `dm/third_party`（[清单](dm/third_party/README.md)）。
- 构建时用到 **Capstone**、**lz4**、**fontTools** 和 **XcodeGen**。

## 许可证

采用 MIT 许可证，见 [LICENSE](LICENSE)。第三方组件保留各自的许可证，见[第三方清单](dm/third_party/README.md)。
