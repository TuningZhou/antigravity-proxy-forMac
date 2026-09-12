#!/usr/bin/env bash
set -e

# ==============================================================================
# Antigravity-Proxy macOS 安装脚本
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_PREFIX="${1:-$HOME/.local}"
BIN_DIR="${INSTALL_PREFIX}/bin"
LIB_DIR="${INSTALL_PREFIX}/lib"
CONFIG_DIR="$HOME/.config/antigravity-proxy"

echo "=================================================="
echo " Antigravity-Proxy macOS 安装程序"
echo " 安装前缀: ${INSTALL_PREFIX}"
echo " 库文件目录: ${LIB_DIR}"
echo " 可执行目录: ${BIN_DIR}"
echo " 配置目录:   ${CONFIG_DIR}"
echo "=================================================="

# 确保编译产物存在
DYLIB_SRC="${PROJECT_ROOT}/output-mac/libantigravity_proxy.dylib"
if [ ! -f "${DYLIB_SRC}" ]; then
    echo "未检测到编译产物，正在先执行构建..."
    (cd "${PROJECT_ROOT}" && ./build.sh Release)
fi

mkdir -p "${BIN_DIR}" "${LIB_DIR}" "${CONFIG_DIR}"

# 1. 复制动态库
cp "${DYLIB_SRC}" "${LIB_DIR}/libantigravity_proxy.dylib"
echo ">> [1/3] 已安装动态库到: ${LIB_DIR}/libantigravity_proxy.dylib"

# 2. 复制默认配置
if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    if [ -f "${PROJECT_ROOT}/config.example.json" ]; then
        cp "${PROJECT_ROOT}/config.example.json" "${CONFIG_DIR}/config.json"
        echo ">> [2/3] 已初始化默认配置: ${CONFIG_DIR}/config.json"
    fi
else
    echo ">> [2/3] 配置目录已有 config.json，保留现有配置。"
fi

# 3. 生成启动器脚本
cat << 'EOF' > "${BIN_DIR}/antigravity-proxy"
#!/usr/bin/env bash
set -e

# Antigravity-Proxy CLI Launcher
DYLIB_PATH="PLACEHOLDER_LIB_DIR/libantigravity_proxy.dylib"

if [ ! -f "${DYLIB_PATH}" ]; then
    echo "[错误] 未找到动态库: ${DYLIB_PATH}"
    exit 1
fi

export DYLD_INSERT_LIBRARIES="${DYLIB_PATH}"
export DYLD_FORCE_FLAT_NAMESPACE=1

TARGET="${1:-app}"

if [ "${TARGET}" = "app" ]; then
    APP_PATH="/Applications/Antigravity.app/Contents/MacOS/Antigravity"
    if [ ! -f "${APP_PATH}" ]; then
        if [ -f "/Applications/Antigravity IDE.app/Contents/MacOS/Antigravity IDE" ]; then
            APP_PATH="/Applications/Antigravity IDE.app/Contents/MacOS/Antigravity IDE"
        fi
    fi
    if [ ! -f "${APP_PATH}" ]; then
        echo "[错误] 未在 /Applications 找到 Antigravity.app！"
        echo "用法: antigravity-proxy /path/to/executable [args...]"
        exit 1
    fi
    exec "${APP_PATH}" "${@:2}"
elif [ "${TARGET}" = "agy" ]; then
    AGY_PATH="$(which agy 2>/dev/null || echo "$HOME/.antigravity/bin/agy")"
    if [ ! -f "${AGY_PATH}" ]; then
        echo "[错误] 未找到 agy CLI 命令！"
        exit 1
    fi
    exec "${AGY_PATH}" "${@:2}"
else
    exec "${TARGET}" "${@:2}"
fi
EOF

sed -i '' "s|PLACEHOLDER_LIB_DIR|${LIB_DIR}|g" "${BIN_DIR}/antigravity-proxy" 2>/dev/null || \
sed -i "s|PLACEHOLDER_LIB_DIR|${LIB_DIR}|g" "${BIN_DIR}/antigravity-proxy"
chmod +x "${BIN_DIR}/antigravity-proxy"

echo ">> [3/3] 已生成全局启动命令: ${BIN_DIR}/antigravity-proxy"
echo ""
echo "=================================================="
echo " 安装成功！"
echo " 请确保 ${BIN_DIR} 已加入您的 PATH 环境变量 (例如在 ~/.zshrc 中添加):"
echo "   export PATH=\"${BIN_DIR}:\$PATH\""
echo ""
echo " 使用方法:"
echo "   antigravity-proxy app      # 启动 Antigravity IDE 客户端"
echo "   antigravity-proxy agy      # 启动 agy 命令行工具"
echo "   antigravity-proxy <cmd>    # 代理任意可执行程序"
echo "=================================================="
