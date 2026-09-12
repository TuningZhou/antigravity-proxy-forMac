#pragma once

namespace Hooks {
    // 安装并激活 API 拦截
    // enableNetworkHooks 为 true 时启用网络层拦截（connect, getaddrinfo 等）
    // 为 false 时仅启用进程派生与继承拦截（posix_spawn, execve 或 CreateProcess）
    void Install(bool enableNetworkHooks);

    // 卸载并清理拦截状态
    void Uninstall();

    // 检查 Hook 是否已安装
    bool IsInstalled();

    // 检查网络 Hook 是否处于启用状态
    bool IsNetworkHookEnabled();
}
