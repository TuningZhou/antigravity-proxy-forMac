#pragma once
#include <fstream>
#include <atomic>
#include <mutex>
#include <string>
#include <algorithm>
#include <cctype>
#include <iostream>

#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <fcntl.h>

#include <ctime>
#include <iomanip>
#include <sstream>

namespace Core {
    // 日志等级（用于控制输出粒度：默认 Info；需要更细粒度排障时可切到 Debug）
    enum class LogLevel : int {
        Debug = 0,
        Info  = 1,
        Warn  = 2,
        Error = 3,
    };

    class Logger {
    private:
        // ========== 日志等级控制 ==========
        // 设计意图：默认 Info（更克制），现场需要时可切到 Debug；同时提供可配置降级能力以降低性能开销。
        static std::atomic<int>& LevelStorage() {
            static std::atomic<int> s_level{static_cast<int>(LogLevel::Info)};
            return s_level;
        }

        static bool TryParseLevelFromString(const std::string& input, LogLevel* out) {
            if (!out) return false;

            // 去掉首尾空白，并统一转小写（配置中常用 debug/info/warn/error）
            std::string s = input;
            auto notSpace = [](unsigned char c) { return !std::isspace(c); };
            s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
            s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
            std::transform(s.begin(), s.end(), s.begin(),
                           [](unsigned char c) { return (char)std::tolower(c); });

            if (s == "debug" || s == "d" || s == "trace" || s == "verbose" || s == "调试") {
                *out = LogLevel::Debug;
                return true;
            }
            if (s == "info" || s == "i" || s == "信息") {
                *out = LogLevel::Info;
                return true;
            }
            if (s == "warn" || s == "warning" || s == "w" || s == "警告") {
                *out = LogLevel::Warn;
                return true;
            }
            if (s == "error" || s == "err" || s == "e" || s == "错误") {
                *out = LogLevel::Error;
                return true;
            }
            return false;
        }

        // ========== 日志目录相关函数 ==========
        
        // 获取动态库所在目录（用于定位日志目录）
        static std::string GetDllDirectory() {
            Dl_info info{};
            if (dladdr(reinterpret_cast<const void*>(&GetDllDirectory), &info) && info.dli_fname) {
                std::string p(info.dli_fname);
                size_t slash = p.find_last_of('/');
                if (slash != std::string::npos) {
                    return p.substr(0, slash);
                }
            }
            return "";
        }

        // 确保目录存在，不存在则创建
        static bool EnsureLogDirectory(const std::string& dirPath) {
            struct stat st{};
            if (stat(dirPath.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
                return true;
            }
            return mkdir(dirPath.c_str(), 0755) == 0;
        }

        // 获取系统临时目录路径
        static std::string GetSystemTempDirectory() {
            const char* tmp = getenv("TMPDIR");
            if (tmp && *tmp) {
                std::string t(tmp);
                if (t.back() == '/') t.pop_back();
                return t;
            }
            return "/tmp";
        }

        // 获取日志目录路径，首次调用时初始化
        // 优先级：动态库目录/logs/ → 系统TEMP目录/antigravity-proxy-logs/
        static std::string GetLogDirectory() {
            static std::string s_logDir;
            static bool s_initialized = false;
            if (!s_initialized) {
                s_initialized = true;
                // 优先尝试动态库目录下的 logs 子目录
                std::string dllDir = GetDllDirectory();
                if (!dllDir.empty()) {
                    std::string dllLogs = dllDir + "/logs";
                    if (EnsureLogDirectory(dllLogs)) {
                        s_logDir = dllLogs;
                        return s_logDir;
                    }
                }
                // 回退到系统 TEMP 目录
                std::string tempDir = GetSystemTempDirectory();
                if (!tempDir.empty()) {
                    std::string tempLogs = tempDir + "/antigravity-proxy-logs";
                    if (EnsureLogDirectory(tempLogs)) {
                        s_logDir = tempLogs;
                    }
                }
            }
            return s_logDir;
        }

        static std::string GetTimestamp() {
            auto now = std::time(nullptr);
            struct tm tm{};
            localtime_r(&now, &tm);
            std::ostringstream oss;
            oss << std::put_time(&tm, "%Y-%m-%d %H:%M:%S");
            return oss.str();
        }

        static std::string GetPidTidPrefix() {
            pid_t pid = getpid();
            uint64_t tid = 0;
#if defined(__APPLE__)
            pthread_threadid_np(NULL, &tid);
#else
            tid = reinterpret_cast<uint64_t>(pthread_self());
#endif
            return "[PID:" + std::to_string(pid) + "][TID:" + std::to_string(tid) + "]";
        }

        // 获取今日日志文件完整路径
        static std::string GetTodayLogName() {
            auto now = std::time(nullptr);
            struct tm tm{};
            localtime_r(&now, &tm);
            std::ostringstream oss;
            std::string logDir = GetLogDirectory();
            if (!logDir.empty()) {
                oss << logDir << "/";
            }
            oss << "proxy-" << std::put_time(&tm, "%Y%m%d") << ".log";
            return oss.str();
        }

        static uint64_t GetFileSizeBytes(const std::string& path) {
            struct stat st{};
            if (stat(path.c_str(), &st) != 0) {
                return 0;
            }
            return static_cast<uint64_t>(st.st_size);
        }

        // 清理旧日志文件，只保留当天的日志
        static void CleanupOldLogs(const std::string& todayLog) {
            std::string logDir = GetLogDirectory();
            std::string dir = logDir.empty() ? "." : logDir;
            DIR* d = opendir(dir.c_str());
            if (d) {
                struct dirent* ent = nullptr;
                while ((ent = readdir(d)) != nullptr) {
                    std::string name(ent->d_name);
                    if (name.rfind("proxy-", 0) == 0 && name.size() >= 14 && name.substr(name.size() - 4) == ".log") {
                        std::string fullPath = logDir.empty() ? name : (logDir + "/" + name);
                        if (todayLog != fullPath) {
                            unlink(fullPath.c_str());
                        }
                    } else if (name == "proxy.log" || name == "proxy.log.1") {
                        std::string fullPath = logDir.empty() ? name : (logDir + "/" + name);
                        if (todayLog != fullPath) {
                            unlink(fullPath.c_str());
                        }
                    }
                }
                closedir(d);
            }
        }

        static void WriteToFile(const std::string& message) {
            static std::string s_todayLog;
            static const uint64_t kMaxLogBytes = 10ull * 1024 * 1024; // 10MB

            static std::mutex s_logMtx;
            std::unique_lock<std::mutex> lock(s_logMtx);

            std::string todayLog = GetTodayLogName();
            if (s_todayLog != todayLog) {
                s_todayLog = todayLog;
                CleanupOldLogs(s_todayLog);
            }

            // 判断本次写入是否会超过上限；超过则直接截断覆盖写入
            const uint64_t currentSize = GetFileSizeBytes(s_todayLog);
            const uint64_t appendBytes = static_cast<uint64_t>(message.size() + 1); // + '\n'
            const bool needTruncate = (currentSize > 0 && (currentSize + appendBytes) > kMaxLogBytes);

            std::ofstream logFile;
            if (needTruncate) {
                logFile.open(s_todayLog, std::ios::out | std::ios::trunc);
            } else {
                logFile.open(s_todayLog, std::ios::out | std::ios::app);
            }
            if (logFile.is_open()) {
                logFile << message << "\n";
            }
        }

        static void TryWriteAtProcessDetach(const std::string& message) {
            const std::string path = GetTodayLogName();
            int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) {
                std::string line = message + "\n";
                write(fd, line.data(), line.size());
                close(fd);
            }
        }

    public:
        // 暴露日志目录给加载提示使用，便于用户一键打开排障目录。
        static std::string GetLogDirectoryPath() {
            return GetLogDirectory();
        }

        // 判断某个等级的日志是否会输出（用于调用方做“懒构造字符串”，减少性能开销）
        static bool IsEnabled(LogLevel level) {
            return static_cast<int>(level) >= LevelStorage().load(std::memory_order_relaxed);
        }

        // 设置全局日志等级
        static void SetLevel(LogLevel level) {
            LevelStorage().store(static_cast<int>(level), std::memory_order_relaxed);
        }

        // 从配置字符串设置等级（支持 debug/info/warn/error，大小写不敏感；非法值保持不变）
        static bool SetLevelFromString(const std::string& levelStr) {
            LogLevel level;
            if (!TryParseLevelFromString(levelStr, &level)) {
                return false;
            }
            SetLevel(level);
            return true;
        }

        static void Debug(const std::string& message) {
            if (!IsEnabled(LogLevel::Debug)) return;
            LogInternal("DEBUG", message);
        }

        static void Info(const std::string& message) {
            if (!IsEnabled(LogLevel::Info)) return;
            LogInternal("INFO", message);
        }

        static void Warn(const std::string& message) {
            if (!IsEnabled(LogLevel::Warn)) return;
            LogInternal("WARN", message);
        }

        static void Error(const std::string& message) {
            if (!IsEnabled(LogLevel::Error)) return;
            LogInternal("ERROR", message);
        }

        static void FatalAtProcessDetach(const std::string& message) {
            std::string line = GetTimestamp() + " " + GetPidTidPrefix() + " [FATAL] " + message;
            TryWriteAtProcessDetach(line);
        }

    private:
        static void LogInternal(const char* level, const std::string& message) {
            std::string line = GetTimestamp() + " " + GetPidTidPrefix() + " [" + level + "] " + message;
            WriteToFile(line);
        }
    };
}
