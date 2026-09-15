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

inline std::string ExtractExecutableTokenFromCommandLine(std::string commandLine) {
    commandLine = StripOuterQuotesCopy(std::move(commandLine));
    if (commandLine.empty()) return "";

    // CreateProcess 的命令行可能是 `"C:\...\Antigravity IDE.exe" --flag`。
    // 先保留引号内完整路径，避免把带空格的 exe 名截断成 `Antigravity`。
    if (commandLine.front() == '"') {
        const size_t closingQuote = commandLine.find('"', 1);
        if (closingQuote != std::string::npos) {
            return commandLine.substr(1, closingQuote - 1);
        }
    }

    const std::string lowerCommandLine = ToLowerAsciiCopy(commandLine);
    const size_t exePos = lowerCommandLine.find(".exe");
    if (exePos != std::string::npos) {
        return commandLine.substr(0, exePos + 4);
    }

    const size_t firstSpace = commandLine.find(' ');
    if (firstSpace != std::string::npos) {
        return commandLine.substr(0, firstSpace);
    }
    return commandLine;
}

inline std::string GetCreateProcessTargetBaseNameA(const char* applicationName, const char* commandLine) {
    std::string target;
    if (applicationName && *applicationName) {
        target = applicationName;
    } else if (commandLine && *commandLine) {
        target = ExtractExecutableTokenFromCommandLine(commandLine);
    }
    target = ExtractBaseNameFromPathLike(std::move(target));
    return target.empty() ? std::string("Unknown") : target;
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

// macOS 进程是否属于需要代理的 Antigravity 相关进程（进程名 + 全路径双重判断）
inline bool IsAntigravityRelatedMacProcess(const std::string& processPath,
                                           const std::string& processName) {
    return IsLanguageServerProcessName(processName) ||
           IsAntigravityBundlePath(processPath);
}

} // namespace Hooks
