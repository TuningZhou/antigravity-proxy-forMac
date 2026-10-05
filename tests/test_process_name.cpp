// 回归测试在 Release 构建下也必须执行断言。
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string>

#include "hooks/ProcessName.hpp"

int main() {
    using Hooks::GetCreateProcessTargetBaseNameA;
    using Hooks::IsAntigravityHostProcessName;
    using Hooks::IsChromiumSubprocess;
    using Hooks::IsLanguageServerProcessName;

    // lpApplicationName 明确给出路径时，不按空格截断文件名。
    assert(GetCreateProcessTargetBaseNameA(
               "C:\\Users\\test\\AppData\\Local\\Programs\\Antigravity\\Antigravity IDE.exe",
               nullptr) == "Antigravity IDE.exe");

    // 命令行带引号时，保留引号内完整 exe 路径，再提取文件名。
    assert(GetCreateProcessTargetBaseNameA(
               nullptr,
               "\"C:\\Users\\test\\AppData\\Local\\Programs\\Antigravity\\Antigravity IDE.exe\" --type=renderer") ==
           "Antigravity IDE.exe");

    // 命令行未加引号但包含 .exe 时，优先截到 .exe，避免参数污染进程名。
    assert(GetCreateProcessTargetBaseNameA(
               nullptr,
               "C:\\Users\\test\\AppData\\Local\\Programs\\Antigravity\\resources\\bin\\language_server.exe --stdio") ==
           "language_server.exe");

    // 普通无空格路径保持历史行为。
    assert(GetCreateProcessTargetBaseNameA(nullptr, "node.exe --inspect") == "node.exe");

    // 新旧 language server 命名都要触发窄范围 node 子进程兼容。
    assert(IsLanguageServerProcessName("language_server.exe"));
    assert(IsLanguageServerProcessName("language_server"));
    assert(IsLanguageServerProcessName("language_server_windows_x64.exe"));
    assert(!IsLanguageServerProcessName("Antigravity IDE.exe"));

    // 保留宿主进程名分类工具的稳定行为；运行时策略在 main.cpp 中统一启用全量 Hook。
    assert(IsAntigravityHostProcessName("Antigravity.exe"));
    assert(IsAntigravityHostProcessName("ANTIGRAVITY IDE.EXE"));
    assert(!IsAntigravityHostProcessName("language_server.exe"));
    assert(!IsAntigravityHostProcessName("node.exe"));

    // Chromium 沙盒与内部辅助子进程识别（宽字符与 ANSI）
    assert(IsChromiumSubprocess(L"\"C:\\Users\\test\\AppData\\Local\\Programs\\antigravity\\Antigravity.exe\" --type=renderer --field-trial-handle=123"));
    assert(IsChromiumSubprocess(L"\"C:\\Users\\test\\AppData\\Local\\Programs\\antigravity\\Antigravity.exe\" --type=gpu-process"));
    assert(IsChromiumSubprocess(L"\"C:\\Users\\test\\AppData\\Local\\Programs\\antigravity\\Antigravity.exe\" --type=utility --utility-sub-type=network.mojom.NetworkService"));
    assert(IsChromiumSubprocess(L"\"C:\\Users\\test\\AppData\\Local\\Programs\\antigravity\\Antigravity.exe\" --type=crashpad-handler"));
    assert(IsChromiumSubprocess("\"C:\\test\\Antigravity.exe\" --type=renderer"));
    assert(IsChromiumSubprocess("/type=renderer"));
    assert(!IsChromiumSubprocess(static_cast<const wchar_t*>(nullptr)));
    assert(!IsChromiumSubprocess(static_cast<const char*>(nullptr)));
    assert(!IsChromiumSubprocess(L""));
    assert(!IsChromiumSubprocess(L"\"C:\\Users\\test\\AppData\\Local\\Programs\\antigravity\\Antigravity.exe\""));
    assert(!IsChromiumSubprocess("C:\\Users\\test\\AppData\\Local\\Programs\\antigravity\\resources\\bin\\language_server.exe --standalone --https_server_port 0"));

    // 版本探测进程识别（宽字符与 ANSI）
    using Hooks::IsStampCheckCommandLine;
    assert(IsStampCheckCommandLine(L"\"C:\\path\\language_server.exe\" --stamp"));
    assert(IsStampCheckCommandLine(L"language_server.exe /stamp"));
    assert(IsStampCheckCommandLine("\"C:\\path\\language_server.exe\" --stamp"));
    assert(!IsStampCheckCommandLine(L"\"C:\\path\\language_server.exe\" --standalone"));
    assert(!IsStampCheckCommandLine(static_cast<const wchar_t*>(nullptr)));
    assert(!IsStampCheckCommandLine(static_cast<const char*>(nullptr)));

    return 0;
}
