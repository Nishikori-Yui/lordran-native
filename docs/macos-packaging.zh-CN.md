# macOS 环境配置与打包

本文介绍 Apple 芯片 Mac 的常规构建流程。配置脚本可以安装公开构建依赖，并使用你自己的游戏文件生成未签名 iOS IPA 或本地 macOS `.app`。

## 开始前

你需要准备：

- 一台运行受支持 macOS 版本的 Apple 芯片 Mac。
- 从 Mac App Store 安装并至少打开过一次、已完成首次设置的 Xcode。脚本会检查 Xcode 是否可用，但不会代你安装 Xcode 或接受许可协议。
- Homebrew。脚本会通过它安装缺少的 Python 3.12、XcodeGen、zstd、SPIRV-Cross 和 .NET 10 SDK。
- 构建时使用你自己的游戏本体 NSP、1.0.3 更新 NSP（`v196608`）和 `prod.keys`。脚本不会下载这些文件。
- 足够的空闲磁盘空间，用于 NSP、解包与 shader 缓存以及最终产物。macOS `.app` 会包含本机游戏数据副本，可能有数 GB。

NSP、密钥、构建输出和最终 App 都应保存在仓库中被 Git 忽略的 `game/` 目录。不要提交或上传这些文件。

## 配置构建环境

打开「终端」，进入仓库根目录并执行：

```bash
bash scripts/setup_macos_packaging.sh --target setup-only
```

脚本会检查 Xcode、通过 Homebrew 安装缺少的依赖，在仓库私有目录
`game/01004AB00A260000/tools-venv-mac` 创建 Python 环境，安装 `lz4`、
`capstone` 和 `fonttools`，并运行只读的 `doctor` 检查。它不会解包 NSP、读取密钥内容、签名 App 或修改 Xcode 设置。

也可以在同一条命令中完成配置和构建。若要使用下面示例中的默认输入路径，请先把自己的文件复制到：

```text
game/01004AB00A260000/
  prod.keys
  [01004AB00A260000][v0].nsp
  [01004AB00A260800][v196608].nsp
```

NSP 文件名可以不同，但该目录中必须包含一个受支持的本体版本及对应的 `v196608` 更新包。

## 构建 iOS IPA

在仓库根目录执行下面的命令，可一次完成环境配置和打包：

```bash
bash scripts/setup_macos_packaging.sh \
  --target ipa \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys"
```

未签名 IPA 默认输出到 NSP 同目录，文件名为 `DarkSoulsRemastered.ipa`。脚本会进一步检查归档结构和 CRC。请使用你自己的侧载工具签名并安装 IPA；配置脚本不会签名，也不会保存签名凭据。

用 `--out` 可以指定 `game/` 下的其他输出位置：

```bash
bash scripts/setup_macos_packaging.sh \
  --target ipa \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys" \
  --out "$PWD/game/01004AB00A260000/LordranNative-test.ipa"
```

## 构建 macOS App

如需生成本机 Mac App，而不是 iOS IPA，执行：

```bash
bash scripts/setup_macos_packaging.sh \
  --target macos-app \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys"
```

生成的 `game/01004AB00A260000/LordranNative.app` 包含 Mac 宿主、改写后的游戏模块、选定版本的 RomFS、macOS Metal shader 库和所需字体。NSP 和密钥不会复制到 App 中。该 App 未签名；如果 Gatekeeper 提示风险，可在 Finder 中右键选择「打开」，确认后启动。

首次启动会在以下位置创建可写数据：

```text
~/Library/Application Support/Lordran Native/
  save/
  temp/
  logs/lordran-native.log
```

替换或移除 App 前，如果要保留进度，请备份 `save/`。App 限制同时运行的实例数量为一个，并打开普通 Mac 游戏窗口。首次着色器构建和 App 组装可能需要较长时间。

配置脚本不会覆盖已经存在的 `.app`。如需明确替换，可在配置完成后直接使用底层打包器：

```bash
game/01004AB00A260000/tools-venv-mac/bin/python \
  scripts/build_ipa_from_nsp.py game/01004AB00A260000 \
  --keys game/01004AB00A260000/prod.keys \
  --target macos-app \
  --out game/01004AB00A260000/LordranNative.app \
  --replace
```

不带 `--replace` 时，如果目标 App 已存在，打包器会拒绝覆盖。App 必须保存在当前 checkout 的 `game/` 私有目录中，因为它包含你的游戏数据。

## 可选：保留解包文件

默认情况下，打包成功后会删除临时解包的游戏文件。shader 翻译缓存会继续保存在私有游戏工作目录中。若还想保留解包文件，可在配置脚本命令中加入 `--keep-extracted`：

```bash
bash scripts/setup_macos_packaging.sh \
  --target ipa \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys" \
  --keep-extracted
```

如果配置或打包失败，可运行 `game/01004AB00A260000/tools-venv-mac/bin/python
scripts/player_support.py doctor --route mac`，并按检查结果处理。更底层的手动构建步骤见[开发文档](development.md#build-by-hand-mac)。
