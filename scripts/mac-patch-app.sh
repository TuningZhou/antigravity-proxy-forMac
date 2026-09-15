#!/usr/bin/env bash
# ==============================================================================
# Antigravity-Proxy macOS 本地签名补丁（Hardened Runtime 解锁 DYLD 注入）
#
# 背景：官方 Antigravity IDE / language_server / agy 均以 Hardened Runtime 签名，
# 且未携带 allow-dyld-environment-variables 与 disable-library-validation
# 权利，dyld 会静默忽略 DYLD_INSERT_LIBRARIES。
#
# 本脚本在用户本机对目标做一次 ad-hoc 重签名并补齐上述权利：
#   - 不联网、不上传、不改变程序功能
#   - App 升级/重装后补丁会被覆盖，重新执行一次即可
#   - 卸载补丁的方法：重装官方 App
#
# 用法（直接执行）：
#   ./scripts/mac-patch-app.sh "/Applications/Antigravity IDE.app" [dylib路径]
#   ./scripts/mac-patch-app.sh "$HOME/.antigravity/bin/agy"
#
# 也可被其他脚本 source，调用 macpatch_ensure_target 等函数。
# ==============================================================================

# 返回码约定：
#   0 已就绪（原本就不需要补丁，或补丁+冒烟验证成功）
#   2 参数不是有效的 app/可执行文件
#   3 没有写权限（需要 sudo 或更换安装位置）
#   4 目标正在运行（需要先退出）
#   5 重签名或注入冒烟验证失败
#   6 系统环境不支持（非 macOS / 缺少 codesign）

__MP_LOG_PREFIX="[patch]"
__mp_log()  { echo "${__MP_LOG_PREFIX} $*"; }
__mp_warn() { echo "${__MP_LOG_PREFIX} [警告] $*" >&2; }
__mp_err()  { echo "${__MP_LOG_PREFIX} [错误] $*" >&2; }

# 解析 .app 包的主可执行文件路径
macpatch_main_executable() {
    local app_dir="$1" exe
    exe="$(/usr/libexec/PlistBuddy -c 'Print:CFBundleExecutable' \
        "${app_dir}/Contents/Info.plist" 2>/dev/null || true)"
    if [ -n "${exe}" ] && [ -f "${app_dir}/Contents/MacOS/${exe}" ]; then
        echo "${app_dir}/Contents/MacOS/${exe}"
    fi
}

# 入参可以是 .app 目录或裸 Mach-O 文件，统一返回主二进制绝对路径
macpatch_resolve_binary() {
    local target="$1"
    if [ -d "${target}" ] && [[ "${target}" == *.app ]]; then
        macpatch_main_executable "${target}"
    elif [ -f "${target}" ]; then
        echo "${target}"
    fi
}

# 判断目标是否需要补丁
# 返回 0=需要补丁，1=不需要（未启用 hardened runtime 或已带齐权利），2=无效目标
macpatch_target_needs_patch() {
    local target="$1" bin dv ents
    bin="$(macpatch_resolve_binary "${target}")"
    if [ -z "${bin}" ] || [ ! -f "${bin}" ]; then
        return 2
    fi
    dv="$(codesign -dv "${bin}" 2>&1 || true)"
    # 未启用 Hardened Runtime 的程序默认允许 DYLD 注入，无需处理
    if ! echo "${dv}" | grep -q "flags=.*runtime"; then
        return 1
    fi
    ents="$(codesign -d --entitlements :- "${bin}" 2>&1 || true)"
    if echo "${ents}" | grep -q "com.apple.security.cs.allow-dyld-environment-variables" \
       && echo "${ents}" | grep -q "com.apple.security.cs.disable-library-validation"; then
        return 1
    fi
    return 0
}

# 生成补丁用 entitlements（保留官方原有权利并补齐注入所需两项）
macpatch_write_entitlements() {
    local out="$1"
    cat > "${out}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables.process</key><true/>
    <key>com.apple.security.automation.apple-events</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.camera</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.network.server</key><true/>
</dict>
</plist>
XML
}

# 目标是否正在运行（按可执行路径匹配）
macpatch_is_running() {
    local target="$1" bin
    bin="$(macpatch_resolve_binary "${target}")"
    [ -n "${bin}" ] && pgrep -f "${bin}" >/dev/null 2>&1
}

# 对目标执行 ad-hoc 重签名
macpatch_apply_signature() {
    local target="$1" ent_file="$2"

    if [ -d "${target}" ] && [[ "${target}" == *.app ]]; then
        __mp_log "补丁对象为应用包: ${target}"

        # 1) 先签包内各 Helper（内层优先，顺序无关）
        local helper
        while IFS= read -r -d '' helper; do
            __mp_log "重签名 Helper: $(basename "${helper}")"
            codesign --force --timestamp=none --options runtime \
                --entitlements "${ent_file}" --sign - "${helper}" >/dev/null
        done < <(find "${target}/Contents/Frameworks" -maxdepth 1 -name "*.app" -print0 2>/dev/null)

        # 2) 再签 Resources 内独立的 language_server 可执行文件
        local lsbin
        while IFS= read -r -d '' lsbin; do
            __mp_log "重签名: $(basename "${lsbin}")"
            codesign --force --timestamp=none --options runtime \
                --entitlements "${ent_file}" --sign - "${lsbin}" >/dev/null
        done < <(find "${target}/Contents/Resources" -type f -perm -u+x \
                    -name 'language_server*' ! -name '*.sh' ! -name '*.LICENSE' \
                    -print0 2>/dev/null)

        # 3) 最后签最外层 App（主二进制带完整 entitlements）
        __mp_log "重签名主程序..."
        codesign --force --timestamp=none --options runtime \
            --entitlements "${ent_file}" --sign - "${target}" >/dev/null
    else
        __mp_log "补丁对象为可执行文件: ${target}"
        codesign --force --timestamp=none --options runtime \
            --entitlements "${ent_file}" --sign - "${target}" >/dev/null
    fi
}

# 冒烟验证：借 DYLD_PRINT_LIBRARIES 确认 dyld 真的加载了我们的 dylib。
# 注意：不能通过 /usr/bin/env 传递 DYLD 变量——它是受保护系统二进制，
# AMFI 会在 exec 时剥除这些变量；必须用 shell export 后直接 exec。
# 仅对 .app 的 Electron 主程序做运行冒烟（独立的 language_server 等直接运行
# 可能产生服务端副作用，其 entitlements 已做静态校验，跳过）。
macpatch_smoke_test() {
    local target="$1" dylib="$2" bin smoke_dir out_file pid i found=0

    [ -f "${dylib}" ] || { __mp_warn "冒烟跳过：dylib 不存在 ${dylib}"; return 0; }
    bin="$(macpatch_resolve_binary "${target}")"
    [ -n "${bin}" ] || return 0

    if [ ! -d "${target}" ] || [[ "${target}" != *.app ]]; then
        __mp_log "独立可执行文件不做运行冒烟（权利已静态校验，以实际日志为准）。"
        return 0
    fi

    smoke_dir="$(mktemp -d)"
    out_file="${smoke_dir}/smoke.log"
    __mp_log "执行注入冒烟验证（仅检测 dylib 是否被加载，随即结束进程，不打开界面）..."

    (
        cd /
        export DYLD_PRINT_LIBRARIES=1
        export DYLD_INSERT_LIBRARIES="${dylib}"
        export DYLD_FORCE_FLAT_NAMESPACE=1
        # 隔离配置目录、禁用 GPU/沙箱，避免冒烟时出现界面或 GPU 崩溃
        "${bin}" --version --no-sandbox --disable-gpu \
                 --user-data-dir="${smoke_dir}/profile" >"${out_file}" 2>&1
    ) &
    pid=$!

    # 最多轮询 12 秒，一旦看到加载行立即结束
    for ((i = 0; i < 24; i++)); do
        if grep -qF "libantigravity_proxy.dylib" "${out_file}" 2>/dev/null; then
            found=1
            break
        fi
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.5
    done

    # 清理冒烟主进程及其包内子进程（ensure 阶段已保证同名 App 未在运行）
    pkill -f "${target}/Contents/" 2>/dev/null || true
    kill -9 "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    rm -rf "${smoke_dir}"

    if [ "${found}" = "1" ]; then
        __mp_log "冒烟通过：dyld 已成功加载代理动态库。"
        return 0
    fi
    __mp_err "冒烟失败：dyld 未加载代理动态库。"
    return 5
}

# 一体化入口：确保目标可被注入
# 用法：macpatch_ensure_target <目标> [dylib路径]
macpatch_ensure_target() {
    local target="$1" dylib="${2:-}" tmpdir bin need

    if [ "$(uname -s)" != "Darwin" ] || ! command -v codesign >/dev/null 2>&1; then
        __mp_err "需要在安装了 Xcode 命令行工具的 macOS 上运行。"
        return 6
    fi
    if [ ! -e "${target}" ]; then
        __mp_err "目标不存在: ${target}"
        return 2
    fi

    bin="$(macpatch_resolve_binary "${target}")"
    if [ -z "${bin}" ]; then
        __mp_err "无法识别的目标（既不是 .app 也不是可执行文件）: ${target}"
        return 2
    fi

    if macpatch_target_needs_patch "${target}"; then
        need=1
    else
        __mp_log "目标无需补丁（权利已齐或未启用 Hardened Runtime）。"
        return 0
    fi

    if macpatch_is_running "${target}"; then
        __mp_err "目标正在运行，请先完全退出 Antigravity 后再执行补丁。"
        return 4
    fi

    if [ ! -w "${bin}" ]; then
        __mp_err "当前用户对目标没有写权限: ${bin}"
        __mp_err "可改用 sudo 手动执行本脚本，或把 App 移到 ~/Applications 后重试。"
        return 3
    fi

    tmpdir="$(mktemp -d)"
    # 不使用 RETURN trap：该函数会被 .command 菜单循环多次调用，函数级 trap
    # 容易残留并在后续无关函数返回时触发；各返回点显式 rm -rf 清理。
    __mp_cleanup_tmp() { rm -rf "${tmpdir}"; }

    macpatch_write_entitlements "${tmpdir}/entitlements.plist"

    __mp_log "开始本地 ad-hoc 重签名（不联网，约需数秒至数十秒）..."
    if ! macpatch_apply_signature "${target}" "${tmpdir}/entitlements.plist"; then
        __mp_err "重签名失败。"
        __mp_cleanup_tmp
        return 5
    fi

    # 签名结构校验（Electron 包 strict 校验偶发告警，不阻断，以冒烟为准）
    codesign --verify "${target}" >/dev/null 2>&1 \
        || __mp_warn "codesign --verify 有告警（以注入冒烟结果为准）。"

    if macpatch_target_needs_patch "${target}"; then
        __mp_err "重签名后仍缺少所需权利。"
        __mp_cleanup_tmp
        return 5
    fi

    if [ -n "${dylib}" ] && [ -f "${dylib}" ]; then
        if ! macpatch_smoke_test "${target}" "${dylib}"; then
            __mp_cleanup_tmp
            return 5
        fi
    fi

    __mp_cleanup_tmp
    __mp_log "补丁完成：${target}"
    return 0
}

# 直接执行模式
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    set -euo pipefail
    if [ $# -lt 1 ]; then
        echo "用法: $0 <Antigravity.app 或可执行文件路径> [dylib路径]"
        exit 2
    fi
    macpatch_ensure_target "$1" "${2:-}"
fi
