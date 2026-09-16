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

# 读取 App 的 Bundle Identifier
app_bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print:CFBundleIdentifier' \
        "${1%/}/Contents/Info.plist" 2>/dev/null || true
}

# 枚举本机安装的全部官方 Antigravity 原件（排除 TUN 副本），每行一个；
# 固定路径优先且 IDE 排在前，Spotlight 结果去重后追加。
list_antigravity_apps() {
    local cand d acc=""
    __lapp_add() {
        local p="${1%/}" stem
        [ -d "${p}" ] || return 0
        stem="$(macpatch_app_stem "${p}" 2>/dev/null || basename "${p}" .app)"
        case "${stem}" in *" TUN") return 0 ;; esac
        case "|${acc}|" in *"|${p}|"*) ;; *) acc="${acc}|${p}" ;; esac
    }
    for cand in \
        "/Applications/Antigravity IDE.app" \
        "/Applications/Antigravity.app" \
        "$HOME/Applications/Antigravity IDE.app" \
        "$HOME/Applications/Antigravity.app"; do
        __lapp_add "${cand}"
    done
    if command -v mdfind >/dev/null 2>&1; then
        d="$(mdfind "(kMDItemCFBundleIdentifier == 'com.google.antigravity-ide') || (kMDItemCFBundleIdentifier == 'com.google.antigravity') || (kMDItemCFBundleIdentifier == 'com.antigravity.desktop')" 2>/dev/null || true)"
        while IFS= read -r cand; do __lapp_add "${cand}"; done <<< "${d}"
        d="$(mdfind "kMDItemContentType == 'com.apple.application-bundle' && (kMDItemFSName == 'Antigravity.app' || kMDItemFSName == 'Antigravity IDE.app')" 2>/dev/null || true)"
        while IFS= read -r cand; do __lapp_add "${cand}"; done <<< "${d}"
    fi
    [ -z "${acc}" ] || printf '%s\n' "${acc:1}" | tr '|' '\n'
}

# 兼容旧调用：返回排序第一的原件
find_antigravity_app() {
    list_antigravity_apps | head -n 1
}

# 按选择器挑选一个 App。
# selector 支持：空（唯一则直接返回，多个时 TTY 交互/非 TTY 报错）、
#   ide（Antigravity IDE）、classic|antigravity（Antigravity）、序号、.app 绝对路径
# 成功 stdout 输出路径；失败 stderr 提示并返回非 0。
pick_antigravity_app() {
    local sel="${1:-}" apps=() i p stem bid sel_lower n
    while IFS= read -r line; do [ -n "${line}" ] && apps+=("${line}"); done < <(list_antigravity_apps)

    # 显式路径
    if [ -n "${sel}" ] && { [[ "${sel}" == /* ]] || [[ "${sel}" == *.app ]]; }; then
        p="${sel%/}"
        if [ ! -d "${p}" ]; then echo "[错误] App 不存在: ${sel}" >&2; return 1; fi
        if command -v macpatch_is_antigravity_app >/dev/null 2>&1 && ! macpatch_is_antigravity_app "${p}"; then
            echo "[错误] 不是 Antigravity 应用: ${sel}" >&2; return 1
        fi
        echo "${p}"; return 0
    fi

    # 关键字
    if [ -n "${sel}" ] && [[ "${sel}" != [0-9]* ]]; then
        sel_lower="$(printf '%s' "${sel}" | tr 'A-Z' 'a-z')"
        for ((i=0; i<${#apps[@]}; i++)); do
            stem="$(macpatch_app_stem "${apps[$i]}" 2>/dev/null || true)"
            bid="$(app_bundle_id "${apps[$i]}")"
            case "${sel_lower}" in
                ide)
                    [[ "${bid}" == "com.google.antigravity-ide" || "${stem}" == "Antigravity IDE" ]] \
                        && { echo "${apps[$i]}"; return 0; } ;;
                classic|antigravity|pro)
                    [[ "${bid}" == "com.google.antigravity" || "${stem}" == "Antigravity" ]] \
                        && { echo "${apps[$i]}"; return 0; } ;;
                *)
                    echo "[错误] 未知应用选择器: ${sel}（可选: ide / classic / 序号 / .app 路径）" >&2
                    return 1 ;;
            esac
        done
        echo "[错误] 没有与 '${sel}' 匹配的已安装应用。当前检测到:" >&2
        printf '         - %s\n' "${apps[@]}" >&2
        return 1
    fi

    # 序号
    if [[ "${sel}" =~ ^[0-9]+$ ]]; then
        n=$((sel-1))
        if [ "${n}" -ge 0 ] && [ "${n}" -lt "${#apps[@]}" ]; then
            echo "${apps[$n]}"; return 0
        fi
        echo "[错误] 序号超出范围: ${sel}（共 ${#apps[@]} 个应用）" >&2; return 1
    fi

    # 空选择器
    if [ "${#apps[@]}" -eq 0 ]; then
        echo "[错误] 未检测到任何 Antigravity 应用（Antigravity.app / Antigravity IDE.app）。" >&2
        return 1
    fi
    if [ "${#apps[@]}" -eq 1 ]; then echo "${apps[0]}"; return 0; fi
    if [ -t 0 ] && [ -t 1 ]; then
        echo "检测到多个 Antigravity 应用，请选择:"
        for ((i=0; i<${#apps[@]}; i++)); do printf "  %d) %s\n" "$((i+1))" "${apps[$i]}"; done
        read -r -p "输入序号后回车: " sel
        pick_antigravity_app "${sel}"
        return $?
    fi
    echo "[错误] 同时检测到多个 Antigravity 应用，非交互环境无法自动选择:" >&2
    for ((i=0; i<${#apps[@]}; i++)); do printf '         %d) %s\n' "$((i+1))" "${apps[$i]}" >&2; done
    echo "       请显式指定，例如: $0 app ide   或   $0 app classic" >&2
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

# ---- 启动前预检：代理端口可达性 + 残留副本持有旧配置 ----
# 解析 dylib 实际会读取的 config.json（候选顺序与 dylib 内置逻辑保持一致）
resolve_runtime_config() {
    local dylib="$1" c
    for c in "$(dirname "${dylib}")/config.json" \
             "$HOME/.config/antigravity-proxy/config.json" \
             "$HOME/.antigravity-proxy/config.json" \
             "$(pwd)/config.json"; do
        [ -f "${c}" ] && { echo "${c}"; return 0; }
    done
    return 0
}

proxy_endpoint_from_config() {
    local cfg="$1" host port
    if [ -f "${cfg}" ]; then
        host="$(sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${cfg}" | head -1)"
        port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${cfg}" | head -1)"
    fi
    echo "${host:-127.0.0.1} ${port:-7890}"
}

# 精确列出某 TUN 副本路径下正在运行的进程 PID（按 .app/Contents/ 前缀，
# 不会误伤官方原件或另一个 TUN 副本）
tun_copy_pids() {
    local prefix="${1%/}/Contents/"
    ps -axo pid=,comm= | awk -v p="${prefix}" 'index($0,p){print $1}'
}

quit_tun_copy() {
    local app="$1" pids rem i
    pids="$(tun_copy_pids "${app}")"
    [ -z "${pids}" ] && return 0
    # shellcheck disable=SC2086
    kill -TERM ${pids} 2>/dev/null || true
    i=0
    while [ "${i}" -lt 10 ]; do
        rem="$(tun_copy_pids "${app}")"
        [ -z "${rem}" ] && return 0
        sleep 0.5
        i=$((i+1))
    done
    # shellcheck disable=SC2086
    kill -KILL ${rem} 2>/dev/null || true
    sleep 0.5
}

# 代理端口 TCP 预检：连不通时交互询问是否继续，非交互直接中止
preflight_proxy_reachable() {
    local cfg="$1" ans host port
    set -- $(proxy_endpoint_from_config "${cfg}")
    host="$1"; port="$2"
    if nc -z -G 2 "${host}" "${port}" >/dev/null 2>&1; then
        return 0
    fi
    echo "[警告] 代理端口 ${host}:${port} 无法连接——代理软件未运行，或端口与配置不一致。"
    echo "       此状态下启动会出现登录/联网失败，报错形如："
    echo "       Post \"https://oauth2.googleapis.com/token\": dial tcp ...: connect: connection refused"
    echo "       请先启动代理软件，或核对/修改配置文件里的 proxy.port。"
    if [ -t 0 ]; then
        read -r -p "       仍要继续启动吗？[y/N] " ans
        case "${ans}" in y|Y|yes|YES) return 0 ;; esac
    fi
    echo "       已中止启动。"
    return 1
}

# 副本已在运行时：macOS 的 open 只会激活旧进程，改端口/配置后不会重载
# （language_server 是长驻单例，会一直使用启动时读到的旧配置），询问退出重启
preflight_restart_running_copy() {
    local app="$1" pids ans n
    pids="$(tun_copy_pids "${app}")"
    [ -z "${pids}" ] && return 0
    # shellcheck disable=SC2086
    set -- ${pids}; n="$#"
    echo "[提示] 该代理副本正在运行（${n} 个进程）。"
    echo "       再次启动只会激活旧进程；刚修改的代理端口/配置必须重启才会生效。"
    if [ -t 0 ]; then
        read -r -p "       退出旧副本（含 language_server）并重新启动吗？[Y/n] " ans
        case "${ans}" in
            n|N|no|NO) echo "       保持现有进程运行（注意：新配置不会生效）。"; return 0 ;;
        esac
    else
        echo "       已中止：请先完全退出该副本（⌘Q）后，再重新运行本启动器。"
        return 1
    fi
    echo "       正在退出旧副本..."
    quit_tun_copy "${app}"
}

# 以注入环境启动 .app（LaunchServices 会重建完整进程树）
launch_app() {
    local app_dir="$1"; shift
    local cfg
    cfg="$(resolve_runtime_config "${DYLIB_PATH}")"
    preflight_proxy_reachable "${cfg}" || return 1
    preflight_restart_running_copy "${app_dir}" || return 1
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

if [ "${TARGET}" = "apps" ]; then
    # 列出检测到的全部 Antigravity 应用，便于在多应用环境确认序号
    __i=0
    while IFS= read -r __app; do
        __i=$((__i+1))
        echo "  ${__i}) ${__app}  [$(app_bundle_id "${__app}")]"
    done < <(list_antigravity_apps)
    [ "${__i}" -eq 0 ] && echo "  （未检测到 Antigravity.app / Antigravity IDE.app）"
    exit 0

elif [ "${TARGET}" = "app" ]; then
    # 可选第二参数：ide / classic / 序号 / .app 路径；缺省时唯一应用直选，多个则交互选择
    APP_DIR="$(pick_antigravity_app "${2:-}")" || exit 1
    echo "[目标] ${APP_DIR}"
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
