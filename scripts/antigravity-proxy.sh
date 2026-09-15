#!/usr/bin/env bash
set -e

# ==============================================================================
# Antigravity-Proxy 启动器 (macOS)
# 用于快速启动已注入代理的 Antigravity.app、agy 命令行或任意可执行文件。
#
# 说明：官方程序启用了 Hardened Runtime，默认禁止 DYLD 注入。首次启动时本脚本
# 会引导对其做一次本地 ad-hoc 重签名补丁（见 scripts/mac-patch-app.sh）。
# App 升级/重装后补丁会被覆盖，重新运行本脚本即可。
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=mac-patch-app.sh
source "${SCRIPT_DIR}/mac-patch-app.sh"

# 查找 dylib 路径（优先 output-mac，其次 build-mac，最后安装目录）
DYLIB_PATH=""
for cand in \
    "${PROJECT_ROOT}/output-mac/libantigravity_proxy.dylib" \
    "${PROJECT_ROOT}/build-mac/libantigravity_proxy.dylib" \
    "$HOME/.local/lib/libantigravity_proxy.dylib" \
    "/usr/local/lib/libantigravity_proxy.dylib"; do
    if [ -f "${cand}" ]; then DYLIB_PATH="${cand}"; break; fi
done

if [ -z "${DYLIB_PATH}" ] || [ ! -f "${DYLIB_PATH}" ]; then
    echo "[错误] 未找到 libantigravity_proxy.dylib！"
    echo "请先在项目根目录下运行构建: ./build.sh"
    exit 1
fi

# 从任意路径（含可执行文件路径）提取所属 .app 目录
derive_app_dir() {
    local p="$1"
    case "${p}" in
        *.app) echo "${p%/}"; return 0 ;;
        *.app/*) echo "${p%%.app/*}.app"; return 0 ;;
    esac
    return 1
}

# 在常见位置 + Spotlight 中查找 Antigravity.app
find_antigravity_app() {
    local cand d
    for cand in \
        "/Applications/Antigravity IDE.app" \
        "/Applications/Antigravity.app" \
        "$HOME/Applications/Antigravity IDE.app" \
        "$HOME/Applications/Antigravity.app"; do
        [ -d "${cand}" ] && { echo "${cand}"; return 0; }
    done
    if command -v mdfind >/dev/null 2>&1; then
        d="$(mdfind "kMDItemCFBundleIdentifier == 'com.antigravity.desktop'" 2>/dev/null | head -n 1)"
        [ -n "${d}" ] && [ -d "${d}" ] && { echo "${d}"; return 0; }
        d="$(mdfind "kMDItemKind == 'Application' && kMDItemDisplayName == 'Antigravity IDE'c" 2>/dev/null | head -n 1)"
        [ -n "${d}" ] && [ -d "${d}" ] && { echo "${d}"; return 0; }
    fi
    return 1
}

# 需要补丁时引导用户确认并执行；返回 0 表示可继续启动
ensure_patch() {
    local target="$1"
    if ! macpatch_target_needs_patch "${target}"; then
        return 0
    fi
    echo ""
    echo "[提示] 检测到 ${target}"
    echo "       启用了 Hardened Runtime 且不允许 DYLD 环境变量注入，代理无法生效。"
    echo "       需要对其执行一次本地 ad-hoc 重签名（仅在本机生效，不联网）。"
    if [ -t 0 ]; then
        local ans=""
        read -r -p "       现在执行签名补丁吗？[Y/n] " ans
        case "${ans}" in
            n|N|no|NO) echo "[中止] 用户取消。请先运行 scripts/mac-patch-app.sh 后再启动。"; return 1 ;;
        esac
    fi
    set +e
    macpatch_ensure_target "${target}" "${DYLIB_PATH}"
    local rc=$?
    set -e
    if [ "${rc}" -eq 4 ]; then
        echo "[中止] 请先完全退出 Antigravity（菜单栏 → Quit / ⌘Q），再重新运行本脚本。"
        return 1
    elif [ "${rc}" -ne 0 ]; then
        echo "[中止] 签名补丁未成功（返回码 ${rc}），暂不启动。"
        return 1
    fi
    return 0
}

# 以注入环境启动 .app（LaunchServices 会重建完整进程树）
launch_app() {
    local app_dir="$1"; shift
    echo "[启动] ${app_dir}"
    echo "[注入] ${DYLIB_PATH}"
    open -n \
        --env DYLD_INSERT_LIBRARIES="${DYLIB_PATH}" \
        --env DYLD_FORCE_FLAT_NAMESPACE=1 \
        "${app_dir}" "$@"
    echo "[完成] Antigravity 已启动，代理日志见 dylib 同级 logs/ 目录。"
}

# 以注入环境直接执行裸可执行文件
launch_exec() {
    local exe="$1"; shift
    echo "[启动] ${exe}"
    echo "[注入] ${DYLIB_PATH}"
    DYLD_INSERT_LIBRARIES="${DYLIB_PATH}" DYLD_FORCE_FLAT_NAMESPACE=1 exec "${exe}" "$@"
}

TARGET="${1:-app}"

if [ "${TARGET}" = "app" ]; then
    APP_DIR="$(find_antigravity_app || true)"
    if [ -z "${APP_DIR}" ]; then
        echo "[错误] 未找到 Antigravity.app！"
        echo "可直接把 .app（或其可执行文件）拖到本脚本/命令行上，例如:"
        echo "  $0 /Applications/YourApp.app"
        exit 1
    fi
    ensure_patch "${APP_DIR}" || exit 1
    launch_app "${APP_DIR}"

elif [ "${TARGET}" = "agy" ]; then
    AGY_PATH="$(command -v agy 2>/dev/null || true)"
    [ -z "${AGY_PATH}" ] && [ -f "$HOME/.antigravity/bin/agy" ] && AGY_PATH="$HOME/.antigravity/bin/agy"
    [ -z "${AGY_PATH}" ] && [ -f "$HOME/.local/bin/agy" ] && AGY_PATH="$HOME/.local/bin/agy"
    if [ -z "${AGY_PATH}" ] || [ ! -f "${AGY_PATH}" ]; then
        echo "[错误] 未在 PATH、~/.antigravity/bin 或 ~/.local/bin 找到 agy！"
        echo "也可直接指定路径: $0 /path/to/agy login"
        exit 1
    fi
    ensure_patch "${AGY_PATH}" || exit 1
    launch_exec "${AGY_PATH}" "${@:2}"

else
    # 用户传入 .app / 包内可执行文件 / 任意程序
    CUSTOM="$(cd "$(dirname "${TARGET}")" 2>/dev/null && pwd)/$(basename "${TARGET}")" || CUSTOM="${TARGET}"
    if [ ! -e "${CUSTOM}" ]; then
        echo "[错误] 目标不存在: ${TARGET}"
        exit 1
    fi
    APP_OF_CUSTOM="$(derive_app_dir "${CUSTOM}" || true)"
    if [ -n "${APP_OF_CUSTOM}" ]; then
        ensure_patch "${APP_OF_CUSTOM}" || exit 1
        launch_app "${APP_OF_CUSTOM}"
    else
        # 任意第三方程序：仅当已经具备注入条件时直接启动，不主动改签名
        if macpatch_target_needs_patch "${CUSTOM}" 2>/dev/null; then
            echo "[警告] ${CUSTOM} 启用了 Hardened Runtime，需先手动执行签名补丁:"
            echo "       ${SCRIPT_DIR}/mac-patch-app.sh '${CUSTOM}' '${DYLIB_PATH}'"
            exit 1
        fi
        launch_exec "${CUSTOM}" "${@:2}"
    fi
fi
