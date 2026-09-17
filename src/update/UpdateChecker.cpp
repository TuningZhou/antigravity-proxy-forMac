#include "UpdateChecker.hpp"

#include "../core/Config.hpp"
#include "../core/Logger.hpp"

namespace UpdateChecker {
    void StartAsync() {
        // macOS / POSIX 平台更新检查占位（后续可支持 libcurl 或后台异步检查）
        const auto& config = Core::Config::Instance();
        if (!config.updates.enabled) {
            if (Core::Logger::IsEnabled(Core::LogLevel::Debug)) {
                Core::Logger::Debug("[更新] 自动更新检查未启用。如需开启，请设置 updates.enabled=true。");
            }
            return;
        }
    }
}
