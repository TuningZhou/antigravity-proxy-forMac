# Antigravity-Proxy macOS 使用与测试指南

本项目已全面支持 macOS 操作系统（兼容 Apple Silicon M1/M2/M3/M4 ARM64 与 Intel x86_64 架构），实现了与 Windows 端一致的**透明代理、FakeIP 域名映射、路由分流规则、子进程继承传播**等全部核心功能。

> ✅ **版本节点验证通过（2026-09-15，Apple Silicon / macOS 26）**：已完成 README 全部 5 项测试的真机端到端验证——CTest 6/6、冒烟脚本、agy CLI 透明联网、**Antigravity IDE TUN 客户端经代理成功完成 Google 账号 OAuth 授权并进入主界面**（登录后 cloudcode / googleapis / 头像 CDN 等域名全部经 SOCKS5 隧道，0 条绕过代理的直连）。详见文档末尾[附录 A：端到端验证记录](#附录-a端到端验证记录2026-09-15)与 [CHANGELOG.md](CHANGELOG.md)。

---

## 目录

- [一、核心实现原理](#一核心实现原理)
- [二、普通用户使用方法 / Usage（3 步上手）](#二普通用户使用方法--usage3-步上手)
- [三、Mac 电脑环境准备（编译依赖）](#三mac-电脑环境准备编译依赖)
- [四、编译构建步骤](#四编译构建步骤)
- [五、配置文件说明](#五配置文件说明)
- [六、Mac 电脑测试执行流程（详细步骤）](#六mac-电脑测试执行流程详细步骤)
  - [测试 1：单元与回归测试验证 (CTest)](#测试-1单元与回归测试验证-ctest)
  - [测试 2：一键自测脚本 (Smoke Test)](#测试-2一键自测脚本-smoke-test)
  - [测试 3：Antigravity CLI (agy) 命令行透明代理测试](#测试-3antigravity-cli-agy-命令行透明代理测试)
  - [测试 4：Antigravity IDE 客户端透明代理测试](#测试-4antigravity-ide-客户端透明代理测试)
  - [测试 5：子进程注入与日志审查验证](#测试-5子进程注入与日志审查验证)
- [七、macOS 常见问题与排坑指南 (SIP / 安全机制)](#七macos-常见问题与排坑指南-sip--安全机制)
- [附录 A：端到端验证记录（2026-09-15）](#附录-a端到端验证记录2026-09-15)

---

## 一、核心实现原理

| 平台机制对比         | Windows 端                                                      | macOS 端                                                                       |
| :------------------- | :-------------------------------------------------------------- | :----------------------------------------------------------------------------- |
| **加载机制**   | 符号导出劫持 (`version.dll` / `dbghelp.dll`)                | 原生动态库注入 (`DYLD_INSERT_LIBRARIES`)                                     |
| **Hook 引擎**  | MinHook (内联机器码 Patch)                                      | Apple 官方原生 Dyld 符号重定向 (`__DATA,__interpose`)；原生函数指针通过**遍历 dyld 镜像 Mach-O 符号表**定位（不使用 `dlsym(RTLD_NEXT)`，原因见第一章末注） |
| **网络拦截**   | `connect`, `WSAConnect`, `getaddrinfo`, `gethostbyname` | `connect`, `getaddrinfo`, `gethostbyname`, `close`                     |
| **子进程注入** | Hook`CreateProcessA/W` 启动挂起 + 注入                        | Hook`posix_spawn`, `posix_spawnp`, `execve` 自动传播环境变量             |
| **跨进程共享** | Windows 具名内存映射 (`CreateFileMappingW`)                   | POSIX 文件内存映射 (`mmap` + `fcntl` 文件锁)                               |
| **安全降级**   | 配置读取失败自动进入 BYPASS 模式                                | 配置读取失败自动进入 BYPASS 模式                                               |

macOS 端完全采用 Apple 官方规范的 **Dyld 符号重定向 (Dyld Interposing)** 技术，无需在内存中修改代码段可执行权限（W^X 机制兼容），原生支持 Apple Silicon 的 Hardened Runtime 与 ARM64 PAC 安全特性，稳定且不崩溃。

> **技术注记：为什么不用 `dlsym(RTLD_NEXT)` 获取原函数？**
> 在现代 macOS（实测 macOS 26）上，一旦本库以 `__DATA,__interpose` 拦截了某符号，钩子内部再调用 `dlsym(RTLD_NEXT, "同名")` 会返回**钩子自身地址**，导致 `my_xxx → RealXxx → my_xxx` 无限递归直至栈溢出。本实现改为 fishhook 同款做法：遍历 dyld 已加载镜像的 Mach-O 符号表，只取 `N_SECT` 真实定义，并**按权威镜像精确归属**（`connect/close/execve/posix_spawn` 取 `libsystem_kernel.dylib`，`posix_spawnp` 取 `libsystem_c.dylib`，`getaddrinfo` 系列取 `libsystem_info.dylib`），天然跳过未定义引用与伞库重导出桩。这也避免了另一个陷阱：`posix_spawn` 在 `libsystem_c` 中存在一个内部回调 `posix_spawnp` 的包装定义，误取会重新进入被拦截的 `posix_spawn` 形成递归环。

---

## 二、普通用户使用方法 / Usage（3 步上手）

> 本节面向**不懂编程、只想让 Antigravity 正常联网**的 Mac 用户。会复制粘贴命令即可。

### 先说结论：和 Windows 一样吗？

**使用思路完全一样（准备代理 → 配置端口 → 启动 Antigravity），但"启动方式"不一样。**

| 对比项 | Windows 电脑 | Mac 电脑 |
| :--- | :--- | :--- |
| 注入方式 | 把 `version.dll` 放到 `Antigravity.exe` 旁边，系统**自动加载** | 由启动器通过 `DYLD_INSERT_LIBRARIES` **临时注入** dylib |
| 首次准备 | 复制文件到安装目录 | 下载解压即用；首次启动自动在官方 App **同目录复制一份副本**（命名为 `Antigravity TUN.app` / `Antigravity IDE TUN.app`），签名补丁只打在副本上，官方原件一个字节都不改 |
| 日常启动 | **照常双击** Antigravity 图标即可 | **必须通过启动器启动**（见第 3 步），启动的是带 TUN 后缀的代理副本；直接点官方图标不走代理 |
| IDE 升级后 | 可能要重新复制 DLL | 升级后首次启动会检测到版本不一致，按提示让启动器**重新复制+补丁副本**即可（原件始终不动） |
| 子进程代理 | 自动注入 | 自动注入（`posix_spawn` / `execve` 自动传播；`language_server` 自动绕过 Seatbelt 沙箱包装） |

> ⚠️ **最重要的一句话：Mac 上每次都要用启动器打开 Antigravity 才走代理——启动器运行的是同目录下的"Antigravity IDE TUN"副本；直接从"访达 / 启动台 / 程序坞"点开不带 TUN 的官方图标不会走代理。**
>
> 🛡️ **原件与副本的分工**：官方原件是"干净的官方入口"，始终保持 Google 原始签名，需要联系官方客服/账号申诉时就用它；"TUN"副本是"代理专用环境"，补丁只打在它上面，不想要代理时把它拖进废纸篓即可，随时可删、随时可由启动器再生成。

### 第 1 步：准备代理 / Prepare a Proxy

启动你的代理软件（Clash Verge、Surge、sing-box、V2RayU 等），确认本机监听端口：

| 代理软件 | 常用端口 |
| :--- | :--- |
| Clash Verge / Mihomo（混合端口） | `7890`（预编译包默认值） |
| V2RayU / V2RayN（SOCKS5） | `10808` |
| Surge（SOCKS5） | `6153` |

> 具体端口**一律以你代理软件设置界面里显示的为准**。可先在终端自测（可选）：
>
> ```bash
> curl -x socks5://127.0.0.1:7890 https://www.google.com -I
> ```
>
> 注意：不要用 macOS 自带的 `/usr/bin/curl` 做注入验证（SIP 会拦截，详见第七节），这里仅验证代理端口本身是否可用。

### 第 2 步：获取程序并改好端口（两种方式任选）

#### 方式 A：下载预编译包（推荐普通用户，免编译、免装 Homebrew）

1. 打开项目的 [Releases 页面](https://github.com/yuaotian/antigravity-proxy/releases)，下载最新版的
   **`antigravity-proxy-vX.X-mac-universal2.zip`**（一个包同时支持 Apple Silicon 与 Intel）。
2. 在"访达"里双击 zip 解压，得到 `Antigravity-Proxy-macOS` 文件夹。**建议移到
   `~/Applications`（用户"应用程序"目录，没有可自行新建）；不要放在桌面/文稿/下载**——
   这些是 macOS 隐私保护目录，可能导致提权报 126 错误（详见第七节 FAQ 4）。
3. 在 **`Antigravity-Proxy.command`** 上点**鼠标右键（或双指点按）→ 打开**，在弹窗里再点"打开"。
   （首次必须右键打开以通过 Gatekeeper；只需操作这一次。若被拦截，可到
   **系统设置 → 隐私与安全性** 点"仍要打开"。）
4. 在启动器菜单选 **3**，确认/修改 `config.json` 里 `proxy.port` 为第 1 步的端口
   （默认 `7890`，端口一致可跳过），保存后关闭文本编辑。

#### 方式 B：源码一键安装（开发者）

在本项目目录里打开"终端"，执行一键安装（首次使用需先按[第三节](#三mac-电脑环境准备编译依赖)装好 Xcode 命令行工具）：

```bash
./scripts/install-mac.sh
```

脚本会自动编译并安装：

- 动态库与签名补丁脚本 → `~/.local/lib/`
- 配置文件 → `~/.config/antigravity-proxy/config.json`
- 启动命令 → `~/.local/bin/antigravity-proxy`

按屏幕提示把 `~/.local/bin` 加进 PATH（写入 `~/.zshrc` 后重新打开终端），再编辑配置端口：

```bash
export PATH="$HOME/.local/bin:$PATH"
open -e ~/.config/antigravity-proxy/config.json
```

> 💡 不想安装也可以直接 `./build.sh Release` 后用 `./scripts/antigravity-proxy.sh`（免安装方式），此时改 `output-mac/config.json`。

### 🔑 关于"本地签名补丁"与"代理副本"（方式 A/B 首次启动都会自动执行）

官方 Antigravity 的主程序（真名 `Electron`）、各 Helper、`language_server_macos_arm` 都启用了苹果
**Hardened Runtime**，且未携带"允许 DYLD 环境变量"权利——不打补丁时，系统会**静默忽略**
`DYLD_INSERT_LIBRARIES`，代理完全不生效（这是 macOS 的安全机制，与 SIP 无关，**不需要关闭 SIP**）。

为了让补丁**不碰官方原件**，启动器采用"原件 + 代理副本"的方式，首次选菜单"1）启动"时自动完成：

1. **复制副本**：在官方 App 的**同一文件夹**里用 `ditto` 完整复制一份，命名规则：
   - `Antigravity.app` → `Antigravity TUN.app`
   - `Antigravity IDE.app` → `Antigravity IDE TUN.app`

   副本的显示名同样带"TUN"后缀，程序坞/访达里一眼可辨。副本体积约 1GB，复制约需数十秒。
2. **只对副本补丁**：在**本机**对副本的主程序、各 Helper 与 `language_server` 做一次 ad-hoc 重签名，
   补上 `allow-dyld-environment-variables` 与 `disable-library-validation` 两个权利，并做注入冒烟验证；
   **不联网、不上传、不改功能**。
3. **启动副本**：之后启动器永远启动这份 TUN 副本。

其他要点：

- **官方原件一个字节都不会被修改**（脚本通过版本/状态校验保证），可随时照常双击使用，
  需要联系官方客服/申诉账号时请用原件；
- 副本与原件 Bundle ID 相同，**共用登录状态与设置，无需重新登录**；但两者是单实例关系，**不要同时运行**；
- 目标目录在 `/Applications` 等不可写位置时，复制副本那一步会弹出**系统授权框**输入本机密码
  （与安装软件相同；密码不经过本工具，完成后副本归属仍改回你本人）；
- **官方 Antigravity 升级后**，启动器会发现副本版本落后并提示重建（重新复制+补丁，按 Y 即可），
  也可以用菜单 **6** 手动重新检测/创建/修复副本；
- **想完全撤销代理环境**：直接把"Antigravity IDE TUN.app"（或"Antigravity TUN.app"）拖到废纸篓，
  官方程序完好无损；不需要重装 Antigravity。

此外，agent 后端 `language_server` 原本由 `sandbox-wrapper.sh → sandbox-exec` 置于 Seatbelt
沙箱中（默认 `(deny network*)`，连不上本地代理端口，且受保护的 `sandbox-exec` 会剥除 DYLD 变量）。
dylib 拦截到该包装脚本时会直接还原为 `language_server` 本体启动（日志中会出现
"已绕过 Seatbelt/sandbox-exec"），使其与普通开发命令行工具拥有相同的联网/注入条件。

### 第 3 步：通过启动器启动 Antigravity / Launch via Launcher

**方式 A**：双击 `Antigravity-Proxy.command` → 菜单选 **1**（首次会先自动复制 TUN 副本并打签名补丁，随后启动副本）；
选 **2** 使用 agy 命令行（agy 1.2.x 起为 Agent CLI，详见下方命令示例）。

**方式 B**：在终端执行：

```bash
# 已执行安装脚本
antigravity-proxy app

# 免安装方式（在项目根目录执行）
./scripts/antigravity-proxy.sh app

# agy 命令行（1.2.x 新版无 status/login 子命令）
antigravity-proxy agy changelog        # 验证联网：拉取更新日志
antigravity-proxy agy -p "你好"        # 非交互跑一轮对话（需已登录）
antigravity-proxy agy -i               # 交互式对话
```

> ℹ️ **关于 agy 登录**：agy 是 Antigravity 的命令行 Agent，账号体系与 IDE 共用（`~/.antigravity` / IDE 登录态）。在 **Antigravity IDE 内登录一次**即可，命令行无需也不再提供 `agy login` / `agy status`（旧版命令在 1.2.x 会报 `unexpected argument`）。agy 二进制启用了 Hardened Runtime，首次经启动器运行时会引导你做一次本地 ad-hoc 签名补丁（仅本机生效）。

启动器会自动在 `/Applications`、`~/Applications` 查找官方 Antigravity 原件（自动跳过已有的 TUN 副本）；
装在别处时，可直接把**官方 Antigravity.app 拖到启动器图标上**，或在终端传入 `.app` 路径——
启动器同样只在同目录创建/使用"TUN"副本，不会修改你拖入的原件：

```bash
./scripts/antigravity-proxy.sh "/Applications/Antigravity IDE.app"
```

启动后正常使用即可，网络流量会自动走代理，无需开启系统全局代理或 TUN 模式。🎉
程序坞/启动台里认准显示名带 **TUN** 的图标启动代理环境；不带 TUN 的官方图标保持"干净入口"用途。

### ✅ 怎么确认代理生效了

查看日志（与 dylib 同级的 `logs/` 目录；方式 A 即解压文件夹内的 `logs/`，方式 B 即 `~/.local/lib/logs/`）：

```bash
tail -n 30 ~/.local/lib/logs/proxy-*.log 2>/dev/null || tail -n 30 output-mac/logs/proxy-*.log
```

看到以下关键行即表示成功（注意主程序真名是 `Electron`，且路径里是代理副本 `Antigravity IDE TUN.app`）：

```text
[INFO] Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)
[INFO] 当前宿主进程: Electron (路径: .../Antigravity IDE TUN.app/Contents/MacOS/Electron)
[INFO] 当前进程 Electron 启用代理拦截模式
[INFO] macOS 代理重定向: 目标=... 代理=127.0.0.1:10808 类型=socks5
[INFO] 检测到 sandbox-wrapper 包装的 language_server_macos_arm，已绕过 Seatbelt/sandbox-exec 直接启动
```

### 💡 让日常使用更省事（可选）

把解压后的文件夹放在固定位置，以后双击 `Antigravity-Proxy.command` 选 1 即可；
终端用户也可以设个别名（把路径换成实际路径）：

```bash
echo "alias agygo='$HOME/Documents/Code-Program/antigravity-proxy/scripts/antigravity-proxy.sh app'" >> ~/.zshrc
source ~/.zshrc
```

### 🔒 首次运行的安全提示

- `.command` 首次请**右键 → 打开**；若被 Gatekeeper 拦截，到 **系统设置 → 隐私与安全性** 点"仍要打开"。
- 若提示 dylib 代码签名无效，可在解压目录执行一次本地临时签名：
  ```bash
  codesign --force --sign - libantigravity_proxy.dylib
  ```
- 补丁提示"正在运行"：先把官方原件和"TUN"副本都用 **⌘Q** 完全退出（两者共用同一登录身份，不能同时开），再回启动器按回车。
- 提示需要管理员权限：在 `/Applications` 里创建副本需要授权，输入本机登录密码即可，仅用于复制副本这一步。
- 补丁提示缺少 `codesign`：终端执行 `xcode-select --install` 安装 Apple 命令行工具。
- Antigravity **升级后**启动器会检测到副本版本落后，选 1 后按 **Y** 即可自动重建副本；也可用菜单 **6** 手动修复。
- 想撤销代理环境：把"应用程序"里的 **Antigravity IDE TUN.app**（或 Antigravity TUN.app）拖到废纸篓即可，官方原件不受影响。
- 更多排坑见[第七节](#七macos-常见问题与排坑指南-sip--安全机制)。

---

## 三、Mac 电脑环境准备（编译依赖）

在 Mac 电脑上执行构建与测试前，请确保安装以下开发工具：

1. **Xcode Command Line Tools**（提供 Clang 编译器与基础 SDK）：
   ```bash
   xcode-select --install
   ```
2. **CMake**（推荐 3.5 及以上）：
   ```bash
   brew install cmake
   ```
3. **确认机器架构**（支持原生编译或构建 Universal 2 通用二进制）：
   ```bash
   uname -m  # 查看当前架构：arm64 (Apple Silicon) 或 x86_64 (Intel)
   ```

---

## 四、编译构建步骤

1. 在 Mac 电脑上拉取或切换到分支代码：

   ```bash
   git checkout antigravity-proxy-forMacOS
   ```
2. 赋予脚本执行权限：

   ```bash
   chmod +x build.sh scripts/*.sh
   ```
3. **执行一键构建**：

   ```bash
   ./build.sh Release
   ```

   > **提示**：如需构建同时支持 M 系列芯片与 Intel 芯片的 Universal 2 通用动态库，可运行：
   >
   > ```bash
   > ARCHS="arm64;x86_64" ./build.sh Release
   > ```
   >
4. 构建完成后，产物将生成在 `output-mac/` 目录下：

   - `output-mac/libantigravity_proxy.dylib`：核心代理动态库
   - `output-mac/config.json` 或 `config.example.json`：配置文件

---

## 五、配置文件说明

macOS 端的配置逻辑与 Windows 完全一致，支持直接共用 `config.json`。

### 配置文件自动查找优先级：

1. `libantigravity_proxy.dylib` 所在同级目录下的 `config.json`
2. `~/.config/antigravity-proxy/config.json`
3. `~/.antigravity-proxy/config.json`
4. 当前进程启动时的工作目录 `./config.json`

### 配置文件示例 (`config.json`)：

```json
{
  "proxy": {
    "type": "socks5",
    "host": "127.0.0.1",
    "port": 10808
  },
  "fakeIp": {
    "enabled": true,
    "range": "198.18.0.0/15"
  },
  "rules": {
    "mode": "rules",
    "routing": {
      "enabled": true,
      "rules": [
        "domain-suffix:googleapis.com,proxy",
        "domain-suffix:anthropic.com,proxy",
        "domain-suffix:openai.com,proxy",
        "domain-keyword:antigravity,proxy",
        "cidr:127.0.0.0/8,direct",
        "cidr:10.0.0.0/8,direct",
        "cidr:192.168.0.0/16,direct"
      ]
    },
    "defaultAction": "proxy"
  },
  "targetProcesses": [
    "Antigravity",
    "Antigravity IDE",
    "agy"
  ],
  "childProcesses": [
    "language_server",
    "language_server_macos_arm64",
    "language_server_macos_x64",
    "node"
  ],
  "childInjection": true,
  "logging": {
    "level": "info",
    "maxFileSizeMB": 20,
    "maxFiles": 5
  },
  "uiLoadNotify": "once"
}
```

> **跨平台兼容提示**：匹配规则内部已做自动兼容，即使配置里写的是 `Antigravity.exe` 或 `agy.exe`，在 macOS 下也会自动去除 `.exe` 后缀匹配 macOS 无后缀的可执行文件名。

---

## 六、Mac 电脑测试执行流程（详细步骤）

请在您的 Mac 电脑上按以下顺序逐步执行测试：

### 测试 1：单元与回归测试验证 (CTest)

在项目目录下执行：

```bash
cd build-mac
ctest --output-on-failure
cd ..
```

**期望结果**：
所有测试用例必须 100% 通过（Passed）：

- `antigravity_tests`: IPv6 规范与 CIDR 解析测试
- `process_name_tests`: macOS 进程名与路径提取测试
- `udp_policy_tests`: UDP 代理策略判断测试
- `socket_family_tests`: 双栈 Socket 与地址映射测试
- `local_target_policy_tests`: 本地回环地址判断测试
- `fakeip_tests`: macOS `mmap` 跨进程 FakeIP 分配与逆向查询测试

---

### 测试 2：一键自测脚本 (Smoke Test)

在项目根目录下执行：

```bash
./scripts/test-mac.sh
```

**期望结果**：

- 脚本打印 `libantigravity_proxy.dylib` 的架构（Mach-O 64-bit dynamically linked shared library）。
- 成功执行并验证环境变量传递。
- 输出当前测试状态。

---

### 测试 3：Antigravity CLI (agy) 命令行透明代理测试

> agy 1.2.x 为 Agent CLI，已无 `status` / `login` 子命令。下面用**需要联网但无需登录**的 `changelog` 做联调；如需对话，在 IDE 登录后用 `agy -p "..."`。

1. 确认已配置好本地代理（例如 Clash/Surge/v2rayN 运行在 127.0.0.1:10808）。
2. 首次运行需对 agy 做一次本地签名补丁（agy 启用 Hardened Runtime）：按启动器提示操作，或手动执行
   （entitlements 与补丁细节见第七章 FAQ；`agy update` 后需重做一次）。
3. 在项目根目录下执行：

   ```bash
   ./scripts/antigravity-proxy.sh agy changelog
   ```

   已登录后可直接验证对话链路：

   ```bash
   ./scripts/antigravity-proxy.sh agy -p "回复 OK"
   ```
4. 查看代理日志（dylib 同级 `logs/` 目录，即 `output-mac/logs/`）：

   ```bash
   tail -n 30 output-mac/logs/proxy-*.log
   ```

**期望结果**：
`changelog` 正常打印版本更新内容、退出码 0；日志中应出现类似记录：

```
[INFO] Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)
[INFO] 当前宿主进程: agy (路径: /Users/<you>/.local/bin/agy)
[INFO] 当前进程 agy 启用代理拦截模式
[INFO] macOS API Hook 已激活 (全量拦截: connect, getaddrinfo, posix_spawn, execve)
[INFO] macOS 代理重定向: 目标=raw.githubusercontent.com:443 代理=127.0.0.1:10808 类型=socks5
[INFO] SOCKS5: 隧道建立成功 ... 目标=raw.githubusercontent.com:443
```

并且 `agy` 命令能够顺利联网通讯，无需系统全局代理。

---

### 测试 4：Antigravity IDE 客户端透明代理测试

1. 确保在 `/Applications/` 下已安装官方 `Antigravity IDE.app`（或通过脚本直接指定路径）。
2. 使用启动脚本启动（首次会自动在同目录创建 `Antigravity IDE TUN.app` 副本，补丁只打副本，随后启动副本）：

   ```bash
   ./scripts/antigravity-proxy.sh app
   ```

   *（若 Antigravity 安装在其他位置，可直接传入官方 .app 路径：`./scripts/antigravity-proxy.sh "/Applications/Antigravity IDE.app"`；同样会使用同目录的 TUN 副本，原件不改动。）*
3. 观察弹出的客户端窗口标题/程序坞图标显示名为"Antigravity IDE TUN"，右上角或底部会收到系统提示："配置读取成功，API Hook 已生效"（仅首次提示）。
4. 在 IDE 内部尝试触发 AI 补全或登录 Google 账户（副本与原件共用登录态）。

**期望结果**：

- TUN 副本正常启动，没有崩溃；官方原件签名与内容保持不变。
- 网络请求通过本地代理（如 127.0.0.1:10808）成功建立连接。
- **点击 "Sign in with Google" 后，浏览器授权完成能正常回到 IDE 并进入主界面。** OAuth 的 token 交换（`oauth2.googleapis.com`）、CloudCode 后端（`cloudcode-pa.googleapis.com`）、头像 CDN（`lh3.googleusercontent.com`）等域名都应在代理日志中看到 `SOCKS5: 隧道建立成功`。

> ⚠️ **登录前务必确认走的是 TUN 副本，且不要同时开着官方原件**：两者共用单实例锁与登录身份。若先启动了未注入的官方原件，再开 TUN 副本只会激活旧窗口（新进程随即退出），此时 Google 授权后回调的 token 交换会**直连 Google 真实 IP 超时报错**（auth.log 中表现为 `connect ETIMEDOUT ...:443` → `loginError`）。正确做法：先 ⌘Q 完全退出所有 Antigravity，再只用启动器启动一次 TUN 副本，然后完成登录。
>
> ✅ 本版本已在真机验证：23 个 Electron/Helper/language_server 进程全部注入，登录全过程 0 条绕过代理的直连连接。

---

### 测试 5：子进程注入与日志审查验证

Antigravity IDE 内部会通过 `posix_spawn` 或 `execve` 启动关键后台子进程（如 `language_server`、`node`）。
执行以下命令观察子进程注入情况：

```bash
grep -E "子进程|宿主进程: language_server" output-mac/logs/proxy-*.log | head
```

**期望结果**：
日志中清晰记录了子进程的派生拦截与环境变量自动注入：

```
[INFO] [成功] 拦截到子进程派生 (posix_spawn): language_server_macos_arm，正在注入 DYLD_INSERT_LIBRARIES
[INFO] 检测到 sandbox-wrapper 包装的 language_server_macos_arm，已绕过 Seatbelt/sandbox-exec 直接启动
[INFO] Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)
[INFO] 当前宿主进程: language_server_macos_arm
[INFO] 当前进程 language_server_macos_arm 启用代理拦截模式
[INFO] SOCKS5: 隧道建立成功 ... 目标=cloudcode-pa.googleapis.com:443
```

这表明子进程无缝继承了透明代理能力！

---

## 七、macOS 常见问题与排坑指南 (SIP / 安全机制)

### 1. 为什么用 macOS 自带的 `/usr/bin/curl` 测试看不到日志？

- **原因**：macOS 的 **SIP (System Integrity Protection)** 机制会保护系统内置二进制文件（例如 `/bin/*`、`/usr/bin/*`）。当执行系统自带的 `/usr/bin/curl` 时，操作系统内核出于安全考虑会自动清除 `DYLD_INSERT_LIBRARIES` 环境变量。
- **解决方案**：测试时请使用第三方应用程序进行验证（如 `Antigravity.app`、通过 npm/brew 安装的 `agy`，或 Homebrew 安装的 `/opt/homebrew/bin/curl`）。

### 2. 提示 "Operation not permitted" 或 "Code signature invalid"？

- **Antigravity 本身没反应/没有代理日志**：官方程序启用了 Hardened Runtime，必须先应用
  第二节介绍的"本地签名补丁"。重新双击 `Antigravity-Proxy.command` 选 1（或菜单 6）即可，
  启动器会自动在同目录准备"TUN"副本、只对副本完成重签名与注入冒烟验证；
  **不需要、也不建议关闭 SIP**。
- 若 macOS 提示的是**动态库**代码签名问题，可对动态库执行本地临时签名：
  ```bash
  codesign --force --sign - output-mac/libantigravity_proxy.dylib
  ```
- 也可单独手动执行补丁脚本：传入官方 App 路径时，脚本会自动创建/更新同目录的
  "Antigravity IDE TUN.app"副本并只对副本打补丁（官方原件不改动）；
  传入 TUN 副本本身则只修补丁；加 `--recreate` 可强制重建副本，加 `--status` 可只查状态：
  ```bash
  # 查看副本状态：missing / needs-patch / outdated / ready
  ./scripts/mac-patch-app.sh --status "/Applications/Antigravity IDE.app"
  # 自动复制副本并打补丁
  ./scripts/mac-patch-app.sh "/Applications/Antigravity IDE.app" output-mac/libantigravity_proxy.dylib
  # 官方升级后强制重建副本
  ./scripts/mac-patch-app.sh --recreate "/Applications/Antigravity IDE.app" output-mac/libantigravity_proxy.dylib
  ```
  注意：对**非 Antigravity 的任意第三方程序**，脚本仍沿用就地补丁方式（不创建副本）。

### 3. 如何全局安装为系统命令？

运行安装脚本：

```bash
./scripts/install-mac.sh
```

此命令会将动态库安装至 `~/.local/lib/`，配置文件安装至 `~/.config/antigravity-proxy/`，并在 `~/.local/bin/` 创建 `antigravity-proxy` 命令。在 `~/.zshrc` 中配置 `export PATH="$HOME/.local/bin:$PATH"` 后，便可在终端任意位置输入 `antigravity-proxy app` 启动！

### 4. 弹出授权框后报 “Operation not permitted (126)”？

- **原因**：免安装包放在了 **桌面 / 文稿(Documents) / 下载(Downloads)** 等 macOS TCC 隐私保护目录。
  授权后以 root 身份执行的系统进程**没有这些目录的访问授权（root 同样受 TCC 约束）**，
  打开补丁脚本即被拒绝，bash 返回 126。
- 新版本启动器已自动规避：提权前会把补丁脚本与 dylib 暂存到系统中立临时目录
  （`/private/tmp`）再让提权进程执行；但代理副本日常启动时仍需从包目录加载 dylib，
  因此**推荐把整个 `Antigravity-Proxy-macOS` 文件夹移动到非保护目录**
  （推荐 `~/Applications`，没有可自行新建），然后重新双击运行。启动器检测到自身位于
  保护目录时，会在菜单顶部显示黄色提醒。
- 备用方案：在 **系统设置 → 隐私与安全性 → 完全磁盘访问权限** 中允许"终端"，
  退出终端后重新打开再试。

---

## 附录 A：端到端验证记录（2026-09-15）

**环境**：Apple Silicon（arm64）、macOS 26.4、Antigravity IDE（Electron）、本机 SOCKS5 代理 `127.0.0.1:10808`。

### A.1 五项测试结果

| 测试 | 结果 | 关键证据 |
| :-- | :-- | :-- |
| 1. CTest 单元/回归 | ✅ 6/6 通过 | `./build.sh Release` |
| 2. 冒烟脚本 | ✅ 通过 | dylib Mach-O 架构正常、环境变量传递正常 |
| 3. agy CLI 透明联网 | ✅ 通过 | `agy changelog` 经 SOCKS5 隧道拉取成功，退出码 0 |
| 4. IDE 客户端 | ✅ **登录成功进入主界面** | auth.log `signedIn`，见 A.2 |
| 5. 子进程注入 | ✅ 通过 | 23 个 Electron/Helper/language_server 进程全部注入 |

### A.2 Google 登录链路时间线（IDE auth.log）

```text
22:57:30 [Auth] signedOut                      ← 干净启动（先 ⌘Q 旧实例再用启动器开 TUN 副本）
23:09:02 [Auth] validatingLogin                ← 第一次尝试（浏览器侧未及时完成授权）
23:09:08 [Auth] loginError → 23:14:51 failure  ← 回调超时，回到 signedOut
23:14:59 [Auth] validatingLogin                ← 第二次尝试
23:15:04 [Auth] success → signedIn             ← ✅ token 交换成功
23:15:04 OAuth token changed, antigravity.handleAuthRefresh
```

代理日志在该窗口抓到的隧道目标（全部 → `127.0.0.1:10808`，**0 条非回环直连、0 条 UDP/QUIC 绕过**）：
`oauth2.googleapis.com`、`www.googleapis.com`、`accounts.google.com`、
`cloudcode-pa.googleapis.com`、`daily-cloudcode-pa.googleapis.com`、
`play.googleapis.com`、`antigravity-unleash.goog`、`lh3.googleusercontent.com`、
以及 Playwright 浏览器 CDN（`*.azureedge.net`）。

### A.3 走网络流量的进程清单（逐进程实测）

| 进程 | 网络职责 | 注入 | 联网 |
| :-- | :-- | :-- | :-- |
| Electron（主进程） | OAuth 本地回调、更新、部分扩展请求 | ✅ | →10808 |
| Helper: NetworkService | Chromium 网络请求唯一出口 | ✅ | →10808 |
| Helper: NodeService ×2~3 | 扩展宿主，token 交换在此发出 | ✅ | →10808 |
| Helper: Renderer / GPU / Plugin | 渲染、图形、插件 | ✅ | 基本无外网 |
| language_server_macos_arm ×2 | 登录后 AI 对话流量出口 | ✅ | 多条 →10808 |
| chrome_crashpad_handler | 仅崩溃上报 | ❌（原始签名，见下） | 实测无外网 |

> **已知非阻塞缺口**：补丁脚本当前只重签 `.app` 主可执行与各 Helper.app。
> `Electron Framework.framework` 内嵌的裸二进制 `chrome_crashpad_handler`、部分 `.node`
> 原生模块（如 microsoft-authentication 的 MSAL 模块）仍为 Google 原始 Hardened Runtime 签名，
> 故不会加载本 dylib。经实测：crashpad 不发起任何外网连接；`.node` 模块由已注入的宿主
> 进程 `dlopen` 加载，其进程内网络调用仍被本 dylib 的进程级 interpose 覆盖。
> 因此 **Google 登录与日常使用链路无漏网流量**；该缺口只影响"作为独立可执行文件被 spawn"的
> 场景（crashpad 崩溃上报、rg 搜索、node-pty spawn-helper），均与登录/对话无关。

### A.4 本版本修复的关键缺陷

1. **C++ 模板 static 缓存串号导致 `posix_spawn` 自递归（致命，IDE 启动 4 秒 SIGBUS）**：
   `posix_spawn_fn` 与 `posix_spawnp_fn` 签名相同，旧实现的函数指针被两个 Real* 共享；
   Electron 先调 `posix_spawnp`（缓存 libsystem_c 地址）后，`my_posix_spawn` 误用
   `posix_spawnp`，其内部回调被 interpose 的 `posix_spawn` → 无限递归。
   修复：每个 `Real*()` 持有独立函数级 `static`，解析逻辑按权威镜像归属
   （kernel / libc / libinfo），不再共用模板缓存。
2. **弃用 `dlsym(RTLD_NEXT)`**：现代 macOS 下对已 interpose 符号会返回钩子自身地址，
   改为遍历 dyld 镜像 Mach-O 符号表取 `N_SECT` 真实定义（见第一章末技术注记）。
3. **Seatbelt 沙箱绕过**：`sandbox-wrapper.sh → sandbox-exec` 默认 `(deny network*)`
   且剥除 DYLD 变量；拦截后还原为 `language_server` 本体启动。
