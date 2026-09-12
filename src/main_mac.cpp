#if defined(__APPLE__)

#include <mach-o/dyld.h>
#include <unistd.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <sys/stat.h>

#include <string>
#include <thread>
#include <fstream>
#include <sstream>

#include "core/Config.hpp"
#include "core/Logger.hpp"
#include "hooks/Hooks.hpp"
#include "hooks/ProcessName.hpp"
#include "update/UpdateChecker.hpp"

namespace {

static std::string GetCurrentProcessPathMac() {
    char buf[1024] = {0};
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0) {
        return std::string(buf);
    }
    const char* prog = getprogname();
    if (prog && *prog) {
        return std::string(prog);
    }
    return "Unknown";
}

static std::string GetCurrentProcessBaseNameMac() {
    return Hooks::ExtractBaseNameFromPathLike(GetCurrentProcessPathMac());
}

static std::string GetDylibIdentity() {
    Dl_info info{};
    if (!dladdr(reinterpret_cast<const void*>(&GetDylibIdentity), &info) || !info.dli_fname) {
        return "unknown-dylib";
    }
    std::string path = info.dli_fname;
    struct stat st{};
    std::ostringstream oss;
    oss << path;
    if (stat(path.c_str(), &st) == 0) {
        oss << "|size=" << st.st_size << "|mtime=" << st.st_mtime;
    }
    return oss.str();
}

static std::string GetLoadNotifyMarkerPath(const std::string& logDir) {
    if (logDir.empty()) return "";
    return logDir + "/load-notify-success.marker";
}

static bool HasShownSuccessForCurrentBuild(const std::string& markerPath, const std::string& identity) {
    if (markerPath.empty()) return false;
    std::ifstream f(markerPath);
    if (!f.is_open()) return false;
    std::string saved;
    std::getline(f, saved);
    return saved == identity;
}

static void MarkSuccessForCurrentBuild(const std::string& markerPath, const std::string& identity) {
    if (markerPath.empty()) return;
    std::ofstream f(markerPath, std::ios::out | std::ios::trunc);
    if (f.is_open()) {
        f << identity << "\n";
    }
}

static void MaybeShowLoadNotifyMac(bool success) {
    const auto& config = Core::Config::Instance();
    if (config.uiLoadNotify == "none") return;

    const std::string logDir = Core::Logger::GetLogDirectoryPath();
    const std::string markerPath = GetLoadNotifyMarkerPath(logDir);
    const std::string identity = GetDylibIdentity();
    const bool onceMode = (config.uiLoadNotify == "once");

    if (success && onceMode && HasShownSuccessForCurrentBuild(markerPath, identity)) {
        return;
    }

    // 仅在开启提示时异步通知
    std::thread([success, onceMode, markerPath, identity]() {
        usleep(400000);
        std::string cmd;
        if (success) {
            cmd = "osascript -e 'display notification \"配置读取成功，API Hook 已生效\" with title \"Antigravity-Proxy macOS\"' >/dev/null 2>&1 &";
        } else {
            cmd = "osascript -e 'display alert \"Antigravity-Proxy 配置加载失败\" message \"配置读取失败，已进入 BYPASS 模式。请检查 config.json。\" as warning' >/dev/null 2>&1 &";
        }
        ::system(cmd.c_str());

        if (success && onceMode) {
            MarkSuccessForCurrentBuild(markerPath, identity);
        }
    }).detach();
}

} // namespace

// ============= macOS 动态库构造与析构入口 =============

__attribute__((constructor))
static void OnDylibLoad() {
    std::string processPath = GetCurrentProcessPathMac();
    std::string processName = Hooks::ExtractBaseNameFromPathLike(processPath);

    Core::Logger::Info("Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)");
    Core::Logger::Info("当前宿主进程: " + processName + " (路径: " + processPath + ")");

    // 1. 加载配置 (会自动在 dylib 同级、~/.config/antigravity-proxy、~/.antigravity-proxy、当前工作目录搜索)
    const bool loaded = Core::Config::Instance().Load("config.json");
    if (!loaded) {
        Core::Logger::Error("配置加载失败：已进入 BYPASS 模式（不拦截网络）。请检查 config.json。");
        MaybeShowLoadNotifyMac(false);
        Hooks::Install(false);
        return;
    }

    const auto& config = Core::Config::Instance();

    // 2. 判断当前进程是否属于目标拦截进程或子进程
    const bool isTarget = config.ShouldInject(processName);
    const bool isChildTarget = config.ShouldInjectChildProcess(processName);
    const bool shouldHook = isTarget || isChildTarget;

    if (!shouldHook) {
        Core::Logger::Info("当前进程 " + processName + " 不在 targetProcesses 或 childProcesses 目标列表中，进入旁路模式");
        Hooks::Install(false);
        return;
    }

    // 3. 安装 Hooks
    Core::Logger::Info("当前进程 " + processName + " 启用代理拦截模式");
    Hooks::Install(true);

    MaybeShowLoadNotifyMac(true);
    UpdateChecker::StartAsync();
}

__attribute__((destructor))
static void OnDylibUnload() {
    Core::Logger::Info("Antigravity-Proxy macOS 动态库卸载：清理 Hooks 上下文");
    Hooks::Uninstall();
}

#endif // __APPLE__
