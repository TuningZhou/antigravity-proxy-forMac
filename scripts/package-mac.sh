#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Antigravity-Proxy macOS 预编译包打包脚本
#
# 产物：dist/antigravity-proxy-v<版本>-mac<架构>.zip
#   - universal2 包同时支持 Apple Silicon (arm64) 与 Intel (x64)
#   - 解压后双击 Antigravity-Proxy.command 即可使用，最终用户无需安装编译工具
#   - 首次启动会在官方 App 同目录自动创建“<原名> TUN.app”副本，
#     并只对副本做本地 ad-hoc 签名补丁（官方原件不被修改，
#     详见包内“使用说明.txt”）
#
# 用法：
#   ./scripts/package-mac.sh                         # 本机当前架构，版本号取 build.ps1
#   ARCHS="arm64;x86_64" ./scripts/package-mac.sh    # Universal 2 通用二进制
#   ./scripts/package-mac.sh --version 2.4           # 指定版本号
#   ./scripts/package-mac.sh --arch arm64            # 指定单一架构
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# ---------------------------------------------------------------- 参数解析 ----
VERSION=""
ARCH_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version|-v)
            [ $# -ge 2 ] || { echo "[错误] $1 需要一个版本号参数" >&2; exit 1; }
            VERSION="$2"; shift 2 ;;
        --arch)
            [ $# -ge 2 ] || { echo "[错误] $1 需要一个架构参数(arm64/x86_64/universal)" >&2; exit 1; }
            ARCH_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0 ;;
        *)
            echo "[错误] 未知参数: $1" >&2
            exit 1 ;;
    esac
done

# 版本号默认取 build.ps1（与 Windows 端保持同一版本源）
if [ -z "${VERSION}" ]; then
    VERSION="$(sed -nE 's/^[[:space:]]*\$Version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.ps1 | head -n 1)"
fi
VERSION="${VERSION#v}"
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "[错误] 版本号格式不正确: ${VERSION}（应为 1.2 或 1.2.3）" >&2
    exit 1
fi
TAG="v${VERSION}"

# ---------------------------------------------------------------- 架构归一 ----
RAW_ARCHS="${ARCH_OVERRIDE:-${ARCHS:-$(uname -m)}}"
case "${RAW_ARCHS}" in
    universal|universal2|fat)
        BUILD_ARCHS="arm64;x86_64"
        ARCH_LABEL="universal2" ;;
    arm64)
        BUILD_ARCHS="arm64"
        ARCH_LABEL="arm64" ;;
    x86_64|x64|intel)
        BUILD_ARCHS="x86_64"
        ARCH_LABEL="x64" ;;
    *";"*)
        # 形如 "arm64;x86_64"
        BUILD_ARCHS="${RAW_ARCHS}"
        ARCH_LABEL="universal2" ;;
    *)
        echo "[错误] 不支持的架构参数: ${RAW_ARCHS}（可选 arm64 / x86_64 / universal）" >&2
        exit 1 ;;
esac

echo "=================================================="
echo " Antigravity-Proxy macOS 预编译包打包"
echo " 版本:     ${TAG}"
echo " 架构:     ${ARCH_LABEL} (${BUILD_ARCHS})"
echo "=================================================="

# ---------------------------------------------------------------- 构建+测试 --
if ! command -v cmake >/dev/null 2>&1; then
    echo "[错误] 未找到 cmake，请先执行: brew install cmake" >&2
    exit 1
fi

ARCHS="${BUILD_ARCHS}" ./build.sh Release

DYLIB_SRC="${PROJECT_ROOT}/output-mac/libantigravity_proxy.dylib"
[ -f "${DYLIB_SRC}" ] || { echo "[错误] 构建产物缺失: ${DYLIB_SRC}" >&2; exit 1; }

# ---------------------------------------------------------------- 暂存目录 --
DIST_DIR="${PROJECT_ROOT}/dist"
STAGE_PARENT="$(mktemp -d)"
PKG_NAME="Antigravity-Proxy-macOS"
STAGE_DIR="${STAGE_PARENT}/${PKG_NAME}"
mkdir -p "${STAGE_DIR}"
trap 'rm -rf "${STAGE_PARENT}"' EXIT

cp "${DYLIB_SRC}" "${STAGE_DIR}/libantigravity_proxy.dylib"

# 配置文件：发布包始终以 config.example.json 为准（默认 7890），
# 避免把开发者本机 config.json 里的自定义端口打进分发包
cp "${PROJECT_ROOT}/config.example.json" "${STAGE_DIR}/config.json"

# 可视化配置工具（与 Windows 包一致，浏览器打开即可导入/编辑/导出 config.json）
if [ -f "${PROJECT_ROOT}/resources/config-web/index.html" ]; then
    cp "${PROJECT_ROOT}/resources/config-web/index.html" "${STAGE_DIR}/配置工具.html"
fi

# 首次启动所需的本地签名补丁脚本
cp "${SCRIPT_DIR}/mac-patch-app.sh" "${STAGE_DIR}/mac-patch-app.sh"
chmod +x "${STAGE_DIR}/mac-patch-app.sh"

# 对动态库做 ad-hoc 签名，保证 Apple Silicon 下可被 dyld 正常加载
codesign --force --sign - "${STAGE_DIR}/libantigravity_proxy.dylib" 2>/dev/null \
    && echo ">> 已对 dylib 完成 ad-hoc 代码签名" \
    || echo "[警告] codesign 执行失败（通常不影响本机使用）"

echo ">> dylib 架构: $(file "${STAGE_DIR}/libantigravity_proxy.dylib")"

# ------------------------------------------------- 双击启动器（.command） ----
cat > "${STAGE_DIR}/Antigravity-Proxy.command" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# ==============================================================================
# Antigravity-Proxy for macOS —— 免安装双击启动器
#
# 使用方式：
#   1) 在“访达”里双击本文件（首次请“右键 → 打开”，以通过 Gatekeeper 提示）
#   2) 在终端执行：./Antigravity-Proxy.command [app|agy] [agy 参数...]
#   3) 直接把 Antigravity.app 拖到本启动器图标上，可立即代理启动
#
# 重要：本启动器不会修改官方 App。首次使用会在官方 App 同目录自动复制一份
#   “Antigravity IDE TUN.app”（或“Antigravity TUN.app”），签名补丁只打在
#   副本上，日常也只启动副本；原件保持官方原始签名，可随时照常双击使用。
# ==============================================================================

# Finder 双击 .command 时 PATH 很短，先补全常见路径
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# 解析脚本自身真实路径（兼容从别名/软链启动）
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
while [ -L "${SCRIPT_PATH}" ]; do
    LINK_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
    SCRIPT_PATH="$(readlink "${SCRIPT_PATH}")"
    [[ "${SCRIPT_PATH}" != /* ]] && SCRIPT_PATH="${LINK_DIR}/${SCRIPT_PATH}"
done
APP_HOME="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
DYLIB="${APP_HOME}/libantigravity_proxy.dylib"
PATCH_SCRIPT="${APP_HOME}/mac-patch-app.sh"
CONFIG="${APP_HOME}/config.json"
LOG_DIR="${APP_HOME}/logs"
# 多应用环境（Antigravity.app 与 Antigravity IDE.app 共存）时记住当前代理目标
LAST_APP_FILE="${APP_HOME}/.last-app"

if [ -t 1 ]; then
    C_RESET="\033[0m"; C_BOLD="\033[1m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"; C_CYAN="\033[36m"
else
    C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

# 本文件夹位于“桌面/文稿/下载”等 TCC 隐私保护目录时给出搬迁提醒
tcc_warn_if_needed() {
    case "${APP_HOME}/" in
        "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*)
            echo -e "${C_YELLOW}[重要提醒] 本文件夹当前位于系统隐私保护目录（桌面/文稿/下载）内。${C_RESET}"
            echo "  macOS 会阻止提权后的系统进程读取这里的文件（报错 Operation not permitted），"
            echo "  代理副本启动时加载本目录的动态库也可能被系统拦截，导致代理不生效。"
            echo "  请先退出本启动器，把整个“Antigravity-Proxy-macOS”文件夹移动到非保护目录，"
            echo -e "  例如“用户应用程序”目录 ${C_BOLD}~/Applications${C_RESET}（没有该文件夹可自行新建），再重新双击运行。"
            echo ""
            ;;
    esac
}

print_header() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}${C_BOLD}==================================================${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}   Antigravity-Proxy for macOS  透明代理启动器${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}==================================================${C_RESET}"
    echo ""
    tcc_warn_if_needed
}

pause() {
    echo ""
    read -r -p "按回车键返回菜单..." _dummy
}

# 读取配置中的代理端口（仅用于界面展示，非精确 JSON 解析）
current_proxy_port() {
    [ -f "${CONFIG}" ] || { echo "未找到 config.json"; return; }
    grep -A4 '"proxy"' "${CONFIG}" 2>/dev/null \
        | grep '"port"' | head -n 1 \
        | sed -E 's/[^0-9]//g'
}

# shell 单引号安全转义
shquote() {
    local s="$1"
    echo "'${s//\'/\'\\\'\'}'"
}

# 从任意路径提取所属 .app 目录
derive_app_dir() {
    local p="$1"
    case "${p}" in
        *.app) echo "${p%/}"; return 0 ;;
        *.app/*) echo "${p%%.app/*}.app"; return 0 ;;
    esac
    return 1
}

# 从 .app 包内解析真实可执行文件路径
resolve_app_executable() {
    local app_dir="$1" exe
    exe="$(/usr/libexec/PlistBuddy -c 'Print:CFBundleExecutable' "${app_dir}/Contents/Info.plist" 2>/dev/null || true)"
    if [ -n "${exe}" ] && [ -f "${app_dir}/Contents/MacOS/${exe}" ]; then
        echo "${app_dir}/Contents/MacOS/${exe}"
    fi
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
        "${HOME}/Applications/Antigravity IDE.app" \
        "${HOME}/Applications/Antigravity.app"; do
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

# 按选择器挑选一个 App（ide / classic|antigravity / 序号 / .app 路径 / 空）
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
    if [ -t 0 ] && [ -t 1 ]; then
        echo "检测到多个 Antigravity 应用，请选择:"
        for ((i=0; i<${#apps[@]}; i++)); do printf "  %d) %s\n" "$((i+1))" "${apps[$i]}"; done
        read -r -p "输入序号后回车: " sel
        pick_antigravity_app "${sel}"
        return $?
    fi
    echo "[错误] 同时检测到多个 Antigravity 应用，请指定选择器: ide / classic / 序号 / .app 路径" >&2
    for ((i=0; i<${#apps[@]}; i++)); do printf '         %d) %s\n' "$((i+1))" "${apps[$i]}" >&2; done
    return 1
}

# 菜单当前代理目标：优先 .last-app 记忆，其次第一个；拖放启动时以 DIRECT_TARGET 为准
current_menu_app() {
    if [ -n "${DIRECT_TARGET:-}" ]; then find_antigravity_app; return $?; fi
    local apps=() saved a
    while IFS= read -r line; do [ -n "${line}" ] && apps+=("${line}"); done < <(list_antigravity_apps)
    [ "${#apps[@]}" -eq 0 ] && return 1
    if [ "${#apps[@]}" -eq 1 ]; then echo "${apps[0]}"; return 0; fi
    saved="$(cat "${LAST_APP_FILE}" 2>/dev/null || true)"
    if [ -n "${saved}" ]; then
        for a in "${apps[@]}"; do
            [ "${a}" == "${saved%/}" ] && { echo "${a}"; return 0; }
        done
    fi
    echo "${apps[0]}"
}

# 菜单 1 使用：选择要以代理模式启动的应用。
# 单应用直接启动；多应用（含首次启动、无记忆文件）弹子菜单列出全部候选，
# 选中的应用写入 .last-app 作为下次默认项。
choose_app_and_launch() {
    local apps=() i choice picked default_idx=1 saved nm mark
    while IFS= read -r line; do [ -n "${line}" ] && apps+=("${line}"); done < <(list_antigravity_apps)
    if [ "${#apps[@]}" -eq 0 ]; then
        echo -e "${C_RED}[错误] 没有找到 Antigravity.app / Antigravity IDE.app。${C_RESET}"
        echo "可把官方应用拖到本启动器（${0##*/}）图标上，或确认其已安装到 /Applications。"
        return 1
    fi
    if [ "${#apps[@]}" -eq 1 ]; then
        launch_app "${apps[0]}"
        return $?
    fi
    saved="$(cat "${LAST_APP_FILE}" 2>/dev/null || true)"
    echo ""
    echo "检测到 ${#apps[@]} 个 Antigravity 应用，请选择要以透明代理模式启动的："
    for ((i=0; i<${#apps[@]}; i++)); do
        nm="$(macpatch_app_stem "${apps[$i]}" 2>/dev/null || basename "${apps[$i]}" .app)"
        mark=""
        if [ -n "${saved}" ] && [ "${saved%/}" == "${apps[$i]}" ]; then
            mark="  ${C_YELLOW}（上次使用）${C_RESET}"
            default_idx=$((i+1))
        fi
        echo -e "  ${C_BOLD}$((i+1))${C_RESET}) 启动 ${nm}${mark}"
    done
    echo -e "  ${C_BOLD}0${C_RESET}) 返回主菜单"
    read -r -p "请输入选项编号 [0-${#apps[@]}]（直接回车 = ${default_idx}）: " choice
    [ -z "${choice}" ] && choice="${default_idx}"
    [ "${choice}" = "0" ] && return 0
    picked="$(pick_antigravity_app "${choice}")" || { echo "无效选择，已返回主菜单。"; return 1; }
    echo "${picked}" > "${LAST_APP_FILE}"
    echo ""
    launch_app "${picked}"
}

# 查找官方 Antigravity 原件：拖放/命令行 DIRECT_TARGET 优先；否则返回排序第一的原件
find_antigravity_app() {
    _tun_is_original_path() { case "$(macpatch_app_stem "$1" 2>/dev/null || basename "$1" .app)" in
        *" TUN") return 1 ;; *) return 0 ;; esac; }
    if [ -n "${DIRECT_TARGET:-}" ]; then
        local d="${DIRECT_TARGET}"
        if [ -d "${d}" ] && [[ "${d}" == *.app ]]; then
            echo "${d%/}"; return 0
        fi
        local app_of
        app_of="$(derive_app_dir "${d}" || true)"
        if [ -n "${app_of}" ] && [ -d "${app_of}" ]; then
            echo "${app_of}"; return 0
        fi
    fi
    list_antigravity_apps | head -n 1
}

find_agy() {
    local p
    p="$(command -v agy 2>/dev/null || true)"
    [ -n "${p}" ] && { echo "${p}"; return; }
    for p in "${HOME}/.antigravity/bin/agy" "${HOME}/.local/bin/agy" \
             "/opt/homebrew/bin/agy" "/usr/local/bin/agy"; do
        [ -f "${p}" ] && { echo "${p}"; return; }
    done
}

check_environment() {
    if [ ! -f "${DYLIB}" ]; then
        echo -e "${C_RED}[错误] 未找到动态库: ${DYLIB}${C_RESET}"
        echo "请重新下载并完整解压本压缩包。"
        return 1
    fi
    if [ ! -f "${CONFIG}" ]; then
        echo -e "${C_RED}[错误] 未找到配置文件: ${CONFIG}${C_RESET}"
        return 1
    fi
    if [ ! -f "${PATCH_SCRIPT}" ]; then
        echo -e "${C_RED}[错误] 未找到补丁脚本: ${PATCH_SCRIPT}${C_RESET}"
        echo "请重新下载并完整解压本压缩包。"
        return 1
    fi
    if ! command -v codesign >/dev/null 2>&1; then
        echo -e "${C_RED}[错误] 未找到 codesign 工具。${C_RESET}"
        echo "请先安装 Apple“命令行开发者工具”：在“终端”执行 xcode-select --install 后重试。"
        return 1
    fi
    # 架构匹配检查
    local host_arch lib_archs
    host_arch="$(uname -m)"
    lib_archs="$(lipo -archs "${DYLIB}" 2>/dev/null || echo "")"
    case " ${lib_archs} " in
        *" ${host_arch} "*) : ;;
        *)
            echo -e "${C_YELLOW}[警告] 动态库架构(${lib_archs})与本机(${host_arch})不匹配。${C_RESET}"
            echo "请下载 universal2 通用版本或对应架构的安装包。"
            ;;
    esac
    return 0
}

# 计算 seed（可能是官方原件或 TUN 副本）对应的原件/副本路径，结果写入全局变量
resolve_app_pair() {
    local seed="${1%/}"
    if macpatch_is_tun_app "${seed}"; then
        COPY_APP="${seed}"
        ORIG_APP="$(macpatch_orig_sibling "${seed}")"
        [ -d "${ORIG_APP}" ] || ORIG_APP=""
    else
        ORIG_APP="${seed}"
        COPY_APP="$(macpatch_tun_sibling "${seed}")"
    fi
}

# 以系统管理员权限执行“复制副本 + 签名补丁”（目标在 /Applications 等无权目录时），
# 完成后把副本与冒烟产生的日志改回当前用户属主。
# 注意：macOS 的“文稿/桌面/下载”受 TCC 隐私保护，提权后的 root 进程没有这些
# 目录的访问授权（root 也受 TCC 约束），直接执行位于其中的脚本会报
# “Operation not permitted (126)”。因此先把补丁脚本与 dylib 暂存到
# 系统中立临时目录 /private/tmp，再让提权进程执行暂存副本。
run_app_prepare_as_admin() {
    local seed="$1" recreate="$2" uid gid inner esc rc=0 stage patch_tmp dylib_tmp
    uid="$(id -u)"; gid="$(id -g)"
    resolve_app_pair "${seed}"
    stage="$(mktemp -d /private/tmp/agy-proxy-admin.XXXXXX 2>/dev/null || mktemp -d -t agyproxy)" || return 1
    chmod 755 "${stage}" 2>/dev/null
    patch_tmp="${stage}/mac-patch-app.sh"
    dylib_tmp="${stage}/libantigravity_proxy.dylib"
    if ! /bin/cp "${PATCH_SCRIPT}" "${patch_tmp}" || ! /bin/cp "${DYLIB}" "${dylib_tmp}"; then
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
    inner="${inner}; /usr/sbin/chown -R ${uid}:${gid} $(shquote "${COPY_APP}") 2>/dev/null; /usr/sbin/chown -R ${uid}:${gid} $(shquote "${LOG_DIR}") 2>/dev/null; exit \$rc"
    esc="${inner//\\/\\\\}"; esc="${esc//\"/\\\"}"
    /usr/bin/osascript -e "do shell script \"${esc}\" with administrator privileges" || rc=$?
    rm -rf "${stage}" 2>/dev/null
    return ${rc}
}

# 提权/补丁失败时，针对 126（TCC 隐私保护拦截）给出可操作提示
admin_fail_hint() {
    local rc="$1"
    [ "${rc}" = "126" ] || return 0
    echo -e "${C_YELLOW}返回码 126（Operation not permitted）通常是 macOS 隐私保护拦截：${C_RESET}"
    echo "  · 请把整个“Antigravity-Proxy-macOS”文件夹移出“桌面/文稿/下载”后重试（推荐放到 ~/Applications）；"
    echo "  · 或在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中允许“终端”，退出终端后重开再试。"
}

# 确保目标已具备注入条件；需要补丁时自动执行（仅会执行一次）
# 返回 0=就绪，非 0=不可启动（用于 agy 等裸可执行文件，就地补丁）
ensure_patch() {
    local target="$1" rc tries ans

    if ! macpatch_target_needs_patch "${target}"; then
        return 0
    fi

    echo ""
    echo -e "${C_YELLOW}--------------------------------------------------${C_RESET}"
    echo -e "${C_BOLD}首次使用需要执行一次“本地签名补丁”${C_RESET}"
    echo "--------------------------------------------------"
    echo "该程序启用了 Hardened Runtime，默认禁止任何第三方动态库注入，"
    echo "代理必须先给它补上本机签名权限："
    echo "  · 仅在本机重签名，加入“允许注入”权限，不联网、不上传、不改功能"
    echo "  · 只需要执行一次；程序升级/重装后需重新补丁"
    echo ""

    # 目标在运行时无法重签名，引导用户退出后重试
    tries=0
    while macpatch_is_running "${target}"; do
        echo -e "${C_YELLOW}检测到目标程序正在运行。${C_RESET}"
        echo "请先完全退出它（⌘Q）。"
        read -r -p "退出后按回车自动继续（输入 s 跳过补丁）: " ans
        [ "${ans}" = "s" ] && return 4
        tries=$((tries + 1))
        [ "${tries}" -ge 5 ] && return 4
    done

    # 可写：直接补丁；不可写：弹出系统密码框用管理员权限补丁
    set +e
    if [ -w "$(macpatch_resolve_binary "${target}")" ]; then
        macpatch_ensure_target "${target}" "${DYLIB}"
        rc=$?
    else
        echo "目标目录当前用户不可写，将弹出系统授权框请求管理员权限..."
        run_app_prepare_as_admin "${target}"
        rc=$?
    fi
    set -e

    case "${rc}" in
        0)
            echo -e "${C_GREEN}签名补丁完成，以后启动无需再次操作（程序升级除外）。${C_RESET}"
            return 0 ;;
        3)
            echo -e "${C_RED}[错误] 没有写权限且未获得管理员授权。${C_RESET}"
            return 3 ;;
        4)
            echo -e "${C_RED}[错误] 程序仍在运行，请退出后重试。${C_RESET}"
            return 4 ;;
        5)
            echo -e "${C_RED}[错误] 签名补丁或注入验证失败。${C_RESET}"
            echo "可把以上 [patch] 输出连同 ${LOG_DIR} 里的日志反馈给项目作者。"
            return 5 ;;
        6)
            echo -e "${C_RED}[错误] 系统缺少 codesign，请先执行 xcode-select --install。${C_RESET}"
            return 6 ;;
        *)
            echo -e "${C_RED}[错误] 补丁未成功（返回码 ${rc}）。${C_RESET}"
            admin_fail_hint "${rc}"
            return "${rc}" ;;
    esac
}

# 交互准备官方 App 的 TUN 副本：复制 →（版本落后时重建）→ 签名补丁。
# 成功后全局 EFFECTIVE_APP 为实际应启动的副本路径；官方原件始终不被修改。
ensure_app_ready() {
    local seed="${1%/}" state tries ans rc parent ov cv do_recreate=""
    resolve_app_pair "${seed}"

    state="$(macpatch_tun_status_word "${seed}")"
    case "${state}" in
        ready)
            EFFECTIVE_APP="${COPY_APP}"
            return 0 ;;
        invalid|not-antigravity)
            ensure_patch "${seed}" || return $?
            EFFECTIVE_APP="${seed}"
            return 0 ;;
    esac

    echo ""
    echo -e "${C_YELLOW}--------------------------------------------------${C_RESET}"
    echo -e "${C_BOLD}首次使用：准备“代理专用副本”（官方原件不会被修改）${C_RESET}"
    echo "--------------------------------------------------"
    echo "  官方原件（保持官方签名）: ${ORIG_APP:-未找到}"
    echo "  代理副本（打补丁/启动）: ${COPY_APP}"
    echo ""
    case "${state}" in
        missing)
            echo "将在官方程序同目录复制一份“$(basename "${COPY_APP}")”，"
            echo "签名补丁只打在副本上。副本与原件共用登录状态，无需重新登录。" ;;
        needs-patch)
            echo "代理副本已存在，需要对其执行一次本地 ad-hoc 签名补丁"
            echo "（不联网、不上传、不改功能；只需一次，升级后重做）。" ;;
        outdated)
            ov="$(macpatch_app_version "${ORIG_APP}")"
            cv="$(macpatch_app_version "${COPY_APP}")"
            echo -e "${C_YELLOW}官方原件已升级（副本 ${cv} / 原件 ${ov}），建议重建副本。${C_RESET}"
            read -r -p "现在删除旧副本并重新复制+补丁吗？[Y/n]（n=继续启动旧版本）: " ans
            case "${ans}" in
                n|N|no|NO)
                    echo "跳过重建，直接为旧版本副本补签名..."
                    set +e
                    macpatch_ensure_target "${COPY_APP}" "${DYLIB}"
                    rc=$?
                    set -e
                    if [ "${rc}" -eq 0 ]; then EFFECTIVE_APP="${COPY_APP}"; return 0; fi
                    echo -e "${C_RED}[错误] 旧副本补丁失败（返回码 ${rc}），可重新选 1 并同意重建。${C_RESET}"
                    return 1 ;;
                *) do_recreate="recreate" ;;
            esac ;;
    esac
    echo ""

    # 原件或副本正在运行都会导致单实例冲突/无法重签，引导先退出
    tries=0
    while macpatch_is_running_related "${seed}"; do
        echo -e "${C_YELLOW}检测到 Antigravity（原件或副本）正在运行。${C_RESET}"
        echo "请先完全退出它（在窗口按 ⌘Q，或菜单栏图标 → Quit）。"
        read -r -p "退出后按回车自动继续（输入 s 跳过）: " ans
        [ "${ans}" = "s" ] && return 4
        tries=$((tries + 1))
        [ "${tries}" -ge 5 ] && return 4
    done

    # 父目录/副本可写就直接执行；/Applications 等不可写位置走系统授权框
    parent="$(dirname "${COPY_APP}")"
    set +e
    if [ -w "${parent}" ] && { [ ! -d "${COPY_APP}" ] || [ -w "${COPY_APP}" ]; }; then
        if [ "${do_recreate}" = "recreate" ]; then
            macpatch_ensure_app_target "${seed}" "${DYLIB}" recreate
        else
            macpatch_ensure_app_target "${seed}" "${DYLIB}"
        fi
        rc=$?
    else
        echo "在“${parent}”创建副本需要管理员权限，将弹出系统授权框（与安装软件相同）..."
        run_app_prepare_as_admin "${seed}" "${do_recreate}"
        rc=$?
    fi
    set -e

    case "${rc}" in
        0)
            EFFECTIVE_APP="${COPY_APP}"
            echo -e "${C_GREEN}代理副本已就绪。以后每次选 1 都会直接启动这个副本。${C_RESET}"
            return 0 ;;
        3)
            echo -e "${C_RED}[错误] 没有写权限且未获得管理员授权。${C_RESET}"
            echo "也可以把官方 Antigravity 复制到“个人应用程序”（~/Applications）后重试。"
            return 3 ;;
        4)
            echo -e "${C_RED}[错误] Antigravity 仍在运行，请退出后重试。${C_RESET}"
            return 4 ;;
        5)
            echo -e "${C_RED}[错误] 复制副本或签名补丁失败。${C_RESET}"
            echo "可把以上 [patch] 输出连同 ${LOG_DIR} 里的日志反馈给项目作者。"
            return 5 ;;
        6)
            echo -e "${C_RED}[错误] 系统缺少 codesign，请先执行 xcode-select --install。${C_RESET}"
            return 6 ;;
        7)
            echo -e "${C_RED}[错误] 副本版本与原件不一致，请重新选 1 并同意重建副本。${C_RESET}"
            return 7 ;;
        *)
            echo -e "${C_RED}[错误] 准备未成功（返回码 ${rc}）。${C_RESET}"
            admin_fail_hint "${rc}"
            return "${rc}" ;;
    esac
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
    echo -e "${C_YELLOW:-}[警告] 代理端口 ${host}:${port} 无法连接——代理软件未运行，或端口与配置不一致。${C_RESET:-}"
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
    echo -e "${C_YELLOW:-}[提示] 该代理副本正在运行（${n} 个进程）。${C_RESET:-}"
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

# 以注入环境启动 .app（LaunchServices 会自动重建完整进程树）
# 始终启动“代理专用副本”，官方原件不触碰
launch_app() {
    local seed="${1:-}" app_dir exe
    if [ -z "${seed}" ]; then
        app_dir="$(current_menu_app || true)"
    else
        app_dir="${seed%/}"
    fi
    if [ -z "${app_dir}" ]; then
        echo -e "${C_RED}[错误] 没有找到 Antigravity.app / Antigravity IDE.app。${C_RESET}"
        echo ""
        echo "请尝试以下任一方式："
        echo "  1) 把 Antigravity 应用拖到本启动器（${0##*/}）图标上再松开"
        echo "  2) 确认 Antigravity 已安装到 /Applications 或“应用程序”文件夹"
        echo "  3) 菜单选 1，在子菜单中指定要代理的应用"
        return 1
    fi

    # 预检顺序：先确认代理端口通（避免无谓等待补丁），再准备副本，
    # 最后处理“副本已在运行、持有旧配置”的常见情况
    preflight_proxy_reachable "${CONFIG}" || return 1
    ensure_app_ready "${app_dir}" || return 1
    exe="$(resolve_app_executable "${EFFECTIVE_APP}")"
    preflight_restart_running_copy "${EFFECTIVE_APP}" || return 1

    echo -e "${C_GREEN}[启动] 正在以透明代理模式启动 Antigravity（代理专用副本）...${C_RESET}"
    echo "       副本: ${EFFECTIVE_APP}"
    [ -n "${ORIG_APP:-}" ] && echo "       原件保持原样，未做任何修改"
    echo "       程序: ${exe}"
    echo "       代理配置: ${CONFIG}"
    open -n \
        --env DYLD_INSERT_LIBRARIES="${DYLIB}" \
        --env DYLD_FORCE_FLAT_NAMESPACE=1 \
        "${EFFECTIVE_APP}" ${@:2}
    echo -e "${C_GREEN}已启动。本终端窗口现在可以关闭，Antigravity 会继续运行。${C_RESET}"
    echo "       代理日志: ${LOG_DIR}"
}

launch_agy() {
    local bin
    bin="$(find_agy)"
    if [ -z "${bin}" ]; then
        echo -e "${C_RED}[错误] 没有找到 agy 命令。${C_RESET}"
        echo "请先安装 Antigravity CLI（agy），或在其安装后重试。"
        return 1
    fi
    ensure_patch "${bin}" || return 1
    echo -e "${C_GREEN}[启动] agy 透明代理模式: ${bin} $*${C_RESET}"
    echo ""
    DYLD_INSERT_LIBRARIES="${DYLIB}" DYLD_FORCE_FLAT_NAMESPACE=1 exec "${bin}" "$@"
}

# 以前台子进程方式运行 agy（不 exec，保证结束后能回到菜单），并报告退出码
run_agy_capture() {
    local bin rc
    bin="$(find_agy)"
    if [ -z "${bin}" ]; then
        echo -e "${C_RED}[错误] 没有找到 agy 命令。${C_RESET}"
        echo "请先安装 Antigravity CLI（agy），或在其安装后重试。"
        pause
        return 1
    fi
    if ! ensure_patch "${bin}"; then
        pause
        return 1
    fi
    echo -e "${C_GREEN}[启动] agy 透明代理模式: ${bin} $*${C_RESET}"
    echo "       agy 的输出会直接显示在下方；结束后按回车即可返回菜单。"
    echo ""
    DYLD_INSERT_LIBRARIES="${DYLIB}" DYLD_FORCE_FLAT_NAMESPACE=1 "${bin}" "$@"
    rc=$?
    echo ""
    if [ "${rc}" -eq 0 ]; then
        echo -e "${C_GREEN}[完成] agy 已正常结束（退出码 0）。${C_RESET}"
    else
        echo -e "${C_YELLOW}[提示] agy 已结束，退出码 ${rc}（非 0，可能是手动中断或命令报错）。${C_RESET}"
        echo "       排障建议：确认代理软件已启动且菜单顶部端口正确；先选本菜单 1"
        echo "       用 changelog 验证联网；agy 1.2.x 已无 status/login 子命令。"
    fi
    pause
}

# 菜单 2：agy 命令行子菜单（每项执行完都能看到结果并返回，不会直接退出启动器）
agy_menu() {
    local sub question
    while true; do
        print_header
        echo "  agy 是 Antigravity 的命令行 Agent，账号体系与图形应用共用（登录一次即可）。"
        echo ""
        echo -e "  ${C_BOLD}1${C_RESET}) 验证联网：agy changelog（拉取更新日志，最快判断代理是否通）"
        echo -e "  ${C_BOLD}2${C_RESET}) 单次对话：agy -p \"你的问题\"（跑完即返回本菜单）"
        echo -e "  ${C_BOLD}3${C_RESET}) 交互式对话：agy -i（在 agy 内输入 /exit 或按 Ctrl+D 退回本菜单）"
        echo -e "  ${C_BOLD}4${C_RESET}) 自定义参数（输入任意 agy 参数，如 --help 或 /hooks）"
        echo -e "  ${C_BOLD}0${C_RESET}) 返回主菜单"
        echo ""
        read -r -p "请输入选项编号后回车: " sub
        case "${sub}" in
            1)
                run_agy_capture changelog ;;
            2)
                read -r -p "请输入要问 agy 的问题（直接回车取消）: " question
                if [ -n "${question}" ]; then
                    run_agy_capture -p "${question}"
                fi ;;
            3)
                echo "提示：进入 agy 交互对话后，输入 /exit 或按 Ctrl+D 结束并返回本菜单。"
                run_agy_capture -i ;;
            4)
                read -r -p "请输入 agy 参数（直接回车取消，例如: --help）: " question
                if [ -n "${question}" ]; then
                    # 故意不加引号：允许用户输入多个参数
                    run_agy_capture ${question}
                fi ;;
            0|"")
                return 0 ;;
            *)
                echo "无效选项，请重新输入。"
                sleep 1 ;;
        esac
    done
}

# 非交互参数直通：./Antigravity-Proxy.command /path/to/Antigravity.app
DIRECT_TARGET=""
if [ $# -gt 0 ] && [ "$1" != "app" ] && [ "$1" != "agy" ] && [ "$1" != "apps" ]; then
    DIRECT_TARGET="$1"
    shift
fi

check_environment || { echo ""; read -r -p "按回车键退出..." _dummy; exit 1; }

# 加载补丁函数库
# shellcheck source=mac-patch-app.sh
source "${PATCH_SCRIPT}"

# 非交互（拖放/命令行参数）流程不会经过菜单，这里同样提醒一次
if [ -n "${DIRECT_TARGET}" ] || [ $# -gt 0 ]; then
    tcc_warn_if_needed
fi

if [ -n "${DIRECT_TARGET}" ]; then
    if [ -d "${DIRECT_TARGET}" ] || derive_app_dir "${DIRECT_TARGET}" >/dev/null 2>&1; then
        launch_app "${DIRECT_TARGET}" "$@"
    else
        # 裸可执行文件：走 agy 同样的注入路径
        if [ ! -e "${DIRECT_TARGET}" ]; then
            echo "[错误] 目标不存在: ${DIRECT_TARGET}"
            read -r -p "按回车键退出..." _dummy
            exit 1
        fi
        ensure_patch "${DIRECT_TARGET}" || { read -r -p "按回车键退出..." _dummy; exit 1; }
        DYLD_INSERT_LIBRARIES="${DYLIB}" DYLD_FORCE_FLAT_NAMESPACE=1 exec "${DIRECT_TARGET}" "$@"
    fi
    exit $?
fi

if [ $# -gt 0 ]; then
    case "$1" in
        app)
            shift
            app_sel="${1:-}"
            if [ -n "${app_sel}" ]; then
                shift
                app_path="$(pick_antigravity_app "${app_sel}")" || exit 1
                launch_app "${app_path}" "$@"
            else
                launch_app "" "$@"
            fi ;;
        apps)
            echo "检测到以下 Antigravity 应用:"
            list_antigravity_apps | cat -n | sed 's/^/  /'
            exit 0 ;;
        agy) shift; launch_agy "$@" ;;
        *)    echo "[错误] 未知参数: $1（可选: app [ide|classic|序号|路径] / apps / agy）"; exit 1 ;;
    esac
    exit $?
fi

# 交互菜单
while true; do
    print_header
    PORT="$(current_proxy_port)"
    # 全部已安装原件 & 上次启动的代理目标（菜单 1 选择后写入 .last-app）
    APP_LIST=()
    while IFS= read -r line; do [ -n "${line}" ] && APP_LIST+=("${line}"); done < <(list_antigravity_apps)
    APP_COUNT="${#APP_LIST[@]}"
    APP_DIR="$(current_menu_app || true)"
    CURRENT_NAME=""
    [ -n "${APP_DIR}" ] && CURRENT_NAME="$(macpatch_app_stem "${APP_DIR}" 2>/dev/null || basename "${APP_DIR}" .app)"
    PATCH_STATE="未找到 Antigravity 应用"
    COPY_PATH=""
    if [ -n "${APP_DIR}" ]; then
        COPY_PATH="$(macpatch_tun_sibling "${APP_DIR}")"
        state_word="$(macpatch_tun_status_word "${APP_DIR}" 2>/dev/null || echo invalid)"
        case "${state_word}" in
            missing)
                PATCH_STATE="${C_YELLOW}尚未创建代理副本（选 1 自动复制“$(basename "${COPY_PATH}")”，官方原件不改动）${C_RESET}" ;;
            outdated)
                PATCH_STATE="${C_YELLOW}代理副本版本落后于官方原件（选 1 可自动重建）${C_RESET}" ;;
            needs-patch)
                PATCH_STATE="${C_YELLOW}代理副本需要首次签名补丁（选 1 自动完成）${C_RESET}" ;;
            ready)
                PATCH_STATE="${C_GREEN}代理副本已就绪（补丁已应用）${C_RESET}" ;;
            *)
                PATCH_STATE="无法识别目标: ${APP_DIR}" ;;
        esac
    fi
    echo -e " 配置文件: ${C_BOLD}${CONFIG}${C_RESET}"
    echo -e " 代理端口: ${C_BOLD}${PORT:-未知}${C_RESET}（如不正确请选 3 修改）"
    echo -e " 副本状态: $(echo -e "${PATCH_STATE}")"
    if [ -n "${APP_DIR}" ]; then
        echo "           官方原件: ${APP_DIR}（不会被修改）"
        echo "           代理副本: ${COPY_PATH}"
        if [ "${APP_COUNT}" -gt 1 ]; then
            echo -e "           本机共检测到 ${C_BOLD}${APP_COUNT}${C_RESET} 个 Antigravity 应用，上次启动: ${C_CYAN}${CURRENT_NAME}${C_RESET}（选 1 可切换）"
        fi
    fi
    echo ""
    if [ "${APP_COUNT}" -gt 1 ]; then
        echo -e "  ${C_BOLD}1${C_RESET}) 启动 Antigravity 或 Antigravity IDE（透明代理模式，使用代理副本）"
    else
        echo -e "  ${C_BOLD}1${C_RESET}) 启动 ${CURRENT_NAME:-Antigravity}（透明代理模式，使用代理副本）"
    fi
    echo -e "  ${C_BOLD}2${C_RESET}) agy 命令行（验证联网 changelog / 单次对话 / 交互式对话）"
    echo -e "  ${C_BOLD}3${C_RESET}) 编辑配置文件 config.json（改代理端口）"
    echo -e "  ${C_BOLD}4${C_RESET}) 查看代理日志（logs 文件夹）"
    echo -e "  ${C_BOLD}5${C_RESET}) 打开《使用说明》"
    echo -e "  ${C_BOLD}6${C_RESET}) 重新检测/创建/修复代理副本（针对上次启动的应用）"
    echo -e "  ${C_BOLD}0${C_RESET}) 退出"
    echo ""
    read -r -p "请输入选项编号后回车: " choice
    case "${choice}" in
        1)
            choose_app_and_launch
            pause ;;
        2)
            agy_menu ;;
        3)
            open -e "${CONFIG}"
            echo "已用“文本编辑”打开 config.json，改完记得保存（Cmd+S）。"
            pause ;;
        4)
            if [ -d "${LOG_DIR}" ]; then
                open "${LOG_DIR}"
            else
                echo "尚未生成日志。先启动一次 Antigravity 后再查看。"
            fi
            pause ;;
        5)
            if [ -f "${APP_HOME}/使用说明.txt" ]; then
                open -e "${APP_HOME}/使用说明.txt"
            else
                echo "未找到 使用说明.txt。"
            fi
            pause ;;
        6)
            if [ -z "${APP_DIR}" ]; then
                echo "没有找到 Antigravity 应用，无法创建代理副本。"
            else
                state_word="$(macpatch_tun_status_word "${APP_DIR}" 2>/dev/null || echo invalid)"
                if [ "${state_word}" = "ready" ]; then
                    echo "当前应用（${CURRENT_NAME}）的代理副本状态正常，无需修复："
                    echo "  ${COPY_PATH}"
                    echo "（官方 Antigravity 升级后，选 1 按提示重建副本即可）"
                else
                    ensure_app_ready "${APP_DIR}" || true
                fi
            fi
            pause ;;
        0|"")
            exit 0 ;;
        *)
            echo "无效选项，请重新输入。"
            sleep 1 ;;
    esac
done
LAUNCHER_EOF
chmod +x "${STAGE_DIR}/Antigravity-Proxy.command"

# ------------------------------------------------------- 使用说明（纯文本） --
cat > "${STAGE_DIR}/使用说明.txt" <<TXT_EOF
==================================================
 Antigravity-Proxy for macOS 使用说明（免安装版）
 版本：${TAG}  架构：${ARCH_LABEL}
 状态：已真机验证（2026-09-15）Google 登录成功并进入 IDE 主界面
==================================================

【这个工具是做什么的？】
让 Antigravity（IDE 客户端和 agy 命令行）的网络流量自动走你本机的
SOCKS5/HTTP 代理，不需要开启系统全局代理或 TUN 模式。
支持 Apple Silicon（M1/M2/M3/M4）与 Intel 芯片。

【使用前准备】
0. 把解压得到的“Antigravity-Proxy-macOS”文件夹放到固定位置：
   推荐放到你的用户“应用程序”目录 ~/Applications（没有可自行新建）。
   请不要放在“桌面 / 文稿(Documents) / 下载(Downloads)”里——这些是
   macOS 隐私保护目录，可能导致提权时报“Operation not permitted (126)”
   或代理副本加载不到本工具，启动器菜单顶部出现黄色提醒时请先搬迁。
1. 先启动你的代理软件（Clash Verge / Surge / V2RayU / sing-box 等）。
2. 在代理软件界面找到并记下本机代理端口：
   - Clash Verge / Mihomo 混合端口通常是 7890
   - V2RayU / V2RayN 的 SOCKS5 端口通常是 10808
   - Surge 的 SOCKS5 端口通常是 6153

【第一次使用（3 步）】
1. 修改代理端口
   双击文件夹里的“Antigravity-Proxy.command”，在菜单中选 3，
   把 config.json 里 proxy 段的 port 改成你代理软件的实际端口，
   保存（Cmd+S）后关闭文本编辑。
   （默认已经是 7890，端口一致可跳过本步。）

2. 启动 Antigravity
   回到菜单选 1。第一次会自动完成两件事（全程约 1 分钟）：
   a) 在官方应用旁边自动复制一份“Antigravity IDE TUN.app”
      （或“Antigravity TUN.app”）——官方原件一个字节都不会被修改；
   b) 只对这份副本执行一次“本地签名补丁”（见下文说明）。
   完成后自动启动的是副本。也可以在菜单选 2 使用 agy 命令行。
   （agy 1.2.x 是 Agent CLI，已无 status/login 子命令；菜单 2 是子菜单：
     1 验证联网 changelog、2 单次对话 -p、3 交互式 -i、4 自定义参数，
     每项执行完会显示退出码，按回车即返回，不会直接关掉启动器。）

   ★ 同时装了 Antigravity 和 Antigravity IDE 两个应用？
     两者是不同的 App，但共用同一套 Google 登录账号。
     - 菜单 1 会先弹出选择子菜单：1) 启动 Antigravity IDE
       2) 启动 Antigravity（上次启动的那个会标注“上次使用”，直接回车即可）；
     - 只装了其中一个时不弹子菜单，菜单 1 直接启动它；
     - 首次使用、还没有记住选择时同样会弹出该子菜单；
     - 也可以把任意一个官方 App 直接拖到本启动器图标上启动它的副本。
     命令行方式：Antigravity-Proxy.command apps        列出全部应用
                 Antigravity-Proxy.command app ide     启动 IDE
                 Antigravity-Proxy.command app classic 启动 Antigravity

3. 以后每次使用
   只要代理软件已经开着，直接双击“Antigravity-Proxy.command”，选 1 即可。
   启动器会启动当前代理目标的 TUN 副本（Antigravity TUN 或 Antigravity IDE TUN）；
   不要直接从启动台/程序坞点不带 TUN 的官方图标——那是官方原件，不走代理。
   （原件和副本共用同一个登录状态，无需重新登录；同一应用的原件与副本不要同时开。）

【什么是“本地签名补丁”？安全吗？】
官方 Antigravity 带有苹果 Hardened Runtime 保护，默认禁止任何第三方
动态库注入（这是 macOS 的安全机制，所以必须先补丁才能使用本代理）。
为了不改动官方原件，本工具采用“原件 + 代理副本”的方式：
  · 首次选菜单 1 时，自动在官方程序同目录复制一份
    “Antigravity IDE TUN.app”（或“Antigravity TUN.app”，体积约 1GB）；
  · 补丁只打在副本上：在你本机用 ad-hoc（临时身份）重新签名副本的
    程序文件，增加“允许 DYLD 注入”和“允许加载本地库”两个权限；
  · 官方原件始终保持 Google 原始签名，可随时照常双击使用，
    需要联系官方客服/申诉账号时请用原件；
  · 不联网、不上传、不改变 Antigravity 功能，也不影响系统其他程序；
  · 副本与原件共用登录状态和设置，无需重新登录；
  · 官方 Antigravity 升级后，启动器会检测到版本不一致并提示重建副本
    （重新复制+补丁，选 1 后按 Y 即可，原件同样不受影响）；
  · 不想要代理环境了：直接把“Antigravity IDE TUN.app”拖到废纸篓即可，
    官方程序完好无损。
另外，agent 后端（language_server）原本被 Seatbelt 沙箱禁止联网，
代理启动副本时会自动让它在沙箱外运行，否则它连不上你的本地代理端口。
这与普通开发命令行工具的运行权限相同。

【第一次双击提示“无法打开”怎么办？】
这是 macOS 的安全提示（本包未在苹果付费注册开发者签名）。
  方法一：在“Antigravity-Proxy.command”上点鼠标“右键”（或双指点按）
          → 选择“打开”→ 在弹窗里再点一次“打开”。只需操作一次。
  方法二：若仍被拦截，打开“系统设置 → 隐私与安全性”，
          页面下方会出现“仍要允许/仍要打开”，点击确认。
  方法三：打开“终端”，输入下面命令后回车（把路径换成实际解压路径）：
          xattr -dr com.apple.quarantine "$HOME/Downloads/${PKG_NAME}"

【补丁提示“正在运行/需要管理员权限”怎么办？】
  · 提示正在运行：先把官方原件和“...TUN”副本都完全退出（⌘Q），
    回到启动器按回车。注意原件和副本不能同时运行（同一个登录身份）。
  · 提示需要管理员权限：在“应用程序”（/Applications）里创建副本需要
    授权，会弹出系统密码框，输入本机登录密码即可（与安装软件相同；
    密码不会经过本工具；仅用于复制副本这一步）。
  · 若弹窗后提示“Operation not permitted (126)”：说明本文件夹放在了
    “桌面/文稿/下载”等隐私保护目录。请先退出启动器，把整个
    “Antigravity-Proxy-macOS”文件夹移到 ~/Applications 等非保护目录再双击运行；
    或到“系统设置 → 隐私与安全性 → 完全磁盘访问权限”允许“终端”后重试。
  · 若提示缺少 codesign：打开“终端”执行 xcode-select --install，
    装完 Apple 命令行工具后重试。

【找不到 Antigravity.app？】
- 请确认 Antigravity 已安装到“应用程序”（/Applications）文件夹。
- 或者：直接把“官方 Antigravity.app”的图标拖到
  “Antigravity-Proxy.command”图标上再松开——启动器同样会自动创建/
  使用同目录的“...TUN.app”副本，不会修改你拖入的原件。
- 也可以在终端手动指定路径，例如：
  ./Antigravity-Proxy.command "/Applications/Antigravity IDE.app"

【怎么确认代理生效了？】
在启动器菜单选 4 查看日志，文件位于本文件夹 logs/proxy-日期.log。
出现下面这些行就说明成功（注意路径里是“Antigravity IDE TUN.app”）：
  Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)
  当前宿主进程: Electron (路径: .../Antigravity IDE TUN.app/...)
  macOS 代理重定向: ... 代理=127.0.0.1:端口 类型=socks5
language_server 启动时还会出现“已绕过 Seatbelt/sandbox-exec”的提示。

【登录 Google 账号的正确姿势】
本版本已实测：在 TUN 副本里点“Sign in with Google”，浏览器授权后能正常
回到 IDE 并进入主界面。请注意：
  · 登录前先用 ⌘Q 彻底退出所有 Antigravity（包括官方原件），只通过本启动
    器选 1 启动一次“Antigravity IDE TUN”副本，再去点登录；
  · 不要在登录过程中重启/再开一个窗口——原件和副本共用单实例锁，若先开
    了未注入的原件，授权后的令牌交换会直连 Google 超时，表现为登录报错；
  · 若第一次授权后转圈/报错，回到 IDE 重新点一次 Sign in 即可（实测第二
    次在数秒内 signedIn 成功），无需重启。

【常见问题】
1. 不要用 macOS 自带的 /usr/bin/curl 测试注入效果——SIP 系统完整性
   保护会对系统自带程序清除 DYLD_INSERT_LIBRARIES，属于正常现象。
   本补丁不需要、也不建议关闭 SIP。
2. 若提示 dylib 代码签名相关错误，可在“终端”执行一次本地临时签名：
   codesign --force --sign - libantigravity_proxy.dylib
   （需先 cd 到解压后的文件夹）
3. 官方 Antigravity 升级后，旧副本仍是旧版本且补丁会失效，启动器
   选 1 时会提示“重建副本”，按 Y 即会自动用新版原件重新复制+补丁；
   也可以用菜单 6 手动触发。
4. 程序坞里出现两个 Antigravity 图标怎么区分？
   代理副本的显示名带“TUN”后缀（访达文件名也是），请认准
   “Antigravity IDE TUN”启动；不带 TUN 的官方原件不走代理。

【如何卸载？】
- 删除代理环境：把“应用程序”文件夹里的“Antigravity IDE TUN.app”
  （或“Antigravity TUN.app”）拖到废纸篓即可，官方原件完好无损。
- 删除本工具：把整个“${PKG_NAME}”文件夹拖到废纸篓即可，没有写入系统目录。
若你之前用过安装脚本安装过全局命令，可删除：
   ~/.local/lib/libantigravity_proxy.dylib
   ~/.local/lib/mac-patch-app.sh
   ~/.local/bin/antigravity-proxy
   ~/.config/antigravity-proxy/

项目主页：https://github.com/yuaotian/antigravity-proxy
TXT_EOF

# ---------------------------------------------------------------- 打包 zip --
ZIP_NAME="antigravity-proxy-${TAG}-mac-${ARCH_LABEL}.zip"
mkdir -p "${DIST_DIR}"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"
rm -f "${ZIP_PATH}"

# ditto 是 macOS 原生打包方式，可保留 Unix 可执行权限，解压后 .command 仍可双击
( cd "${STAGE_PARENT}" && ditto -c -k --keepParent "${PKG_NAME}" "${ZIP_PATH}" )

echo ""
echo "=================================================="
echo " 打包完成！"
echo " 压缩包: ${ZIP_PATH}"
echo " 包含内容:"
( cd "${STAGE_PARENT}" && find "${PKG_NAME}" -type f | sed 's/^/   /' )
echo ""
echo " SHA-256:"
shasum -a 256 "${ZIP_PATH}" | sed 's/^/   /'
echo "=================================================="
