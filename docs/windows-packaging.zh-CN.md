# Windows 打包（实验性）

[English](windows-packaging.md)

`LordranNative-shell-build-input.zip` 是不含游戏文件的未签名 iOS 构建输入，里面只有宿主可执行文件、公开的游戏档案表格和字体资源，不是可安装 App。`Build unsigned iOS shell` Actions 工作流仅在手动运行或推送 tag 时触发，并上传保留 30 天的 ZIP 产物；普通提交和 PR 不会触发构建。若 tag 已有对应的 GitHub Release，工作流还会将 ZIP 附加到该 Release。若之后才创建 Release，可在该 tag 上手动重跑工作流以附加壳文件。

## 环境要求

- Windows 10/11 x64、Python 3.12 或更高版本、.NET 10 SDK。
- 将 `zstd` 加入 `PATH`，用于解压着色器容器。
- 使用 SPIRV-Cross 上游标签 `vulkan-sdk-1.4.357.0`、提交 `6c09849fe88c48eaed08413aa022aaa136a3a057` 构建的程序。安装 CMake、Ninja 和 C++ 编译器；使用 MSVC 时，在 Visual Studio 的 Developer PowerShell 中执行：

  ```powershell
  git clone --branch vulkan-sdk-1.4.357.0 --depth 1 https://github.com/KhronosGroup/SPIRV-Cross
  if ((git -C SPIRV-Cross rev-parse HEAD) -ne "6c09849fe88c48eaed08413aa022aaa136a3a057") { throw "Unexpected SPIRV-Cross source revision" }
  cmake -S SPIRV-Cross -B SPIRV-Cross/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DSPIRV_CROSS_ENABLE_TESTS=OFF "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=$PWD/SPIRV-Cross/build/bin"
  cmake --build SPIRV-Cross/build --target spirv-cross
  if ($LASTEXITCODE -ne 0) { throw "SPIRV-Cross build failed" }
  $spirvCross = (Resolve-Path SPIRV-Cross/build/bin/spirv-cross.exe).Path
  $spirvCrossSha256 = (Get-FileHash -Algorithm SHA256 $spirvCross).Hash.ToLowerInvariant()
  $env:Path = "$(Split-Path $spirvCross);$env:Path"
  $env:DM_SPIRV_CROSS_SHA256 = $spirvCrossSha256
  ```

- 游戏本体 NSP、1.0.3 更新 NSP（`v196608`）和你自己的 `prod.keys`。
- 大约 15 GB 可用空间，用于解包文件、着色器处理和缓存。

在准备执行构建的同一个 PowerShell 窗口检查工具：

```powershell
py -3 --version
dotnet --list-sdks
spirv-cross --version
zstd --version
```

建议在已被 Git 忽略的 `game/` 目录下创建 Python 虚拟环境，并直接调用其中的解释器。这样不必修改 PowerShell 执行策略，也不会将依赖安装到其他 Python 环境：

```powershell
py -3 -m venv game/01004AB00A260000/tools-venv
$python = (Resolve-Path game/01004AB00A260000/tools-venv/Scripts/python.exe).Path
& $python -m pip install lz4 capstone fonttools
& $python scripts/player_support.py doctor --route shell
```

下载空壳前，doctor 只检查本机工具。取得匹配的空壳后，通过 `--shell` 增加兼容性检查。同一解释器还可在打包前运行 `scripts/player_support.py build ... --dry-run`，打包后运行 `scripts/player_support.py verify <IPA> --full-crc`。这些是结构检查，不代表已运行游戏。

Windows 使用你从指定上游源码构建的可执行文件的完整 SHA-256。可通过 `--spirv-cross-sha256` 传入，也可在构建会话中保留 `DM_SPIRV_CROSS_SHA256`。配置工具链时保存该值，在新会话中恢复；不要从未经信任的替换程序重新计算指纹。此检查用于发现 `PATH` 指向了其他程序或二进制被替换，哈希本身不能证明源码来源。整个流程不需要私有工具链记录。macOS 仍校验仓库锁定的 Mac 二进制指纹；不要把 Windows 哈希写入 `dmsh_chain.lock` 或 `dmsh_chain.h`。

## 构建

源码仓库与壳必须来自同一个 GitHub Release。请把 NSP、密钥、构建中间文件和 IPA 都放在 `game/` 下；该目录已被 Git 忽略。

```powershell
& $python scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip `
  --spirv-cross-sha256 $spirvCrossSha256
```

打包器会校验壳的源码指纹、游戏档案、着色器链版本和着色器清单，并在读取 NSP 前检查工具链；识别 NSP 标题号与版本，按档案核对改写后的模块构建号，编译仓库内的着色器翻译器，提取和改写所选游戏版本，将全部档案着色器翻译为 MSL，生成 `Guest.framework` 并组装 IPA。开始翻译时还会再次校验工具指纹。中间文件和日志保存在 `<NSP 文件夹>/01004AB00A260000_shell_build/`；成功后会删除解包目录，传入 `--keep-extracted` 则保留。要打包本体版本可加 `-p v0`，但仍须提供档案要求的着色器版本。

常用选项：

```powershell
# 构建成功后保留解出的 ExeFS/RomFS。
& $python scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip `
  --keep-extracted

# 打包已登记的本体版本，而不是默认更新版本。
& $python scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip `
  --package v0 `
  --out game/01004AB00A260000/DarkSoulsRemastered-v0.ipa

# 查看全部参数，不会读取游戏文件。
& $python scripts/build_ipa_from_shell.py -h
```

输出路径必须位于当前仓库的 `game/` 下。默认输出为 `<NSP 文件夹>/DarkSoulsRemastered.ipa`。不要让两个打包进程同时使用同一个工作目录。

## 安装与首次启动

从 Actions 下载的 ZIP 只是壳构建输入。请用 AltStore 或 Sideloadly 等工具对最终 IPA 签名和侧载；该工具需要用你自己的身份替换占位签名信息。Windows 无法运行 Apple Metal 编译器，因此 IPA 会将 MSL 源码作为着色器库内容。iOS 首次使用时会逐个编译着色器并缓存；首次加载场景可能要等几分钟。之后的启动会复用系统缓存。此流程尚未在所有 iOS 设备上验证。

## 故障排查

- **壳与源码不匹配：** 下载与源码检出版本相同的 Release。
- **标题号或构建号不受支持：** 使用《黑暗之魂：重制版》本体 NSP 和档案已登记的版本。本仓库只支持标题 `01004AB00A260000`。
- **缺少工具：** 在同一个 PowerShell 会话中确认 `dotnet`、`spirv-cross`、`zstd` 和选定的 Python 可用，并把 `lz4`、`capstone`、`fonttools` 安装到该 Python 解释器。
- **SPIRV-Cross 指纹缺失或不符：** 按上面说明从指定上游提交构建，记录完整 SHA-256，通过 `--spirv-cross-sha256` 或 `DM_SPIRV_CROSS_SHA256` 提供，并确认 `Get-Command spirv-cross` 指向该程序。Windows 编译产物与仓库锁定的 Mac 二进制指纹不同，不要因此修改共享锁。
- **解包失败：** 查看对应的 `nx_extract_build.log` 或 `extract_<version>.log`；确认本体和更新 NSP 完整、密钥是用户自己的有效 `prod.keys`，且磁盘空间足够。不要打印或复制密钥到日志。
- **模块构建号不匹配：** NSP 版本未登记在 `dm/games/01004AB00A260000/game.tsv`；停止，不要绕过校验。
- **壳 ZIP 路径缺失或多出文件：** 壳生成端和消费端的白名单采用 fail-closed。添加资源前必须先证明它是公开数据且不含游戏派生或私人内容，不要直接放宽白名单。
- **IPA 无法安装：** 打包器按设计输出未签名 IPA。使用受支持的侧载工具以用户自己的身份签名；不要添加 CI 签名或提交证书/描述文件。
- **着色器链不匹配或着色器缺失：** 使用匹配的壳与源码版本，以及上面指定的 SPIRV-Cross 标签；不要混用其他构建的着色器缓存。
- **首次启动很慢：** 使用源码着色器的 IPA 会如此。首次编译时保持 App 在前台，直到完成。

该流程仍属实验性。如果可以使用 Mac/Xcode，建议优先使用常规流程，因为它会在安装前编译好着色器。
