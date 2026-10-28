# 🚀 Antigravity-Proxy v2.6.0 发布说明

省流：Google 搞抽象，把 Antigravity 升到 v2.28.0、Antigravity IDE 升到 v2.6.0，AI 后端统一换成 Gemini CLI 系的 **agy**（v1.4.9）。

于是两个平台都出现了"**两份 agy**"：

- **Windows**：两份 `agy.exe`，把 `antigravity-proxy-v2.6.0-cli-win-x64.zip` 分别解压到两个目录即可；
- **macOS**：两份 `agy`（`~/.local/bin/agy` 与 `~/.gemini/bin/agy`），**无需手工复制**——启动器会在每次启动 IDE 前自动完成重签名自愈，本版本已修复升级后 AI 视图报 `Server failed to start ... after 30000ms` 的问题。

> 本次的 macOS 压缩包（Assets）与 v2.5.6 结构一致，但 **dylib 与启动器已更新**，请务必使用 v2.6.0 的包。

IDE v2.6.0 的后端换成了 Gemini CLI 系（agy v1.4.9，language server 2.28.0），遵循 Gemini CLI 的目录约定，把程序和配置放在 `~/.gemini`（Windows 为 `%USERPROFILE%\.gemini`，即 `C:\Users\您的电脑名\.gemini`，下面有 `bin`、`antigravity`、`antigravity-cli` 等）。因此：

| 平台 | 终端 agy（PATH 中） | IDE 内嵌 agy（不进 PATH） |
| :--- | :--- | :--- |
| **Windows** | `%LOCALAPPDATA%\agy\bin\agy.exe`（官方安装器 + auto-updater 维护） | `%USERPROFILE%\.gemini\bin\agy.exe`（IDE 扩展下载） |
| **macOS** | `~/.local/bin/agy`（官方安装器 + auto-updater 维护） | `~/.gemini/bin/agy`（IDE 2.6.0 扩展下载） |

两份是同一版本但**不是同一份文件**，各自独立更新。Windows 的 DLL 劫持只对同目录 exe 生效，所以必须往两个目录都放 shim；macOS 因 Hardened Runtime 会拦截 DYLD 注入，所以由启动器在每次启动 IDE 前自动对 `~/.gemini/bin/agy` 做本地 ad-hoc 重签名（不改动 `Antigravity IDE.app` 本体；IDE 扩展下次升级覆盖后仍会自动自愈）。

本项目提供 **Windows** 与 **macOS** 平台下 Google Antigravity（桌面 IDE 与命令行 agy / CLI）的透明代理支持，彻底解决国内网络环境下无法登录 Google 账号、Token 交换超时（`i/o timeout`）、以及 AI 补全连通性问题。

---

## 📦 平台二进制分发包说明 (Release Assets)

> 💡 **请在页面最下方的 Assets 区域根据操作系统与芯片架构下载对应压缩包：**

| 平台 / 芯片架构 | 推荐下载的压缩包 (Assets) | 适用场景 / 包含内容 |
| :--- | :--- | :--- |
| **macOS (全机型)** | `antigravity-proxy-v2.6.0-mac-universal2.zip` | **强烈推荐**！通用双架构，原生同时支持 Apple Silicon (M1~M4) 与 Intel Mac |
| **macOS (Apple Silicon)** | `antigravity-proxy-v2.6.0-mac-arm64.zip` | 专为 M1/M2/M3/M4 芯片优化的轻量包 |
| **macOS (Intel)** | `antigravity-proxy-v2.6.0-mac-x64.zip` | 专为 Intel 处理器 Mac 优化的轻量包 |
| **Windows (桌面端)** | `antigravity-proxy-v2.6.0-ide-win-x64.zip` | Windows Antigravity IDE 专用（含 `output/ide/version.dll` 与配置） |
| **Windows (命令行)** | `antigravity-proxy-v2.6.0-cli-win-x64.zip` | Windows Antigravity CLI 专用（含 `output/cli/dbghelp.dll`、`antigravity_proxy.dll`） |

---

## 🌟 本次版本核心更新 (Changelog)

### 🍏 macOS 分支 (`antigravity-proxy-forMacOS`) 更新要点

1. **适配 Antigravity IDE 2.6.0：内嵌 Gemini 后端 `~/.gemini/bin/agy` 自动注入与自愈**：
   - Google 本轮把 Antigravity IDE 升到 **2.6.0**、语言服务器升到 **2.28.0**，IDE 内的 AI 后端由 app 包内的 `language_server` 换成 **`agy`（Gemini CLI 内核，当前 1.4.9）**。
   - 这份 agy 由 IDE 扩展下载到 `~/.gemini/bin/agy`，**不在 `Antigravity IDE.app` 包内、路径也不含 `antigravity`**，旧版 dylib 会把它当成普通进程放行，且它带 Hardened Runtime，DYLD 注入会被系统静默忽略——表现为 IDE 内 AI 视图报 `Couldn't load this view` / `Server failed to start at http://127.0.0.1:xxxxx after 30000ms`。
   - **dylib 侧新增双 agy 识别**：`IsAntigravityRelatedMacProcess()` 增加 `agy` 进程名与 `~/.gemini/` 路径兜底，IDE 通过 `posix_spawn` / `posix_spawnp` / `execve` 派生的后端全部自动注入；日志中可见 `当前宿主进程: agy` 与 `当前进程 agy 启用代理拦截模式`。
   - **启动器侧新增静默自愈**：每次通过启动器启动 IDE 前，自动检测 `~/.gemini/bin/agy` 是否仍为官方签名；若官方后台静默升级覆盖，则自动完成本地 ad-hoc 重签名（已打过补丁时仅毫秒级校验，首次重签约需数秒），**无需手工复制文件，也不修改官方原件**。
   - **自动清理孤儿后端**：IDE 超时退出后若 `agy --hub` 仍挂在 launchd 下，启动器会识别 `ppid=1` 的残留后端并清理，避免旧进程占用文件或让新 IDE 误连旧后端。
   - **首次升级后的正确姿势**：⌘Q 完全退出 IDE（含后台进程），再运行一次启动器即可完成自愈；若 `~/.gemini/bin/agy` 尚未生成，先启动一次 IDE 让扩展下载，再退出并重跑启动器。
   - 终端 agy 与 IDE 后端是两份独立文件：`~/.local/bin/agy` 由官方 auto-updater 维护，原有自愈机制继续生效；两处都走同一套 SOCKS5 透明代理。

2. **命令行 `agy` 原生体验与毫秒级“自愈补丁”机制**：
   - **原生终端体验**：推荐配置别名后，普通用户可直接在终端中敲 `agy` 回车开启交互对话，无需记忆长命令。
   - **毫秒级抗更新自愈补丁**：针对 Google 官方后台频繁静默升级 `~/.local/bin/agy` 并启用 Hardened Runtime（拦截动态库）的问题，启动器内置自愈检测——每次运行在 0.1 秒内自动完成本地重签名校验与修复，静默更新后**永不失效**！
   - **凭据全自动复用**：命令行 `agy` 与桌面端 IDE 完全共享 Google 登录态。在代理启动的 IDE 副本中登录一次后，命令行自动识别复用，彻底终结 `token exchange failed: i/o timeout` 错误。
   - **管道与脚本纯净输出**：启动器的辅助提示（`[启动] agy 透明代理模式...`）已重定向至 `stderr`，管道处理（如 `agy changelog | grep ...`）或自动化脚本捕获时 `stdout` 保持 100% 纯净。
   - **终端未安装独立 CLI 时的兜底**：启动器会依次查找 `PATH`、`~/.antigravity/bin`、`~/.local/bin`，最后回退到 IDE 下载的 `~/.gemini/bin/agy`，避免"只装了 IDE 却无法用命令行"的困惑。

3. **构建与打包脚本全面增强 (`package-mac.sh`)**：
   - 新增 `--arch all` 一键批量构建 `universal2`、`arm64` 与 `x64` 三种产物。
   - 新增**架构兼容性智能熔断检查**：当下错架构或动态库与系统不匹配时，启动器会输出醒目、友好的中文诊断提示，避免因架构不匹配导致 macOS dyld 抛出 SIGABRT (DYLD Code 9) 异常崩溃。
   - 彻底修复 `ditto` 打包时由于 AppleDouble（`._*`）隐藏属性文件导致的打包污染。

4. **双应用（IDE + Classic）智能支持与本地安全补丁**：
   - 智能识别 `/Applications` 下的 `Antigravity IDE` 与 `Antigravity`。
   - 采用“原件保持不变 + 本地临时签名打副本”方案，绕过 Apple Hardened Runtime，**无需关闭 macOS SIP 系统完整性保护**。

5. **端到端链路验证通过**：
   - 完美绕过 Seatbelt 沙箱对子进程的拦截，Google OAuth 鉴权及 Gemini 模型通信流量 100% 经 SOCKS5 代理隧道（默认 `127.0.0.1:10808`），0 条直连泄露；IDE 2.6.0 内嵌 agy 与终端 agy 均确认命中代理。

---

### 🪟 Windows 分支 (`antigravity-proxy-forWindows`) 更新要点

1. **适配 Antigravity IDE 2.6.0：`agy` 出现两份，CLI 包要装两个目录**：
   - IDE 内的 Gemini 后端由 `language_server.exe` 切换为 **`agy.exe`（Gemini CLI 内核，当前 1.4.9）**，Windows 上出现两份 `agy.exe`，同一版本但不是同一份文件，各自独立更新：

     | 目录 | 由谁安装 | 在 PATH 中 | 实际用途 |
     | :--- | :--- | :--- | :--- |
     | `%LOCALAPPDATA%\agy\bin` | Antigravity CLI 官方安装器 + 后台 auto-updater | ✅ 是 | 你在终端里敲 `agy` 时运行的就是这一份 |
     | `%USERPROFILE%\.gemini\bin` | **Antigravity IDE 2.6.0 扩展**自动下载（遵循 Gemini CLI 的 `~/.gemini` 目录约定） | ❌ 否 | IDE 内嵌的 Gemini 后端，仅供 IDE 调用 |

   - **为什么必须装两处**：Windows 的 DLL 劫持只对**同目录**的 exe 生效。只部署 `%LOCALAPPDATA%\agy\bin` 时，IDE 内嵌的 agy 仍会直连 Google，表现为后端 30 秒超时、扩展报 `Server failed to start at http://127.0.0.1:11407`；只部署 `%USERPROFILE%\.gemini\bin` 时，终端 `agy` 会报 `token exchange failed ... i/o timeout`。
   - **部署前必须完全退出所有 `agy.exe` 与 Antigravity 进程**，否则 `dbghelp.dll` / `antigravity_proxy.dll` 被占用，复制会静默失败（文件大小与时间戳都不变，看似已覆盖实则未生效）。建议复制后核对文件大小或 SHA256。
   - `agy` 的后台自动更新只替换 `agy.exe`，不会删除 shim 文件（实测更新后仍在）；每次更新后建议打开 `logs/proxy-YYYYMMDD.log` 确认仍有 `[信息] 配置加载成功。` 与 `隧道建立成功`。
   - 该情形与 `http.proxy` 设置无关：shim 生效时无需修改 IDE 的用户设置；若某次 shim 未加载，可在设置里临时加 `"http.proxy": "http://127.0.0.1:10808"` 作为兜底（Go 程序不读 Windows 系统代理，只认 `HTTP_PROXY`/`HTTPS_PROXY`）。
2. **修复 Antigravity IDE 无法登录 Google 账号（新增 `host_full_hooks` 配置）**：
   - Antigravity IDE 与 Antigravity 是两个不同产品：Antigravity IDE 在 **Electron 主进程**内完成 Google OAuth 令牌交换（`oauth2.googleapis.com/token`、`loadCodeAssist`），而此前版本对宿主进程仅安装进程创建 Hook，导致令牌交换直连超时——浏览器显示授权成功，IDE 却报 "There was an error with your authentication"。
   - 新增 `host_full_hooks` 白名单（大小写不敏感，支持子串匹配，默认 `["Antigravity IDE.exe"]`）：命中的宿主进程恢复全量网络 Hook，登录流量经代理隧道完成。
   - `Antigravity.exe` 的登录流量本就走 `language_server.exe`（全量 Hook），无需加入该列表，行为完全不受影响。
   - 回环地址（如 OAuth 本地回调 `localhost` 端口）在 Hook 层有硬性直连保护，不受宿主全量 Hook 影响。
3. **CLI 同步加载与端口对齐**：
   - 优化 CLI shim 注入机制，在进程启动初始化时即完成同步加载，防止命令行最初的几次网络请求发生直连泄漏；端口默认对齐 `10808`。
4. **IDE 与 CLI 双目录独立发布架构**：
   - 严格分立 `output/ide/`（基于 `version.dll` 劫持）与 `output/cli/`（基于 `dbghelp.dll` 延迟加载），杜绝混合复制导致的文件冲突。
5. **子进程与崩溃防护强化**：
   - 增强对 Chromium 各类 Helper 进程与 Crashpad 的识别和生命周期保护，提高长时间运行时的抗崩溃稳定性。
6. **多语言与小白指引完善**：
   - 补充中文、英文、俄文（zh/en/ru）的全套 Antigravity CLI / IDE 极简配置指南与常见问题排查文档。

---

## 🛠️ 快速安装使用摘要

### 🍎 macOS 用户（推荐日常姿势）

1. 下载 `antigravity-proxy-v2.6.0-mac-universal2.zip`（或对应架构包）解压，建议将解压出的 `Antigravity-Proxy-macOS` 文件夹移动到 `~/Applications/`。
2. 确保本地代理客户端已开启（如 Surge、Clash、v2ray，默认监听 SOCKS5 `127.0.0.1:10808`）。
3. **桌面端启动**：双击 `Antigravity-Proxy.command` 选 **1**，按提示生成并启动 `Antigravity IDE TUN` 副本；在副本中点击 **Sign in with Google** 完成登录。
   - 若 IDE 刚升级到 2.6.0，**先 ⌘Q 完全退出 IDE，再运行一次启动器**：启动器会自动为 `~/.gemini/bin/agy` 完成重签名自愈，日志出现 `自愈完成：IDE 内嵌 Gemini 后端已可注入代理` 即可正常使用 AI 面板。
4. **命令行 agy 终端一劳永逸配置**：
   在系统终端执行一次以下命令（写入别名）：
   ```bash
   echo 'alias agy="$HOME/Applications/Antigravity-Proxy-macOS/Antigravity-Proxy.command agy"' >> ~/.zshrc
   source ~/.zshrc
   ```
   完成以上配置别名之后，新建任意终端窗口，直接输入 `agy` 回车即可开启交互对话，享受透明代理与抗更新自愈保护！

### 🪟 Windows 用户（极简使用指引）

1. **准备工作**：
   确保本地代理软件（如 v2rayN、Clash 等）已开启（默认监听 SOCKS5 `127.0.0.1:10808`；若使用 Clash 默认混合端口 `7890`，请在包内 `config.json` 中将 `port` 改为 `7890`）。
2. **桌面端（Antigravity IDE / Antigravity )部署**：
   - 下载并解压 `antigravity-proxy-v2.6.0-ide-win-x64.zip`。
   - 将包内的 `version.dll` 与 `config.json` 复制到 Antigravity IDE / Antigravity 安装目录（即 Antigravity IDE.exe 或 Antigravity.exe 同级目录）。
   - 直接启动 Antigravity IDE.exe 或 Antigravity.exe，网络请求即刻自动走代理。
3. **命令行端（Antigravity CLI / `agy`）部署 —— 2.6.0 起有两个目录**：
   - 下载并解压 `antigravity-proxy-v2.6.0-cli-win-x64.zip`。
   - **先完全退出所有 `agy.exe` 与 Antigravity 进程**（DLL 被占用时复制会静默失败，文件大小与时间戳都不变）。
   - **目录 A（终端 `agy`，已在 PATH 中）**：按键盘 <kbd>Win</kbd> + <kbd>R</kbd>，输入 `%LOCALAPPDATA%\agy\bin` 并按回车。
   - **目录 B（Antigravity IDE 2.6.0 内嵌 Gemini 后端）**：按键盘 <kbd>Win</kbd> + <kbd>R</kbd>，输入 `%USERPROFILE%\.gemini\bin` 并按回车。若该目录不存在，先启动一次 Antigravity IDE 2.6.0，扩展会自动下载 agy 并创建它。
   - 将包内的 **3 个文件**（`dbghelp.dll`、`antigravity_proxy.dll`、`config.json`）**分别复制到 A、B 两个目录**（⚠️ **切勿复制桌面端的 `version.dll`**）。只装一处会导致另一侧直连：IDE 报 `Server failed to start at http://127.0.0.1:11407`，或终端报 `token exchange failed ... i/o timeout`。
   - 复制完成后核对文件大小，确认与压缩包内一致，再运行 `agy` 或启动 Antigravity IDE 即可畅享透明代理。

---

## 🧪 升级到 2.6.0 后自检清单

| 检查项 | 预期结果 |
| :--- | :--- |
| 启动器更新日志 | 出现 `自愈完成：IDE 内嵌 Gemini 后端已可注入代理: .../.gemini/bin/agy` |
| `logs/proxy-*.log` | 出现 `当前宿主进程: agy`、`当前进程 agy 启用代理拦截模式` |
| IDE AI 面板 | 不再出现 `Server failed to start ... after 30000ms`，可正常对话 |
| 终端 `agy` | `agy changelog` 能经代理拉取；首次登录后无需重复登录 |
| 直连泄露检查 | 日志中无 agy 的 Google 域名直连记录 |

> 仍失败时：⌘Q 退出 IDE → 重新运行启动器 → 查看 `~/.gemini/logs/install.log` 与 `logs/proxy-*.log`；必要时执行
> `./scripts/mac-patch-app.sh "$HOME/.gemini/bin/agy" ./output-mac/libantigravity_proxy.dylib` 手工兜底。详见 `README_MAC.md` 第七节 FAQ 7。
