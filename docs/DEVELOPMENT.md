# Antigravity-Proxy (macOS) 开发与架构文档

> 📌 **分支定位**：本分支（`antigravity-proxy-forMacOS`）专门负责 **macOS 平台**的透明代理实现；Windows 版本由 `main` 分支维护。

---

## 🏗️ 架构设计说明

### 设计原则
本项目严格遵循以下设计原则:

| 原则 | 应用 |
|------|------|
| **KISS** | 保持简单的网络重定向逻辑，不引入复杂的异步框架 |
| **YAGNI** | 仅实现 macOS 平台需要的功能，不做过度设计 |
| **SOLID/SRP** | 分离配置 (Config)、日志 (Logger)、网络 (Network)、Hook (Hooks) 职责 |

### 模块架构

```
┌─────────────────────────────────────────────────────────────┐
│                 Dylib Entry (main_mac.cpp)                  │
│  - __attribute__((constructor)) 动态库加载                   │
│  - 加载配置 (Config::Load)                                   │
│  - 目标进程/子进程识别                                        │
│  - 安装 Hooks (Hooks::Install)                               │
└─────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
   │ Core Module  │   │Network Module│   │ Hooks Module │
   │ - Config     │   │ - SOCKS5     │   │ - my_connect │
   │ - Logger     │   │ - HTTP Conn  │   │ - getaddrinfo│
   │ - UdpPolicy  │   │ - FakeIP(mmap│   │ - posix_spawn│
   └──────────────┘   └──────────────┘   └──────────────┘
```

### 错误处理策略
- **Fail-Safe**: 配置加载失败或 Hook 初始化失败时，不崩溃，自动进入 BYPASS 模式并让目标程序继续运行。

---

## 🔑 核心技术决策

### 1. 采用 Apple 原生 Dyld 符号重定向 (Dyld Interposing)
- **机制**：通过 Mach-O `__DATA,__interpose` 段实现系统符号重定向，无需修改内存代码段执行权限，原生兼容 macOS Hardened Runtime、W^X 保护及 ARM64 PAC (Pointer Authentication)。
- **原函数解析**：弃用在已 interpose 符号下会递归返回钩子自身的 `dlsym(RTLD_NEXT)`，改为遍历 dyld 已加载镜像 Mach-O 符号表直接解析 `N_SECT` 真实符号，并按权威镜像（`libsystem_kernel.dylib` / `libsystem_c.dylib` / `libsystem_info.dylib`）精确定位。

### 2. 跨进程 FakeIP 共享
- **机制**：采用 POSIX 文件内存映射（`/tmp/antigravity_proxy_fakeip.map`）与 `fcntl` 文件记录锁，实现 Electron 主进程、Helper 进程与后端 `language_server` 之间的跨进程 FakeIP 映射同步。

### 3. 子进程继承与沙箱绕过
- **继承传播**：拦截 `posix_spawn`、`posix_spawnp` 和 `execve`，自动将 `DYLD_INSERT_LIBRARIES` 注入环境变量传递至子进程。
- **Seatbelt 沙箱绕过**：检测到 `sandbox-wrapper.sh` / `sandbox-exec` 包装时，自动还原为 `language_server` 本体直接执行，穿透网络沙箱隔离。

---

## 📚 参考资料

- [Apple Dyld Interposing Documentation](https://opensource.apple.com/source/dyld/)
- [Mach-O File Format Reference](https://github.com/aidansteele/osx-abi-macho-file-format-reference)
- [nlohmann/json](https://github.com/nlohmann/json)
