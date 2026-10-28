#pragma once

#include <algorithm>
#include <cctype>
#include <string>
#include <utility>

namespace Hooks {

inline std::string ToLowerAsciiCopy(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

inline void TrimAsciiInPlace(std::string& s) {
    auto isWs = [](unsigned char c) { return std::isspace(c) != 0; };
    size_t begin = 0;
    while (begin < s.size() && isWs(static_cast<unsigned char>(s[begin]))) begin++;
    size_t end = s.size();
    while (end > begin && isWs(static_cast<unsigned char>(s[end - 1]))) end--;
    s = s.substr(begin, end - begin);
}

inline std::string StripOuterQuotesCopy(std::string s) {
    TrimAsciiInPlace(s);
    if (s.size() >= 2 && s.front() == '"' && s.back() == '"') {
        s = s.substr(1, s.size() - 2);
        TrimAsciiInPlace(s);
    }
    return s;
}

inline std::string ExtractBaseNameFromPathLike(std::string s) {
    s = StripOuterQuotesCopy(std::move(s));
    const size_t lastSlash = s.find_last_of("\\/");
    if (lastSlash != std::string::npos) {
        s = s.substr(lastSlash + 1);
    }
    return StripOuterQuotesCopy(std::move(s));
}


inline bool IsLanguageServerProcessName(const std::string& processName) {
    const std::string lowerName = ToLowerAsciiCopy(processName);
    return lowerName == "language_server.exe" ||
           lowerName == "language_server" ||
           lowerName.find("language_server_windows") != std::string::npos ||
           lowerName.find("language_server_macos") != std::string::npos;
}

inline bool IsAntigravityHostProcessName(const std::string& processName) {
    const std::string lowerName = ToLowerAsciiCopy(processName);
    return lowerName == "antigravity.exe" ||
           lowerName == "antigravity ide.exe" ||
           lowerName == "antigravity" ||
           lowerName == "antigravity ide";
}

// macOS 上 Antigravity IDE 的真实主程序名为 Electron（包内各 Helper 名为
// "Antigravity IDE Helper (Renderer/GPU/...)"，agent 后端为
// language_server_macos_arm），仅按进程名匹配会漏掉这些进程。
// 兜底规则：可执行文件全路径（大小写不敏感）位于 Antigravity app 包内即命中。
inline bool IsAntigravityBundlePath(const std::string& processPath) {
    const std::string lowerPath = ToLowerAsciiCopy(processPath);
    return lowerPath.find("antigravity") != std::string::npos;
}

// Antigravity 2.6.0 起，IDE 内嵌的 Gemini 后端改用 agy（Gemini CLI 内核）。
// 它由 IDE 扩展下载到 Gemini CLI 的目录约定下，不在 Antigravity app 包内：
//   macOS: ~/.gemini/bin/agy
//   Windows: %USERPROFILE%\.gemini\bin\agy.exe
// 终端独立安装的 agy（macOS: ~/.local/bin/agy）是另一份文件、独立更新。
// 路径兜底因此需要把 "agy" 进程名与 ~/.gemini 目录一并纳入识别，
// 否则 IDE 派生的后端会进入旁路模式（表现为 30 秒后
// "Server failed to start at http://127.0.0.1:xxxxx"）。
inline bool IsAgyProcessName(const std::string& processName) {
    std::string lowerName = ToLowerAsciiCopy(processName);
    if (lowerName.size() > 4 && lowerName.compare(lowerName.size() - 4, 4, ".exe") == 0) {
        lowerName.resize(lowerName.size() - 4);
    }
    return lowerName == "agy";
}

inline bool IsGeminiCliBackendPath(const std::string& processPath) {
    const std::string lowerPath = ToLowerAsciiCopy(processPath);
    return lowerPath.find("/.gemini/") != std::string::npos ||
           lowerPath.find("\\.gemini\\") != std::string::npos;
}

// macOS 进程是否属于需要代理的 Antigravity 相关进程（进程名 + 全路径双重判断）
inline bool IsAntigravityRelatedMacProcess(const std::string& processPath,
                                           const std::string& processName) {
    return IsLanguageServerProcessName(processName) ||
           IsAntigravityBundlePath(processPath) ||
           IsAgyProcessName(processName) ||
           IsGeminiCliBackendPath(processPath);
}

} // namespace Hooks
