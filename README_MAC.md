# Antigravity-Proxy macOS 使用与测试指南

本项目已全面支持 macOS 操作系统（兼容 Apple Silicon M1/M2/M3/M4 ARM64 与 Intel x86_64 架构），实现了与 Windows 端一致的**透明代理、FakeIP 域名映射、路由分流规则、子进程继承传播**等全部核心功能。

---

## 目录
- [一、核心实现原理](#一核心实现原理)
- [二、Mac 电脑环境准备](#二mac-电脑环境准备)
- [三、编译构建步骤](#三编译构建步骤)
- [四、配置文件说明](#四配置文件说明)
- [五、Mac 电脑测试执行流程（详细步骤）](#五mac-电脑测试执行流程详细步骤)
  - [测试 1：单元与回归测试验证 (CTest)](#测试-1单元与回归测试验证-ctest)
  - [测试 2：一键自测脚本 (Smoke Test)](#测试-2一键自测脚本-smoke-test)
  - [测试 3：Antigravity CLI (agy) 命令行透明代理测试](#测试-3antigravity-cli-agy-命令行透明代理测试)
  - [测试 4：Antigravity IDE 客户端透明代理测试](#测试-4antigravity-ide-客户端透明代理测试)
  - [测试 5：子进程注入与日志审查验证](#测试-5子进程注入与日志审查验证)
- [六、macOS 常见问题与排坑指南 (SIP / 安全机制)](#六macos-常见问题与排坑指南-sip--安全机制)

---

## 一、核心实现原理

| 平台机制对比 | Windows 端 | macOS 端 |
| :--- | :--- | :--- |
| **加载机制** | 符号导出劫持 (`version.dll` / `dbghelp.dll`) | 原生动态库注入 (`DYLD_INSERT_LIBRARIES`) |
| **Hook 引擎** | MinHook (内联机器码 Patch) | Apple 官方原生 Dyld 符号重定向 (`__DATA,__interpose`) + `dlsym(RTLD_NEXT)` |
| **网络拦截** | `connect`, `WSAConnect`, `getaddrinfo`, `gethostbyname` | `connect`, `getaddrinfo`, `gethostbyname`, `close` |
| **子进程注入** | Hook `CreateProcessA/W` 启动挂起 + 注入 | Hook `posix_spawn`, `posix_spawnp`, `execve` 自动传播环境变量 |
| **跨进程共享** | Windows 具名内存映射 (`CreateFileMappingW`) | POSIX 文件内存映射 (`mmap` + `fcntl` 文件锁) |
| **安全降级** | 配置读取失败自动进入 BYPASS 模式 | 配置读取失败自动进入 BYPASS 模式 |

macOS 端完全采用 Apple 官方规范的 **Dyld 符号重定向 (Dyld Interposing)** 技术，无需在内存中修改代码段可执行权限（W^X 机制兼容），原生支持 Apple Silicon 的 Hardened Runtime 与 ARM64 PAC 安全特性，稳定且不崩溃。

---

## 二、Mac 电脑环境准备

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

## 三、编译构建步骤

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
   > ```bash
   > ARCHS="arm64;x86_64" ./build.sh Release
   > ```

4. 构建完成后，产物将生成在 `output-mac/` 目录下：
   - `output-mac/libantigravity_proxy.dylib`：核心代理动态库
   - `output-mac/config.json` 或 `config.example.json`：配置文件

---

## 四、配置文件说明

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
    "port": 7890
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

## 五、Mac 电脑测试执行流程（详细步骤）

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

1. 确认已配置好本地代理（例如 Clash/Surge 运行在 127.0.0.1:7890）。
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
[INFO] macOS 代理重定向: 目标=... 代理=127.0.0.1:7890 类型=socks5
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
- 网络请求通过本地代理（如 127.0.0.1:7890）成功建立连接。

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

## 六、macOS 常见问题与排坑指南 (SIP / 安全机制)

### 1. 为什么用 macOS 自带的 `/usr/bin/curl` 测试看不到日志？
- **原因**：macOS 的 **SIP (System Integrity Protection)** 机制会保护系统内置二进制文件（例如 `/bin/*`、`/usr/bin/*`）。当执行系统自带的 `/usr/bin/curl` 时，操作系统内核出于安全考虑会自动清除 `DYLD_INSERT_LIBRARIES` 环境变量。
- **解决方案**：测试时请使用第三方应用程序进行验证（如 `Antigravity.app`、通过 npm/brew 安装的 `agy`，或 Homebrew 安装的 `/opt/homebrew/bin/curl`）。

### 2. 提示 "Operation not permitted" 或 "Code signature invalid"？
- 若 macOS 提示动态库代码签名问题，可对动态库执行本地临时签名：
  ```bash
  codesign --force --deep --sign - output-mac/libantigravity_proxy.dylib
  ```

### 3. 如何全局安装为系统命令？
运行安装脚本：
```bash
./scripts/install-mac.sh
```
此命令会将动态库安装至 `~/.local/lib/`，配置文件安装至 `~/.config/antigravity-proxy/`，并在 `~/.local/bin/` 创建 `antigravity-proxy` 命令。在 `~/.zshrc` 中配置 `export PATH="$HOME/.local/bin:$PATH"` 后，便可在终端任意位置输入 `antigravity-proxy app` 启动！
