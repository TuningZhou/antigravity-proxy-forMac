#if defined(__APPLE__)

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <dlfcn.h>
#include <errno.h>

#include <crt_externs.h>
#include <atomic>

#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <mutex>
#include <memory>

#include "../core/Config.hpp"
#include "../core/Logger.hpp"
#include "../network/PlatformSocket.hpp"
#include "../network/FakeIP.hpp"
#include "../network/Socks5.hpp"
#include "../network/HttpConnect.hpp"
#include "../network/SocketIo.hpp"
#include "../network/LocalTargetPolicy.hpp"
#include "Hooks.hpp"
#include "ProcessName.hpp"



namespace {

// ============= 原生函数指针获取 (dlsym RTLD_NEXT) =============

using connect_fn = int (*)(int, const struct sockaddr*, socklen_t);
using getaddrinfo_fn = int (*)(const char*, const char*, const struct addrinfo*, struct addrinfo**);
using freeaddrinfo_fn = void (*)(struct addrinfo*);
using gethostbyname_fn = struct hostent* (*)(const char*);
using close_fn = int (*)(int);
using posix_spawn_fn = int (*)(pid_t*, const char*, const posix_spawn_file_actions_t*,
                               const posix_spawnattr_t*, char* const[], char* const[]);
using posix_spawnp_fn = int (*)(pid_t*, const char*, const posix_spawn_file_actions_t*,
                                const posix_spawnattr_t*, char* const[], char* const[]);
using execve_fn = int (*)(const char*, char* const[], char* const[]);

inline connect_fn RealConnect() {
    static connect_fn fn = reinterpret_cast<connect_fn>(dlsym(RTLD_NEXT, "connect"));
    return fn;
}

inline getaddrinfo_fn RealGetaddrinfo() {
    static getaddrinfo_fn fn = reinterpret_cast<getaddrinfo_fn>(dlsym(RTLD_NEXT, "getaddrinfo"));
    return fn;
}

inline freeaddrinfo_fn RealFreeaddrinfo() {
    static freeaddrinfo_fn fn = reinterpret_cast<freeaddrinfo_fn>(dlsym(RTLD_NEXT, "freeaddrinfo"));
    return fn;
}

inline gethostbyname_fn RealGethostbyname() {
    static gethostbyname_fn fn = reinterpret_cast<gethostbyname_fn>(dlsym(RTLD_NEXT, "gethostbyname"));
    return fn;
}

inline close_fn RealClose() {
    static close_fn fn = reinterpret_cast<close_fn>(dlsym(RTLD_NEXT, "close"));
    return fn;
}

inline posix_spawn_fn RealPosixSpawn() {
    static posix_spawn_fn fn = reinterpret_cast<posix_spawn_fn>(dlsym(RTLD_NEXT, "posix_spawn"));
    return fn;
}

inline posix_spawnp_fn RealPosixSpawnp() {
    static posix_spawnp_fn fn = reinterpret_cast<posix_spawnp_fn>(dlsym(RTLD_NEXT, "posix_spawnp"));
    return fn;
}

inline execve_fn RealExecve() {
    static execve_fn fn = reinterpret_cast<execve_fn>(dlsym(RTLD_NEXT, "execve"));
    return fn;
}

// 获取当前 dylib 的绝对路径
static std::string GetCurrentDylibPath() {
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&GetCurrentDylibPath), &info) && info.dli_fname) {
        return std::string(info.dli_fname);
    }
    return "";
}

// 记录自定义分配的 addrinfo 结构指针，以便安全释放
static std::unordered_set<struct addrinfo*> g_customAddrInfos;
static std::mutex g_customAddrInfosMtx;

// 记录 socket 目标信息
struct SocketTargetInfo {
    std::string host;
    uint16_t port = 0;
};
static std::unordered_map<int, SocketTargetInfo> g_socketTargets;
static std::mutex g_socketTargetsMtx;

static void RememberSocket(int fd, const std::string& host, uint16_t port) {
    if (fd < 0 || host.empty() || port == 0) return;
    std::lock_guard<std::mutex> lock(g_socketTargetsMtx);
    g_socketTargets[fd] = {host, port};
}

static void ForgetSocket(int fd) {
    if (fd < 0) return;
    std::lock_guard<std::mutex> lock(g_socketTargetsMtx);
    g_socketTargets.erase(fd);
}

} // namespace

namespace Hooks {
    static std::atomic<bool> g_installed{true};
    static std::atomic<bool> g_networkHooksEnabled{true};

    bool IsInstalled() {
        return g_installed.load(std::memory_order_relaxed);
    }

    bool IsNetworkHookEnabled() {
        return g_installed.load(std::memory_order_relaxed) &&
               g_networkHooksEnabled.load(std::memory_order_relaxed);
    }

    void Install(bool enableNetworkHooks) {
        g_networkHooksEnabled.store(enableNetworkHooks);
        g_installed.store(true);
        Core::Logger::Info(enableNetworkHooks
            ? "macOS API Hook 已激活 (全量拦截: connect, getaddrinfo, posix_spawn, execve)"
            : "macOS API Hook 已激活 (旁路网络拦截，仅保留进程派生拦截)");
    }

    void Uninstall() {
        g_installed.store(false);
        {
            std::lock_guard<std::mutex> lock(g_socketTargetsMtx);
            g_socketTargets.clear();
        }
        Core::Logger::Info("macOS API Hook 已注销并清理状态");
    }
}

namespace {

// 注入 DYLD_INSERT_LIBRARIES 到环境变量数组
static std::vector<std::string> BuildInjectedEnv(char* const envp[], const std::string& dylibPath) {
    std::vector<std::string> envList;
    bool foundDyld = false;
    bool foundFlat = false;

    char* const* currentEnv = envp ? envp : (*_NSGetEnviron());
    if (currentEnv) {
        for (int i = 0; currentEnv[i] != nullptr; ++i) {
            std::string item(currentEnv[i]);
            if (item.rfind("DYLD_INSERT_LIBRARIES=", 0) == 0) {
                foundDyld = true;
                if (item.find(dylibPath) == std::string::npos) {
                    item += ":" + dylibPath;
                }
            } else if (item.rfind("DYLD_FORCE_FLAT_NAMESPACE=", 0) == 0) {
                foundFlat = true;
            }
            envList.push_back(item);
        }
    }

    if (!foundDyld) {
        envList.push_back("DYLD_INSERT_LIBRARIES=" + dylibPath);
    }
    if (!foundFlat) {
        envList.push_back("DYLD_FORCE_FLAT_NAMESPACE=1");
    }
    return envList;
}

static std::vector<char*> ToCharPtrArray(const std::vector<std::string>& vec) {
    std::vector<char*> ptrs;
    ptrs.reserve(vec.size() + 1);
    for (const auto& s : vec) {
        ptrs.push_back(const_cast<char*>(s.c_str()));
    }
    ptrs.push_back(nullptr);
    return ptrs;
}

} // namespace

// ============= 替换函数实现 =============

extern "C" {

int my_connect(int sockfd, const struct sockaddr* addr, socklen_t addrlen) {
    if (!Hooks::IsNetworkHookEnabled() || !addr || sockfd < 0) {
        return RealConnect()(sockfd, addr, addrlen);
    }

    // 仅拦截 IPv4 与 IPv6 TCP 连接
    if (addr->sa_family != AF_INET && addr->sa_family != AF_INET6) {
        return RealConnect()(sockfd, addr, addrlen);
    }

    // 检查套接字类型，仅处理 SOCK_STREAM (TCP)
    int sockType = 0;
    socklen_t typeLen = sizeof(sockType);
    if (getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &sockType, &typeLen) == 0) {
        if (sockType != SOCK_STREAM) {
            return RealConnect()(sockfd, addr, addrlen);
        }
    }

    // 忽略本地回环目标
    if (Network::IsLoopbackSockaddr(addr, addrlen)) {
        return RealConnect()(sockfd, addr, addrlen);
    }

    const auto& config = Core::Config::Instance();
    std::string targetHost;
    uint16_t targetPort = 0;
    bool isFakeIp = false;

    if (addr->sa_family == AF_INET) {
        const auto* a4 = reinterpret_cast<const sockaddr_in*>(addr);
        targetPort = ntohs(a4->sin_port);
        uint32_t ipHost = ntohl(a4->sin_addr.s_addr);

        if (config.fakeIp.enabled && Network::FakeIP::Instance().IsFakeIP(ipHost)) {
            targetHost = Network::FakeIP::Instance().GetDomain(ipHost);
            isFakeIp = true;
        }

        if (targetHost.empty()) {
            char ipBuf[INET_ADDRSTRLEN] = {};
            inet_ntop(AF_INET, &a4->sin_addr, ipBuf, sizeof(ipBuf));
            targetHost = ipBuf;
        }
    } else if (addr->sa_family == AF_INET6) {
        const auto* a6 = reinterpret_cast<const sockaddr_in6*>(addr);
        targetPort = ntohs(a6->sin6_port);
        char ipBuf[INET6_ADDRSTRLEN] = {};
        inet_ntop(AF_INET6, &a6->sin6_addr, ipBuf, sizeof(ipBuf));
        targetHost = ipBuf;
    }

    // 端口白名单判断
    if (!config.rules.IsPortAllowed(targetPort)) {
        if (isFakeIp) {
            // FakeIP 端口未在代理名单中，尝试解析真实地址直连
            addrinfo hints{};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            addrinfo* res = nullptr;
            if (RealGetaddrinfo()(targetHost.c_str(), nullptr, &hints, &res) == 0 && res) {
                auto* realAddr = reinterpret_cast<sockaddr_in*>(res->ai_addr);
                realAddr->sin_port = htons(targetPort);
                int rc = RealConnect()(sockfd, reinterpret_cast<sockaddr*>(realAddr), res->ai_addrlen);
                RealFreeaddrinfo()(res);
                return rc;
            }
        }
        return RealConnect()(sockfd, addr, addrlen);
    }

    // 规则分流匹配 (DecideRoute)
    std::string action = "proxy";
    if (config.rules.routing.enabled) {
        std::string matchedRule;
        action = config.rules.DecideRoute(targetHost, targetPort, "tcp", &matchedRule);
    }

    if (action == "direct") {
        if (isFakeIp) {
            addrinfo hints{};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            addrinfo* res = nullptr;
            if (RealGetaddrinfo()(targetHost.c_str(), nullptr, &hints, &res) == 0 && res) {
                auto* realAddr = reinterpret_cast<sockaddr_in*>(res->ai_addr);
                realAddr->sin_port = htons(targetPort);
                int rc = RealConnect()(sockfd, reinterpret_cast<sockaddr*>(realAddr), res->ai_addrlen);
                RealFreeaddrinfo()(res);
                return rc;
            }
        }
        return RealConnect()(sockfd, addr, addrlen);
    }

    // 建立代理隧道
    Core::Logger::Info("macOS 代理重定向: 目标=" + targetHost + ":" + std::to_string(targetPort) +
                       " 代理=" + config.proxy.host + ":" + std::to_string(config.proxy.port) +
                       " 类型=" + config.proxy.type);

    // 解析代理服务器地址
    sockaddr_in proxyAddr{};
    proxyAddr.sin_family = AF_INET;
    proxyAddr.sin_port = htons(static_cast<uint16_t>(config.proxy.port));
    if (inet_pton(AF_INET, config.proxy.host.c_str(), &proxyAddr.sin_addr) != 1) {
        addrinfo hints{};
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        addrinfo* res = nullptr;
        if (RealGetaddrinfo()(config.proxy.host.c_str(), nullptr, &hints, &res) != 0 || !res) {
            Core::Logger::Error("代理服务器域名解析失败: " + config.proxy.host);
            errno = EHOSTUNREACH;
            return -1;
        }
        proxyAddr.sin_addr = reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr;
        RealFreeaddrinfo()(res);
    }

    // 检查套接字当前是否为非阻塞
    int flags = fcntl(sockfd, F_GETFL, 0);
    bool wasNonBlocking = (flags != -1) && (flags & O_NONBLOCK);

    // 连接代理服务器
    int connectRc = RealConnect()(sockfd, reinterpret_cast<sockaddr*>(&proxyAddr), sizeof(proxyAddr));
    if (connectRc != 0) {
        if (errno == EINPROGRESS || errno == EWOULDBLOCK) {
            if (!Network::SocketIo::WaitConnect(sockfd, config.timeout.connect_ms)) {
                Core::Logger::Error("连接代理服务器超时或失败: " + config.proxy.host + ":" + std::to_string(config.proxy.port));
                return -1;
            }
        } else {
            Core::Logger::Error("连接代理服务器失败: err=" + std::to_string(errno));
            return -1;
        }
    }

    // 执行代理握手 (SOCKS5 / HTTP CONNECT)
    bool handshakeOk = false;
    if (config.proxy.type == "http") {
        handshakeOk = Network::HttpConnectClient::Handshake(sockfd, targetHost, targetPort);
    } else {
        handshakeOk = Network::Socks5Client::Handshake(sockfd, targetHost, targetPort);
    }

    if (!handshakeOk) {
        Core::Logger::Error("代理握手失败: 目标=" + targetHost + ":" + std::to_string(targetPort));
        errno = ECONNREFUSED;
        return -1;
    }

    // 握手完成，若原本是非阻塞模式则恢复非阻塞
    if (wasNonBlocking) {
        Network::SocketIo::SetNonBlocking(sockfd, true);
    }

    RememberSocket(sockfd, targetHost, targetPort);
    return 0;
}

int my_getaddrinfo(const char* node, const char* service,
                   const struct addrinfo* hints, struct addrinfo** res) {
    if (!Hooks::IsNetworkHookEnabled() || !node || !res) {
        return RealGetaddrinfo()(node, service, hints, res);
    }

    // 若输入本身已是 IPv4/IPv6 字符串或 loopback，直接交由原生解析
    if (Network::IsLoopbackHost(node)) {
        return RealGetaddrinfo()(node, service, hints, res);
    }
    in_addr addr4{};
    in6_addr addr6{};
    if (inet_pton(AF_INET, node, &addr4) == 1 || inet_pton(AF_INET6, node, &addr6) == 1) {
        return RealGetaddrinfo()(node, service, hints, res);
    }

    const auto& config = Core::Config::Instance();
    if (config.fakeIp.enabled) {
        // 分配 FakeIP
        uint32_t fakeIpHost = Network::FakeIP::Instance().GetFakeIP(node);
        auto* ai = reinterpret_cast<struct addrinfo*>(std::calloc(1, sizeof(struct addrinfo)));
        auto* sa = reinterpret_cast<struct sockaddr_in*>(std::calloc(1, sizeof(struct sockaddr_in)));

        sa->sin_family = AF_INET;
        sa->sin_addr.s_addr = htonl(fakeIpHost);
        sa->sin_port = service ? htons(static_cast<uint16_t>(std::atoi(service))) : 0;

        ai->ai_family = AF_INET;
        ai->ai_socktype = hints ? hints->ai_socktype : SOCK_STREAM;
        ai->ai_protocol = hints ? hints->ai_protocol : IPPROTO_TCP;
        ai->ai_addr = reinterpret_cast<struct sockaddr*>(sa);
        ai->ai_addrlen = sizeof(struct sockaddr_in);
        ai->ai_canonname = strdup(node);

        {
            std::lock_guard<std::mutex> lock(g_customAddrInfosMtx);
            g_customAddrInfos.insert(ai);
        }

        *res = ai;
        return 0;
    }

    return RealGetaddrinfo()(node, service, hints, res);
}

void my_freeaddrinfo(struct addrinfo* res) {
    if (!res) return;

    bool isCustom = false;
    {
        std::lock_guard<std::mutex> lock(g_customAddrInfosMtx);
        auto it = g_customAddrInfos.find(res);
        if (it != g_customAddrInfos.end()) {
            g_customAddrInfos.erase(it);
            isCustom = true;
        }
    }

    if (isCustom) {
        if (res->ai_canonname) std::free(res->ai_canonname);
        if (res->ai_addr) std::free(res->ai_addr);
        std::free(res);
        return;
    }

    RealFreeaddrinfo()(res);
}

struct hostent* my_gethostbyname(const char* name) {
    if (!Hooks::IsNetworkHookEnabled() || !name) return RealGethostbyname()(name);

    if (Network::IsLoopbackHost(name)) {
        return RealGethostbyname()(name);
    }

    const auto& config = Core::Config::Instance();
    if (config.fakeIp.enabled) {
        uint32_t fakeIpHost = Network::FakeIP::Instance().GetFakeIP(name);
        static thread_local hostent s_he{};
        static thread_local in_addr s_addr{};
        static thread_local char* s_addrList[2] = {nullptr, nullptr};
        static thread_local std::string s_name;

        s_addr.s_addr = htonl(fakeIpHost);
        s_addrList[0] = reinterpret_cast<char*>(&s_addr);
        s_addrList[1] = nullptr;

        s_name = name;
        s_he.h_name = const_cast<char*>(s_name.c_str());
        s_he.h_aliases = nullptr;
        s_he.h_addrtype = AF_INET;
        s_he.h_length = sizeof(in_addr);
        s_he.h_addr_list = s_addrList;
        return &s_he;
    }

    return RealGethostbyname()(name);
}

int my_close(int fd) {
    ForgetSocket(fd);
    return RealClose()(fd);
}

// ============= 子进程拦截与环境变量自动注入 =============

int my_posix_spawn(pid_t* pid, const char* path,
                   const posix_spawn_file_actions_t* file_actions,
                   const posix_spawnattr_t* attrp,
                   char* const argv[], char* const envp[]) {
    if (!Hooks::IsInstalled() || !path) return RealPosixSpawn()(pid, path, file_actions, attrp, argv, envp);

    std::string baseName = Hooks::ExtractBaseNameFromPathLike(path);
    const auto& config = Core::Config::Instance();

    if (config.childInjection && config.ShouldInjectChildProcess(baseName)) {
        std::string dylibPath = GetCurrentDylibPath();
        if (!dylibPath.empty()) {
            Core::Logger::Info("[成功] 拦截到子进程派生 (posix_spawn): " + baseName + "，正在注入 DYLD_INSERT_LIBRARIES");
            auto envList = BuildInjectedEnv(envp, dylibPath);
            auto charPtrs = ToCharPtrArray(envList);
            return RealPosixSpawn()(pid, path, file_actions, attrp, argv, charPtrs.data());
        }
    }

    return RealPosixSpawn()(pid, path, file_actions, attrp, argv, envp);
}

int my_posix_spawnp(pid_t* pid, const char* file,
                    const posix_spawn_file_actions_t* file_actions,
                    const posix_spawnattr_t* attrp,
                    char* const argv[], char* const envp[]) {
    if (!Hooks::IsInstalled() || !file) return RealPosixSpawnp()(pid, file, file_actions, attrp, argv, envp);

    std::string baseName = Hooks::ExtractBaseNameFromPathLike(file);
    const auto& config = Core::Config::Instance();

    if (config.childInjection && config.ShouldInjectChildProcess(baseName)) {
        std::string dylibPath = GetCurrentDylibPath();
        if (!dylibPath.empty()) {
            Core::Logger::Info("[成功] 拦截到子进程派生 (posix_spawnp): " + baseName + "，正在注入 DYLD_INSERT_LIBRARIES");
            auto envList = BuildInjectedEnv(envp, dylibPath);
            auto charPtrs = ToCharPtrArray(envList);
            return RealPosixSpawnp()(pid, file, file_actions, attrp, argv, charPtrs.data());
        }
    }

    return RealPosixSpawnp()(pid, file, file_actions, attrp, argv, envp);
}

int my_execve(const char* path, char* const argv[], char* const envp[]) {
    if (!Hooks::IsInstalled() || !path) return RealExecve()(path, argv, envp);

    std::string baseName = Hooks::ExtractBaseNameFromPathLike(path);
    const auto& config = Core::Config::Instance();

    if (config.childInjection && config.ShouldInjectChildProcess(baseName)) {
        std::string dylibPath = GetCurrentDylibPath();
        if (!dylibPath.empty()) {
            Core::Logger::Info("[成功] 拦截到进程替换 (execve): " + baseName + "，正在注入 DYLD_INSERT_LIBRARIES");
            auto envList = BuildInjectedEnv(envp, dylibPath);
            auto charPtrs = ToCharPtrArray(envList);
            return RealExecve()(path, argv, charPtrs.data());
        }
    }

    return RealExecve()(path, argv, envp);
}

} // extern "C"

// ============= Apple Dyld Interpose 符号重定向段 =============

#define DYLD_INTERPOSE(_replacement,_replacee) \
__attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
__attribute__((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

DYLD_INTERPOSE(my_connect, connect)
DYLD_INTERPOSE(my_getaddrinfo, getaddrinfo)
DYLD_INTERPOSE(my_freeaddrinfo, freeaddrinfo)
DYLD_INTERPOSE(my_gethostbyname, gethostbyname)
DYLD_INTERPOSE(my_close, close)
DYLD_INTERPOSE(my_posix_spawn, posix_spawn)
DYLD_INTERPOSE(my_posix_spawnp, posix_spawnp)
DYLD_INTERPOSE(my_execve, execve)

#endif // __APPLE__
