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
#include <sys/syscall.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

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

// ============= 原生函数指针获取 =============
//
// 重要：不能依赖 dlsym(RTLD_NEXT, "xxx")。在现代 macOS（实测 macOS 26）上，
// 当本库以 __DATA,__interpose 拦截某符号后，从钩子内部调用
// dlsym(RTLD_NEXT, 同名) 会返回【钩子自身地址】，从而 my_xxx -> RealXxx
// -> my_xxx 无限递归直至栈溢出。
//
// 正确做法：遍历 dyld 已加载镜像的 Mach-O 符号表（fishhook 同款方式），
// 只取 N_SECT 类型（镜像自身真实定义）的符号——天然跳过：
//   - N_UNDF：本库/主程序对系统函数的未定义引用
//   - N_INDR：libSystem 伞库的重导出桩（会重新指向被拦截的槽位）
//   - 其它注入库（替换函数不会以系统原名作为定义名）

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

// 在系统镜像中按带下划线的符号名（如 "_connect"）定位真实实现地址。
static void* ResolveSystemSymbol(const char* symbolName) {
    const uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; ++i) {
        const char* imageName = _dyld_get_image_name(i);
        if (imageName == nullptr) continue;
        // 仅在系统库目录中查找：connect/close/execve/posix_spawn 位于
        // libsystem_kernel，posix_spawnp 位于 libsystem_c，
        // getaddrinfo 系列位于 libsystem_info。
        if (strstr(imageName, "/usr/lib/system/") == nullptr) continue;

        const auto* header = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
        if (header == nullptr || header->magic != MH_MAGIC_64) continue;
        const intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        const symtab_command* symtab = nullptr;
        int64_t linkeditBase = 0;
        const load_command* cmd = reinterpret_cast<const load_command*>(
            reinterpret_cast<const uint8_t*>(header) + sizeof(mach_header_64));
        for (uint32_t c = 0; c < header->ncmds; ++c) {
            if (cmd->cmd == LC_SYMTAB) {
                symtab = reinterpret_cast<const symtab_command*>(cmd);
            } else if (cmd->cmd == LC_SEGMENT_64) {
                const auto* seg = reinterpret_cast<const segment_command_64*>(cmd);
                if (strncmp(seg->segname, "__LINKEDIT", 11) == 0) {
                    linkeditBase = static_cast<int64_t>(seg->vmaddr) -
                                   static_cast<int64_t>(seg->fileoff);
                }
            }
            cmd = reinterpret_cast<const load_command*>(
                reinterpret_cast<const uint8_t*>(cmd) + cmd->cmdsize);
        }
        if (symtab == nullptr || symtab->nsyms == 0) continue;

        const auto* symbols = reinterpret_cast<const nlist_64*>(
            static_cast<uintptr_t>(slide) + linkeditBase + symtab->symoff);
        const char* strings = reinterpret_cast<const char*>(
            static_cast<uintptr_t>(slide) + linkeditBase + symtab->stroff);
        for (uint32_t n = 0; n < symtab->nsyms; ++n) {
            const nlist_64& entry = symbols[n];
            if (entry.n_un.n_strx == 0) continue;
            if ((entry.n_type & N_TYPE) != N_SECT) continue; // 仅真实定义
            if ((entry.n_type & N_EXT) == 0) continue;
            if (strcmp(strings + entry.n_un.n_strx, symbolName) == 0) {
                return reinterpret_cast<void*>(
                    static_cast<uintptr_t>(slide) + entry.n_value);
            }
        }
    }
    return nullptr;
}

// 按函数指针类型解析真实系统函数（惰性、只解析一次）；符号表解析失败时
// 最后才回退到 dlsym（正常环境下不应走到）。
template <typename FnT>
static FnT RealSystemFunction(const char* mangledName) {
    static FnT fn = nullptr;
    if (fn == nullptr) {
        void* p = ResolveSystemSymbol(mangledName);
        if (p == nullptr) {
            p = dlsym(RTLD_NEXT, mangledName + 1); // 去掉前导下划线
        }
        fn = reinterpret_cast<FnT>(p);
    }
    return fn;
}

inline connect_fn RealConnect() { return RealSystemFunction<connect_fn>("_connect"); }
inline getaddrinfo_fn RealGetaddrinfo() { return RealSystemFunction<getaddrinfo_fn>("_getaddrinfo"); }
inline freeaddrinfo_fn RealFreeaddrinfo() { return RealSystemFunction<freeaddrinfo_fn>("_freeaddrinfo"); }
inline gethostbyname_fn RealGethostbyname() { return RealSystemFunction<gethostbyname_fn>("_gethostbyname"); }
inline close_fn RealClose() { return RealSystemFunction<close_fn>("_close"); }
inline posix_spawn_fn RealPosixSpawn() { return RealSystemFunction<posix_spawn_fn>("_posix_spawn"); }
inline posix_spawnp_fn RealPosixSpawnp() { return RealSystemFunction<posix_spawnp_fn>("_posix_spawnp"); }
inline execve_fn RealExecve() { return RealSystemFunction<execve_fn>("_execve"); }

// 获取当前 dylib 的绝对路径
static std::string GetCurrentDylibPath() {
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&GetCurrentDylibPath), &info) && info.dli_fname) {
        return std::string(info.dli_fname);
    }
    return "";
}

// 极简自旋锁：只使用原子 CAS，不经过 pthread_mutex。
// 背景：运行环境中可能存在同样 interpose close / 锁原语的第三方注入库
// （如沙箱库），若在 close 钩子内使用 std::mutex，可能形成
// close -> my_close -> mutex::lock -> (拦截层) -> close 的递归环直至栈溢出。
class TinySpinLock {
public:
    void lock() {
        while (m_flag.test_and_set(std::memory_order_acquire)) {
            // 自旋等待持有者释放
        }
    }
    void unlock() {
        m_flag.clear(std::memory_order_release);
    }
private:
    std::atomic_flag m_flag = ATOMIC_FLAG_INIT;
};

// 记录自定义分配的 addrinfo 结构指针，以便安全释放
// 注意：进程退出时 C++ 全局对象先于 dyld 镜像析构器被销毁，而镜像析构器
// （及退出阶段的 late hook）仍可能访问这些容器/锁，故刻意堆分配且永不释放，
// 避免对已析构锁加锁导致 "mutex lock failed: Invalid argument" 崩溃。
static std::unordered_set<struct addrinfo*>& CustomAddrInfos() {
    static auto* s = new std::unordered_set<struct addrinfo*>();
    return *s;
}
static TinySpinLock& CustomAddrInfosMtx() {
    static auto* m = new TinySpinLock();
    return *m;
}

// 记录 socket 目标信息
struct SocketTargetInfo {
    std::string host;
    uint16_t port = 0;
};
static std::unordered_map<int, SocketTargetInfo>& SocketTargets() {
    static auto* m = new std::unordered_map<int, SocketTargetInfo>();
    return *m;
}
static TinySpinLock& SocketTargetsMtx() {
    static auto* m = new TinySpinLock();
    return *m;
}

static void RememberSocket(int fd, const std::string& host, uint16_t port) {
    if (fd < 0 || host.empty() || port == 0) return;
    std::lock_guard<TinySpinLock> lock(SocketTargetsMtx());
    SocketTargets()[fd] = {host, port};
}

static void ForgetSocket(int fd) {
    if (fd < 0) return;
    std::lock_guard<TinySpinLock> lock(SocketTargetsMtx());
    SocketTargets().erase(fd);
}

// 直接发起内核系统调用关闭 fd，全程不经过任何可被 interpose 的库符号
// （close、syscall 等都可能被沙箱类注入库拦截并回调本钩子，形成递归栈溢出）。
static int RawSyscallClose(int fd) {
#if defined(__arm64__)
    register long x0 __asm__("x0") = fd;
    register long x16 __asm__("x16") = static_cast<long>(SYS_close);
    unsigned long carry = 0;
    __asm__ volatile("svc #0x80\n"
                     "cset %[carry], cs"
                     : "+r"(x0), [carry] "=r"(carry)
                     : "r"(x16)
                     : "cc", "memory");
    if (carry) {
        errno = static_cast<int>(x0);
        return -1;
    }
    return static_cast<int>(x0);
#elif defined(__x86_64__)
    long ret = 0;
    register long rdi __asm__("rdi") = fd;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "0"(static_cast<long>(SYS_close)), "r"(rdi)
                     : "rcx", "r11", "cc", "memory");
    if (static_cast<unsigned long>(ret) > static_cast<unsigned long>(-4096L)) {
        errno = static_cast<int>(-ret);
        return -1;
    }
    return static_cast<int>(ret);
#else
    #error "Unsupported architecture for RawSyscallClose"
#endif
}

} // namespace

namespace Hooks {
    // 默认必须为 false：dyld 加载本库后、构造函数执行前，libSystem 初始化器
    // （如 __malloc_init）内部就可能触发被 interpose 的 close 等函数。
    // 此阶段 malloc/互斥锁/dlsym 均不可用，默认放行可避免早期自死锁。
    static std::atomic<bool> g_installed{false};
    static std::atomic<bool> g_networkHooksEnabled{false};

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
            std::lock_guard<TinySpinLock> lock(SocketTargetsMtx());
            SocketTargets().clear();
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
        // FakeIP 的 IsFakeIP/GetDomain 均接收网络字节序地址
        uint32_t ipNetworkOrder = a4->sin_addr.s_addr;

        if (config.fakeIp.enabled && Network::FakeIP::Instance().IsFakeIP(ipNetworkOrder)) {
            targetHost = Network::FakeIP::Instance().GetDomain(ipNetworkOrder);
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

    // 规则分流匹配 (MatchRouting)
    // host 为 IP 字面量时 MatchRouting 内部可直接解析，无需额外传 ip
    std::string action = "proxy";
    std::string matchedRule;
    if (config.rules.routing.enabled) {
        config.rules.MatchRouting(targetHost, "", false, targetPort, "tcp", &action, &matchedRule);
        action = Core::ProxyRules::ToLower(std::move(action));
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
        // 分配 FakeIP（Alloc 返回网络字节序，可直接写入 sin_addr）
        uint32_t fakeIpNetwork = Network::FakeIP::Instance().Alloc(node);
        if (fakeIpNetwork != 0) {
            auto* ai = reinterpret_cast<struct addrinfo*>(std::calloc(1, sizeof(struct addrinfo)));
            auto* sa = reinterpret_cast<struct sockaddr_in*>(std::calloc(1, sizeof(struct sockaddr_in)));

            sa->sin_family = AF_INET;
            sa->sin_addr.s_addr = fakeIpNetwork;
            sa->sin_port = service ? htons(static_cast<uint16_t>(std::atoi(service))) : 0;

            ai->ai_family = AF_INET;
            ai->ai_socktype = hints ? hints->ai_socktype : SOCK_STREAM;
            ai->ai_protocol = hints ? hints->ai_protocol : IPPROTO_TCP;
            ai->ai_addr = reinterpret_cast<struct sockaddr*>(sa);
            ai->ai_addrlen = sizeof(struct sockaddr_in);
            ai->ai_canonname = strdup(node);

            {
                std::lock_guard<TinySpinLock> lock(CustomAddrInfosMtx());
                CustomAddrInfos().insert(ai);
            }

            *res = ai;
            return 0;
        }
        // FakeIP 分配失败（地址池异常）时回退原始解析
    }

    return RealGetaddrinfo()(node, service, hints, res);
}

void my_freeaddrinfo(struct addrinfo* res) {
    if (!res) return;

    bool isCustom = false;
    {
        std::lock_guard<TinySpinLock> lock(CustomAddrInfosMtx());
        auto it = CustomAddrInfos().find(res);
        if (it != CustomAddrInfos().end()) {
            CustomAddrInfos().erase(it);
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
        // 分配 FakeIP（Alloc 返回网络字节序，可直接写入 s_addr）
        uint32_t fakeIpNetwork = Network::FakeIP::Instance().Alloc(name);
        if (fakeIpNetwork != 0) {
            static thread_local hostent s_he{};
            static thread_local in_addr s_addr{};
            static thread_local char* s_addrList[2] = {nullptr, nullptr};
            static thread_local std::string s_name;

            s_addr.s_addr = fakeIpNetwork;
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
        // FakeIP 分配失败（地址池异常）时回退原始解析
    }

    return RealGethostbyname()(name);
}

int my_close(int fd) {
    if (Hooks::IsInstalled()) {
        ForgetSocket(fd);
    }
    // 始终直接发起原始内核系统调用关闭 fd：
    // 1. close 无用户态缓冲/簿记语义，与 libc 包装函数完全等价；
    // 2. 不经过 close/syscall/dlsym 等可被再次拦截的符号，避免与同样
    //    interpose libc 的第三方注入库（如沙箱）互相回调形成递归环；
    // 3. 极早期（malloc 尚未初始化）调用也安全。
    return RawSyscallClose(fd);
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
