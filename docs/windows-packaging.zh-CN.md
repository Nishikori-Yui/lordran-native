# Windows 打包（实验性）

[English](windows-packaging.md)

`LordranNative-shell-build-input.zip` 是不含游戏文件的未签名 iOS 构建输入，里面只有宿主可执行文件、公开的游戏档案表格和字体资源，不是可安装 App。`Build unsigned iOS shell` Actions 工作流仅在手动运行或推送 tag 时触发，并上传保留 30 天的 ZIP 产物；普通提交和 PR 不会触发构建。若 tag 已有对应的 GitHub Release，工作流还会将 ZIP 附加到该 Release。若之后才创建 Release，可在该 tag 上手动重跑工作流以附加壳文件。

## 环境要求

- Windows 10/11 x64、Python 3.12 或更高版本、.NET 10 SDK。
- 将 `zstd` 加入 `PATH`，用于解压着色器容器。
- 使用 SPIRV-Cross 上游标签 `vulkan-sdk-1.4.357.0` 构建的程序。安装 CMake 和 Ninja，然后执行：

  ```powershell
  git clone --branch vulkan-sdk-1.4.357.0 --depth 1 https://github.com/KhronosGroup/SPIRV-Cross
  cmake -S SPIRV-Cross -B SPIRV-Cross/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DSPIRV_CROSS_ENABLE_TESTS=OFF
  cmake --build SPIRV-Cross/build --target spirv-cross
  $env:Path += ";$PWD\SPIRV-Cross\build\bin\Release"
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

着色器翻译阶段会校验 SPIRV-Cross 二进制指纹。若按上面的源码标签构建出的程序仍与仓库锁定值不同，脚本会停止，不会默默使用其他翻译器。请按错误提示处理；不要为了绕过错误而修改 `dmsh_chain.lock` 或 `dmsh_chain.h`。

## 构建

源码仓库与壳必须来自同一个 GitHub Release。请把 NSP、密钥、构建中间文件和 IPA 都放在 `game/` 下；该目录已被 Git 忽略。

```powershell
py -3 -m pip install lz4 capstone fonttools
py -3 scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip
```

打包器会校验壳的源码指纹、游戏档案、着色器链版本和着色器清单；识别 NSP 标题号与版本，按档案核对改写后的模块构建号，编译仓库内的着色器翻译器，提取和改写所选游戏版本，将全部档案着色器翻译为 MSL，生成 `Guest.framework` 并组装 IPA。中间文件和日志保存在 `<NSP 文件夹>/01004AB00A260000_shell_build/`；成功后会删除解包目录，传入 `--keep-extracted` 则保留。要打包本体版本可加 `-p v0`，但仍须提供档案要求的着色器版本。

常用选项：

```powershell
# 构建成功后保留解出的 ExeFS/RomFS。
py -3 scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip `
  --keep-extracted

# 打包已登记的本体版本，而不是默认更新版本。
py -3 scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip `
  --package v0 `
  --out game/01004AB00A260000/DarkSoulsRemastered-v0.ipa

# 查看全部参数，不会读取游戏文件。
py -3 scripts/build_ipa_from_shell.py -h
```

输出路径必须位于当前仓库的 `game/` 下。默认输出为 `<NSP 文件夹>/DarkSoulsRemastered.ipa`。不要让两个打包进程同时使用同一个工作目录。

## 安装与首次启动

从 Actions 下载的 ZIP 只是壳构建输入。请用 AltStore 或 Sideloadly 等工具对最终 IPA 签名和侧载；该工具需要用你自己的身份替换占位签名信息。Windows 无法运行 Apple Metal 编译器，因此 IPA 会将 MSL 源码作为着色器库内容。iOS 首次使用时会逐个编译着色器并缓存；首次加载场景可能要等几分钟。之后的启动会复用系统缓存。此流程尚未在所有 iOS 设备上验证。

## 故障排查

- **壳与源码不匹配：** 下载与源码检出版本相同的 Release。
- **标题号或构建号不受支持：** 使用《黑暗之魂：重制版》本体 NSP 和档案已登记的版本。本仓库只支持标题 `01004AB00A260000`。
- **缺少工具：** 在同一个 PowerShell 会话中确认 `dotnet`、`spirv-cross`、`zstd` 和 `py -3` 可用，并把 Python 依赖安装到该 Python 解释器。
- **SPIRV-Cross 指纹不符：** 使用与 `dm/gfx/tools/dmsh_chain.lock` 锁定内容匹配的二进制。仅使用相同源码标签不保证二进制指纹一致。除非有意更换整个项目的着色器工具链，否则不要修改锁。
- **解包失败：** 查看对应的 `nx_extract_build.log` 或 `extract_<version>.log`；确认本体和更新 NSP 完整、密钥是用户自己的有效 `prod.keys`，且磁盘空间足够。不要打印或复制密钥到日志。
- **模块构建号不匹配：** NSP 版本未登记在 `dm/games/01004AB00A260000/game.tsv`；停止，不要绕过校验。
- **壳 ZIP 路径缺失或多出文件：** 壳生成端和消费端的白名单采用 fail-closed。添加资源前必须先证明它是公开数据且不含游戏派生或私人内容，不要直接放宽白名单。
- **IPA 无法安装：** 打包器按设计输出未签名 IPA。使用受支持的侧载工具以用户自己的身份签名；不要添加 CI 签名或提交证书/描述文件。
- **着色器链不匹配或着色器缺失：** 使用匹配的壳与源码版本，以及上面指定的 SPIRV-Cross 标签；不要混用其他构建的着色器缓存。
- **首次启动很慢：** 使用源码着色器的 IPA 会如此。首次编译时保持 App 在前台，直到完成。

该流程仍属实验性。如果可以使用 Mac/Xcode，建议优先使用常规流程，因为它会在安装前编译好着色器。
