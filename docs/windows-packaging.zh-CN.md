# Windows 打包（实验性）

[English](windows-packaging.md)

本文档**全部使用 PowerShell 语法**，不是 `cmd.exe`。请在 PowerShell 中逐段复制执行。推荐使用 PowerShell 7；Windows PowerShell 5.1 也支持本文档中的命令。安装工具后请重新打开 PowerShell，让新的 `PATH` 生效。

如果你第一次接触这个项目，先了解下面几个文件的含义：

- **仓库：** 本项目的本地源码副本。本文档默认放在 `C:\src\lordran-native`。
- **壳 ZIP：** GitHub Actions 生成的公开、无游戏内容的构建输入，包含原生程序和公开资源，但不是可安装 App。
- **NSP：** 你自己的 Nintendo Switch 游戏包。需要本体和 1.0.3 更新包；仓库不提供这些大文件。
- **`prod.keys`：** 你自己的密钥文件，用来读取 NSP。不要上传，也不要把内容粘贴到日志或 Issue。
- **IPA：** 最后生成的未签名 iOS 安装包，安装前必须使用你自己的 Apple 账号签名。

下面的命令按顺序分段执行，建议始终使用同一个 PowerShell 窗口。终端如果显示了 `PS>` 提示符，不要把提示符本身复制进去。

Windows 打包流程不需要 Xcode，可以生成未签名 iOS IPA：

1. 下载与当前源码版本一致的无游戏壳 ZIP。
2. 从指定源码构建 Windows 版 SPIRV-Cross，并记录 SHA-256。
3. 把自己的 NSP 和 `prod.keys` 放入被 Git 忽略的 `game/` 目录。
4. 执行环境检查、打包和归档校验。
5. 使用自己的 Apple 签名流程签名并侧载 IPA。

壳 ZIP 只是构建输入，不是可安装 App，也不含游戏文件。GitHub Actions
工作流仅在手动运行或推送 tag 时构建；普通提交和 PR 不会触发。Actions
产物保留 30 天。如果 tag 已经有 GitHub Release，工作流还会将 ZIP 上传到
该 Release。

## 快速配置（推荐）

仓库提供了面向首次使用者的 `scripts/setup_windows_packaging.ps1`。它会优先复用兼容的已有工具，只安装缺少的依赖；如果系统中没有 `zstd.exe`，还会下载官方 zstd 命令行工具；随后构建指定版本的 SPIRV-Cross、创建仓库内的 Python 环境并执行只读环境检查。它不会下载或打开 NSP、`prod.keys` 或其他私人游戏数据。

在仓库根目录的普通 PowerShell 中执行下面这一条命令。它只对本次调用临时绕过执行策略，不会永久修改用户或系统策略：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1
```

**不需要先安装 winget，也不需要 Microsoft Store。** 系统中有 `winget` 时，脚本会尝试用它安装缺少的工具；没有时自动改用官方便携下载，winget 安装失败也会转用该路径。如果想明确跳过 winget，可以直接复制这一条：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -NoWinget
```

不使用 winget 时，各项依赖的处理方式如下：

| 依赖 | 缺少兼容版本时，脚本会怎么做 |
| --- | --- |
| Git | 解压 Git for Windows 官方 MinGit 2.56.0.2。 |
| Python | 解压官方 Python 3.12.10 到 `game/01004AB00A260000/tools-python/`，从通过校验的 wheel 安装 pip，不依赖 Windows Installer 服务。 |
| .NET | 解压官方 .NET SDK 10.0.402 ZIP，不修改系统 SDK 安装。 |
| CMake / Ninja | 解压官方 CMake 3.31.12 和 Ninja 1.12.1 ZIP。 |
| C++ 编译器 | 复用 Visual Studio 2022；或探测已有 Clang/MinGW，只有编译、链接、运行 x64 测试程序都成功才采用。没有可用编译器时，启动微软官方 Visual Studio 2022 Build Tools 安装程序。 |
| zstd | 复用已有 `zstd.exe`，或解压固定的官方 1.5.7 归档。 |

公开归档会在解压前检查固定的 SHA-256/SHA-512；Visual Studio 安装程序会在运行前检查有效的微软 Authenticode 签名。便携公共工具和下载缓存默认放在 `$HOME\src` 下，可用 `-ToolRoot` 修改；Python 和 Python 依赖保存在仓库被忽略的 `game/` 目录内。脚本只修改本次进程的 `PATH`，不永久修改用户或系统设置。重新打开 PowerShell 后再次运行脚本，也会找到并复用自己安装的工具。

缺少的工具、Python 依赖和 SPIRV-Cross 源码需要联网下载。便携工具不需要管理员权限；如果没有可用 C++ 编译器，Visual Studio 安装可能弹出 UAC 管理员确认，或要求重启。按提示重启 Windows 后，再运行同一条命令即可。脚本不会绕过管理员权限或组织策略。自动下载面向 x64 Windows，不支持 Windows on ARM。

脚本结束时会打印 SPIRV-Cross 程序路径、SHA-256 文件和实际使用的 Python 解释器路径，请保留这些信息供后续打包使用。自动流程不需要另外打开 Developer PowerShell。

### 一次完成环境配置和打包

配置脚本也可以在依赖安装后直接继续打包。先把与当前源码 checkout 来自同一 Release 的公开壳 ZIP、你自己的游戏本体 NSP、`v196608` 更新 NSP 和 `prod.keys` 放入 `game/01004AB00A260000/`。壳和源码版本必须一致；脚本不会下载壳、游戏文件或密钥。然后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -Build
```

脚本会安装/检查公开工具链、准备 Python 环境、执行壳兼容性预检、构建未签名 IPA 并检查生成的归档。默认使用上面的输入路径，IPA 会以带时间戳的名称输出到 NSP 同目录。若之前已经完成环境配置，可加上 `-SkipInstall -SkipSpirvCross`，脚本会验证已保存的 SPIRV-Cross 程序及其指纹后直接构建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -SkipInstall -SkipSpirvCross -Build
```

可用 `-NspDirectory`、`-KeysFile`、`-ShellZip` 和 `-OutputPath` 指定其他输入/输出路径（都必须位于当前 checkout 的 `game/` 目录下），用 `-Package v0` 选择打包版本，或用 `-KeepExtracted` 保留解包数据。若目标 IPA 已存在，脚本默认拒绝覆盖；确认后再加 `-ReplaceOutput`。

脚本可以安全地再次运行。常用选项如下：

```powershell
# 复用已有工具，不安装缺少的公共工具；Python 依赖仍可能需要下载。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -SkipInstall

# 使用已有的 zstd.exe，不下载脚本提供的便携版本。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -ZstdPath 'C:\tools\zstd.exe'

# 将不符合要求的 SPIRV-Cross 目录移到备份目录，再重新克隆指定源码。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -Force
```

`-SkipVisualStudio` 禁止安装编译器；重新构建 SPIRV-Cross 时，已有 C++ 编译器仍须通过探测。`-SkipSpirvCross` 会验证并复用指定源码 checkout 中的程序和已保存指纹；仅重新打包时，不再要求编译器、CMake 或 Ninja。这些选项都不会跳过壳与源码匹配检查或着色器指纹校验。

配置完成后，继续执行第 5 节的壳下载和私有输入文件步骤。下面的手动安装流程是可选备用方案；缺少 winget 并不需要改用手动安装。

## 1. 手动安装工具（备用流程）

如果还没有 Git、Python 或 .NET，可以先在普通 PowerShell 中执行下面的可选命令。执行完后关闭并重新打开 PowerShell：

```powershell
winget install --id Git.Git -e
winget install --id Python.Python.3.12 -e
winget install --id Microsoft.DotNet.SDK.10 -e
winget install --id Kitware.CMake -e
winget install --id Ninja-build.Ninja -e
```

还需要 `zstd.exe` 和 MSVC C++ 编译器。请安装 Visual Studio 或 Visual Studio Build Tools，并勾选 **使用 C++ 的桌面开发**工作负载；然后安装 Windows 版 zstd，并把包含 `zstd.exe` 的目录加入 `PATH`。如果 `winget` 找不到某个软件，请改用官方安装程序；项目不要求使用特定的软件包管理器。

本文档会用到两种 PowerShell：

- **普通 PowerShell：** 下载仓库、创建 Python 环境和运行打包命令。
- **Visual Studio Developer PowerShell：** 构建 SPIRV-Cross。请从 Visual Studio 开始菜单文件夹打开它，这样 `cl.exe` 和 Windows SDK 会自动配置好。

## 2. 环境要求

准备一台 64 位 Windows 10/11 电脑，并安装：

- x64 Python 3.12 或更高版本。手动命令使用 `py -3`；自动脚本也支持
  `python.exe` 或自己下载的便携 Python。
- .NET 10 SDK。
- Git、CMake、Ninja 和可用的 C++ 工具链。手动示例采用 MSVC，自动脚本也可复用
  通过探测的 Clang/MinGW。使用 MSVC 时，最方便的方式是打开
  **Visual Studio Developer PowerShell**，因为它会自动设置 CMake 所需的编译器环境。
- 加入 `PATH` 的 `zstd.exe`，用于解压着色器容器。
- 构建前至少约 15 GB 可用空间；如果要保留解包文件和缓存，建议至少保留 30 GB。
- 你自己的游戏本体 NSP、1.0.3 更新 NSP（`v196608`）和自己的
  `prod.keys`。不要把密钥放入 Git、Issue 或日志。

请使用所在环境批准的软件源或官方安装程序安装工具。安装后关闭并重新打开
PowerShell。在**同一个将要执行构建的 PowerShell 窗口**中检查工具：

```powershell
$ErrorActionPreference = 'Stop'
py -3 --version
dotnet --list-sdks
git --version
cmake --version
ninja --version
zstd --version
```

第一条命令必须显示 Python 3.12 或更高版本；SDK 列表必须包含 .NET 10。
如果出现「找不到命令」，先修复 `PATH`，不要混用不同 PowerShell 窗口中的工具。

## 3. 下载仓库并设置路径

如果还没有仓库，请在普通 PowerShell 中执行：

```powershell
New-Item -ItemType Directory -Force -Path 'C:\src' | Out-Null
Set-Location 'C:\src'
git clone https://github.com/Nishikori-Yui/lordran-native.git
Set-Location 'C:\src\lordran-native'
```

如果上面使用的版本是某个指定 Release，请把下面的 `v0.1.0` 替换成对应 tag。尽量使用 Release 版本，因为壳 ZIP 和源码必须来自同一个版本；如果你使用开发分支，也必须确保壳和源码来自同一个 commit。

```powershell
git fetch --tags
git checkout v0.1.0
```

现在设置后续命令使用的路径。第一行只在仓库不位于 `C:\src\lordran-native` 时修改。下面这些变量会被后续命令重复使用，因此可以直接复制后面的代码块。

```powershell
$ErrorActionPreference = 'Stop'
Set-Location 'C:\src\lordran-native'

$Repo = (Get-Location).Path
$GameDir = Join-Path $Repo 'game\01004AB00A260000'
$Keys = Join-Path $GameDir 'prod.keys'
$Shell = Join-Path $GameDir 'LordranNative-shell-build-input.zip'
$Output = Join-Path $GameDir 'LordranNative-Windows.ipa'
$BuildWork = Join-Path $GameDir '01004AB00A260000_shell_build'

New-Item -ItemType Directory -Force -Path $GameDir | Out-Null
Write-Host "仓库：$Repo"
Write-Host "私有游戏目录：$GameDir"
```

仓库的 `game/` 目录已被 Git 忽略。NSP、密钥、壳 ZIP、解包文件、日志和
IPA 都应放在这里。打包器会拒绝当前仓库 `game/` 目录之外的输出路径。

## 4. 构建指定版本的 SPIRV-Cross

Windows 必须使用以下精确版本的 SPIRV-Cross：

- 标签：`vulkan-sdk-1.4.357.0`
- 提交：`6c09849fe88c48eaed08413aa022aaa136a3a057`

这一节请在 **Visual Studio Developer PowerShell** 中执行。选择一个空的父目录。
下面的命令如果发现目录已经存在会主动停止，避免误用未知源码构建。

```powershell
$ToolRoot = Join-Path $env:USERPROFILE 'src'
$SpirvCrossRoot = Join-Path $ToolRoot 'SPIRV-Cross'
$SpirvCrossTag = 'vulkan-sdk-1.4.357.0'
$SpirvCrossCommit = '6c09849fe88c48eaed08413aa022aaa136a3a057'

New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
if (Test-Path $SpirvCrossRoot) {
    throw "拒绝复用已有的 SPIRV-Cross 目录：$SpirvCrossRoot"
}

git clone --branch $SpirvCrossTag --depth 1 `
    'https://github.com/KhronosGroup/SPIRV-Cross' $SpirvCrossRoot

$ActualCommit = (git -C $SpirvCrossRoot rev-parse HEAD).Trim()
if ($ActualCommit -ne $SpirvCrossCommit) {
    throw "SPIRV-Cross 提交不符合要求：$ActualCommit"
}

$SpirvCrossBuild = Join-Path $SpirvCrossRoot 'build'
$SpirvCrossBin = Join-Path $SpirvCrossBuild 'bin'
cmake -S $SpirvCrossRoot -B $SpirvCrossBuild -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DSPIRV_CROSS_ENABLE_TESTS=OFF `
    "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=$SpirvCrossBin"
cmake --build $SpirvCrossBuild --target spirv-cross

$SpirvCrossExe = (Resolve-Path (Join-Path $SpirvCrossBin 'spirv-cross.exe')).Path
$SpirvCrossSha256 = (Get-FileHash -Algorithm SHA256 $SpirvCrossExe).Hash.ToLowerInvariant()
$env:Path = "$(Split-Path $SpirvCrossExe);$env:Path"
$env:DM_SPIRV_CROSS_SHA256 = $SpirvCrossSha256
$SpirvCrossHashFile = Join-Path $SpirvCrossRoot 'spirv-cross.sha256'
Set-Content -NoNewline -Path $SpirvCrossHashFile -Value $SpirvCrossSha256

Write-Host "SPIRV-Cross：$SpirvCrossExe"
Write-Host "SPIRV-Cross SHA-256：$SpirvCrossSha256"
```

如果要新开 PowerShell 窗口，请在执行后续打包命令的窗口中运行下面的代码。
构建步骤会把指纹保存到本地构建出的程序旁边；下面的代码会读取保存值，并再次校验
该路径下的程序。不要用未经信任的下载文件替换这两个文件。

```powershell
$SpirvCrossRoot = Join-Path $env:USERPROFILE 'src\SPIRV-Cross'
$SpirvCrossExe = Join-Path $SpirvCrossRoot 'build\bin\spirv-cross.exe'
$SpirvCrossHashFile = Join-Path $SpirvCrossRoot 'spirv-cross.sha256'
if (-not (Test-Path -LiteralPath $SpirvCrossExe -PathType Leaf) -or
    -not (Test-Path -LiteralPath $SpirvCrossHashFile -PathType Leaf)) {
    throw 'SPIRV-Cross 程序或已保存的指纹文件不存在。'
}
$SpirvCrossSha256 = (Get-Content -Raw -LiteralPath $SpirvCrossHashFile).Trim().ToLowerInvariant()
$ActualSpirvCrossSha256 = (Get-FileHash -Algorithm SHA256 $SpirvCrossExe).Hash.ToLowerInvariant()
if ($ActualSpirvCrossSha256 -ne $SpirvCrossSha256) {
    throw 'SPIRV-Cross 程序与已保存的 SHA-256 不匹配。'
}
$env:Path = "$(Split-Path $SpirvCrossExe);$env:Path"
$env:DM_SPIRV_CROSS_SHA256 = $SpirvCrossSha256
Write-Host "已恢复 SPIRV-Cross SHA-256：$SpirvCrossSha256"
```

哈希检查用于发现 `PATH` 指向了其他程序或程序被替换，但哈希本身不能证明源码来源。
不要把 Windows 哈希写入 `dmsh_chain.lock` 或 `dmsh_chain.h`；Windows 和 macOS
编译出的程序指纹不同。

## 5. 放置输入文件并创建 Python 环境

### 下载壳 ZIP

在 GitHub 仓库的 **Releases** 页面打开与上面 checkout 相同的 tag，下载
`LordranNative-shell-build-input.zip`。如果 Release 中没有该文件，就打开仓库的
**Actions** 页面，选择 **Build unsigned iOS shell**，进入同一个 tag 的成功运行记录，
下载名为 `LordranNative-shell-build-input` 的 artifact。

不要使用其他 tag 的壳。壳与源码版本不匹配是构建失败最常见的原因之一。

把壳 ZIP、两个 NSP 和自己的 `prod.keys` 复制到 `$GameDir`。文件名可以不同，但该目录必须包含一个受支持的本体版本及其 `v196608` 更新版本。

检查私有输入是否存在：

```powershell
$Required = @($Keys, $Shell)
foreach ($Path in $Required) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "缺少必需文件：$Path"
    }
}

Get-ChildItem -LiteralPath $GameDir -File |
    Select-Object Name, Length, LastWriteTime
```

如果已经运行自动配置脚本，使用它打印的 Python 路径，跳过下面的创建环境步骤。
重新打开 PowerShell 后，可以这样恢复解释器路径：

```powershell
$Python = Join-Path $GameDir 'tools-venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    $Python = Join-Path $GameDir 'tools-python\python.exe'
}
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw 'Packaging Python is missing. Run the setup script first.'
}
& $Python --version
```

如果采用手动安装的常规 Python，则创建仓库内的虚拟环境并安装依赖：

```powershell
$PythonVenv = Join-Path $GameDir 'tools-venv'
py -3 -m venv $PythonVenv
$Python = (Resolve-Path (Join-Path $PythonVenv 'Scripts\python.exe')).Path

& $Python -m pip install --upgrade pip
& $Python -m pip install lz4 capstone fonttools
& $Python --version
```

本次会话中始终使用 `& $Python ...` 调用脚本。这样不需要修改 PowerShell 执行策略，
也不会把依赖安装到其他 Python 环境。

## 6. 执行构建前检查

先运行 doctor。它会检查本机工具；提供 `--shell` 后，还会检查壳的清单和兼容性数据。

```powershell
& $Python scripts/player_support.py doctor `
    --route shell `
    --shell $Shell `
    --work-dir $BuildWork `
    --spirv-cross-sha256 $SpirvCrossSha256
if ($LASTEXITCODE -ne 0) {
    throw '环境检查失败；请先修复上面的错误。'
}
```

再运行 dry-run。它会检查路径和参数，但不会生成最终 IPA：

```powershell
& $Python scripts/player_support.py build $GameDir `
    --keys $Keys `
    --shell $Shell `
    --out $Output `
    --spirv-cross-sha256 $SpirvCrossSha256 `
    --dry-run
if ($LASTEXITCODE -ne 0) {
    throw 'dry-run 失败；请先修复上面的错误。'
}
```

## 7. 构建未签名 IPA

只有 doctor 和 dry-run 都成功后，才执行正式构建：

```powershell
& $Python scripts/player_support.py build $GameDir `
    --keys $Keys `
    --shell $Shell `
    --out $Output `
    --spirv-cross-sha256 $SpirvCrossSha256
if ($LASTEXITCODE -ne 0) {
    throw 'IPA 构建失败；请查看 game 私有目录下的日志。'
}

Get-Item -LiteralPath $Output | Select-Object FullName, Length, LastWriteTime
```

打包器会检查壳源码指纹、标题号、档案登记的模块构建号、着色器链、着色器清单和
SPIRV-Cross 指纹，然后提取并改写选定的游戏版本，将档案着色器翻译为 MSL，生成
`Guest.framework` 并组装未签名 IPA。日志和中间文件位于 `$BuildWork`。构建成功后
会删除解包文件，除非使用 `--keep-extracted`。

需要直接调试底层打包器时，可以使用：

```powershell
& $Python scripts/build_ipa_from_shell.py $GameDir `
    --keys $Keys `
    --shell $Shell `
    --out $Output `
    --spirv-cross-sha256 $SpirvCrossSha256
```

不要让两个构建进程同时使用同一个 `$GameDir`。

### 可选命令

构建成功后保留解出的 `ExeFS`/`RomFS`：

```powershell
& $Python scripts/player_support.py build $GameDir `
    --keys $Keys `
    --shell $Shell `
    --out $Output `
    --spirv-cross-sha256 $SpirvCrossSha256 `
    --keep-extracted
```

打包已登记的本体版本，而不是默认的 `v196608` 更新版本。更新 NSP 仍然需要提供，
因为它可能用于档案要求的着色器提取和校验：

```powershell
$BaseOutput = Join-Path $GameDir 'LordranNative-base-v0.ipa'
& $Python scripts/player_support.py build $GameDir `
    --keys $Keys `
    --shell $Shell `
    --package v0 `
    --out $BaseOutput `
    --spirv-cross-sha256 $SpirvCrossSha256
```

只有在确实需要自定义 App 身份时才使用 `--bundle-id`，并确保它与壳及
`Guest.framework` 的最终身份保持一致。

## 8. 校验与安装

构建完成后执行归档结构和校验和检查：

```powershell
& $Python scripts/player_support.py verify $Output `
    --target device `
    --full-crc `
    --match-source
if ($LASTEXITCODE -ne 0) {
    throw 'IPA 校验失败。'
}
```

这项检查验证归档结构和 CRC，不代表已经完成游戏运行测试。IPA 按设计是未签名的，
请使用 AltStore、Sideloadly 或其他受支持的工具，用自己的 Apple 身份签名后安装。
Windows 无法运行 Apple Metal 编译器，因此 IPA 内包含 MSL 源码，iOS 会在首次使用
时编译着色器。第一次进入场景可能需要几分钟，后续启动会复用系统缓存。

## 故障排查

- **没有 winget 或 Microsoft Store：** 直接运行配置脚本，或加上 `-NoWinget`，
  不需要先安装 App Installer。官方下载失败时，检查报错中的网址、网络/代理策略及
  剩余磁盘空间，不要关闭哈希校验。
- **没有管理员权限：** 已有 Clang/MinGW 通过编译器探测后，就无需安装 Visual Studio；
  否则需要请管理员安装 C++ 工作负载。`-NoWinget` 不会绕过 UAC。
- **找不到命令：** 重新打开与构建相同类型的 PowerShell，重新执行第 1 节检查。
  构建 SPIRV-Cross 时不要混用普通 PowerShell 和 Developer PowerShell。
- **壳与源码不匹配：** 下载与当前 checkout 相同 Release tag 的壳，不要把 `main`
  的壳与旧源码混用。
- **SPIRV-Cross 指纹不符：** 检查 `Get-Command spirv-cross`、`$SpirvCrossExe`
  和 `$env:DM_SPIRV_CROSS_SHA256`。必要时重新构建指定提交，不要修改仓库着色器锁。
- **缺少 Python 依赖：** 确认 `$Python` 位于
  `game/01004AB00A260000/tools-venv` 或 `tools-python` 内，再执行
  `& $Python -m pip install lz4 capstone fonttools`。
- **标题号或构建号不受支持：** 使用标题 `01004AB00A260000` 和
  `dm/games/01004AB00A260000/game.tsv` 中登记的版本，不要绕过检查。
- **解包失败：** 查看 `$BuildWork` 下的 `nx_extract_build.log` 和
  `extract_<version>.log`，确认两个 NSP 完整、`prod.keys` 有效且磁盘空间充足。
  不要打印密钥内容。
- **壳 ZIP 包含意外文件：** 壳生成端和消费端使用 fail-closed 白名单。不要在未证明
  资源公开且不含游戏派生或私人数据前放宽白名单。
- **IPA 无法安装：** 输出是未签名 IPA。请使用自己的侧载工具签名，不要把证书或
  provisioning profile 加入仓库。
- **首次启动很慢：** Windows 路线使用源码着色器，首次编译时请保持 App 在前台。

该流程仍属实验性。如果可以使用 Mac/Xcode，建议优先使用常规流程，因为它会在安装
前预先编译着色器。
