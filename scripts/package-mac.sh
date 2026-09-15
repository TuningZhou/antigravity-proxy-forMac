#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Antigravity-Proxy macOS 预编译包打包脚本
#
# 产物：dist/antigravity-proxy-v<版本>-mac<架构>.zip
#   - universal2 包同时支持 Apple Silicon (arm64) 与 Intel (x64)
#   - 解压后双击 Antigravity-Proxy.command 即可使用，最终用户无需安装编译工具
#   - 首次启动会引导对 Antigravity.app 做本地 ad-hoc 签名补丁
#     （官方 Hardened Runtime 默认禁止 DYLD 注入，详见包内“使用说明.txt”）
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

if [ -t 1 ]; then
    C_RESET="\033[0m"; C_BOLD="\033[1m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"; C_CYAN="\033[36m"
else
    C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

print_header() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}${C_BOLD}==================================================${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}   Antigravity-Proxy for macOS  透明代理启动器${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}==================================================${C_RESET}"
    echo ""
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

# 查找 Antigravity.app 目录（DIRECT_TARGET 优先，其次常见位置，最后 Spotlight）
find_antigravity_app() {
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
    local cand found
    for cand in \
        "/Applications/Antigravity IDE.app" \
        "/Applications/Antigravity.app" \
        "${HOME}/Applications/Antigravity IDE.app" \
        "${HOME}/Applications/Antigravity.app"; do
        [ -d "${cand}" ] && { echo "${cand}"; return 0; }
    done
    if command -v mdfind >/dev/null 2>&1; then
        found="$(mdfind "kMDItemCFBundleIdentifier == 'com.antigravity.desktop'" 2>/dev/null | head -n 1 || true)"
        [ -n "${found}" ] && [ -d "${found}" ] && { echo "${found}"; return 0; }
        found="$(mdfind "kMDItemContentType == 'com.apple.application-bundle' && (kMDItemFSName == 'Antigravity.app' || kMDItemFSName == 'Antigravity IDE.app')" 2>/dev/null | head -n 1 || true)"
        [ -n "${found}" ] && [ -d "${found}" ] && { echo "${found}"; return 0; }
    fi
    return 1
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
    case ",${lib_archs}," in
        *",${host_arch},"*) : ;;
        *)
            echo -e "${C_YELLOW}[警告] 动态库架构(${lib_archs})与本机(${host_arch})不匹配。${C_RESET}"
            echo "请下载 universal2 通用版本或对应架构的安装包。"
            ;;
    esac
    return 0
}

# 以系统管理员权限执行补丁（目标在无权写入的目录时使用），
# 完成后把冒烟产生的 root 日志改回当前用户
run_patch_as_admin() {
    local target="$1" uid gid inner esc
    uid="$(id -u)"; gid="$(id -g)"
    inner="/bin/bash $(shquote "${PATCH_SCRIPT}") $(shquote "${target}") $(shquote "${DYLIB}"); rc=\$?; /usr/sbin/chown -R ${uid}:${gid} $(shquote "${LOG_DIR}") 2>/dev/null; exit \$rc"
    esc="${inner//\\/\\\\}"; esc="${esc//\"/\\\"}"
    /usr/bin/osascript -e "do shell script \"${esc}\" with administrator privileges"
}

# 确保目标已具备注入条件；需要补丁时自动执行（仅会执行一次）
# 返回 0=就绪，非 0=不可启动
ensure_patch() {
    local target="$1" rc tries ans

    if ! macpatch_target_needs_patch "${target}"; then
        return 0
    fi

    echo ""
    echo -e "${C_YELLOW}--------------------------------------------------${C_RESET}"
    echo -e "${C_BOLD}首次使用需要执行一次“本地签名补丁”${C_RESET}"
    echo "--------------------------------------------------"
    echo "官方 Antigravity 启用了 Hardened Runtime，默认禁止任何第三方"
    echo "动态库注入，因此代理必须先给它补上本机签名权限："
    echo "  · 仅在本机重签名，加入“允许注入”权限，不联网、不上传、不改功能"
    echo "  · 只需要执行一次；Antigravity 升级/重装后需重新补丁"
    echo "  · 卸载补丁的方法：重装官方 Antigravity"
    echo ""

    # 目标在运行时无法重签名，引导用户退出后重试
    tries=0
    while macpatch_is_running "${target}"; do
        echo -e "${C_YELLOW}检测到 Antigravity 正在运行。${C_RESET}"
        echo "请先完全退出它（在 Antigravity 窗口按 ⌘Q，或菜单栏图标 → Quit）。"
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
        run_patch_as_admin "${target}"
        rc=$?
    fi
    set -e

    case "${rc}" in
        0)
            echo -e "${C_GREEN}签名补丁完成，以后启动无需再次操作（升级 Antigravity 除外）。${C_RESET}"
            return 0 ;;
        3)
            echo -e "${C_RED}[错误] 没有写权限且未获得管理员授权。${C_RESET}"
            echo "可把 Antigravity.app 移到“个人应用程序”文件夹（~/Applications）后重试。"
            return 3 ;;
        4)
            echo -e "${C_RED}[错误] Antigravity 仍在运行，请退出后重试。${C_RESET}"
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
            return "${rc}" ;;
    esac
}

# 以注入环境启动 .app（LaunchServices 会自动重建完整进程树）
launch_app() {
    local app_dir exe
    app_dir="$(find_antigravity_app || true)"
    if [ -z "${app_dir}" ]; then
        echo -e "${C_RED}[错误] 没有找到 Antigravity.app。${C_RESET}"
        echo ""
        echo "请尝试以下任一方式："
        echo "  1) 把 Antigravity.app 拖到本启动器（${0##*/}）图标上再松开"
        echo "  2) 确认 Antigravity 已安装到 /Applications 或“应用程序”文件夹"
        return 1
    fi
    exe="$(resolve_app_executable "${app_dir}")"

    ensure_patch "${app_dir}" || return 1

    echo -e "${C_GREEN}[启动] 正在以透明代理模式启动 Antigravity ...${C_RESET}"
    echo "       ${exe}"
    echo "       代理配置: ${CONFIG}"
    open -n \
        --env DYLD_INSERT_LIBRARIES="${DYLIB}" \
        --env DYLD_FORCE_FLAT_NAMESPACE=1 \
        "${app_dir}"
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

# 非交互参数直通：./Antigravity-Proxy.command /path/to/Antigravity.app
DIRECT_TARGET=""
if [ $# -gt 0 ] && [ "$1" != "app" ] && [ "$1" != "agy" ]; then
    DIRECT_TARGET="$1"
    shift
fi

check_environment || { echo ""; read -r -p "按回车键退出..." _dummy; exit 1; }

# 加载补丁函数库
# shellcheck source=mac-patch-app.sh
source "${PATCH_SCRIPT}"

if [ -n "${DIRECT_TARGET}" ]; then
    if [ -d "${DIRECT_TARGET}" ] || derive_app_dir "${DIRECT_TARGET}" >/dev/null 2>&1; then
        launch_app "$@"
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
        app) shift; launch_app "$@" ;;
        agy) shift; launch_agy "$@" ;;
        *)    echo "[错误] 未知参数: $1（可选: app / agy）"; exit 1 ;;
    esac
    exit $?
fi

# 交互菜单
while true; do
    print_header
    PORT="$(current_proxy_port)"
    APP_DIR="$(find_antigravity_app || true)"
    PATCH_STATE="未找到 Antigravity.app"
    if [ -n "${APP_DIR}" ]; then
        if macpatch_target_needs_patch "${APP_DIR}" 2>/dev/null; then
            PATCH_STATE="${C_YELLOW}需要首次签名补丁（选 1 启动时自动完成）${C_RESET}"
        else
            PATCH_STATE="${C_GREEN}已就绪（补丁已应用 / 无需补丁）${C_RESET}"
        fi
    fi
    echo -e " 配置文件: ${C_BOLD}${CONFIG}${C_RESET}"
    echo -e " 代理端口: ${C_BOLD}${PORT:-未知}${C_RESET}（如不正确请选 3 修改）"
    echo -e " 补丁状态: $(echo -e "${PATCH_STATE}")"
    echo ""
    echo -e "  ${C_BOLD}1${C_RESET}) 启动 Antigravity IDE（透明代理模式）"
    echo -e "  ${C_BOLD}2${C_RESET}) 启动 agy 命令行（status / login 等）"
    echo -e "  ${C_BOLD}3${C_RESET}) 编辑配置文件 config.json（改代理端口）"
    echo -e "  ${C_BOLD}4${C_RESET}) 查看代理日志（logs 文件夹）"
    echo -e "  ${C_BOLD}5${C_RESET}) 打开《使用说明》"
    echo -e "  ${C_BOLD}6${C_RESET}) 重新检测/修复签名补丁"
    echo -e "  ${C_BOLD}0${C_RESET}) 退出"
    echo ""
    read -r -p "请输入选项编号后回车: " choice
    case "${choice}" in
        1)
            launch_app
            pause ;;
        2)
            echo ""
            read -r -p "请输入 agy 参数（直接回车默认 status，例如 login）: " agy_args
            # 故意不加引号：允许用户输入多个参数
            launch_agy ${agy_args:-status}
            pause ;;
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
                echo "没有找到 Antigravity.app，无法应用补丁。"
            else
                if macpatch_target_needs_patch "${APP_DIR}"; then
                    ensure_patch "${APP_DIR}" || true
                else
                    echo "当前补丁状态正常，无需重复补丁。"
                    echo "（Antigravity 升级后若注入失效，可重新执行本选项）"
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
==================================================

【这个工具是做什么的？】
让 Antigravity（IDE 客户端和 agy 命令行）的网络流量自动走你本机的
SOCKS5/HTTP 代理，不需要开启系统全局代理或 TUN 模式。
支持 Apple Silicon（M1/M2/M3/M4）与 Intel 芯片。

【使用前准备】
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
   回到菜单选 1。第一次会自动执行“本地签名补丁”（见下文说明），
   完成后 Antigravity 自动启动。之后这个终端窗口就可以关掉。
   也可以在菜单选 2 使用 agy 命令行（默认执行 agy status）。

3. 以后每次使用
   只要代理软件已经开着，直接双击“Antigravity-Proxy.command”，
   选 1 即可。不要直接从启动台/程序坞点开 Antigravity——那样不走代理。

【什么是“本地签名补丁”？安全吗？】
官方 Antigravity 带有苹果 Hardened Runtime 保护，默认禁止任何第三方
动态库注入（这是 macOS 的安全机制，所以必须先补丁才能使用本代理）。
补丁做的事：
  · 在你本机用 ad-hoc（临时身份）重新签名 Antigravity 的程序文件，
    增加“允许 DYLD 注入”和“允许加载本地库”两个权限；
  · 不联网、不上传、不改变 Antigravity 功能，也不影响系统其他程序；
  · 只作用于这台电脑，补丁不会随 App 拷贝到别的机器；
  · 只需执行一次；Antigravity 升级/重装后补丁会被覆盖，再选菜单 1
    或菜单 6 重新补丁即可；
  · 想完全撤销：重装官方 Antigravity。
另外，agent 后端（language_server）原本被 Seatbelt 沙箱禁止联网，
代理启动时会自动让它在沙箱外运行，否则它连不上你的本地代理端口。
这与普通开发命令行工具的运行权限相同。

【第一次双击提示“无法打开”怎么办？】
这是 macOS 的安全提示（本包未在苹果付费注册开发者签名）。
  方法一：在“Antigravity-Proxy.command”上点鼠标“右键”（或双指点按）
          → 选择“打开”→ 在弹窗里再点一次“打开”。只需操作一次。
  方法二：若仍被拦截，打开“系统设置 → 隐私与安全性”，
          页面下方会出现“仍要允许/仍要打开”，点击确认。
  方法三：打开“终端”，输入下面命令后回车（把路径换成实际解压路径）：
          xattr -dr com.apple.quarantine "$HOME/Downloads/${PKG_NAME}"

【补丁提示“正在运行/没有写权限”怎么办？】
  · 提示正在运行：在 Antigravity 窗口按 ⌘Q 完全退出，回到启动器按回车。
  · 提示需要管理员权限：会弹出系统密码框，输入本机登录密码授权即可
    （与安装软件时的授权相同；密码不会经过本工具）。
  · 若提示缺少 codesign：打开“终端”执行 xcode-select --install，
    装完 Apple 命令行工具后重试。

【找不到 Antigravity.app？】
- 请确认 Antigravity 已安装到“应用程序”（/Applications）文件夹。
- 或者：直接把 Antigravity.app 的图标拖到
  “Antigravity-Proxy.command”图标上再松开，就会立即代理启动。
- 也可以在终端手动指定路径，例如：
  ./Antigravity-Proxy.command "/Applications/Antigravity IDE.app"

【怎么确认代理生效了？】
在启动器菜单选 4 查看日志，文件位于本文件夹 logs/proxy-日期.log。
出现下面这些行就说明成功：
  Antigravity-Proxy macOS 动态库已加载 (DYLD_INSERT_LIBRARIES)
  当前宿主进程: Electron (路径: .../Antigravity IDE.app/...)
  macOS 代理重定向: ... 代理=127.0.0.1:端口 类型=socks5
language_server 启动时还会出现“已绕过 Seatbelt/sandbox-exec”的提示。

【常见问题】
1. 不要用 macOS 自带的 /usr/bin/curl 测试注入效果——SIP 系统完整性
   保护会对系统自带程序清除 DYLD_INSERT_LIBRARIES，属于正常现象。
   本补丁不需要、也不建议关闭 SIP。
2. 若提示 dylib 代码签名相关错误，可在“终端”执行一次本地临时签名：
   codesign --force --sign - libantigravity_proxy.dylib
   （需先 cd 到解压后的文件夹）
3. Antigravity 升级后注入失效属正常（官方签名覆盖了补丁），
   重新运行启动器选 1 或选 6 重新补丁即可。

【如何卸载？】
直接把整个“${PKG_NAME}”文件夹拖到废纸篓即可，没有写入系统目录。
若希望撤销 Antigravity 的本地签名补丁，重装一次官方 Antigravity。
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
