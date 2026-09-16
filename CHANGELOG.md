# 更新日志 / Changelog

本文件记录 Antigravity-Proxy 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/)。

## 未发布 / Unreleased

### 新增（Added）

- **同时支持两个独立应用：经典版 `Antigravity.app` 与 `Antigravity IDE.app`**。
  两者 Bundle ID 不同（`com.google.antigravity` / `com.google.antigravity-ide`，
  主可执行分别为 `Antigravity` / `Electron`），但共用同一套 Google 登录与账号验证。
  - 启动器新增统一应用发现：固定路径优先 + `mdfind` 三 Bundle ID
    （`com.google.antigravity-ide`、`com.google.antigravity`、`com.antigravity.desktop`）
    + FSName 兜底，自动排除自身生成的 "TUN" 副本并按路径去重。
  - 新增 `apps` 动作列出全部已安装应用（序号 + Bundle ID）；`app` 支持选择器：
    `ide`、`classic`（别名 `antigravity`/`pro`）、序号、`.app` 绝对路径。
    只装一个时直选，装多个的非交互环境显式报错，不再替用户猜测。
  - 图形菜单（`Antigravity-Proxy.command`）菜单 **1** 在检测到多个应用时
    内联弹出应用选择子菜单（`1) Antigravity IDE` / `2) Antigravity` / `0) 返回`，
    上次启动的应用标注"上次使用"并作为回车默认项，选择记忆到包目录 `.last-app`）；
    只装一个应用时不弹子菜单、直接启动。原独立的"菜单 7 切换"已合并进菜单 1。
  - 菜单 **2** 的 agy 改为子菜单：① `changelog` 验证联网 ② 单次对话 `-p`
    ③ 交互式 `-i` ④ 自定义参数；每项执行完显示退出码并暂停返回主菜单。
  - 补丁脚本对经典版生成独立的 `Antigravity TUN.app`（与 IDE 的
    `Antigravity IDE TUN.app` 互不冲突），并可签名 `Contents/Resources/bin/language_server`。

### 平台行为（Changed）

- dylib 进程识别全面泛化：`IsAntigravityBundlePath()` 按可执行路径含 `antigravity`
  判定，`IsLanguageServerProcessName()` 精确命中纯名 `language_server`，
  两个应用无需区分进程名即可全部注入；**C++ 代码零改动**即兼容经典版。
- `scripts/antigravity-proxy.sh`、`scripts/install-mac.sh` 内嵌启动器、
  `scripts/package-mac.sh` heredoc 及 dist 内 `Antigravity-Proxy.command`
  三处启动逻辑统一为同一套枚举/选择函数，语义保持一致。

### 修复（Fixed）

- **修复"修改代理端口后不重启应用，登录持续失败"的问题**。现象为经典版
  `Antigravity TUN.app` 登录时报
  `Post "https://oauth2.googleapis.com/token": dial tcp 198.18.0.x:443: connect: connection refused`：
  应用先于改端口启动，长驻单例后端 `language_server` 一直缓存旧端口，
  macOS 的 `open` 再次启动只激活旧进程、不重载配置。
  三处启动器新增启动前预检：
  1. TCP 探测 `proxy.host:proxy.port`，不通则明确告警（交互可强制继续，非交互直接中止），
     避免在代理软件未启动/端口不一致时"假启动"；
  2. 检测到目标 TUN 副本仍在运行时，提示并可一键退出旧副本
     （TERM 等待 5 秒后 KILL，按 `.app/Contents/` 路径精确匹配，
     不影响官方原件与另一个 TUN 副本）再重新启动，保证新配置生效。
- **修复图形菜单中 agy 执行后无法返回、看不到结果的问题**：旧菜单 2 直接
  `exec agy`，进程结束即关闭终端，既不显示退出码也回不到主菜单。现改为
  子菜单 + 子进程方式运行，输出直接回显、结束后报告退出码（非 0 附带排障提示）
  并按回车返回主菜单；命令行非交互用法（`.command agy …`）仍保持 exec 前台语义。

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
