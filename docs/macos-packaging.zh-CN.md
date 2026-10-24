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

打开「终端」，进入仓库根目录。中国大陆网络建议先在**当前终端窗口**设置中科大 Homebrew 镜像和清华 PyPI 镜像，再运行配置脚本；下面整段可以直接复制：

```bash
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
bash scripts/setup_macos_packaging.sh --target setup-only
```

这些设置也适用于同一窗口里后续的 `--target ipa`、`--target macos-app` 和手动 `brew` / pip 命令。它们不写入 shell 配置文件，也不修改 Git remote；新开的终端不会继承本次设置。脚本不根据系统语言自动选择镜像。

### 镜像覆盖范围与官方源回退

- Homebrew 的软件包元数据和可用的预编译 bottle 使用中科大镜像；Python 包使用清华镜像。保留 HTTPS 和包管理器原有的完整性检查。
- 镜像**不是所有下载的代理**。Xcode 仍从 Apple 获取；Homebrew cask（例如 .NET SDK）和源码包可能仍从上游获取。Homebrew 自身的 Git 更新、GitHub 仓库、Release 壳 ZIP、NuGet 等未在此处换源。
- 仅替换公开工具和依赖的下载源，不会把 NSP、密钥、缓存或生成的 IPA / App 发送给镜像站。
- Homebrew 尚未安装时，先按 [Homebrew 官方说明](https://brew.sh/)安装；也可参考[中科大的 Homebrew 说明](https://mirrors.ustc.edu.cn/help/brew.git.html)。不要运行来源不明的“一键换源”脚本。

镜像可能有同步延迟，也可能对当前网络限制访问。如果遇到超时、HTTP 403、缺少版本或哈希不匹配，不要关闭证书验证或修改校验值。pip 的 `No matching distribution` 也可能由镜像访问失败引起，先检查前面是否有 `Could not fetch URL`。在当前窗口执行下面整段，恢复 Homebrew 默认源、明确使用官方 PyPI，再重试：

```bash
unset HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN
export PIP_INDEX_URL="https://pypi.org/simple"
bash scripts/setup_macos_packaging.sh --target setup-only
```

如果你原本就在 shell 配置文件中设置了其他镜像，请另行核对自己的设置；上面的命令不会重写它们。镜像维护方说明：[清华 PyPI](https://mirrors.tuna.tsinghua.edu.cn/help/pypi/)、[中科大 Homebrew bottles](https://mirrors.ustc.edu.cn/help/homebrew-bottles.html)。

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

### Mac 画质设置

游戏运行时打开 **Graphics / 画质** 菜单。菜单会保存以下设置，并在下次启动时生效：

- **分辨率：** 游戏默认内部渲染尺寸的 50%、75%、原生或 125%。
- **MSAA：** 游戏默认，或当前 Metal 设备支持的 2x、4x、8x 覆盖值。覆盖只作用于游戏已经创建的多重采样目标，不会把所有单采样目标强制改成 MSAA。
- **纹理过滤：** 游戏默认，或 2x、4x、8x、16x 各向异性过滤。
- **Bloom：** 游戏默认、开启或关闭。

这些设置会在 guest 创建图形资源前应用，因此修改后需要重启游戏。菜单会根据当前 Metal 设备显示可用的 MSAA 档位，并提供恢复默认设置的操作。如果设置了诊断环境变量 `DM_GAME_RES`，分辨率菜单会被该显式覆盖值优先覆盖。

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

## App 版本元数据

App 版本标识 Lordran Native，不是 `--package` 选择的 Nintendo 游戏更新版本。
原生 iOS、Simulator、macOS App 和壳构建共用 `scripts/app_version.py`；
`dm/ios/project.yml` 通过构建脚本接收数字版本，不再写死版本号。
壳工作流会获取 tag/历史元数据，并检查所选 tag 确实指向 HEAD。

- 准确的 `vMAJOR.MINOR.PATCH` 或 `MAJOR.MINOR.PATCH` tag 将
  `CFBundleShortVersionString` 设为不带 `v` 的 `MAJOR.MINOR.PATCH`。
- `CFBundleVersion` 使用 `(MAJOR + 1).MINOR.PATCH`，因此 `v0.2.0` 对应 `1.2.0`。
  这是确定性的正主版本映射，不是 CI 运行计数。支持 tag 主版本 0-9998、次版本和补丁版本
  0-99；超出范围的数字 tag 会报错，不会生成不符合 Apple 约束的版本号。
- 预发布和构建后缀不进入 Apple 数字字段。`v0.2.0-rc.1+build.7` 的数字字段为
  `0.2.0` 和 `1.2.0`；完整 tag 与完整 commit ID 保存在 `dm/app-version.json`。
  不同预发布可能共享数字版本；此机制不负责 App Store 构建号分配。
- 非 SemVer tag 保留完整身份，但数字字段回退到 `0.0.0` / `1.0.0`。无 tag 的 commit
  和 Actions 分支运行也使用该数字回退，并以 `dev-<12 位 commit>` 标识，绝不沿用最近的旧 tag。
  本地存在多个准确 tag 时必须通过 `GITHUB_REF=refs/tags/<tag>` 明确选择。
- `dm/` 或 `scripts/` 有本地修改时，使用开发数字回退和
  `dev-<commit>-dirty-<内容哈希>`，保留完整指纹及所选的基础 tag，不冒充干净 Release。
- 没有 `.git` 的纯源码下载使用 `dev-source-<内容哈希>` 和开发数字回退。之前构建生成的版本
  文件不参与解析；解压在其他 checkout 内的源码也不会继承外层 checkout 的 tag。
  新壳 ZIP 文件名和嵌入元数据使用同一份源码身份。
- Windows/预编译壳打包即使没有 Git，也保留壳内的身份和数字版本，并检查它们与壳 plist 一致；
  manifest、源码及游戏档案检查保持不变。没有版本元数据的旧壳保留旧 plist 版本，以 manifest
  源码指纹标记为旧壳，不会猜测当前 checkout 的 tag。

元数据位于 iOS App 的 `dm/app-version.json` 和 Mac App 的
`Contents/Resources/dm/app-version.json`。iOS 诊断导出包含完整源码身份；Mac App 启动器
每次启动都会记录它。它们标识构建，但不能证明游戏兼容性、签名有效性，也不证明本地修改过的源码
与干净 Release 一致。
