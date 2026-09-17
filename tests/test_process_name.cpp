// 回归测试在 Release 构建下也必须执行断言。
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <string>

#include "hooks/ProcessName.hpp"

int main() {
    using Hooks::ExtractBaseNameFromPathLike;
    using Hooks::IsAntigravityHostProcessName;
    using Hooks::IsLanguageServerProcessName;
    using Hooks::IsAntigravityBundlePath;
    using Hooks::IsAntigravityRelatedMacProcess;

    // 新旧 language server 命名都要触发窄范围子进程兼容。
    assert(IsLanguageServerProcessName("language_server"));
    assert(IsLanguageServerProcessName("language_server_macos_arm64"));
    assert(IsLanguageServerProcessName("language_server_macos_x64"));
    assert(IsLanguageServerProcessName("language_server.exe"));
    assert(!IsLanguageServerProcessName("Antigravity IDE"));

    // 宿主进程名分类
    assert(IsAntigravityHostProcessName("antigravity"));
    assert(IsAntigravityHostProcessName("Antigravity"));
    assert(IsAntigravityHostProcessName("antigravity ide"));
    assert(IsAntigravityHostProcessName("Antigravity IDE"));
    assert(!IsAntigravityHostProcessName("language_server"));
    assert(!IsAntigravityHostProcessName("node"));

    // macOS POSIX 路径测试
    assert(ExtractBaseNameFromPathLike("/Applications/Antigravity.app/Contents/MacOS/Antigravity") == "Antigravity");
    assert(ExtractBaseNameFromPathLike("/Applications/Antigravity IDE TUN.app/Contents/MacOS/Electron") == "Electron");
    assert(ExtractBaseNameFromPathLike("/Users/test/.antigravity/bin/agy") == "agy");
    assert(ExtractBaseNameFromPathLike("/path/to/language_server_macos_arm64") == "language_server_macos_arm64");

    // macOS Bundle 路径与进程判断测试
    assert(IsAntigravityBundlePath("/Applications/Antigravity.app/Contents/MacOS/Antigravity"));
    assert(IsAntigravityBundlePath("/Applications/Antigravity IDE TUN.app/Contents/Frameworks/Antigravity IDE Helper.app/Contents/MacOS/Antigravity IDE Helper"));
    assert(!IsAntigravityBundlePath("/usr/bin/curl"));

    assert(IsAntigravityRelatedMacProcess("/Applications/Antigravity.app/Contents/MacOS/Electron", "Electron"));
    assert(IsAntigravityRelatedMacProcess("/Users/test/.antigravity/bin/language_server_macos_arm64", "language_server_macos_arm64"));
    assert(!IsAntigravityRelatedMacProcess("/bin/bash", "bash"));

    return 0;
}
