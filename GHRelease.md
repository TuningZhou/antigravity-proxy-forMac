# 🚀 Antigravity-Proxy v2.5.5 发布说明

本项目提供 **Windows** 与 **macOS** 平台下 Google Antigravity（桌面 IDE 与命令行 agy / CLI）的透明代理支持，彻底解决国内网络环境下无法登录 Google 账号、Token 交换超时（`i/o timeout`）、以及 AI 补全连通性问题。

---

## 📦 平台二进制分发包说明 (Release Assets)

> 💡 **请在页面最下方的 Assets 区域根据操作系统与芯片架构下载对应压缩包：**

| 平台 / 芯片架构 | 推荐下载的压缩包 (Assets) | 适用场景 / 包含内容 |
| :--- | :--- | :--- |
| **macOS (全机型)** | `antigravity-proxy-v2.5.5-mac-universal2.zip` | **强烈推荐**！通用双架构，原生同时支持 Apple Silicon (M1~M4) 与 Intel Mac |
| **macOS (Apple Silicon)** | `antigravity-proxy-v2.5.5-mac-arm64.zip` | 专为 M1/M2/M3/M4 芯片优化的轻量包 |
| **macOS (Intel)** | `antigravity-proxy-v2.5.5-mac-x64.zip` | 专为 Intel 处理器 Mac 优化的轻量包 |
| **Windows (桌面端)** | `antigravity-proxy-v2.5.5-ide-win-x64.zip` | Windows Antigravity IDE 专用（含 `output/ide/version.dll` 与配置） |
| **Windows (命令行)** | `antigravity-proxy-v2.5.5-cli-win-x64.zip` | Windows Antigravity CLI 专用（含 `output/cli/dbghelp.dll`、`antigravity_proxy.dll`） |

---

## 🌟 本次版本核心更新 (Changelog)

### 🍏 macOS 分支 (`antigravity-proxy-forMacOS`) 更新要点

1. **命令行 `agy` 原生体验与毫秒级“自愈补丁”机制**：
   - **原生终端体验**：推荐配置别名后，普通用户可直接在终端中敲 `agy` 回车开启交互对话，无需记忆长命令。
   - **毫秒级抗更新自愈补丁**：针对 Google 官方后台频繁静默升级 `~/.local/bin/agy` 并启用 Hardened Runtime（拦截动态库）的问题，启动器内置自愈检测——每次运行在 0.1 秒内自动完成本地重签名校验与修复，静默更新后**永不失效**！
   - **凭据全自动复用**：命令行 `agy` 与桌面端 IDE 完全共享 Google 登录态。在代理启动的 IDE 副本中登录一次后，命令行自动识别复用，彻底终结 `token exchange failed: i/o timeout` 错误。
   - **管道与脚本纯净输出**：启动器的辅助提示（`[启动] agy 透明代理模式...`）已重定向至 `stderr`，管道处理（如 `agy changelog | grep ...`）或自动化脚本捕获时 `stdout` 保持 100% 纯净。

2. **构建与打包脚本全面增强 (`package-mac.sh`)**：
   - 新增 `--arch all` 一键批量构建 `universal2`、`arm64` 与 `x64` 三种产物。
   - 新增**架构兼容性智能熔断检查**：当下错架构或动态库与系统不匹配时，启动器会输出醒目、友好的中文诊断提示，避免因架构不匹配导致 macOS dyld 抛出 SIGABRT (DYLD Code 9) 异常崩溃。
   - 彻底修复 `ditto` 打包时由于 AppleDouble（`._*`）隐藏属性文件导致的打包污染。

3. **双应用（IDE + Classic）智能支持与本地安全补丁**：
   - 智能识别 `/Applications` 下的 `Antigravity IDE` 与 `Antigravity`。
   - 采用“原件保持不变 + 本地临时签名打副本”方案，绕过 Apple Hardened Runtime，**无需关闭 macOS SIP 系统完整性保护**。

4. **端到端链路验证通过**：
   - 完美绕过 Seatbelt 沙箱对子进程 `language_server` 的拦截，Google OAuth 鉴权及 Gemini 模型通信流量 100% 经 SOCKS5 代理隧道（默认 `127.0.0.1:10808`），0 条直连泄露。

---

### 🪟 Windows 分支 (`antigravity-proxy-forWindows`) 更新要点

1. **CLI 同步加载与端口对齐**：
   - 优化 CLI shim 注入机制，在进程启动初始化时即完成同步加载，防止命令行最初的几次网络请求发生直连泄漏；端口默认对齐 `10808`。
2. **IDE 与 CLI 双目录独立发布架构**：
   - 严格分立 `output/ide/`（基于 `version.dll` 劫持）与 `output/cli/`（基于 `dbghelp.dll` 延迟加载），杜绝混合复制导致的文件冲突。
3. **子进程与崩溃防护强化**：
   - 增强对 Chromium 各类 Helper 进程与 Crashpad 的识别和生命周期保护，提高长时间运行时的抗崩溃稳定性。
4. **多语言与小白指引完善**：
   - 补充中文、英文、俄文（zh/en/ru）的全套 Antigravity CLI / IDE 极简配置指南与常见问题排查文档。

---

## 🛠️ 快速安装使用摘要

### 🍎 macOS 用户（推荐日常姿势）

1. 下载 `antigravity-proxy-v2.5.5-mac-universal2.zip`（或对应架构包）解压，建议将解压出的 `Antigravity-Proxy-macOS` 文件夹移动到 `~/Applications/`。
2. 确保本地代理客户端已开启（如 Surge、Clash、v2ray，默认监听 SOCKS5 `127.0.0.1:10808`）。
3. **桌面端启动**：双击 `Antigravity-Proxy.command` 选 **1**，按提示生成并启动 `Antigravity IDE TUN` 副本；在副本中点击 **Sign in with Google** 完成登录。
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
   - 下载并解压 `antigravity-proxy-v2.5.5-ide-win-x64.zip`。
   - 将包内的 `version.dll` 与 `config.json` 复制到 Antigravity IDE / Antigravity 安装目录（即 Antigravity IDE.exe 或 Antigravity.exe 同级目录）。
   - 直接启动 Antigravity IDE.exe 或 Antigravity.exe，网络请求即刻自动走代理。
3. **命令行端（Antigravity CLI / `agy`）部署**：
   - 下载并解压 `antigravity-proxy-v2.5.5-cli-win-x64.zip`。
   - 按键盘 <kbd>Win</kbd> + <kbd>R</kbd>，输入 `%LOCALAPPDATA%\agy\bin` 并按回车，直达 `agy.exe` 所在目录。
   - 将包内的 **3 个文件**（`dbghelp.dll`、`antigravity_proxy.dll`、`config.json`）全部复制到该目录（⚠️ **切勿复制桌面端的 `version.dll`**）。
   - 在任意终端（PowerShell 或 CMD）中直接运行 `agy` 即可畅享透明代理，彻底解决 `token exchange timeout` 登录超时！
