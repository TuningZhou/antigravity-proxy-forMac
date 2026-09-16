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

app_bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print:CFBundleIdentifier' \
        "${1%/}/Contents/Info.plist" 2>/dev/null || true
}

# 枚举本机全部官方 Antigravity 原件（排除 TUN 副本），每行一个，IDE 优先
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

find_antigravity_app() {
    list_antigravity_apps | head -n 1
}

# 选择器：ide / classic|antigravity / 序号 / .app 路径 / 空（唯一直选，多个需 TTY）
pick_antigravity_app() {
    local sel="${1:-}" apps=() i p stem bid sel_lower n
    while IFS= read -r line; do [ -n "${line}" ] && apps+=("${line}"); done < <(list_antigravity_apps)

    if [ -n "${sel}" ] && { [[ "${sel}" == /* ]] || [[ "${sel}" == *.app ]]; }; then
        p="${sel%/}"
        if [ ! -d "${p}" ]; then echo "[错误] App 不存在: ${sel}" >&2; return 1; fi
        if command -v macpatch_is_antigravity_app >/dev/null 2>&1 && ! macpatch_is_antigravity_app "${p}"; then
            echo "[错误] 不是 Antigravity 应用: ${sel}" >&2; return 1
        fi
        echo "${p}"; return 0
    fi

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

    if [[ "${sel}" =~ ^[0-9]+$ ]]; then
        n=$((sel-1))
        if [ "${n}" -ge 0 ] && [ "${n}" -lt "${#apps[@]}" ]; then
            echo "${apps[$n]}"; return 0
        fi
        echo "[错误] 序号超出范围: ${sel}（共 ${#apps[@]} 个应用）" >&2; return 1
    fi

    if [ "${#apps[@]}" -eq 0 ]; then
        echo "[错误] 未检测到任何 Antigravity 应用（Antigravity.app / Antigravity IDE.app）。" >&2
        return 1
    fi
    if [ "${#apps[@]}" -eq 1 ]; then echo "${apps[0]}"; return 0; fi
    if [ -t 0 ]; then
        echo "检测到多个 Antigravity 应用，请选择:"
        for ((i=0; i<${#apps[@]}; i++)); do printf "  %d) %s\n" "$((i+1))" "${apps[$i]}"; done
        read -r -p "输入序号后回车: " sel
        pick_antigravity_app "${sel}"
        return $?
    fi
    echo "[错误] 同时检测到多个 Antigravity 应用，请显式指定: $0 app ide | $0 app classic" >&2
    for ((i=0; i<${#apps[@]}; i++)); do printf '         %d) %s\n' "$((i+1))" "${apps[$i]}" >&2; done
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

launch_app() {
    local cfg
    cfg="$(resolve_runtime_config "${DYLIB_PATH}")"
    preflight_proxy_reachable "${cfg}" || return 1
    preflight_restart_running_copy "$1" || return 1
    open -n \
        --env DYLD_INSERT_LIBRARIES="${DYLIB_PATH}" \
        --env DYLD_FORCE_FLAT_NAMESPACE=1 \
        "$1"
    echo "[完成] Antigravity 代理副本已启动。日志: PLACEHOLDER_LIB_DIR/logs/"
}

TARGET="${1:-app}"

if [ "${TARGET}" = "apps" ]; then
    __i=0
    while IFS= read -r __app; do
        __i=$((__i+1))
        echo "  ${__i}) ${__app}  [$(app_bundle_id "${__app}")]"
    done < <(list_antigravity_apps)
    [ "${__i}" -eq 0 ] && echo "  （未检测到 Antigravity.app / Antigravity IDE.app）"
    exit 0
fi

if [ "${TARGET}" = "app" ]; then
    # 可选选择器: ide / classic / 序号 / .app 路径
    APP_DIR="$(pick_antigravity_app "${2:-}")" || exit 1
    echo "[目标] ${APP_DIR}"
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
echo "   antigravity-proxy apps            # 列出检测到的全部 Antigravity 应用"
echo "   antigravity-proxy app             # 启动（多个应用时交互选择）"
echo "   antigravity-proxy app ide         # 启动 Antigravity IDE（或 classic 启动 Antigravity）"
echo "   antigravity-proxy agy             # 启动 agy 命令行工具"
echo "   antigravity-proxy <path>          # 代理指定的 .app 或可执行程序"
echo "=================================================="
