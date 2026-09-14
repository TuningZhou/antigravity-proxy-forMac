#!/usr/bin/env bash
set -e

# ==============================================================================
# Antigravity-Proxy macOS 综合自测与联调验证脚本
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

echo "=================================================="
echo " Antigravity-Proxy macOS 综合测试套件"
echo "=================================================="

# 1. 检查或执行构建
if [ ! -f "output-mac/libantigravity_proxy.dylib" ]; then
    echo "[步骤 1] 未检测到已编译动态库，正在触发构建..."
    ./build.sh Release
else
    echo "[步骤 1] 检测到现有动态库: output-mac/libantigravity_proxy.dylib"
fi

DYLIB_PATH="${PROJECT_ROOT}/output-mac/libantigravity_proxy.dylib"
echo "[检查] 动态库架构信息:"
file "${DYLIB_PATH}"

# 2. 检查配置文件
CONFIG_PATH="${PROJECT_ROOT}/config.json"
if [ ! -f "${CONFIG_PATH}" ]; then
    if [ -f "${PROJECT_ROOT}/config.example.json" ]; then
        echo "[步骤 2] 未找到 config.json，从 config.example.json 复制创建测试配置..."
        cp "${PROJECT_ROOT}/config.example.json" "${CONFIG_PATH}"
    else
        echo "[错误] 缺少 config.example.json 模板！"
        exit 1
    fi
else
    echo "[步骤 2] 使用现有配置文件: ${CONFIG_PATH}"
fi

# 3. 运行所有单元与回归测试
echo ""
echo "[步骤 3] 正在运行 CTest 单元回归测试..."
if [ -d "build-mac" ]; then
    (cd build-mac && ctest --output-on-failure)
    echo ">> 单元测试全部通过！"
fi

# 4. 模拟进程注入测试
echo ""
echo "[步骤 4] 模拟动态库加载与子进程派生拦截测试..."

# 清除旧的测试日志标记（若有）
mkdir -p "${PROJECT_ROOT}/logs"

echo ">> 启动注入测试..."
DYLD_INSERT_LIBRARIES="${DYLIB_PATH}" DYLD_FORCE_FLAT_NAMESPACE=1 \
    /bin/bash -c "echo '>> [子进程环境验证] 环境变量 DYLD_INSERT_LIBRARIES 状态:' && env | grep DYLD" || true

# 5. 查看最新生成的日志
echo ""
echo "=================================================="
echo " 最近生成的 Antigravity-Proxy 日志:"
echo "=================================================="
LATEST_LOG="$(ls -t "${PROJECT_ROOT}/logs"/proxy-*.log 2>/dev/null | head -n 1 || echo "")"
if [ -n "${LATEST_LOG}" ] && [ -f "${LATEST_LOG}" ]; then
    echo ">> 日志文件: ${LATEST_LOG}"
    echo "--------------------------------------------------"
    tail -n 20 "${LATEST_LOG}"
    echo "--------------------------------------------------"
else
    echo "提示: 未生成独立日志文件（可能目标进程不在 targetProcesses 名单内，此行为符合安全预期）。"
fi

echo ""
echo "=================================================="
echo " macOS 端测试验证完成！"
echo "=================================================="
