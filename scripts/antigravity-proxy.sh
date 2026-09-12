#!/usr/bin/env bash
set -e

# ==============================================================================
# Antigravity-Proxy 启动器 (macOS)
# 用于快速启动已注入代理的 Antigravity.app、Antigravity IDE 或 agy 命令行
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 查找 dylib 路径 (优先检查 output-mac，其次 build-mac，最后系统路径)
DYLIB_PATH=""
if [ -f "${PROJECT_ROOT}/output-mac/libantigravity_proxy.dylib" ]; then
    DYLIB_PATH="${PROJECT_ROOT}/output-mac/libantigravity_proxy.dylib"
elif [ -f "${PROJECT_ROOT}/build-mac/libantigravity_proxy.dylib" ]; then
    DYLIB_PATH="${PROJECT_ROOT}/build-mac/libantigravity_proxy.dylib"
elif [ -f "/usr/local/lib/libantigravity_proxy.dylib" ]; then
    DYLIB_PATH="/usr/local/lib/libantigravity_proxy.dylib"
fi

if [ -z "${DYLIB_PATH}" ] || [ ! -f "${DYLIB_PATH}" ]; then
    echo "[错误] 未找到 libantigravity_proxy.dylib！"
    echo "请先在项目根目录下运行构建: ./build.sh"
    exit 1
fi

export DYLD_INSERT_LIBRARIES="${DYLIB_PATH}"
export DYLD_FORCE_FLAT_NAMESPACE=1

TARGET="${1:-app}"

if [ "${TARGET}" = "app" ]; then
    APP_PATH=""
    if [ -f "/Applications/Antigravity.app/Contents/MacOS/Antigravity" ]; then
        APP_PATH="/Applications/Antigravity.app/Contents/MacOS/Antigravity"
    elif [ -f "/Applications/Antigravity IDE.app/Contents/MacOS/Antigravity IDE" ]; then
        APP_PATH="/Applications/Antigravity IDE.app/Contents/MacOS/Antigravity IDE"
    elif [ -d "$HOME/Applications/Antigravity.app" ]; then
        APP_PATH="$HOME/Applications/Antigravity.app/Contents/MacOS/Antigravity"
    fi

    if [ -z "${APP_PATH}" ] || [ ! -f "${APP_PATH}" ]; then
        echo "[错误] 未在常用目录中找到 Antigravity.app！"
        echo "请直接指定可执行文件绝对路径运行，例如:"
        echo "  $0 /Applications/YourApp.app/Contents/MacOS/YourBinary"
        exit 1
    fi

    echo "[启动] 正在以透明代理模式启动 Antigravity: ${APP_PATH}"
    echo "[注入] DYLD_INSERT_LIBRARIES=${DYLIB_PATH}"
    exec "${APP_PATH}" "${@:2}"

elif [ "${TARGET}" = "agy" ]; then
    AGY_PATH="$(which agy 2>/dev/null || echo "")"
    if [ -z "${AGY_PATH}" ]; then
        if [ -f "$HOME/.antigravity/bin/agy" ]; then
            AGY_PATH="$HOME/.antigravity/bin/agy"
        elif [ -f "$HOME/.local/bin/agy" ]; then
            AGY_PATH="$HOME/.local/bin/agy"
        fi
    fi

    if [ -z "${AGY_PATH}" ] || [ ! -f "${AGY_PATH}" ]; then
        echo "[错误] 未在系统 PATH 或 ~/.antigravity/bin 找到 agy 可执行文件！"
        echo "如果 agy 位于其他路径，可直接指定路径执行，例如:"
        echo "  $0 /path/to/agy login"
        exit 1
    fi

    echo "[启动] 正在以透明代理模式启动 Antigravity CLI: ${AGY_PATH}"
    echo "[注入] DYLD_INSERT_LIBRARIES=${DYLIB_PATH}"
    exec "${AGY_PATH}" "${@:2}"

else
    # 用户直接传入了自定义命令或可执行文件路径
    echo "[启动] 正在以透明代理模式执行目标: ${TARGET}"
    echo "[注入] DYLD_INSERT_LIBRARIES=${DYLIB_PATH}"
    exec "${TARGET}" "${@:2}"
fi
