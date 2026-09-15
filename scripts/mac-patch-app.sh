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
# TUN 副本机制（默认行为，原件永不修改）：
#   对官方 Antigravity.app 执行补丁时，会先在同目录复制一份
#   "<原名> TUN.app"（如 /Applications/Antigravity IDE TUN.app），
#   克隆副本带修改显示名 + ad-hoc 重签名都只作用于副本；
#   官方原件保持原始签名，作为“干净入口”保留；不要副本了直接删除即可。
#
# 用法（直接执行）：
#   ./scripts/mac-patch-app.sh "/Applications/Antigravity IDE.app" [dylib路径]
#   ./scripts/mac-patch-app.sh --recreate "/Applications/Antigravity IDE.app" [dylib路径]
#   ./scripts/mac-patch-app.sh --status "/Applications/Antigravity IDE.app"
#   ./scripts/mac-patch-app.sh "$HOME/.antigravity/bin/agy"
#
# 也可被其他脚本 source，调用 macpatch_ensure_app_target / macpatch_ensure_target 等函数。
# ==============================================================================

# 返回码约定：
#   0 已就绪（原本就不需要补丁，或副本创建+补丁+冒烟验证成功）
#   2 参数不是有效的 app/可执行文件
#   3 没有写权限（需要 sudo 或更换安装位置）
#   4 目标正在运行（需要先退出）
#   5 重签名/复制或注入冒烟验证失败
#   6 系统环境不支持（非 macOS / 缺少 codesign）
#   7 TUN 副本版本落后于官方原件（需要 --recreate 重建）

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

# ==============================================================================
# TUN 副本机制
# 补丁绝不直接作用于官方原件：首次在原件同目录克隆一份 "<原名> TUN.app"，
# 重签名只打在副本上，日常启动也启动副本。原件保持 Google 原始签名。
# ==============================================================================

MACPATCH_TUN_SUFFIX=" TUN"

# 取 .app 的文件名主干（去路径、去 .app）
macpatch_app_stem() {
    local base
    base="$(basename "${1%/}")"
    echo "${base%.app}"
}

# 是否为 "... TUN.app" 副本
macpatch_is_tun_app() {
    local app="$1"
    [ -d "${app}" ] || return 1
    [[ "${app%/}" == *.app ]] || return 1
    case "$(macpatch_app_stem "${app}")" in
        *"${MACPATCH_TUN_SUFFIX}") return 0 ;;
        *) return 1 ;;
    esac
}

# 识别官方 Antigravity 应用（只对它自动克隆，避免误改其他 App）
macpatch_is_antigravity_app() {
    local app="$1" stem bid
    [ -d "${app}" ] || return 1
    [[ "${app%/}" == *.app ]] || return 1
    stem="$(macpatch_app_stem "${app}")"
    shopt -s nocasematch 2>/dev/null || true
    if [[ "${stem}" == Antigravity* ]]; then
        shopt -u nocasematch 2>/dev/null || true
        return 0
    fi
    shopt -u nocasematch 2>/dev/null || true
    bid="$(/usr/libexec/PlistBuddy -c 'Print:CFBundleIdentifier' \
        "${app}/Contents/Info.plist" 2>/dev/null || true)"
    echo "${bid}" | grep -qi 'antigravity'
}

# 原件 → 同目录 TUN 副本路径；传入副本则原样返回
macpatch_tun_sibling() {
    local app dir stem
    app="${1%/}"
    dir="$(dirname "${app}")"
    stem="$(macpatch_app_stem "${app}")"
    case "${stem}" in
        *"${MACPATCH_TUN_SUFFIX}") echo "${app}" ;;
        *) echo "${dir}/${stem}${MACPATCH_TUN_SUFFIX}.app" ;;
    esac
}

# 副本 → 推测的官方原件路径（可能不存在）
macpatch_orig_sibling() {
    local app dir stem
    app="${1%/}"
    dir="$(dirname "${app}")"
    stem="$(macpatch_app_stem "${app}")"
    case "${stem}" in
        *"${MACPATCH_TUN_SUFFIX}")
            echo "${dir}/${stem%${MACPATCH_TUN_SUFFIX}}.app" ;;
        *) echo "${app}" ;;
    esac
}

# 读取 App 的 CFBundleShortVersionString
macpatch_app_version() {
    /usr/libexec/PlistBuddy -c 'Print:CFBundleShortVersionString' \
        "${1%/}/Contents/Info.plist" 2>/dev/null || true
}

# 纯路径解析（不拷贝）：副本已存在则返回副本，否则返回原件
macpatch_effective_app() {
    local app copy
    app="${1%/}"
    if macpatch_is_antigravity_app "${app}" && ! macpatch_is_tun_app "${app}"; then
        copy="$(macpatch_tun_sibling "${app}")"
        [ -d "${copy}" ] && { echo "${copy}"; return 0; }
    fi
    echo "${app}"
}

# 原件或副本任一正在运行即返回 0（同 bundle id 具有单实例锁）
macpatch_is_running_related() {
    local seed other
    macpatch_is_running "${seed:=$1}" && return 0
    if macpatch_is_tun_app "${seed}"; then
        other="$(macpatch_orig_sibling "${seed}")"
    else
        other="$(macpatch_tun_sibling "${seed}")"
    fi
    [ -d "${other}" ] && macpatch_is_running "${other}"
}

# 副本状态词：invalid / not-antigravity / missing / outdated / needs-patch / ready
macpatch_tun_status_word() {
    local seed="$1" orig copy ov cv
    if [ ! -d "${seed}" ] || [[ "${seed%/}" != *.app ]]; then
        echo invalid; return
    fi
    if ! macpatch_is_antigravity_app "${seed}"; then
        echo not-antigravity; return
    fi
    if macpatch_is_tun_app "${seed}"; then
        copy="${seed%/}"
        orig="$(macpatch_orig_sibling "${seed}")"
        [ -d "${orig}" ] || orig=""
    else
        orig="${seed%/}"
        copy="$(macpatch_tun_sibling "${seed}")"
    fi
    if [ ! -d "${copy}" ]; then
        echo missing; return
    fi
    if [ -n "${orig}" ] && [ -d "${orig}" ]; then
        ov="$(macpatch_app_version "${orig}")"
        cv="$(macpatch_app_version "${copy}")"
        if [ -n "${ov}" ] && [ -n "${cv}" ] && [ "${ov}" != "${cv}" ]; then
            echo outdated; return
        fi
    fi
    if macpatch_target_needs_patch "${copy}"; then
        echo needs-patch
    else
        echo ready
    fi
}

# 把副本的 Dock/访达显示名改成带 TUN 后缀，避免两个同名图标混淆。
# 官方包无 InfoPlist.strings 覆盖；若日后出现本地化覆盖也一并改写。
# 注意：必须在外层重签名之前调用（Info.plist 属于签名内容）。
macpatch_set_copy_display_name() {
    local app="$1" name="$2" plist s
    plist="${app}/Contents/Info.plist"
    [ -f "${plist}" ] || return 0
    if /usr/libexec/PlistBuddy -c 'Print:CFBundleDisplayName' "${plist}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${name}" "${plist}" >/dev/null 2>&1 || true
    else
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${name}" "${plist}" >/dev/null 2>&1 || true
    fi
    for s in "${app}/Contents/Resources/"*.lproj/InfoPlist.strings; do
        [ -f "${s}" ] || continue
        if /usr/libexec/PlistBuddy -c 'Print:CFBundleDisplayName' "${s}" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${name}" "${s}" >/dev/null 2>&1 || true
        fi
    done
}

# 克隆官方原件 → TUN 副本。调用前需确认副本不存在、父目录可写。
# 返回 0 成功；3 父目录不可写；5 复制失败
macpatch_clone_app() {
    local orig="$1" copy="$2"
    [ -d "${orig}" ] || { __mp_err "官方原件不存在: ${orig}"; return 2; }
    [ -e "${copy}" ] && { __mp_err "副本已存在: ${copy}"; return 5; }
    if [ ! -w "$(dirname "${copy}")" ]; then
        return 3
    fi
    __mp_log "首次使用：正在复制一份官方程序（官方原件不会被修改）..."
    __mp_log "  原件（保持原样）: ${orig}"
    __mp_log "  副本（打补丁）:   ${copy}"
    __mp_log "副本体积约 1GB，复制需要数十秒，请耐心等待..."
    if ! ditto "${orig}" "${copy}"; then
        __mp_err "复制失败，请检查磁盘空间后重试。"
        rm -rf "${copy}" 2>/dev/null || true
        return 5
    fi
    # 副本不带下载隔离标记，避免 Gatekeeper 弹“已损坏，打不开”
    xattr -dr com.apple.quarantine "${copy}" 2>/dev/null || true
    macpatch_set_copy_display_name "${copy}" "$(macpatch_app_stem "${copy}")"
    __mp_log "副本创建完成（登录状态与设置和原件共用，无需重新登录）。"
    return 0
}

# 删除旧副本并按当前原件重新克隆。
# 返回 4 副本正在运行；3 不可写；5 删除/复制失败
macpatch_reclone_app() {
    local orig="$1" copy="$2"
    [ -d "${orig}" ] || { __mp_err "官方原件不存在: ${orig}"; return 2; }
    if [ -d "${copy}" ] && macpatch_is_running "${copy}"; then
        __mp_err "TUN 副本正在运行，请先 ⌘Q 完全退出后再重建。"
        return 4
    fi
    if [ -d "${copy}" ]; then
        if [ ! -w "$(dirname "${copy}")" ] || [ ! -w "${copy}" ]; then
            return 3
        fi
        __mp_log "正在删除旧版本副本..."
        if ! rm -rf "${copy}"; then
            __mp_err "旧副本删除失败。"
            return 5
        fi
    fi
    macpatch_clone_app "${orig}" "${copy}"
}

# 一体化入口（App 走 TUN 副本机制；裸可执行文件保持就地补丁）
# 用法：macpatch_ensure_app_target <目标> [dylib路径] [recreate]
# 成功后全局变量 MACPATCH_EFFECTIVE_TARGET 为实际应启动的目标路径
# 返回码同 macpatch_ensure_target，另：7=副本版本落后，需 recreate 重建
macpatch_ensure_app_target() {
    local target="$1" dylib="${2:-}" recreate="${3:-}"
    local app_dir copy orig ov cv
    MACPATCH_EFFECTIVE_TARGET=""

    if [ "$(uname -s)" != "Darwin" ] || ! command -v codesign >/dev/null 2>&1; then
        __mp_err "需要在安装了 Xcode 命令行工具的 macOS 上运行。"
        return 6
    fi
    if [ ! -e "${target}" ]; then
        __mp_err "目标不存在: ${target}"
        return 2
    fi

    if [ ! -d "${target}" ] || [[ "${target%/}" != *.app ]]; then
        # 裸可执行文件（agy / language_server 等）：保持就地补丁
        MACPATCH_EFFECTIVE_TARGET="${target}"
        macpatch_ensure_target "${target}" "${dylib}"
        return $?
    fi
    app_dir="${target%/}"

    if ! macpatch_is_antigravity_app "${app_dir}"; then
        # 非 Antigravity 的其他 App：保持原有就地补丁行为
        MACPATCH_EFFECTIVE_TARGET="${app_dir}"
        macpatch_ensure_target "${app_dir}" "${dylib}"
        return $?
    fi

    if macpatch_is_tun_app "${app_dir}"; then
        copy="${app_dir}"
        orig="$(macpatch_orig_sibling "${app_dir}")"
        [ -d "${orig}" ] || orig=""
    else
        orig="${app_dir}"
        copy="$(macpatch_tun_sibling "${app_dir}")"
    fi

    if [ ! -d "${copy}" ]; then
        [ -n "${orig}" ] && [ -d "${orig}" ] || { __mp_err "找不到可复制的官方原件。"; return 2; }
        macpatch_clone_app "${orig}" "${copy}" || return $?
    elif [ "${recreate}" = "recreate" ]; then
        [ -n "${orig}" ] && [ -d "${orig}" ] || { __mp_err "找不到官方原件，无法重建副本。"; return 2; }
        macpatch_reclone_app "${orig}" "${copy}" || return $?
    else
        if [ -n "${orig}" ] && [ -d "${orig}" ]; then
            ov="$(macpatch_app_version "${orig}")"
            cv="$(macpatch_app_version "${copy}")"
            if [ -n "${ov}" ] && [ -n "${cv}" ] && [ "${ov}" != "${cv}" ]; then
                __mp_warn "TUN 副本版本(${cv})与官方原件(${ov})不一致。"
                __mp_warn "建议重建副本（加 --recreate 重新复制；官方原件不会被改动）。"
                MACPATCH_EFFECTIVE_TARGET="${copy}"
                return 7
            fi
        fi
    fi

    MACPATCH_EFFECTIVE_TARGET="${copy}"
    macpatch_ensure_target "${copy}" "${dylib}"
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
    mode="ensure"
    case "${1:-}" in
        --status)   mode="status"; shift ;;
        --recreate) mode="recreate"; shift ;;
        -h|--help)
            echo "用法: $0 [--status|--recreate] <Antigravity.app 或可执行文件路径> [dylib路径]"
            echo "  默认        首次自动在同目录创建“<原名> TUN.app”副本并只对副本打补丁"
            echo "  --status    输出副本状态: missing / outdated / needs-patch / ready 等"
            echo "  --recreate  官方升级后，删除旧副本并按当前原件重新复制+补丁"
            exit 0 ;;
    esac
    if [ $# -lt 1 ]; then
        echo "用法: $0 [--status|--recreate] <Antigravity.app 或可执行文件路径> [dylib路径]"
        exit 2
    fi
    case "${mode}" in
        status)
            macpatch_tun_status_word "$1"
            ;;
        recreate)
            macpatch_ensure_app_target "$1" "${2:-}" recreate
            ;;
        ensure)
            macpatch_ensure_app_target "$1" "${2:-}"
            ;;
    esac
fi
