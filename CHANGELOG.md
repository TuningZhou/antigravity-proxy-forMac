# 更新日志 / Changelog

本文件记录 Antigravity-Proxy 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/)。

## 2026-09-15 — macOS 端到端验证版本（Apple Silicon / macOS 26）

本版本在真机完成 macOS 全链路验证：经启动器启动 `Antigravity IDE TUN.app` 后，
**Google 账号 OAuth 授权成功并进入 IDE 主界面**；登录全过程的网络请求
（`oauth2.googleapis.com`、`cloudcode-pa.googleapis.com`、`www.googleapis.com`、
`accounts.google.com`、`lh3.googleusercontent.com` 等）全部经本地 SOCKS5 隧道，
**0 条绕过代理的直连连接**。CTest 6/6 通过。

### 修复（Fixed）

- **修复 `posix_spawn` 自递归导致 Electron 启动约 4 秒 SIGBUS 崩溃的致命缺陷**。
  原因是 `posix_spawn_fn` 与 `posix_spawnp_fn` 函数签名相同，旧实现的模板静态缓存被
  两个 `Real*` 共享；Electron 先调用 `posix_spawnp`（缓存 `libsystem_c` 地址）后，
  `my_posix_spawn` 误用该指针，其内部又回调被 interpose 的 `posix_spawn`，形成无限递归。
  现在每个 `Real*()` 各自持有独立的函数级 `static const` 指针，模板只负责解析、不再缓存函数地址。
- **修复原函数指针解析错误**。新增 `ResolveSystemSymbol(symbol, preferredImageBasename)`，
  两轮扫描 dyld 镜像并按权威镜像精确归属：`connect/close/execve/posix_spawn` 取
  `libsystem_kernel.dylib`，`posix_spawnp` 取 `libsystem_c.dylib`，
  `getaddrinfo/freeaddrinfo/gethostbyname` 取 `libsystem_info.dylib`；
  仅接受 `N_SECT` 真实定义（`(n_type & N_TYPE) == N_SECT`），
  使用 `nlist_64.n_un.n_strx` 正确读取符号名，跳过未定义引用与伞库重导出桩。
- **弃用 `dlsym(RTLD_NEXT)` 获取原函数**：现代 macOS 上对已被 `__DATA,__interpose`
  拦截的符号，该调用返回钩子自身地址，必然造成递归。改为遍历 Mach-O 符号表直接定位。
- 修复 zsh 环境变量名冲突（审计脚本中 `status` 为只读变量，改名规避）。

### 平台行为（Changed）

- 拦截 `sandbox-wrapper.sh → sandbox-exec` 包装链：检测到被 Seatbelt 沙箱
  （默认 `(deny network*)` 且剥除 DYLD 变量）包裹的 `language_server_macos_arm` 时，
  还原为本体直接启动，使 agent 后端获得与普通命令行工具一致的联网/注入条件。
- macOS 子进程注入覆盖 `posix_spawn`、`posix_spawnp`、`execve`，自动传播
  `DYLD_INSERT_LIBRARIES`；网络层拦截 `connect/getaddrinfo/gethostbyname/close`。

### 验证证据（Verified）

- IDE `auth.log`：`signedOut → validatingLogin → success → signedIn`，
  随后 `OAuth token changed, executing antigravity.handleAuthRefresh`。
- 进程审计：Electron 主进程、NetworkService、Renderer、多个 NodeService、
  2 个 `language_server_macos_arm` 全部加载 dylib（实测 23 个进程）。
- `lsof` 实证：所有非回环连接均指向本地代理端口；无直连外网 TCP、无 UDP/QUIC 绕过。

### 已知非阻塞项（Known limitations）

- `mac-patch-app.sh` 当前只重签 `.app` 主可执行与各 `Helper.app`；
  `Electron Framework.framework` 内嵌的裸二进制 `chrome_crashpad_handler` 及部分
  `.node` 原生模块仍为 Google 原始 Hardened Runtime 签名。实测 crashpad 不发起外网连接，
  `.node` 由已注入宿主 `dlopen` 加载、其进程内网络调用仍被覆盖，故不影响 Google 登录与对话。

### 文档（Docs）

- README_MAC.md：更新 Hook 引擎机制说明、agy 1.2.x 新命令（无 `status/login`）、
  修正日志路径与 `language_server_macos_arm` 名称，新增「附录 A：端到端验证记录」。
- README.md / README_EN.md：macOS 章节补充真机验证通过标记与单实例登录注意事项。
