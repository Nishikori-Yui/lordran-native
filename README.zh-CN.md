# Lordran Native

[English](README.md) | [简体中文](README.zh-CN.md)

Lordran Native 将 **《黑暗之魂：重制版》**（`01004AB00A260000`）原生带到 Apple 平台。游戏的 ARM64 代码直接在 Apple 硬件上执行，改写器适配依赖内核的指令，宿主提供 Horizon 系统服务，图形层通过 Metal 实现 NVN。

本项目基于 [seedds/nxnative](https://github.com/seedds/nxnative)，现独立维护，专注于《黑暗之魂：重制版》的移植。

**项目仍处于实验阶段。** 当前主要在 Mac 上进行移植和调试；iOS 构建可生成用于 iPhone 和 iPad 的未签名 IPA，图形表现和设备兼容性仍需验证。本仓库目前只支持《黑暗之魂：重制版》（`01004AB00A260000`）。

你需要自行准备游戏 NSP 和 `prod.keys`。仓库不含游戏文件或密钥，项目与任天堂及游戏发行商无关。

## 准备条件

- 常规构建路径：一台安装 Xcode 和 Homebrew 的 Apple 芯片 Mac。
  [Mac 打包说明](docs/macos-packaging.zh-CN.md)提供了一键环境配置脚本，可生成
  iOS IPA 或本地 macOS App。
- Windows 实验性壳构建路径：64 位 Windows 10/11，以及包含自动化
  PowerShell 配置脚本的[Windows 打包说明](docs/windows-packaging.zh-CN.md)。
- 游戏本体 NSP 和 **1.0.3 更新**（`v196608`）。即使打包本体版本，也需要这两份文件来提取着色器。
- 你自己的 `prod.keys`。
- 如需使用 IPA：运行 **iOS / iPadOS 26 或更高版本**的 iPhone 或 iPad，以及侧载工具。
- 空闲磁盘空间约为 NSP 总大小的两倍，再加 10 GB。

## Mac 一键配置

请先从 Mac App Store 安装 Xcode，并安装 Homebrew。在仓库根目录执行下面整段，即可安装其余公开工具并检查环境；该命令不会读取游戏文件。中国大陆网络建议使用以下中科大 Homebrew 和清华 PyPI 镜像设置，仅影响当前终端及其子进程：

```bash
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
bash scripts/setup_macos_packaging.sh --target setup-only
```

请在同一终端中执行后续命令。镜像不覆盖 Xcode、部分 cask 和上游源码下载；镜像同步延迟或不可用时，按 [Mac 打包说明](docs/macos-packaging.zh-CN.md#镜像覆盖范围与官方源回退)切回官方源，不要关闭校验。

如需一次完成配置并构建未签名 iOS IPA：

```bash
bash scripts/setup_macos_packaging.sh \
  --target ipa \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys"
```

如需改为构建本地 macOS `.app`，更换目标参数：

```bash
bash scripts/setup_macos_packaging.sh \
  --target macos-app \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys"
```

构建前请把自己的游戏本体 NSP、`v196608` 更新 NSP 和 `prod.keys` 放入私有目录 `game/01004AB00A260000/`。脚本只安装公开工具，不会下载游戏文件或密钥。Xcode 要求、产物位置、存档、覆盖已有 App 和故障排查见 [Mac 打包说明](docs/macos-packaging.zh-CN.md)。

## 让 agent 帮你完成

如果你使用能读取本机文件、执行命令的 Codex、Claude Code 等 agent，可以复制下面的提示。[玩家辅助 skill](skills/lordran-native-support/SKILL.md) 会按任务选择现有文档和工具，直接读取即可使用；也可以通过 agent 支持的方式安装。请使用同一仓库版本的 skill，并告诉 agent 你正在使用的本地 checkout 或 Release。

**准备环境并打包：**

```text
请帮助我在这台 macOS 或 Windows 电脑上准备 Lordran Native 环境。读取
https://raw.githubusercontent.com/Nishikori-Yui/lordran-native/main/skills/lordran-native-support/SKILL.md
并遵循其中链接的适用仓库文档。检查已经安装的工具，协助补齐缺少的依赖，
准备好之后，用匹配的源码和空壳打包我拥有的本地游戏输入。
游戏文件和密钥保留在本机。遇到管理员确认或需要手动安装 SDK 的步骤时，
请告诉我具体操作并等待。验证未签名产物，说明实际完成了哪些检查。
```

**整理问题反馈：**

```text
请根据我提供的诊断报告和复现描述，整理 Lordran Native 的问题反馈。读取
https://raw.githubusercontent.com/Nishikori-Yui/lordran-native/main/skills/lordran-native-support/SKILL.md
以及其中链接的当前 issue 模板。检查并脱敏相关证据，未证实的信息标为未知，
给我一份可以预览、直接粘贴的 Markdown；如有匹配的现有 issue，也请提出。
这次只整理反馈，发布或开始修改代码之前请先询问。
```

整理反馈不需要 GitHub 登录或构建环境。没有本地 checkout 时，agent 也可以读取公开模板，在对话中生成草稿。分享前请核对脱敏内容。

### 本地辅助命令

在 checkout 中可以使用下列 Python 命令执行检查。Windows 将 `python3` 换成 `py -3`，或直接使用虚拟环境的 Python 路径。它们复用现有打包器和模板。

```sh
# 检查工具，不安装软件，也不提取游戏输入。
python3 scripts/player_support.py doctor

# 在 game/ 下生成带时间戳的反馈草稿和日志摘录。
python3 scripts/prepare_issue.py "诊断报告的路径.txt" --symptom "描述遇到的问题" --step "描述触发问题的操作"

# 查看打包命令，暂不执行。
python3 scripts/player_support.py build game/01004AB00A260000 --keys game/01004AB00A260000/prod.keys --dry-run

# 检查实机 IPA，不安装也不运行。
python3 scripts/player_support.py verify game/01004AB00A260000/LordranNative.ipa
```

准备好后移除 `--dry-run`，工具会在环境检查通过后调用现有打包器，并检查生成的归档。Windows 还需要 `--shell` 和[Windows 文档](docs/windows-packaging.zh-CN.md)中的工具指纹。辅助打包默认采用带时间戳的文件名；如果明确指定的输出文件已存在，需要先确认覆盖，再使用 `--replace`。

Doctor 会报告缺少的依赖、提取工具项目所需的 SDK、profile/chain 一致性及可用磁盘空间。用 `doctor --route shell --shell <匹配的空壳.zip>` 可以同时执行空壳消费端的兼容性检查；下载空壳前检查环境时可以省略 `--shell`。它不会安装软件或验证密钥文件内容。

归档检查覆盖 arm64 平台、App 结构、游戏数据标记、shader 清单及反射 chain，区分空壳输入、实机 IPA 和 Simulator 归档；后者需指定 `--target simulator`。可选的 `--full-crc` 会读取所有归档成员检查 CRC；`--match-source` 还要求归档包含与当前 checkout 完全匹配的空壳 manifest。默认不比对源码指纹，不据此认定签名有效或游戏已通过运行验证。

性能报告使用 `--kind performance`。已知时可填写 `--expected`、`--actual`、`--frequency`，或多次使用 `--step`；仅在独立确认源码版本后填写 `--build`。工具保留当前与历史日志的区别，并将元数据标明为导出快照。它不改动原报告、不发布 issue，也不发起网络请求。可选的 `--issues-json <文件>` 可读取本地 `gh issue list --state all --json number,title,state --limit 100` 快照，给出供核对的标题匹配候选；标题匹配不等于已经确认重复。`--out-dir` 可以指定 `game/` 下的其他私有输出目录。

## 构建未签名 IPA

### 1. 安装构建工具

```sh
git clone https://github.com/Nishikori-Yui/lordran-native.git lordran-native
cd lordran-native
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m venv game/01004AB00A260000/tools-venv
source game/01004AB00A260000/tools-venv/bin/activate
python -m pip install lz4 capstone fonttools
```

构建还需要 .NET 10 SDK 和 Xcode 的 Metal 编译器。若包管理器安装了不同主版本的 SDK，请按 doctor 报告安装与项目要求匹配的 SDK；保留其他仍在使用的 SDK。后续检查和构建都使用虚拟环境中的 Python。

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

另有默认关闭的打包选项 `--experimental-60fps`，仅为已核验的 1.0.3 构建调整限帧参数，
同时检查 build ID 和原始指令。它保留限帧函数，不保证游戏计时正确或稳定达到 60 FPS，
不能与导入的金手指、补丁一起使用。

构建时可实验性地导入本地金手指和 IPS/IPS32 补丁（包括 60 FPS 候选），并可启用游玩中开关。
补丁必须匹配 main NSO 构建 ID。运行时模式默认全部关闭；iOS 从浮动菜单进入「金手指」，Mac 按 F6 打开菜单、F7/F8 选择、F9 切换。
支持的格式和使用方法见[开发文档](docs/development.md#experimental-static-cheats-and-60-fps-patches)。

如需在 Apple 芯片 Mac 上构建实验性的 iOS 模拟器版本，请参照[模拟器构建步骤](docs/development.md#build-for-ios-simulator-apple-silicon)。此版本输出独立的 `.app.zip`，与真机 IPA 分开。

### 在 Windows 上打包（无需 Xcode）

这是一条不需要 Xcode 的实验性路径。完整步骤见[Windows 打包说明](docs/windows-packaging.zh-CN.md)，其中提供了一个 PowerShell 脚本：它会安装公开构建依赖、构建指定版本的 SPIRV-Cross、创建仓库内的 Python 环境并执行只读环境检查。脚本不会下载 NSP、密钥或其他私人游戏数据。

在仓库根目录的 PowerShell 中直接执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -PipIndexUrl 'https://pypi.tuna.tsinghua.edu.cn/simple'
```

这里显式选择清华 PyPI 镜像，仅用于 Python 依赖，不会修改全局 pip 设置。Windows 脚本使用 pip 隔离模式，不能只设置 `PIP_INDEX_URL`。其他工具仍从原有官方渠道下载；官方源重试命令和覆盖范围见 [Windows 镜像说明](docs/windows-packaging.zh-CN.md#国内镜像的范围与官方源回退)。

不需要先安装 winget 或 Microsoft Store：脚本优先复用兼容工具，只为缺少的依赖使用 winget 或通过校验的官方便携下载；加上 `-NoWinget` 可明确使用官方下载。已有 Clang/MinGW 编译器通过探测后也可复用；只有没有可用 C++ 编译器时才需要 Visual Studio 安装程序，此时可能请求管理员确认。公开工具和 SPIRV-Cross 需要联网下载。运行结束后会打印后续打包所需的程序路径和 SHA-256。然后从同一个 Release 下载匹配的壳 ZIP，并把游戏本体 NSP、1.0.3 更新 NSP 和自己的 `prod.keys` 放入私有的 `game/01004AB00A260000/` 目录（该目录已被 Git 忽略）。

新的壳文件名包含准确的 Release tag，例如 `LordranNative-shell-build-input-v0.2.0.zip`；开发构建则使用 `dev-<12 位 commit>`。这里只是命名示例，并非建议使用尚未发布的 tag。保留下载时的文件名。`-Build` 会在上述目录中查找唯一的新版或旧版壳 ZIP；如果存在多个候选文件，必须用 `-ShellZip <匹配的文件>` 明确选择。历史 Release 的无版本资产保持不变，文件名也不能代替源码与 manifest 兼容性检查。

准备好这 4 个输入文件后，也可以在一次运行中完成依赖配置和 IPA 构建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -PipIndexUrl 'https://pypi.tuna.tsinghua.edu.cn/simple' -Build
```

如果已经完成环境配置，加上 `-SkipInstall -SkipSpirvCross -Build` 即可重新检查已保存的工具链并打包，无需重复安装。脚本会校验生成的 IPA；签名和侧载仍由你自行完成。

如果不使用上面的自动配置脚本、而是按照 [Windows 文档](docs/windows-packaging.zh-CN.md#2-环境要求)的备用流程操作，请先配置指定版本的 SPIRV-Cross 并记录 `$spirvCrossSha256`。建议在仓库的私有 `game/` 目录中创建虚拟环境，并直接调用其解释器；这样无需修改 PowerShell 执行策略，也不会把依赖装到其他 Python 环境：

```powershell
py -3 -m venv game/01004AB00A260000/tools-venv
$python = (Resolve-Path game/01004AB00A260000/tools-venv/Scripts/python.exe).Path
& $python -m pip install --index-url 'https://pypi.tuna.tsinghua.edu.cn/simple' lz4 capstone fonttools
& $python scripts/player_support.py doctor --route shell
$Shell = 'game/01004AB00A260000/LordranNative-shell-build-input-v0.2.0.zip' # Use your downloaded filename.
& $python scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell $Shell `
  --spirv-cross-sha256 $spirvCrossSha256
```

下载空壳后，用同一解释器运行 `scripts/player_support.py doctor --route shell --shell $Shell`。也可以先用 `scripts/player_support.py build ... --dry-run` 预览，再执行构建；使用 `verify <IPA> --full-crc` 检查归档。命令选项和校验边界见上方「本地辅助命令」及 [Windows 打包说明](docs/windows-packaging.zh-CN.md)。

壳和源码必须来自同一个 Release。构建前先按 [Windows 打包说明](docs/windows-packaging.zh-CN.md) 从指定源码构建 SPIRV-Cross，并将其 SHA-256 保存到 `DM_SPIRV_CROSS_SHA256`，或通过 `--spirv-cross-sha256` 传入。脚本会校验游戏标题及档案登记的模块构建号，在本机改写游戏模块并生成未签名 IPA。NSP、密钥、解包文件和生成的 IPA 都不会上传。此无 Xcode 流程会把着色器源码放进 IPA，首次启动时由 iPhone 编译；首次进入场景可能需要等待数分钟。Mac 的常规流程仍会预先编译着色器。壳 ZIP 只是打包输入，不是可安装 App；请对最终生成的 IPA 进行签名和侧载。

### App 版本与构建身份

原生 iOS、Simulator、macOS App 和新壳构建使用同一个版本解析器。准确位于 `v0.2.0`
tag 时，显示版本为 `0.2.0`；Apple 构建版本为 `1.2.0`，首段是 tag 的主版本号加一，
以满足 Apple 对构建版本首段必须为正数的要求。`v0.2.0-rc.1+build.7` 等预发布和构建后缀
完整保存在源码身份中，不写入 Apple 数字版本字段。任意非 SemVer tag 使用显示版本
`0.0.0` / 构建版本 `1.0.0`，仍保留完整 tag。

开发 commit 使用 `0.0.0` / `1.0.0` 和 `dev-<commit>`，不会回退到最近的旧 tag。
本地代码修改使用 `dev-<commit>-dirty-<内容哈希>` 和开发数字回退，不冒充干净 Release。
没有 `.git` 的源码下载使用 `dev-source-<内容哈希>`，不会猜测 Release。Windows 打包即使
没有 Git，也会保留预编译壳的版本身份。旧壳保留原版本，以源码指纹标识，不猜测 tag。
完整身份存储在 `dm/app-version.json`，会进入 iOS 诊断导出和 macOS App 启动日志。
字段限制见 [Mac 指南](docs/macos-packaging.zh-CN.md#app-版本元数据)和
[Windows 指南](docs/windows-packaging.zh-CN.md#app-版本元数据)。

### 4. 侧载 IPA

使用你的侧载工具签名并安装未签名 IPA。App 会采用 NSP 中的游戏名称和图标。

默认 Bundle ID 为 `dev.nishikori.lordran-native`，原生打包、Simulator 和 CI 空壳使用同一默认值。两个 Python 打包器及辅助打包命令均可用 `--bundle-id` 覆盖，手动构建可设置 `DM_BUNDLE_ID`。Windows 注入默认继承空壳的 ID，Guest framework 使用 `<app-bundle-id>.guest`。

## 操作方式

- **触屏：** 左摇杆控制移动。3D 布局下，在屏幕空白处滑动可转动视角，滑动位移会累积到游戏读取时再消费，不再被显示回调中的零值覆盖。正常抬手保留一次待消费输入，取消触摸立即清空；未消费的输入在 100 毫秒后过期。**触控与手柄 → 触屏视角** 中可分别设置横轴、纵轴反转，并将灵敏度调整为 0.05～3 倍，提供慢速（0.5 倍）、标准（1 倍）和快速（2 倍）预设。新 1 倍相当于旧 3 倍；旧设置会一次性换算以保留原响应，点击重置则使用新 1 倍默认值。这些设置同时作用于滑屏和右侧虚拟摇杆，立即生效，并在下次启动时保留。按钮触摸独立处理，R3 用于锁定目标。
- **悬浮菜单：** 点按吸附在屏幕边缘的半透明悬浮球，可打开帧率开关、带时间戳的日志导出和输入设置。进入 **调整按键** 后，拖动带外框的按键可移动位置，拖动右下角手柄可缩放，点画面中央的 **确定** 保存退出。旋转、透明度和形状在当前按键的设置中调整。
- **手柄：** 连接实体手柄后，触屏按键默认隐藏，手柄提供完整按键布局。菜单中可以选择当前手柄、自动识别任天堂/Xbox 按键映射，并调整摇杆死区。
- **Mac：** 可使用 DualSense 手柄，或 PC 风格的键盘和鼠标映射。启动宿主时设置 `DM_WINDOW=1`，即可打开游戏窗口。

## 设置与存档

在 iOS 的「文件」App 中打开本应用的文件夹。语言、运行模式、帧率显示和其他输入设置都在半透明悬浮菜单中修改。语言和运行模式修改后会二次确认并退出应用，下一次启动时游戏会加载新设置。其他诊断开关仍可写入 `Documents/env.txt`，每行填写一个 `KEY=VALUE`。

语言、运行模式和性能浮层由悬浮菜单管理，请不要再把这三个值写入 `env.txt`。

性能浮层显示实际上屏 FPS 和帧时间。点击可展开或收起游戏 FPS、GPU 耗时、内存、分辨率和温控状态。

Mac 在游戏画面右上角直接显示荧光绿性能文字，没有底框或按钮。
按 **F5** 循环切换 **简洁 → 详细 → 关闭**；部分 Mac 键盘需要按 **Fn-F5**。
**View** 菜单中也有相同入口，显示模式会保存。文字不会拦截鼠标或键盘输入。
详细模式还会显示已保存的分辨率档位、MSAA 和纹理各向异性过滤；
若设置了 `DM_GAME_RES` 诊断覆盖，则显示为 `Override`。

Mac 还提供 **Graphics / 画质** 菜单，可保存并在下次启动时应用以下设置：
内部渲染分辨率 50%、75%、原生或 125%；当前设备支持的 2x/4x/8x MSAA；
2x/4x/8x/16x 纹理各向异性过滤；在支持 MetalFX 的 GPU 上，还可为低于原生的
分辨率档位启用空间超分辨率。设置会在 guest 创建图形资源前应用，
修改后需要重启游戏。

存档位于 `save/`。重装前请备份 `save/` 和 `pso_user.tsv`：部分侧载工具会创建新的应用数据目录。恢复这两项即可保留存档和管线预热清单。

首次进入新场景时，Metal 编译新管线可能造成短暂卡顿。应用会将这些管线记录到 `pso_user.tsv`，供后续启动时预热。

## 排查问题

如果游戏无法启动、意外退出或画面异常，请导出诊断报告：

1. 打开半透明悬浮菜单，点击 **Export log / 导出日志**。隐藏性能浮层后，菜单仍可使用。
2. 通过系统分享面板保存或发送带时间戳的诊断报告（`*-diagnostics-<UTC 时间戳>-<ID>.txt`）。应用的 `diagnostics/` 文件夹中也会保留一份。
3. 附上设备型号、系统版本，以及触发问题的操作步骤。

前台运行异常中断后，下次启动会先提供诊断导出入口，再启动游戏。报告包含本次和上次运行日志、设备与 GPU 信息、性能快照，每份日志最多保留末尾 8 MiB。报告不包含存档、游戏文件或系统崩溃报告。

也可以直接从应用文件夹中获取 `log.txt` 和 `log.prev.txt`。新日志使用精确到毫秒的 UTC 时间戳，旧版本保留的日志维持原文。构建失败时，请查看 NSP 旁的 `01004AB00A260000_build/logs/`。

可以把诊断报告和复现步骤交给 agent，按[反馈提示](#让-agent-帮你完成)生成可复制的 issue 草稿，也可以自行填写模板。不要把完整私有日志放进公开 issue；本地工具生成的草稿和摘录仍需你检查，因为自动脱敏无法识别所有私人信息或自定义凭据。

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
