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
echo ">> [1/4] 已安装动态库到: ${LIB_DIR}/libantigravity_proxy.dylib"

# 2. 复制签名补丁脚本
if [ -f "${SCRIPT_DIR}/mac-patch-app.sh" ]; then
    cp "${SCRIPT_DIR}/mac-patch-app.sh" "${LIB_DIR}/mac-patch-app.sh"
    chmod +x "${LIB_DIR}/mac-patch-app.sh"
    echo ">> [2/4] 已安装签名补丁脚本: ${LIB_DIR}/mac-patch-app.sh"
else
    echo ">> [2/4] [警告] 未找到 mac-patch-app.sh，启动器将缺少自动补丁能力。"
fi

# 3. 复制默认配置
if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    if [ -f "${PROJECT_ROOT}/config.example.json" ]; then
        cp "${PROJECT_ROOT}/config.example.json" "${CONFIG_DIR}/config.json"
        echo ">> [3/4] 已初始化默认配置: ${CONFIG_DIR}/config.json"
    fi
else
    echo ">> [3/4] 配置目录已有 config.json，保留现有配置。"
fi

# 4. 生成启动器脚本
cat << 'EOF' > "${BIN_DIR}/antigravity-proxy"
#!/usr/bin/env bash
set -e

# Antigravity-Proxy macOS Launcher（由 install-mac.sh 生成）
# 对官方 Antigravity：自动在同目录准备“<原名> TUN.app”副本，补丁只打副本，
# 原件保持官方签名。
DYLIB_PATH="PLACEHOLDER_LIB_DIR/libantigravity_proxy.dylib"
PATCH_SCRIPT="PLACEHOLDER_LIB_DIR/mac-patch-app.sh"

if [ ! -f "${DYLIB_PATH}" ]; then
    echo "[错误] 未找到动态库: ${DYLIB_PATH}"
    exit 1
fi
[ -f "${PATCH_SCRIPT}" ] && source "${PATCH_SCRIPT}"

derive_app_dir() {
    local p="$1"
    case "${p}" in
        *.app) echo "${p%/}"; return 0 ;;
        *.app/*) echo "${p%%.app/*}.app"; return 0 ;;
    esac
    return 1
}

shquote() {
    local s="$1"
    echo "'${s//\'/\'\\\'\'}'"
}

find_antigravity_app() {
    local cand d
    _tun_is_original_path() { case "$(macpatch_app_stem "$1" 2>/dev/null)" in
        *" TUN") return 1 ;; *) return 0 ;; esac; }
    for cand in \
        "/Applications/Antigravity IDE.app" \
        "/Applications/Antigravity.app" \
        "$HOME/Applications/Antigravity IDE.app" \
        "$HOME/Applications/Antigravity.app"; do
        [ -d "${cand}" ] && { echo "${cand}"; return 0; }
    done
    if command -v mdfind >/dev/null 2>&1; then
        d="$(mdfind "(kMDItemCFBundleIdentifier == 'com.google.antigravity-ide') || (kMDItemCFBundleIdentifier == 'com.antigravity.desktop')" 2>/dev/null || true)"
        while IFS= read -r line; do
            [ -n "${line}" ] && [ -d "${line}" ] && _tun_is_original_path "${line}" && { echo "${line%/}"; return 0; }
        done <<< "${d}"
    fi
    return 1
}

# /Applications 等不可写目录：弹窗提权完成“复制副本+补丁”，并 chown 回当前用户。
# macOS 的“文稿/桌面/下载”受 TCC 保护，root 提权进程无权读取其中的脚本
# （报 Operation not permitted 126），先把补丁脚本与 dylib 暂存到 /private/tmp。
run_app_prepare_as_admin() {
    local seed="$1" recreate="$2" copy uid gid inner esc rc=0 stage patch_tmp dylib_tmp
    copy="$(macpatch_tun_sibling "${seed}" 2>/dev/null || true)"
    macpatch_is_tun_app "${seed}" 2>/dev/null && copy="${seed%/}"
    uid="$(id -u)"; gid="$(id -g)"
    stage="$(mktemp -d /private/tmp/agy-proxy-admin.XXXXXX 2>/dev/null || mktemp -d -t agyproxy)" || return 1
    chmod 755 "${stage}" 2>/dev/null
    patch_tmp="${stage}/mac-patch-app.sh"
    dylib_tmp="${stage}/libantigravity_proxy.dylib"
    if ! /bin/cp "${PATCH_SCRIPT}" "${patch_tmp}" || ! /bin/cp "${DYLIB_PATH}" "${dylib_tmp}"; then
        rm -rf "${stage}" 2>/dev/null
        echo "[错误] 无法准备提权临时文件: ${stage}" >&2
        return 1
    fi
    chmod 755 "${patch_tmp}" "${dylib_tmp}" 2>/dev/null
    if [ "${recreate}" = "recreate" ]; then
        inner="/bin/bash $(shquote "${patch_tmp}") --recreate $(shquote "${seed}") $(shquote "${dylib_tmp}"); rc=\$?"
    else
        inner="/bin/bash $(shquote "${patch_tmp}") $(shquote "${seed}") $(shquote "${dylib_tmp}"); rc=\$?"
    fi
    inner="${inner}; /usr/sbin/chown -R ${uid}:${gid} $(shquote "${copy}") 2>/dev/null; exit \$rc"
    esc="${inner//\\/\\\\}"; esc="${esc//\"/\\\"}"
    /usr/bin/osascript -e "do shell script \"${esc}\" with administrator privileges" || rc=$?
    rm -rf "${stage}" 2>/dev/null
    return ${rc}
}

ensure_patch() {
    local target="$1"
    if ! command -v macpatch_target_needs_patch >/dev/null 2>&1; then
        echo "[警告] 缺少补丁脚本，跳过 Hardened Runtime 检查（注入可能被系统忽略）。"
        return 0
    fi
    if ! macpatch_target_needs_patch "${target}"; then
        return 0
    fi
    echo "[提示] ${target} 启用了 Hardened Runtime，需要一次本地 ad-hoc 重签名才能注入。"
    if [ -t 0 ]; then
        local ans=""
        read -r -p "       现在执行签名补丁吗？[Y/n] " ans
        case "${ans}" in
            n|N|no|NO) echo "[中止] 用户取消。"; return 1 ;;
        esac
    fi
    set +e
    macpatch_ensure_target "${target}" "${DYLIB_PATH}"
    local rc=$?
    set -e
    [ "${rc}" -ne 0 ] && { echo "[中止] 补丁未成功（返回码 ${rc}）。"; return 1; }
    return 0
}

# 官方 App：准备 TUN 副本（复制/重建/补丁），结果写入 EFFECTIVE_APP
ensure_app_ready() {
    local seed="$1" state ans rc do_recreate="" parent ov cv
    if ! command -v macpatch_tun_status_word >/dev/null 2>&1; then
        echo "[警告] 缺少补丁脚本，无法准备代理副本，将直接启动目标（注入可能失效）。"
        EFFECTIVE_APP="${seed%/}"; return 0
    fi
    state="$(macpatch_tun_status_word "${seed}")"
    case "${state}" in
        ready)
            EFFECTIVE_APP="$(macpatch_effective_app "${seed}")"; return 0 ;;
        invalid|not-antigravity)
            ensure_patch "${seed}" || return 1
            EFFECTIVE_APP="${seed%/}"; return 0 ;;
    esac

    echo "[提示] 代理不会修改官方原件，将在同目录准备副本："
    echo "         $(macpatch_tun_sibling "${seed}")"
    if [ "${state}" = "outdated" ]; then
        ov="$(macpatch_app_version "${seed}")"
        cv="$(macpatch_app_version "$(macpatch_tun_sibling "${seed}")")"
        echo "       副本版本(${cv})落后于原件(${ov})，建议重建。"
        if [ -t 0 ]; then
            read -r -p "       现在重建副本（重新复制+补丁）吗？[Y/n] " ans
            case "${ans}" in n|N|no|NO) ;; *) do_recreate="recreate" ;; esac
        fi
    fi
    if [ -t 0 ]; then
        read -r -p "       现在准备代理副本吗？[Y/n] " ans
        case "${ans}" in
            n|N|no|NO) echo "[中止] 用户取消。"; return 1 ;;
        esac
    fi
    if macpatch_is_running_related "${seed}"; then
        echo "[中止] 请先完全退出 Antigravity（原件或副本，⌘Q）。"
        return 1
    fi

    parent="$(dirname "$(macpatch_tun_sibling "${seed}")")"
    set +e
    if [ -w "${parent}" ]; then
        if [ "${do_recreate}" = "recreate" ]; then
            macpatch_ensure_app_target "${seed}" "${DYLIB_PATH}" recreate
        else
            macpatch_ensure_app_target "${seed}" "${DYLIB_PATH}"
        fi
        rc=$?
    else
        echo "       在“${parent}”创建副本需要管理员权限，将弹出系统授权框..."
        run_app_prepare_as_admin "${seed}" "${do_recreate}"
        rc=$?
    fi
    set -e
    if [ "${rc}" -ne 0 ]; then
        echo "[中止] 代理副本准备未成功（返回码 ${rc}）。"
        if [ "${rc}" = "126" ]; then
            echo "       返回码 126 (Operation not permitted) 多为 macOS 隐私保护拦截："
            echo "       请在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中允许“终端”后重试。"
        fi
        return 1
    fi
    EFFECTIVE_APP="${MACPATCH_EFFECTIVE_TARGET:-$(macpatch_tun_sibling "${seed}")}"
}

launch_app() {
    open -n \
        --env DYLD_INSERT_LIBRARIES="${DYLIB_PATH}" \
        --env DYLD_FORCE_FLAT_NAMESPACE=1 \
        "$1"
    echo "[完成] Antigravity 代理副本已启动。日志: PLACEHOLDER_LIB_DIR/logs/"
}

TARGET="${1:-app}"

if [ "${TARGET}" = "app" ]; then
    APP_DIR="$(find_antigravity_app || true)"
    [ -z "${APP_DIR}" ] && { echo "[错误] 未找到 Antigravity.app，可直接传入路径: $0 /path/to/Antigravity.app"; exit 1; }
    ensure_app_ready "${APP_DIR}" || exit 1
    echo "[启动] ${EFFECTIVE_APP}"
    launch_app "${EFFECTIVE_APP}"
elif [ "${TARGET}" = "agy" ]; then
    AGY_PATH="$(command -v agy 2>/dev/null || true)"
    [ -z "${AGY_PATH}" ] && [ -f "$HOME/.antigravity/bin/agy" ] && AGY_PATH="$HOME/.antigravity/bin/agy"
    [ -z "${AGY_PATH}" ] && [ -f "$HOME/.local/bin/agy" ] && AGY_PATH="$HOME/.local/bin/agy"
    [ -z "${AGY_PATH}" ] && { echo "[错误] 未找到 agy CLI 命令！"; exit 1; }
    ensure_patch "${AGY_PATH}" || exit 1
    echo "[启动] ${AGY_PATH}"
    DYLD_INSERT_LIBRARIES="${DYLIB_PATH}" DYLD_FORCE_FLAT_NAMESPACE=1 exec "${AGY_PATH}" "${@:2}"
else
    if [ ! -e "${TARGET}" ]; then
        echo "[错误] 目标不存在: ${TARGET}"
        exit 1
    fi
    APP_OF_CUSTOM="$(derive_app_dir "${TARGET}" || true)"
    if [ -n "${APP_OF_CUSTOM}" ]; then
        if command -v macpatch_is_antigravity_app >/dev/null 2>&1 && macpatch_is_antigravity_app "${APP_OF_CUSTOM}"; then
            ensure_app_ready "${APP_OF_CUSTOM}" || exit 1
        else
            ensure_patch "${APP_OF_CUSTOM}" || exit 1
            EFFECTIVE_APP="${APP_OF_CUSTOM}"
        fi
        echo "[启动] ${EFFECTIVE_APP}"
        launch_app "${EFFECTIVE_APP}"
    else
        echo "[启动] ${TARGET}"
        DYLD_INSERT_LIBRARIES="${DYLIB_PATH}" DYLD_FORCE_FLAT_NAMESPACE=1 exec "${TARGET}" "${@:2}"
    fi
fi
EOF

sed -i '' "s|PLACEHOLDER_LIB_DIR|${LIB_DIR}|g" "${BIN_DIR}/antigravity-proxy" 2>/dev/null || \
sed -i "s|PLACEHOLDER_LIB_DIR|${LIB_DIR}|g" "${BIN_DIR}/antigravity-proxy"
chmod +x "${BIN_DIR}/antigravity-proxy"

echo ">> [4/4] 已生成全局启动命令: ${BIN_DIR}/antigravity-proxy"
echo ""
echo "=================================================="
echo " 安装成功！"
echo " 请确保 ${BIN_DIR} 已加入您的 PATH 环境变量 (例如在 ~/.zshrc 中添加):"
echo "   export PATH=\"${BIN_DIR}:\$PATH\""
echo ""
echo " 使用方法:"
echo "   antigravity-proxy app      # 启动 Antigravity IDE（首次自动创建 TUN 副本并打补丁）"
echo "   antigravity-proxy agy      # 启动 agy 命令行工具"
echo "   antigravity-proxy <path>   # 代理指定的 .app 或可执行程序"
echo "=================================================="
