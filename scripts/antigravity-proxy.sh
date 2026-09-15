#!/usr/bin/env bash
set -e

# ==============================================================================
# Antigravity-Proxy 启动器 (macOS)
# 用于快速启动已注入代理的 Antigravity.app、agy 命令行或任意可执行文件。
#
# 说明：官方程序启用了 Hardened Runtime，默认禁止 DYLD 注入。首次启动时本脚本
# 会在官方 App 同目录自动复制一份“<原名> TUN.app”副本，签名补丁只打在副本上，
# 官方原件始终保持原始签名（见 scripts/mac-patch-app.sh）。
# App 升级后按提示重建副本即可（重新复制+补丁）。
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

# 在常见位置 + Spotlight 中查找官方 Antigravity 原件（排除 TUN 副本）
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

# shell 单引号安全转义（管理员提权命令拼接用）
shquote() {
    local s="$1"
    echo "'${s//\'/\'\\\'\'}'"
}

# 在 /Applications 等不可写目录创建副本+补丁时，弹出系统授权框提权，
# 完成后把副本属主改回当前用户。
# 注意：macOS 的“文稿/桌面/下载”受 TCC 隐私保护，提权后的 root 进程没有这些
# 目录的访问授权（root 也受 TCC 约束），直接执行位于其中的脚本会报
# “Operation not permitted (126)”。因此先把补丁脚本与 dylib 暂存到
# 系统中立临时目录 /private/tmp，再让提权进程执行暂存副本。
run_app_prepare_as_admin() {
    local seed="$1" recreate="$2" copy uid gid inner esc rc=0 stage patch_tmp dylib_tmp
    copy="$(macpatch_tun_sibling "${seed}")"
    macpatch_is_tun_app "${seed}" && copy="${seed%/}"
    uid="$(id -u)"; gid="$(id -g)"
    stage="$(mktemp -d /private/tmp/agy-proxy-admin.XXXXXX 2>/dev/null || mktemp -d -t agyproxy)" || return 1
    chmod 755 "${stage}" 2>/dev/null
    patch_tmp="${stage}/mac-patch-app.sh"
    dylib_tmp="${stage}/libantigravity_proxy.dylib"
    if ! /bin/cp "${SCRIPT_DIR}/mac-patch-app.sh" "${patch_tmp}" || ! /bin/cp "${DYLIB_PATH}" "${dylib_tmp}"; then
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

# 针对官方 App：确保 TUN 副本就绪（复制/重建/补丁），结果写入 EFFECTIVE_APP
ensure_app_ready() {
    local seed="$1" state ans rc do_recreate="" parent ov cv
    state="$(macpatch_tun_status_word "${seed}")"
    case "${state}" in
        ready)
            EFFECTIVE_APP="$(macpatch_effective_app "${seed}")"
            return 0 ;;
        invalid|not-antigravity)
            ensure_patch "${seed}" || return 1
            EFFECTIVE_APP="${seed%/}"
            return 0 ;;
    esac

    echo ""
    echo "[提示] 检测到官方原件: ${seed}"
    echo "       代理不会修改官方原件。将在同目录准备代理副本："
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
    echo "       副本与原件共用登录状态，无需重新登录；只需执行一次，升级后重做。"
    if [ -t 0 ]; then
        read -r -p "       现在准备代理副本吗？[Y/n] " ans
        case "${ans}" in
            n|N|no|NO) echo "[中止] 用户取消。"; return 1 ;;
        esac
    fi

    if macpatch_is_running_related "${seed}"; then
        echo "[中止] 请先完全退出 Antigravity（原件或副本，菜单栏 → Quit / ⌘Q）。"
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

    if [ "${rc}" -eq 7 ]; then
        echo "[中止] 副本版本与原件不一致，请重新运行本脚本并同意重建副本。"
        return 1
    elif [ "${rc}" -ne 0 ]; then
        echo "[中止] 代理副本准备未成功（返回码 ${rc}），暂不启动。"
        if [ "${rc}" = "126" ]; then
            echo "       返回码 126 (Operation not permitted) 多为 macOS 隐私保护拦截："
            echo "       请把工具/脚本移出“桌面/文稿/下载”目录后重试，或在"
            echo "       “系统设置 → 隐私与安全性 → 完全磁盘访问权限”中允许“终端”后重试。"
        fi
        return 1
    fi
    EFFECTIVE_APP="${MACPATCH_EFFECTIVE_TARGET:-$(macpatch_tun_sibling "${seed}")}"
    return 0
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
    ensure_app_ready "${APP_DIR}" || exit 1
    launch_app "${EFFECTIVE_APP}"

elif [ "${TARGET}" = "agy" ]; then
    AGY_PATH="$(command -v agy 2>/dev/null || true)"
    [ -z "${AGY_PATH}" ] && [ -f "$HOME/.antigravity/bin/agy" ] && AGY_PATH="$HOME/.antigravity/bin/agy"
    [ -z "${AGY_PATH}" ] && [ -f "$HOME/.local/bin/agy" ] && AGY_PATH="$HOME/.local/bin/agy"
    if [ -z "${AGY_PATH}" ] || [ ! -f "${AGY_PATH}" ]; then
        echo "[错误] 未在 PATH、~/.antigravity/bin 或 ~/.local/bin 找到 agy！"
        echo "也可直接指定路径: $0 /path/to/agy changelog"
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
        if macpatch_is_antigravity_app "${APP_OF_CUSTOM}"; then
            ensure_app_ready "${APP_OF_CUSTOM}" || exit 1
            launch_app "${EFFECTIVE_APP}"
        else
            ensure_patch "${APP_OF_CUSTOM}" || exit 1
            launch_app "${APP_OF_CUSTOM}"
        fi
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
