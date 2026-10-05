// 防止 windows.h 自动包含 winsock.h (避免与 winsock2.h 冲突)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <DbgHelp.h>
#pragma comment(lib, "dbghelp.lib")

#include <cwchar>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include "core/Config.hpp"
#include "core/Logger.hpp"
#include "hooks/ProcessName.hpp"
#include "update/UpdateChecker.hpp"

// CRT 参数与纯虚函数异常捕获
static void CustomInvalidParameterHandler(
    const wchar_t* expression,
    const wchar_t* function,
    const wchar_t* file,
    unsigned int line,
    uintptr_t /*pReserved*/
) {
    char msg[512];
    snprintf(msg, sizeof(msg),
             "[CRASH] CRT Invalid Parameter: %ls in %ls (%ls:%u)",
             expression ? expression : L"unknown",
             function ? function : L"unknown",
             file ? file : L"unknown",
             line);
    Core::Logger::Error(msg);
}

static void CustomPureCallHandler() {
    Core::Logger::Error("[CRASH] Pure Virtual Function Call Detected!");
}

// 全局异常向量捕获：记录未捕获异常代码、发生地址与模块名，并在崩溃时落盘 minidump
static LONG WINAPI ProcessVectoredExceptionHandler(PEXCEPTION_POINTERS pExceptionInfo) {
    if (!pExceptionInfo || !pExceptionInfo->ExceptionRecord) {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    const DWORD code = pExceptionInfo->ExceptionRecord->ExceptionCode;
    // 忽略常见良性非致命调试、RPC 异常以及标准 MSVC C++ 内部异常 (0xE06D7363)
    // 0xE06D7363 在正常 C++ 运行时 try-catch 中频繁触发，VEH 位于异常处理最顶端，
    // 不应拦截或记录，避免造成严重性能损耗与日志风暴。
    if (code == 0x40010006 || code == 0x000006BA || code == 0x406D1388 || code == 0xE06D7363) {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    PVOID addr = pExceptionInfo->ExceptionRecord->ExceptionAddress;
    char modName[MAX_PATH] = "UnknownModule";
    HMODULE hMod = NULL;
    if (GetModuleHandleExA(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCSTR>(addr),
        &hMod) && hMod) {
        GetModuleFileNameA(hMod, modName, MAX_PATH);
    }

    // 捕获所有严重异常 (0x80000000 ~ 0xFFFFFFFF)
    if ((code & 0x80000000) != 0) {
        char msg[512];
        snprintf(msg, sizeof(msg),
                 "[CRASH] 捕获到进程致命异常! Code=0x%08X, Address=0x%p, Module=%s",
                 code, addr, modName);
        Core::Logger::Error(msg);

        // 尝试写入 mini dump 便于现场定位
        const std::string dumpPath = Core::Logger::GetLogDirectoryPath() +
                                     "\\crash-" + std::to_string(GetCurrentProcessId()) + ".dmp";
        HANDLE hFile = CreateFileA(dumpPath.c_str(), GENERIC_WRITE, 0, NULL,
                                   CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hFile != INVALID_HANDLE_VALUE) {
            MINIDUMP_EXCEPTION_INFORMATION exInfo{};
            exInfo.ThreadId = GetCurrentThreadId();
            exInfo.ExceptionPointers = pExceptionInfo;
            exInfo.ClientPointers = FALSE;
            MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), hFile,
                              MiniDumpNormal, &exInfo, NULL, NULL);
            CloseHandle(hFile);
            Core::Logger::Error("[CRASH] Minidump 已写入: " + dumpPath);
        }
    }

    return EXCEPTION_CONTINUE_SEARCH;
}

// 前向声明
namespace Hooks {
    void Install(bool enableNetworkHooks);
    void Uninstall();
}

namespace VersionProxy {
    bool Initialize();
    void Uninitialize();
}

namespace {
    static bool IsCommandLineWhitespace(wchar_t value) {
        return value == L' ' || value == L'\t' || value == L'\r' || value == L'\n';
    }

    static bool IsOpenUrlArgument(const wchar_t* begin, const wchar_t* end) {
        constexpr wchar_t kOpenUrlSwitch[] = L"--open-url";
        const wchar_t* cursor = begin;
        for (const wchar_t* expected = kOpenUrlSwitch; *expected != L'\0'; ++expected) {
            while (cursor < end && *cursor == L'"') ++cursor;
            if (cursor == end || *cursor != *expected) return false;
            ++cursor;
        }

        while (cursor < end && *cursor == L'"') ++cursor;
        return cursor == end || *cursor == L'=';
    }

    static bool IsOpenUrlProtocolLaunch() {
        // 只按参数边界检查启动标记，不复制、保存或记录可能包含 URL、查询参数及令牌的内容。
        const wchar_t* cursor = GetCommandLineW();
        if (cursor == nullptr) return false;

        while (*cursor != L'\0') {
            while (IsCommandLineWhitespace(*cursor)) ++cursor;
            if (*cursor == L'\0') break;

            const wchar_t* argumentBegin = cursor;
            bool inQuotes = false;
            unsigned int precedingBackslashes = 0;
            while (*cursor != L'\0') {
                const wchar_t value = *cursor;
                if (value == L'\\') {
                    ++precedingBackslashes;
                    ++cursor;
                    continue;
                }
                if (value == L'"' && (precedingBackslashes % 2) == 0) {
                    inQuotes = !inQuotes;
                } else if (!inQuotes && IsCommandLineWhitespace(value)) {
                    break;
                }
                precedingBackslashes = 0;
                ++cursor;
            }

            if (IsOpenUrlArgument(argumentBegin, cursor)) return true;
        }
        return false;
    }

    static std::string GetCurrentProcessBaseName() {
        char processPath[MAX_PATH] = {0};
        const DWORD len = GetModuleFileNameA(NULL, processPath, MAX_PATH);
        if (len == 0 || len >= MAX_PATH) return "Unknown";
        return Hooks::ExtractBaseNameFromPathLike(processPath);
    }

    struct LoadNotifyPayload {
        bool success;
        bool askOpenLogs;
        std::wstring message;
    };

    static std::wstring Utf8ToWideLocal(const std::string& input) {
        if (input.empty()) return L"";
        int len = MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, NULL, 0);
        if (len <= 0) return L"";
        std::wstring result(len, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, &result[0], len);
        if (!result.empty() && result.back() == L'\0') result.pop_back();
        return result;
    }

    static std::string GetDllIdentity() {
        char modulePath[MAX_PATH] = {0};
        HMODULE hModule = NULL;
        if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCSTR>(&GetDllIdentity),
            &hModule)) {
            return "unknown-module";
        }
        DWORD len = GetModuleFileNameA(hModule, modulePath, MAX_PATH);
        if (len == 0 || len >= MAX_PATH) {
            return "unknown-module";
        }

        WIN32_FILE_ATTRIBUTE_DATA data{};
        std::ostringstream oss;
        oss << modulePath;
        if (GetFileAttributesExA(modulePath, GetFileExInfoStandard, &data)) {
            oss << "|size=" << data.nFileSizeHigh << ":" << data.nFileSizeLow
                << "|mtime=" << data.ftLastWriteTime.dwHighDateTime << ":" << data.ftLastWriteTime.dwLowDateTime;
        }
        return oss.str();
    }

    static std::string GetLoadNotifyMarkerPath(const std::string& logDir) {
        if (logDir.empty()) return "";
        return logDir + "\\load-notify-success.marker";
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

    static void OpenLogDirectoryIfNeeded(HMODULE shell32, const std::string& logDir) {
        if (!shell32 || logDir.empty()) return;
        using ShellExecuteWFn = HINSTANCE (WINAPI*)(HWND, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, INT);
        auto shellExecuteW = reinterpret_cast<ShellExecuteWFn>(GetProcAddress(shell32, "ShellExecuteW"));
        if (!shellExecuteW) return;
        const std::wstring wideDir = Utf8ToWideLocal(logDir);
        if (wideDir.empty()) return;
        shellExecuteW(NULL, L"open", wideDir.c_str(), NULL, NULL, SW_SHOWNORMAL);
    }

    DWORD WINAPI LoadNotifyThreadProc(LPVOID param) {
        std::unique_ptr<LoadNotifyPayload> payload(reinterpret_cast<LoadNotifyPayload*>(param));
        if (!payload) return 0;

        // 延迟到 DllMain 返回后再按需加载 user32，避免默认导入 UI 库并降低加载期行为面。
        Sleep(800);
        HMODULE user32 = LoadLibraryW(L"user32.dll");
        if (!user32) return 0;

        using MessageBoxWFn = int (WINAPI*)(HWND, LPCWSTR, LPCWSTR, UINT);
        auto messageBoxW = reinterpret_cast<MessageBoxWFn>(GetProcAddress(user32, "MessageBoxW"));
        if (!messageBoxW) {
            FreeLibrary(user32);
            return 0;
        }

        UINT flags = MB_TOPMOST | MB_SETFOREGROUND | (payload->success ? MB_ICONINFORMATION : MB_ICONERROR);
        flags |= payload->askOpenLogs ? MB_YESNO : MB_OK;
        int result = messageBoxW(
            NULL,
            payload->message.c_str(),
            L"Antigravity-Proxy 加载状态",
            flags
        );

        if (payload->askOpenLogs && result == IDYES) {
            HMODULE shell32 = LoadLibraryW(L"shell32.dll");
            if (shell32) {
                OpenLogDirectoryIfNeeded(shell32, Core::Logger::GetLogDirectoryPath());
                FreeLibrary(shell32);
            }
        }
        FreeLibrary(user32);
        return 0;
    }

    void MaybeShowLoadNotifyAsync(bool success) {
        const auto& config = Core::Config::Instance();
        if (config.uiLoadNotify == "none") return;

        const std::string logDir = Core::Logger::GetLogDirectoryPath();
        const std::string markerPath = GetLoadNotifyMarkerPath(logDir);
        const std::string identity = GetDllIdentity();
        const bool onceMode = config.uiLoadNotify == "once";
        if (success && onceMode && HasShownSuccessForCurrentBuild(markerPath, identity)) {
            return;
        }

        auto* payload = new LoadNotifyPayload{};
        payload->success = success;
        payload->askOpenLogs = true;
        if (success) {
            payload->message =
                L"Antigravity-Proxy 已加载成功，配置读取成功，API Hook 安装流程已执行。\n\n"
                L"后续同一版本成功加载不会继续弹窗；更新到新版 DLL 后会再次提示一次。\n\n"
                L"是否打开日志目录，查看加载与代理排障信息？";
        } else {
            payload->message =
                L"Antigravity-Proxy 已加载，但配置读取失败，当前已进入 BYPASS 模式（不安装 Hooks）。\n\n"
                L"请检查 config.json 与日志告警信息。\n\n"
                L"是否打开日志目录进行排查？";
        }

        HANDLE hThread = CreateThread(NULL, 0, LoadNotifyThreadProc, payload, 0, NULL);
        if (hThread) {
            CloseHandle(hThread);
            if (success && onceMode) {
                MarkSuccessForCurrentBuild(markerPath, identity);
            }
        } else {
            delete payload;
            Core::Logger::Warn("加载提示线程启动失败, err=" + std::to_string(GetLastError()));
        }
    }
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    switch (fdwReason) {
    case DLL_PROCESS_ATTACH: {
        DisableThreadLibraryCalls(hinstDLL);
        
        // ============================================================================
        // VersionProxy 采用懒加载模式 (Lazy Initialization)
        // Initialize() 现在是空操作，真正的系统 version.dll 会在导出函数首次被调用时加载
        // 这样可以避免在 DllMain 中调用 LoadLibraryW 导致的 Loader Lock 问题
        // （可能触发 0xc0000022 STATUS_ACCESS_DENIED 错误）
        // ============================================================================
        VersionProxy::Initialize();  // 空操作，保持接口兼容
        
        // 检查是否为 Chromium 专有子进程（renderer, gpu-process, utility, crashpad-handler 等）。
        // 这些子进程运行在 Chromium 沙盒中并启用了 Arbitrary Code Guard (ACG)，
        // 严禁安装 MinHook 或修改内存保护属性；且它们不派生业务进程，也不直接发起外网 AI 业务请求。
        // 直接完全旁路，避免触发渲染沙盒崩溃或破坏 Chromium 内部 IPC。
        if (Hooks::IsChromiumSubprocess(GetCommandLineW())) {
            return TRUE;
        }

        // 注册全局异常捕获，在宿主或业务进程出现未捕获异常时第一时间记录模块名和调用上下文
        AddVectoredExceptionHandler(1, ProcessVectoredExceptionHandler);
        _set_invalid_parameter_handler(CustomInvalidParameterHandler);
        _set_purecall_handler(CustomPureCallHandler);

        Core::Logger::Info("Antigravity-Proxy DLL 已加载 (模拟 version.dll)");
        Core::Logger::Info(IsOpenUrlProtocolLaunch()
            ? "启动类型：协议启动"
            : "启动类型：普通启动");
        
        // 加载配置
        const bool loaded = Core::Config::Instance().Load("config.json");
        
        // WARN-4: 必须检查 Load() 返回值。若加载失败则进入 BYPASS 模式，避免“坏配置导致全局网络不可用”。
        if (!loaded) {
            Core::Logger::Error("配置加载失败：已进入 BYPASS 模式（不安装 Hooks）。请检查 config.json 与日志告警信息。");
            MaybeShowLoadNotifyAsync(false);
            break;
        }

        const std::string processName = GetCurrentProcessBaseName();
        const bool enableNetworkHooks = !Hooks::IsAntigravityHostProcessName(processName);
        Core::Logger::Info(enableNetworkHooks
            ? "当前进程 " + processName + " 使用全量模式：安装网络与进程创建 Hook"
            : "当前进程 " + processName + " 使用注入器模式：仅安装进程创建 Hook，跳过网络 Hook");
        Hooks::Install(enableNetworkHooks);
        MaybeShowLoadNotifyAsync(true);
        // 更新检查默认关闭；启用后也只在后台异步提示，不阻塞 Hook 安装主流程。
        UpdateChecker::StartAsync();
        break;
    }
        
    case DLL_PROCESS_DETACH: {
        if (lpvReserved != nullptr) {
            // 进程终止时其他模块和线程状态不可控；仅保留一次日志作为原因证据，不执行复杂清理。
            Core::Logger::TryInfoAtProcessDetach("进程终止，DLL 随当前进程分离：已跳过 Hooks 与版本代理清理");
            break;
        }

        // lpvReserved 为空表示动态卸载，或 DLL 加载失败后的回滚；此时保留必要清理。
        Hooks::Uninstall();
        VersionProxy::Uninitialize();
        Core::Logger::Info("DLL 被显式释放或加载失败回滚：已完成 Hooks 与版本代理清理");
        break;
    }
    }
    return TRUE;
}
