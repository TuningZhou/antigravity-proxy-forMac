# Antigravity-Proxy macOS 使用与测试指南

本项目已全面支持 macOS 操作系统（兼容 Apple Silicon M1/M2/M3/M4 ARM64 与 Intel x86_64 架构），实现了与 Windows 端一致的**透明代理、FakeIP 域名映射、路由分流规则、子进程继承传播**等全部核心功能。

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

---

## 一、核心实现原理

| 平台机制对比         | Windows 端                                                      | macOS 端                                                                       |
| :------------------- | :-------------------------------------------------------------- | :----------------------------------------------------------------------------- |
| **加载机制**   | 符号导出劫持 (`version.dll` / `dbghelp.dll`)                | 原生动态库注入 (`DYLD_INSERT_LIBRARIES`)                                     |
| **Hook 引擎**  | MinHook (内联机器码 Patch)                                      | Apple 官方原生 Dyld 符号重定向 (`__DATA,__interpose`) + `dlsym(RTLD_NEXT)` |
| **网络拦截**   | `connect`, `WSAConnect`, `getaddrinfo`, `gethostbyname` | `connect`, `getaddrinfo`, `gethostbyname`, `close`                     |
| **子进程注入** | Hook`CreateProcessA/W` 启动挂起 + 注入                        | Hook`posix_spawn`, `posix_spawnp`, `execve` 自动传播环境变量             |
| **跨进程共享** | Windows 具名内存映射 (`CreateFileMappingW`)                   | POSIX 文件内存映射 (`mmap` + `fcntl` 文件锁)                               |
| **安全降级**   | 配置读取失败自动进入 BYPASS 模式                                | 配置读取失败自动进入 BYPASS 模式                                               |

macOS 端完全采用 Apple 官方规范的 **Dyld 符号重定向 (Dyld Interposing)** 技术，无需在内存中修改代码段可执行权限（W^X 机制兼容），原生支持 Apple Silicon 的 Hardened Runtime 与 ARM64 PAC 安全特性，稳定且不崩溃。

---

## 二、普通用户使用方法 / Usage（3 步上手）

> 本节面向**不懂编程、只想让 Antigravity 正常联网**的 Mac 用户。会复制粘贴命令即可。

### 先说结论：和 Windows 一样吗？

**使用思路完全一样（准备代理 → 配置端口 → 启动 Antigravity），但"启动方式"不一样。**

| 对比项 | Windows 电脑 | Mac 电脑 |
| :--- | :--- | :--- |
| 注入方式 | 把 `version.dll` 放到 `Antigravity.exe` 旁边，系统**自动加载** | 由启动器通过 `DYLD_INSERT_LIBRARIES` **临时注入** dylib |
| 首次准备 | 复制文件到安装目录 | 下载解压即用；首次启动自动执行一次"本地签名补丁"（见下文说明） |
| 日常启动 | **照常双击** Antigravity 图标即可 | **必须通过启动器启动**（见第 3 步），直接点图标不走代理 |
| IDE 升级后 | 可能要重新复制 DLL | 重新双击启动器一次，会自动重新应用补丁 |
| 子进程代理 | 自动注入 | 自动注入（`posix_spawn` / `execve` 自动传播；`language_server` 自动绕过 Seatbelt 沙箱包装） |

> ⚠️ **最重要的一句话：Mac 上每次都要用启动器打开 Antigravity 才走代理；直接从"访达 / 启动台 / 程序坞"点开 Antigravity 图标不会走代理。**

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
2. 在"访达"里双击 zip 解压，得到 `Antigravity-Proxy-macOS` 文件夹（建议移到"应用程序"或你的用户目录）。
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

### 🔑 关于"本地签名补丁"（方式 A/B 首次启动都会自动执行）

官方 Antigravity 的主程序（真名 `Electron`）、各 Helper、`language_server_macos_arm` 都启用了苹果
**Hardened Runtime**，且未携带"允许 DYLD 环境变量"权利——不打补丁时，系统会**静默忽略**
`DYLD_INSERT_LIBRARIES`，代理完全不生效（这是 macOS 的安全机制，与 SIP 无关，**不需要关闭 SIP**）。

首次选菜单"1）启动"时，启动器会调用包内的 `mac-patch-app.sh` 自动完成：

- 在**本机**对 Antigravity 做一次 ad-hoc 重签名，补上 `allow-dyld-environment-variables`
  与 `disable-library-validation` 两个权利；**不联网、不上传、不改功能**；
- 同时重签名包内 Helper 与 `language_server`，并做注入冒烟验证；
- 目标在 `/Applications` 不可写时，会弹出**系统授权框**输入本机密码（与安装软件时相同）；
- 只需执行一次。**Antigravity 升级/重装会覆盖补丁**，重新双击启动器即可自动再打一次；
- 想完全撤销：重装官方 Antigravity 即可。

此外，agent 后端 `language_server` 原本由 `sandbox-wrapper.sh → sandbox-exec` 置于 Seatbelt
沙箱中（默认 `(deny network*)`，连不上本地代理端口，且受保护的 `sandbox-exec` 会剥除 DYLD 变量）。
dylib 拦截到该包装脚本时会直接还原为 `language_server` 本体启动（日志中会出现
"已绕过 Seatbelt/sandbox-exec"），使其与普通开发命令行工具拥有相同的联网/注入条件。

### 第 3 步：通过启动器启动 Antigravity / Launch via Launcher

**方式 A**：双击 `Antigravity-Proxy.command` → 菜单选 **1**（首次会先自动打签名补丁，随后启动 IDE）；
选 **2** 使用 agy 命令行（默认 `agy status`）。

**方式 B**：在终端执行：

```bash
# 已执行安装脚本
antigravity-proxy app

# 免安装方式（在项目根目录执行）
./scripts/antigravity-proxy.sh app

# agy 命令行
antigravity-proxy agy status
antigravity-proxy agy login
```

启动器会自动在 `/Applications`、`~/Applications` 查找 Antigravity；装在别处时，可直接把
**Antigravity.app 拖到启动器图标上**，或在终端传入 `.app` 路径：

```bash
./scripts/antigravity-proxy.sh "/Applications/Antigravity IDE.app"
```

启动后正常使用即可，网络流量会自动走代理，无需开启系统全局代理或 TUN 模式。🎉

### ✅ 怎么确认代理生效了

查看日志（与 dylib 同级的 `logs/` 目录；方式 A 即解压文件夹内的 `logs/`，方式 B 即 `~/.local/lib/logs/`）：

```bash
tail -n 30 ~/.local/lib/logs/proxy-*.log 2>/dev/null || tail -n 30 output-mac/logs/proxy-*.log
```

看到以下关键行即表示成功（注意主程序真名是 `Electron`）：

```text
[INFO] Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)
[INFO] 当前宿主进程: Electron (路径: .../Antigravity IDE.app/Contents/MacOS/Electron)
[INFO] 当前进程 Electron 启用代理拦截模式
[INFO] macOS 代理重定向: 目标=... 代理=127.0.0.1:7890 类型=socks5
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
- 补丁提示"正在运行"：先在 Antigravity 窗口按 **⌘Q** 完全退出，再回启动器按回车。
- 补丁提示缺少 `codesign`：终端执行 `xcode-select --install` 安装 Apple 命令行工具。
- Antigravity **升级后**需要重新应用一次签名补丁（启动器会自动检测并提示）。
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

1. 确认已配置好本地代理（例如 Clash/Surge 运行在 127.0.0.1:10808）。
2. 在项目根目录下执行：

   ```bash
   ./scripts/antigravity-proxy.sh agy status
   ```

   或者直接运行登录/对话命令：

   ```bash
   ./scripts/antigravity-proxy.sh agy login
   ```
3. 查看代理日志：

   ```bash
   tail -n 30 logs/proxy-*.log
   ```

**期望结果**：
日志中应出现类似记录：

```
[INFO] Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)
[INFO] 当前宿主进程: agy
[INFO] 当前进程 agy 启用代理拦截模式
[INFO] macOS API Hook 已激活 (全量拦截: connect, getaddrinfo, posix_spawn, execve)
[INFO] macOS 代理重定向: 目标=... 代理=127.0.0.1:10808 类型=socks5
```

并且 `agy` 命令能够顺利联网通讯，无需系统全局代理。

---

### 测试 4：Antigravity IDE 客户端透明代理测试

1. 确保在 `/Applications/` 下已安装 `Antigravity.app`（或通过脚本直接指定路径）。
2. 使用启动脚本启动：

   ```bash
   ./scripts/antigravity-proxy.sh app
   ```

   *（若 Antigravity 安装在其他位置，可直接传入绝对路径：`./scripts/antigravity-proxy.sh /Applications/Antigravity.app/Contents/MacOS/Antigravity`）*
3. 观察客户端窗口弹出，并且右上角或底部会收到系统提示：“配置读取成功，API Hook 已生效”（仅首次提示）。
4. 在 IDE 内部尝试触发 AI 补全或登录 Google 账户。

**期望结果**：

- IDE 正常启动，没有崩溃。
- 网络请求通过本地代理（如 127.0.0.1:10808）成功建立连接。

---

### 测试 5：子进程注入与日志审查验证

Antigravity IDE 内部会通过 `posix_spawn` 或 `execve` 启动关键后台子进程（如 `language_server`、`node`）。
执行以下命令观察子进程注入情况：

```bash
grep "子进程" logs/proxy-*.log
```

**期望结果**：
日志中清晰记录了子进程的派生拦截与环境变量自动注入：

```
[INFO] [成功] 拦截到子进程派生 (posix_spawn): language_server_macos_arm64，正在注入 DYLD_INSERT_LIBRARIES
[INFO] Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)
[INFO] 当前宿主进程: language_server_macos_arm64
[INFO] 当前进程 language_server_macos_arm64 启用代理拦截模式
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
  补丁会自动完成重签名与注入冒烟验证；**不需要、也不建议关闭 SIP**。
- 若 macOS 提示的是**动态库**代码签名问题，可对动态库执行本地临时签名：
  ```bash
  codesign --force --sign - output-mac/libantigravity_proxy.dylib
  ```
- 也可单独对任意目标手动执行补丁脚本：
  ```bash
  ./scripts/mac-patch-app.sh "/Applications/Antigravity IDE.app" output-mac/libantigravity_proxy.dylib
  ```

### 3. 如何全局安装为系统命令？

运行安装脚本：

```bash
./scripts/install-mac.sh
```

此命令会将动态库安装至 `~/.local/lib/`，配置文件安装至 `~/.config/antigravity-proxy/`，并在 `~/.local/bin/` 创建 `antigravity-proxy` 命令。在 `~/.zshrc` 中配置 `export PATH="$HOME/.local/bin:$PATH"` 后，便可在终端任意位置输入 `antigravity-proxy app` 启动！
