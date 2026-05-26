#!/bin/bash
# =========================================================
# 项目名称：NF-Manager 纯内核极速转发与安全面板
# 版本：v5.0
# 仓库：https://github.com/starshine369/nftables-keep
# =========================================================
#
# 设计要点：
#   - 转发规则字段：本地端口 | 目标(IP或域名) | 目标端口 | 协议 | 模式 | 备注
#     协议: tcp / udp / tcp+udp     模式: ip / static / dynamic
#   - 旧 3 段空格分隔格式启动时自动迁移
#   - 备份集中放 /etc/nf_manager/backups/，每种文件最多保留 7 份
#   - 日志写 /var/log/nf_manager.log，由 logrotate 周/1MB 轮转保留 7 份
#   - DDNS resolver 仅在存在 dynamic 规则时由 systemd timer 启动
#   - 卸载分两档：8 仅删脚本本身；99 完全卸载，环境恢复干净
#
# 命令行参数：
#   nf                  进交互菜单
#   nf --apply          热加载规则（脚本调用 / 排障）
#   nf --resolver-tick  resolver timer 触发的解析检查
#   nf --diagnose       直接跑诊断
# =========================================================

set -o pipefail

# 终端显示对齐依赖 bash 在 UTF-8 locale 下统计字符数（${#var}）
# 大多数现代发行版默认为 UTF-8；若是 C/POSIX locale 显式切到 C.UTF-8
case "${LC_ALL:-${LANG:-C}}" in
    *UTF-8*|*utf8*) ;;
    *) export LANG=C.UTF-8 LC_ALL=C.UTF-8 ;;
esac

# --- [1. 路径与常量] ---
DIR_PATH="/etc/nf_manager"
BACKUP_DIR="${DIR_PATH}/backups"
CONFIG_FILE="${DIR_PATH}/forward.list"
RULES_FILE="${DIR_PATH}/rules.nft"
RESOLVER_CACHE="${DIR_PATH}/resolver.cache"      # 格式: domain|ip|epoch
WHITELIST_DEF="/etc/my_allow_ips.nft"
ACTION_FILE="${DIR_PATH}/whitelist_action.nft"
STATUS_FILE="${DIR_PATH}/whitelist.status"
MSS_FILE="${DIR_PATH}/mss.nft"
MSS_STATUS_FILE="${DIR_PATH}/mss.status"
MSS_VALUE_FILE="${DIR_PATH}/mss.value"
SSH_PORT_FILE="${DIR_PATH}/ssh.port"             # 记录初装时填的 SSH 端口
MAIN_CONF="/etc/nftables.conf"
LOG_FILE="/var/log/nf_manager.log"
LOGROTATE_CONF="/etc/logrotate.d/nf_manager"
RESOLVER_SERVICE="/etc/systemd/system/nf_manager_resolver.service"
RESOLVER_TIMER="/etc/systemd/system/nf_manager_resolver.timer"
RESOLVER_INTERVAL_FILE="${DIR_PATH}/resolver.interval"  # 间隔秒数，默认 60
BACKUP_KEEP=7                                    # 每种文件保留份数

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

VERSION="v5.0"

# =========================================================
# --- [2. 通用工具函数] ---
# =========================================================

log_msg() {
    # 用法: log_msg LEVEL TAG "消息文本"
    # 静默写日志，不污染终端输出
    local level="$1" tag="$2"; shift 2
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    # 创建日志目录失败时静默忽略（避免 root 权限不足时阻塞）
    [ -d "$(dirname "$LOG_FILE")" ] || return 0
    printf '[%s] [%-5s] %-10s %s\n' "$ts" "$level" "$tag" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

err_exit() {
    echo -e "${RED}❌ $*${RESET}" >&2
    log_msg ERROR FATAL "$*"
    exit 1
}

# ----- 终端显示宽度工具（处理中文等宽字符对齐） -----
# 计算字符串去除 ANSI 转义后的显示宽度
# 规则：ASCII 算 1 列，多字节字符（CJK / 全角）算 2 列
# 依赖：UTF-8 locale（脚本顶部已确保）
display_width() {
    local s="$1"
    # 移除 ANSI 转义序列 (ESC[...letter)
    s=$(printf '%s' "$s" | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g')
    local bytes chars cjk
    bytes=$(printf '%s' "$s" | wc -c)
    chars=${#s}
    if [ "$bytes" -eq "$chars" ]; then
        # ${#} 返回字节数（非 UTF-8 locale），全部按 1 列算
        echo "$chars"
    else
        # UTF-8 下 CJK 占 3 字节 1 字符，差值的一半即 CJK 数
        cjk=$(( (bytes - chars) / 2 ))
        echo $(( chars + cjk ))
    fi
}

# 把字符串补齐空格到指定显示宽度（用于表格右侧对齐）
pad_display() {
    local s="$1" target="$2"
    local w pad
    w=$(display_width "$s")
    pad=$((target - w))
    if [ "$pad" -gt 0 ]; then
        printf '%s%*s' "$s" "$pad" ""
    else
        printf '%s' "$s"
    fi
}

# 备份单个文件到 BACKUP_DIR，按文件名前缀维护保留份数
backup_file() {
    local src="$1"
    [ -f "$src" ] || return 0
    mkdir -p "$BACKUP_DIR"
    local base
    base=$(basename "$src")
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local dst="${BACKUP_DIR}/${base}.${ts}.bak"
    cp -a "$src" "$dst" && log_msg INFO BACKUP "$src -> $dst"

    # 清理同前缀的旧备份，保留最近 BACKUP_KEEP 份
    # 用 find 比 ls 解析更安全
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "${base}.*.bak" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | awk -v keep="$BACKUP_KEEP" 'NR>keep {print $2}' \
        | xargs -r rm -f
}

# 校验：端口 1-65535
validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 校验：IPv4 点分十进制
validate_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    # 注意：local IFS='.' arr=($x) 一行写法 IFS 不能及时生效，必须拆开
    local IFS='.'
    local -a octets=($1)
    local o
    [ "${#octets[@]}" -eq 4 ] || return 1
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        [ "$o" -gt 255 ] && return 1
    done
    return 0
}

# 校验：域名（不含尾点，至少一个点）
validate_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# 解析域名取第一个 A 记录 IPv4；失败返回非 0
resolve_domain() {
    local domain="$1" ip=""
    # 优先用 getent（走系统 resolver，内置缓存），其次 dig，最后 host
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
    fi
    if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
        ip=$(dig +short +time=3 +tries=2 A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    fi
    if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
        ip=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}')
    fi
    [ -z "$ip" ] && return 1
    echo "$ip"
}

# 检测包管理器：apt / dnf / yum
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    else echo unknown; fi
}

# 安装一个包（自动选包管理器）
install_pkg() {
    local pkg="$1"
    case $(detect_pkg_mgr) in
        apt) apt-get update -qq && apt-get install -y "$pkg" ;;
        dnf) dnf install -y "$pkg" ;;
        yum) yum install -y "$pkg" ;;
        *) echo -e "${RED}未识别包管理器，无法自动安装 $pkg${RESET}"; return 1 ;;
    esac
}

# 卸载一个包
remove_pkg() {
    local pkg="$1"
    case $(detect_pkg_mgr) in
        apt) apt-get remove --purge -y "$pkg" >/dev/null 2>&1; apt-get autoremove -y >/dev/null 2>&1 ;;
        dnf) dnf remove -y "$pkg" >/dev/null 2>&1 ;;
        yum) yum remove -y "$pkg" >/dev/null 2>&1 ;;
    esac
}

# 解析 forward.list 一行到 P_* 全局变量；空行/注释返回非 0
parse_rule() {
    local line="$1"
    [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && return 1
    IFS='|' read -r P_LPORT P_TARGET P_RPORT P_PROTO P_MODE P_COMMENT <<< "$line"
    # 字段缺失（迁移失败等情况）补默认
    [ -z "$P_PROTO" ] && P_PROTO="tcp+udp"
    [ -z "$P_MODE" ]  && P_MODE="ip"
    return 0
}

# 备注里禁止 | 和换行，多余空白压缩
sanitize_comment() {
    local s="$1"
    s="${s//|/／}"     # 用全角斜杠替换，避免破坏字段分隔
    s="${s//$'\n'/ }"
    echo "$s"
}

# =========================================================
# --- [3. 旧格式迁移] ---
# =========================================================
migrate_old_format() {
    [ ! -s "$CONFIG_FILE" ] && return 0
    # 已是新格式（含 |）就跳过
    if head -1 "$CONFIG_FILE" | grep -q '|'; then
        return 0
    fi
    echo -e "${YELLOW}检测到旧版 3 段空格格式，正在自动迁移为 v5 六段格式...${RESET}"
    log_msg INFO MIGRATE "开始迁移 forward.list 旧格式"
    backup_file "$CONFIG_FILE"

    local tmp
    tmp=$(mktemp)
    local count=0
    while read -r l_port r_ip r_port _; do
        [ -z "$l_port" ] && continue
        # 旧数据全部按 IP 模式 + tcp+udp + 空备注 迁移
        printf '%s|%s|%s|%s|%s|%s\n' "$l_port" "$r_ip" "$r_port" "tcp+udp" "ip" "" >> "$tmp"
        ((count++))
    done < "$CONFIG_FILE"
    mv "$tmp" "$CONFIG_FILE"
    log_msg INFO MIGRATE "迁移完成，共 $count 条"
    echo -e "${GREEN}✅ 迁移完成（$count 条），原文件已备份到 ${BACKUP_DIR}${RESET}"
    sleep 1
}

# =========================================================
# --- [4. 域名解析缓存] ---
# =========================================================

# 写缓存
cache_set() {
    local domain="$1" ip="$2"
    local tmp
    tmp=$(mktemp)
    # 删除旧记录后写新记录
    grep -v "^${domain}|" "$RESOLVER_CACHE" 2>/dev/null > "$tmp" || true
    printf '%s|%s|%s\n' "$domain" "$ip" "$(date +%s)" >> "$tmp"
    mv "$tmp" "$RESOLVER_CACHE"
}

# 读缓存中域名对应的 IP；无则空
cache_get() {
    local domain="$1"
    [ -f "$RESOLVER_CACHE" ] || return 1
    awk -F'|' -v d="$domain" '$1==d {print $2; exit}' "$RESOLVER_CACHE"
}

# 解析目标字段为实际 IP（处理三种模式）
resolve_target_ip() {
    local target="$1" mode="$2"
    case "$mode" in
        ip|static)
            # static 模式：forward.list 里目标字段就是创建时解析的 IP
            echo "$target"
            return 0
            ;;
        dynamic)
            local cached
            cached=$(cache_get "$target")
            if [ -n "$cached" ]; then
                echo "$cached"
                return 0
            fi
            # 缓存缺失时即时解析一次
            local ip
            if ip=$(resolve_domain "$target"); then
                cache_set "$target" "$ip"
                echo "$ip"
                return 0
            fi
            return 1
            ;;
        *)
            echo "$target"
            return 0
            ;;
    esac
}

# =========================================================
# --- [5. 转发规则核心] ---
# =========================================================

generate_whitelist_action() {
    # 按协议分别收集端口，避免对纯 TCP 规则也 drop UDP
    local tcp_ports="" udp_ports="" line
    while IFS= read -r line; do
        parse_rule "$line" || continue
        case "$P_PROTO" in
            tcp)      tcp_ports+="${P_LPORT}," ;;
            udp)      udp_ports+="${P_LPORT}," ;;
            tcp+udp)  tcp_ports+="${P_LPORT},"; udp_ports+="${P_LPORT}," ;;
        esac
    done < "$CONFIG_FILE"
    tcp_ports="${tcp_ports%,}"
    udp_ports="${udp_ports%,}"

    {
        echo "        # 核心防御：白名单与临时访客放行"
        echo "        ip saddr \$ALLOWED_CIDRS accept"
        echo "        ip saddr @temp_ips accept"
        [ -n "$tcp_ports" ] && echo "        tcp dport { $tcp_ports } drop"
        [ -n "$udp_ports" ] && echo "        udp dport { $udp_ports } drop"
        [ -z "$tcp_ports$udp_ports" ] && echo "        # 当前没有任何转发端口，白名单无生效目标"
    } > "$ACTION_FILE"
}

list_rules() {
    echo -e "\n${CYAN}--- 🚀 当前转发规则 ---${RESET}"
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}目前没有任何转发规则。${RESET}"
        echo "------------------------------------------------------------------------"
        return
    fi
    printf "${BOLD}%-4s %-7s %-30s %-7s %-9s %-8s %s${RESET}\n" \
        "序号" "本地" "目标" "目标端" "协议" "模式" "备注"
    echo "------------------------------------------------------------------------"
    local idx=1 line
    while IFS= read -r line; do
        parse_rule "$line" || continue
        local target_show="$P_TARGET"
        # 域名+动态模式时附带显示解析到的 IP
        if [ "$P_MODE" = "dynamic" ]; then
            local rip
            rip=$(cache_get "$P_TARGET")
            [ -n "$rip" ] && target_show="${P_TARGET}(${rip})"
        fi
        # 截断显示，避免破坏对齐
        local target_disp="${target_show:0:29}"
        local comment_disp="${P_COMMENT:0:30}"
        printf "[%-2s] %-7s %-30s %-7s %-9s %-8s %s\n" \
            "$idx" "$P_LPORT" "$target_disp" "$P_RPORT" "$P_PROTO" "$P_MODE" "$comment_disp"
        ((idx++))
    done < "$CONFIG_FILE"
    echo "------------------------------------------------------------------------"
}

# 根据 CONFIG_FILE 生成 rules.nft 并热加载
apply_rules() {
    backup_file "$RULES_FILE"
    {
        echo "table ip nf_manager_nat"
        echo "flush table ip nf_manager_nat"
        echo ""
        echo "table ip nf_manager_nat {"
        echo "    chain prerouting {"
        echo "        type nat hook prerouting priority dstnat; policy accept;"
    } > "$RULES_FILE"

    local line resolved_ips=""
    while IFS= read -r line; do
        parse_rule "$line" || continue
        local rip
        if ! rip=$(resolve_target_ip "$P_TARGET" "$P_MODE"); then
            echo -e "${YELLOW}⚠️  规则 ${P_LPORT} -> ${P_TARGET} 解析失败，本次跳过${RESET}"
            log_msg WARN APPLY "规则 ${P_LPORT}->${P_TARGET} 解析失败，跳过"
            continue
        fi
        case "$P_PROTO" in
            tcp)
                echo "        tcp dport $P_LPORT dnat to ${rip}:${P_RPORT}" >> "$RULES_FILE"
                ;;
            udp)
                echo "        udp dport $P_LPORT dnat to ${rip}:${P_RPORT}" >> "$RULES_FILE"
                ;;
            tcp+udp|*)
                echo "        tcp dport $P_LPORT dnat to ${rip}:${P_RPORT}" >> "$RULES_FILE"
                echo "        udp dport $P_LPORT dnat to ${rip}:${P_RPORT}" >> "$RULES_FILE"
                ;;
        esac
        resolved_ips+="${rip}\n"
    done < "$CONFIG_FILE"

    {
        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority srcnat; policy accept;"
    } >> "$RULES_FILE"

    # 同一目标 IP 只生成一条 masquerade
    if [ -n "$resolved_ips" ]; then
        echo -e "$resolved_ips" | sort -u | while read -r rip; do
            [ -n "$rip" ] && echo "        ip daddr $rip masquerade" >> "$RULES_FILE"
        done
    fi
    echo "    }" >> "$RULES_FILE"
    echo "}" >> "$RULES_FILE"

    # 白名单开启时同步刷新拦截端口
    local status
    status=$(cat "$STATUS_FILE" 2>/dev/null)
    [ "$status" = "ON" ] && generate_whitelist_action

    # 加载并把错误显示出来（之前的版本静默吞了，排障困难）
    local nft_err
    if ! nft_err=$(nft -f "$MAIN_CONF" 2>&1); then
        echo -e "${RED}❌ 规则加载失败：${RESET}"
        echo -e "${RED}${nft_err}${RESET}"
        log_msg ERROR APPLY "nft -f 失败: ${nft_err}"
        return 1
    fi
    log_msg INFO APPLY "规则热加载成功"
    echo -e "${GREEN}✅ 转发规则已热加载至内核！${RESET}"
}

# 添加规则的交互流程
add_rule() {
    echo -e "\n${CYAN}--- ➕ 添加新转发规则 ---${RESET}"
    local l_port r_port target proto mode comment input_domain

    # 本地端口
    while true; do
        read -p "请输入 [本地监听端口] (1-65535): " l_port
        validate_port "$l_port" || { echo -e "${RED}端口非法${RESET}"; continue; }
        if grep -qE "^${l_port}\|" "$CONFIG_FILE"; then
            echo -e "${RED}端口 ${l_port} 已存在！${RESET}"; continue
        fi
        if ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE ":${l_port}$"; then
            echo -e "${YELLOW}⚠️  端口 ${l_port} 当前被本机其他进程监听，仍可建立 DNAT 但本机访问会冲突${RESET}"
            read -p "继续? (y/N): " yn
            [ "$yn" != "y" ] && [ "$yn" != "Y" ] && continue
        fi
        break
    done

    # 目标：先选模式再录入
    echo "请选择目标类型："
    echo "  1) 固定 IP (默认)"
    echo "  2) 域名 - 静态：脚本解析一次，之后当 IP 用，IP 变了不跟随"
    echo "  3) 域名 - 动态 DDNS：后台定时解析，IP 变了自动热重载"
    read -p "选择 [1-3，默认1]: " tchoice
    [ -z "$tchoice" ] && tchoice=1

    case "$tchoice" in
        1)
            while true; do
                read -p "请输入 [目标 IPv4]: " target
                validate_ipv4 "$target" && break
                echo -e "${RED}IP 格式非法${RESET}"
            done
            mode="ip"
            ;;
        2)
            while true; do
                read -p "请输入 [目标域名]: " input_domain
                validate_domain "$input_domain" || { echo -e "${RED}域名格式非法${RESET}"; continue; }
                echo -e "${CYAN}正在解析 $input_domain ...${RESET}"
                if target=$(resolve_domain "$input_domain"); then
                    echo -e "${GREEN}解析成功：$input_domain -> $target${RESET}"
                    break
                fi
                echo -e "${RED}解析失败，请检查域名或 DNS${RESET}"
            done
            mode="static"
            ;;
        3)
            while true; do
                read -p "请输入 [目标域名]: " input_domain
                validate_domain "$input_domain" || { echo -e "${RED}域名格式非法${RESET}"; continue; }
                echo -e "${CYAN}首次解析 $input_domain ...${RESET}"
                local first_ip
                if first_ip=$(resolve_domain "$input_domain"); then
                    echo -e "${GREEN}首次解析：$input_domain -> $first_ip${RESET}"
                    cache_set "$input_domain" "$first_ip"
                    target="$input_domain"
                    mode="dynamic"
                    break
                fi
                echo -e "${RED}解析失败，无法添加 dynamic 规则${RESET}"
                read -p "重试? (y/N): " yn
                [ "$yn" != "y" ] && [ "$yn" != "Y" ] && return
            done
            ;;
        *)
            echo -e "${RED}非法选择${RESET}"; sleep 1; return
            ;;
    esac

    # 目标端口
    while true; do
        read -p "请输入 [目标端口] (1-65535): " r_port
        validate_port "$r_port" && break
        echo -e "${RED}端口非法${RESET}"
    done

    # 协议
    echo "请选择协议："
    echo "  1) TCP+UDP (默认)"
    echo "  2) 仅 TCP"
    echo "  3) 仅 UDP"
    read -p "选择 [1-3，默认1]: " pchoice
    case "$pchoice" in
        2) proto="tcp" ;;
        3) proto="udp" ;;
        *) proto="tcp+udp" ;;
    esac

    # 备注
    read -p "备注（回车跳过）: " comment
    comment=$(sanitize_comment "$comment")

    # 落盘前备份配置
    backup_file "$CONFIG_FILE"
    printf '%s|%s|%s|%s|%s|%s\n' "$l_port" "$target" "$r_port" "$proto" "$mode" "$comment" >> "$CONFIG_FILE"
    log_msg INFO ADD "$l_port -> $target:$r_port $proto $mode 备注=${comment:--}"

    apply_rules
    # 动态规则可能需要启动 resolver timer
    sync_resolver_state
    sleep 1
}

delete_rule() {
    list_rules
    [ ! -s "$CONFIG_FILE" ] && { sleep 1; return; }
    read -p "请输入要删除的序号 (0取消，支持逗号分隔多选): " del_input
    [ "$del_input" = "0" ] || [ -z "$del_input" ] && return

    # 解析有效行的序号 -> 真实行号映射
    local -a line_map=()
    local real_line=0 idx=0 line
    while IFS= read -r line; do
        ((real_line++))
        parse_rule "$line" || continue
        ((idx++))
        line_map[$idx]=$real_line
    done < "$CONFIG_FILE"

    # 拆分逗号 / 空格输入
    local -a to_delete=()
    local item
    for item in ${del_input//,/ }; do
        if [[ "$item" =~ ^[0-9]+$ ]] && [ -n "${line_map[$item]:-}" ]; then
            to_delete+=("${line_map[$item]}")
        else
            echo -e "${RED}忽略非法序号: $item${RESET}"
        fi
    done
    [ ${#to_delete[@]} -eq 0 ] && { echo -e "${YELLOW}没有有效的删除项${RESET}"; sleep 1; return; }

    backup_file "$CONFIG_FILE"
    # 按真实行号从大到小删，避免行号偏移
    local sorted
    sorted=$(printf '%s\n' "${to_delete[@]}" | sort -rn)
    local removed_logs=""
    while read -r ln; do
        local raw
        raw=$(sed -n "${ln}p" "$CONFIG_FILE")
        removed_logs+="${raw}\n"
        sed -i "${ln}d" "$CONFIG_FILE"
    done <<< "$sorted"

    log_msg INFO DELETE "$(echo -e "$removed_logs" | tr '\n' ';')"
    apply_rules
    sync_resolver_state
    echo -e "${GREEN}已删除 ${#to_delete[@]} 条规则${RESET}"
    sleep 1
}

edit_rule() {
    list_rules
    [ ! -s "$CONFIG_FILE" ] && { sleep 1; return; }
    read -p "请输入要编辑的序号 (0取消): " edit_idx
    [ "$edit_idx" = "0" ] || [ -z "$edit_idx" ] && return
    [[ ! "$edit_idx" =~ ^[0-9]+$ ]] && { echo -e "${RED}序号非法${RESET}"; sleep 1; return; }

    # 找到该序号对应的真实行
    local real_line=0 idx=0 found="" line
    while IFS= read -r line; do
        ((real_line++))
        parse_rule "$line" || continue
        ((idx++))
        if [ "$idx" = "$edit_idx" ]; then
            found="$line"
            break
        fi
    done < "$CONFIG_FILE"

    [ -z "$found" ] && { echo -e "${RED}序号不存在${RESET}"; sleep 1; return; }
    parse_rule "$found" || { echo -e "${RED}解析失败${RESET}"; sleep 1; return; }

    echo -e "\n${CYAN}当前值：${RESET}本地=$P_LPORT 目标=$P_TARGET 目标端口=$P_RPORT 协议=$P_PROTO 模式=$P_MODE 备注=$P_COMMENT"
    echo "（回车保留原值）"

    local new_target="$P_TARGET" new_rport="$P_RPORT" new_proto="$P_PROTO" new_comment="$P_COMMENT" v

    read -p "新目标 IP/域名 [$P_TARGET]: " v
    [ -n "$v" ] && new_target="$v"

    read -p "新目标端口 [$P_RPORT]: " v
    if [ -n "$v" ]; then
        validate_port "$v" || { echo -e "${RED}端口非法${RESET}"; sleep 1; return; }
        new_rport="$v"
    fi

    read -p "新协议 (tcp/udp/tcp+udp) [$P_PROTO]: " v
    [ -n "$v" ] && new_proto="$v"
    case "$new_proto" in tcp|udp|tcp+udp) ;; *) echo -e "${RED}协议非法${RESET}"; sleep 1; return ;; esac

    read -p "新备注 [$P_COMMENT]: " v
    if [ -n "$v" ]; then new_comment=$(sanitize_comment "$v"); fi

    backup_file "$CONFIG_FILE"
    local new_line
    new_line=$(printf '%s|%s|%s|%s|%s|%s' "$P_LPORT" "$new_target" "$new_rport" "$new_proto" "$P_MODE" "$new_comment")
    # 用 awk 安全替换指定行（避免 sed 特殊字符转义麻烦）
    awk -v ln="$real_line" -v repl="$new_line" 'NR==ln{print repl; next} {print}' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    log_msg INFO EDIT "$found  =>  $new_line"
    apply_rules
    sync_resolver_state
    sleep 1
}

# 批量端口段添加，简化中转配置
batch_add_rules() {
    echo -e "\n${CYAN}--- 📦 批量添加端口段 ---${RESET}"
    local start_p end_p target r_start proto mode comment input_domain fip

    read -p "本地端口起始: " start_p
    validate_port "$start_p" || { echo -e "${RED}非法${RESET}"; sleep 1; return; }
    read -p "本地端口结束: " end_p
    validate_port "$end_p" || { echo -e "${RED}非法${RESET}"; sleep 1; return; }
    [ "$end_p" -lt "$start_p" ] && { echo -e "${RED}结束端口需 >= 起始${RESET}"; sleep 1; return; }
    [ $((end_p - start_p)) -gt 200 ] && { echo -e "${YELLOW}超过 200 个端口，请分批${RESET}"; sleep 1; return; }

    read -p "目标 IP/域名: " input_domain
    if validate_ipv4 "$input_domain"; then
        target="$input_domain"
        mode="ip"
    elif validate_domain "$input_domain"; then
        echo "  1) 静态域名 (默认)  2) 动态 DDNS"
        read -p "选择 [1-2]: " mc
        if [ "$mc" = "2" ]; then
            fip=$(resolve_domain "$input_domain") || { echo -e "${RED}解析失败${RESET}"; sleep 1; return; }
            cache_set "$input_domain" "$fip"
            target="$input_domain"
            mode="dynamic"
        else
            fip=$(resolve_domain "$input_domain") || { echo -e "${RED}解析失败${RESET}"; sleep 1; return; }
            target="$fip"
            mode="static"
        fi
    else
        echo -e "${RED}目标格式非法${RESET}"; sleep 1; return
    fi

    read -p "目标端口起始（保持区间对齐）: " r_start
    validate_port "$r_start" || { echo -e "${RED}非法${RESET}"; sleep 1; return; }

    echo "  1) TCP+UDP (默认)  2) 仅 TCP  3) 仅 UDP"
    read -p "选择 [1-3]: " pc
    case "$pc" in 2) proto="tcp" ;; 3) proto="udp" ;; *) proto="tcp+udp" ;; esac

    read -p "备注（统一）: " comment
    comment=$(sanitize_comment "$comment")

    backup_file "$CONFIG_FILE"
    local p added=0 skipped=0
    for ((p=start_p; p<=end_p; p++)); do
        if grep -qE "^${p}\|" "$CONFIG_FILE"; then ((skipped++)); continue; fi
        local rp=$((r_start + p - start_p))
        printf '%s|%s|%s|%s|%s|%s\n' "$p" "$target" "$rp" "$proto" "$mode" "$comment" >> "$CONFIG_FILE"
        ((added++))
    done
    log_msg INFO BATCH "起始=$start_p 结束=$end_p 添加=$added 跳过=$skipped"
    echo -e "${GREEN}添加 $added 条，跳过 $skipped 条已存在${RESET}"
    apply_rules
    sync_resolver_state
    sleep 1
}

# =========================================================
# --- [6. 域名 resolver 服务] ---
# =========================================================

# 当前是否存在任何 dynamic 规则
has_dynamic_rules() {
    [ -s "$CONFIG_FILE" ] || return 1
    awk -F'|' '$5=="dynamic" {found=1; exit} END {exit !found}' "$CONFIG_FILE"
}

# 根据是否还有 dynamic 规则自动安装/启停 resolver timer
sync_resolver_state() {
    if has_dynamic_rules; then
        install_resolver_unit
        systemctl enable --now nf_manager_resolver.timer >/dev/null 2>&1
        log_msg INFO RESOLVER "存在 dynamic 规则，已确保 timer 启用"
    else
        if [ -f "$RESOLVER_TIMER" ]; then
            systemctl disable --now nf_manager_resolver.timer >/dev/null 2>&1
            log_msg INFO RESOLVER "无 dynamic 规则，已停止 timer"
        fi
    fi
}

install_resolver_unit() {
    [ -f "$RESOLVER_TIMER" ] && [ -f "$RESOLVER_SERVICE" ] && return 0
    local interval
    interval=$(cat "$RESOLVER_INTERVAL_FILE" 2>/dev/null)
    [ -z "$interval" ] && interval=60

    cat > "$RESOLVER_SERVICE" << EOF
[Unit]
Description=NF-Manager DDNS Resolver tick
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nf --resolver-tick
EOF

    cat > "$RESOLVER_TIMER" << EOF
[Unit]
Description=Run NF-Manager DDNS resolver every ${interval}s

[Timer]
OnBootSec=30s
OnUnitActiveSec=${interval}s
AccuracySec=5s
Unit=nf_manager_resolver.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
}

# resolver 主逻辑：被 timer 触发或菜单手动触发
resolver_tick() {
    [ -s "$CONFIG_FILE" ] || exit 0
    local changed=0 line
    while IFS= read -r line; do
        parse_rule "$line" || continue
        [ "$P_MODE" = "dynamic" ] || continue

        local old_ip new_ip
        old_ip=$(cache_get "$P_TARGET")
        if ! new_ip=$(resolve_domain "$P_TARGET"); then
            log_msg WARN RESOLVE "$P_TARGET 解析失败，沿用旧IP=${old_ip:-空}"
            continue
        fi
        if [ "$new_ip" != "$old_ip" ]; then
            log_msg INFO RESOLVE "$P_TARGET ${old_ip:-空} -> $new_ip"
            cache_set "$P_TARGET" "$new_ip"
            changed=1
        fi
    done < "$CONFIG_FILE"

    if [ "$changed" = "1" ]; then
        log_msg INFO RESOLVE "检测到 IP 变化，触发 apply_rules"
        apply_rules >/dev/null 2>&1
    fi
}

manage_resolver() {
    echo -e "\n${CYAN}--- 🌐 DDNS 解析器管理 ---${RESET}"
    local interval
    interval=$(cat "$RESOLVER_INTERVAL_FILE" 2>/dev/null)
    [ -z "$interval" ] && interval=60

    local active="未安装"
    if [ -f "$RESOLVER_TIMER" ]; then
        if systemctl is-active --quiet nf_manager_resolver.timer; then
            active="${GREEN}运行中${RESET}"
        else
            active="${YELLOW}已安装但未启用${RESET}"
        fi
    fi

    local dynamic_count
    dynamic_count=$(awk -F'|' '$5=="dynamic"' "$CONFIG_FILE" 2>/dev/null | wc -l)

    echo -e "  Timer 状态：$active"
    echo -e "  解析间隔：${YELLOW}${interval}s${RESET}"
    echo -e "  Dynamic 规则数：${YELLOW}${dynamic_count}${RESET}"
    echo "------------------------------"
    echo "1) 立即触发一次解析检查"
    echo "2) 修改解析间隔"
    echo "3) 查看解析缓存"
    echo "4) 查看 resolver 日志"
    echo "0) 返回"
    read -p "选择: " c
    case "$c" in
        1)
            echo -e "${CYAN}执行中...${RESET}"
            resolver_tick
            echo -e "${GREEN}完成${RESET}"
            sleep 1
            ;;
        2)
            read -p "新间隔秒数 (建议 30-600): " n
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 10 ] && [ "$n" -le 3600 ] || { echo -e "${RED}范围非法${RESET}"; sleep 1; return; }
            echo "$n" > "$RESOLVER_INTERVAL_FILE"
            rm -f "$RESOLVER_TIMER" "$RESOLVER_SERVICE"
            sync_resolver_state
            echo -e "${GREEN}已更新${RESET}"
            sleep 1
            ;;
        3)
            if [ -s "$RESOLVER_CACHE" ]; then
                echo -e "${CYAN}域名 | 当前IP | 最后更新${RESET}"
                while IFS='|' read -r d ip ts; do
                    [ -z "$d" ] && continue
                    printf "%s | %s | %s\n" "$d" "$ip" "$(date -d "@$ts" '+%F %T' 2>/dev/null || echo "$ts")"
                done < "$RESOLVER_CACHE"
            else
                echo -e "${YELLOW}缓存为空${RESET}"
            fi
            echo "按任意键返回..."; read -n 1 -s
            ;;
        4)
            if [ -f "$LOG_FILE" ]; then
                grep -E 'RESOLVE|RESOLVER' "$LOG_FILE" | tail -30
            else
                echo -e "${YELLOW}暂无日志${RESET}"
            fi
            echo "按任意键返回..."; read -n 1 -s
            ;;
    esac
}

# =========================================================
# --- [7. 防御 / 调优（原有功能改造）] ---
# =========================================================

edit_whitelist() {
    backup_file "$WHITELIST_DEF"
    ${EDITOR:-nano} "$WHITELIST_DEF"
    echo -e "\n${CYAN}正在语法检查...${RESET}"
    local err
    if err=$(nft -c -f "$MAIN_CONF" 2>&1); then
        nft -f "$MAIN_CONF" && echo -e "${GREEN}✅ 白名单已重载${RESET}"
        log_msg INFO WHITELIST "编辑后重载成功"
    else
        echo -e "${RED}❌ 语法错误：${err}${RESET}"
        echo -e "${RED}已拒绝重载，请修复后再试${RESET}"
        log_msg ERROR WHITELIST "语法错误: $err"
    fi
    echo "按任意键返回..."; read -n 1 -s
}

toggle_whitelist() {
    local status
    status=$(cat "$STATUS_FILE" 2>/dev/null)
    if [ "$status" = "ON" ]; then
        echo "" > "$ACTION_FILE"
        echo "OFF" > "$STATUS_FILE"
        nft -f "$MAIN_CONF" && echo -e "${GREEN}🔓 白名单已关闭${RESET}"
        log_msg INFO WHITELIST "已关闭"
    else
        generate_whitelist_action
        echo "ON" > "$STATUS_FILE"
        nft -f "$MAIN_CONF" && echo -e "${RED}🛡️ 白名单已开启${RESET}"
        log_msg INFO WHITELIST "已开启"
    fi
    sleep 1
}

view_temp_ips() {
    echo -e "\n${CYAN}--- ⏳ 临时放行名单 ---${RESET}"
    local info
    info=$(nft list set ip filter temp_ips 2>/dev/null)
    if [ -z "$info" ]; then
        echo -e "${YELLOW}temp_ips 集合不存在${RESET}"
    elif echo "$info" | grep -q "elements = { }"; then
        echo -e "${GREEN}当前无临时放行 IP${RESET}"
    else
        echo "$info" | grep "expires" | sed 's/elements = { //g; s/ }//g' | tr ',' '\n' | while read -r line; do
            [ -n "$line" ] && echo " 🔓 $line"
        done
    fi
    echo "按任意键返回..."; read -n 1 -s
}

manage_mss() {
    local status current_val
    status=$(cat "$MSS_STATUS_FILE" 2>/dev/null)
    current_val=$(cat "$MSS_VALUE_FILE" 2>/dev/null)
    [ -z "$current_val" ] && current_val="1338"

    echo -e "\n${CYAN}--- 🛠️ MTU/MSS 钳制 ---${RESET}"
    echo -e "状态: $([ "$status" = "ON" ] && echo -e "${GREEN}开启${RESET}" || echo -e "${RED}关闭${RESET}")"
    echo -e "数值: ${YELLOW}$current_val${RESET}"
    echo "1) 切换 开/关"
    echo "2) 修改数值"
    echo "0) 返回"
    read -p "选择: " mc
    case "$mc" in
        1)
            if [ "$status" = "ON" ]; then
                echo "" > "$MSS_FILE"
                echo "OFF" > "$MSS_STATUS_FILE"
                log_msg INFO MSS "已关闭"
            else
                echo "tcp flags syn tcp option maxseg size set $current_val" > "$MSS_FILE"
                echo "ON" > "$MSS_STATUS_FILE"
                log_msg INFO MSS "已开启 size=$current_val"
            fi
            nft -f "$MAIN_CONF" && echo -e "${GREEN}已生效${RESET}"
            sleep 1
            ;;
        2)
            read -p "新数值 (1200-1500): " new_val
            [[ "$new_val" =~ ^[0-9]+$ ]] && [ "$new_val" -ge 1200 ] && [ "$new_val" -le 1500 ] || { echo -e "${RED}范围非法${RESET}"; sleep 1; return; }
            echo "$new_val" > "$MSS_VALUE_FILE"
            if [ "$status" = "ON" ]; then
                echo "tcp flags syn tcp option maxseg size set $new_val" > "$MSS_FILE"
                nft -f "$MAIN_CONF"
            fi
            log_msg INFO MSS "数值改为 $new_val"
            echo -e "${GREEN}已更新${RESET}"
            sleep 1
            ;;
    esac
}

# =========================================================
# --- [8. 系统诊断] ---
# =========================================================

print_check() {
    # $1=状态符号 OK/FAIL/WARN  $2=描述  $3=详情
    local marker
    case "$1" in
        OK)   marker="${GREEN}[✓]${RESET}" ;;
        FAIL) marker="${RED}[✗]${RESET}" ;;
        WARN) marker="${YELLOW}[!]${RESET}" ;;
    esac
    # 描述列统一补齐到显示宽度 36，详情从同一列开始
    printf '  %b %s  %s\n' "$marker" "$(pad_display "$2" 36)" "$3"
}

diagnose() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║                   NF-Manager 系统诊断                      ║${RESET}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${RESET}"

    # --- 1. 内核转发参数 ---
    echo -e "\n${BOLD}[1/7] 内核转发参数${RESET}"
    local v4_fwd v6_fwd rp_filter route_localnet
    v4_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    v6_fwd=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)
    rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
    route_localnet=$(sysctl -n net.ipv4.conf.all.route_localnet 2>/dev/null)

    if [ "$v4_fwd" = "1" ]; then
        print_check OK "net.ipv4.ip_forward" "= 1"
    else
        print_check FAIL "net.ipv4.ip_forward" "= ${v4_fwd:-?} (应为 1)"
    fi
    if [ "$v6_fwd" = "1" ]; then
        print_check OK "net.ipv6.conf.all.forwarding" "= 1"
    else
        print_check WARN "net.ipv6.conf.all.forwarding" "= ${v6_fwd:-?} (如不用 v6 可忽略)"
    fi
    if [ "$rp_filter" = "2" ] || [ "$rp_filter" = "0" ]; then
        print_check OK "net.ipv4.conf.all.rp_filter" "= $rp_filter (转发友好)"
    else
        print_check WARN "net.ipv4.conf.all.rp_filter" "= $rp_filter (严格模式可能拦非对称路由)"
    fi
    if [ "$route_localnet" = "1" ]; then
        print_check OK "net.ipv4.conf.all.route_localnet" "= 1 (允许 DNAT 到 127.0.0.0/8)"
    else
        print_check WARN "net.ipv4.conf.all.route_localnet" "= ${route_localnet:-?} (转发到本机回环时需开启)"
    fi

    # 持久化检查
    if grep -rqE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null; then
        print_check OK "sysctl 持久化" "已写入"
    else
        print_check WARN "sysctl 持久化" "未写入，重启后可能失效"
    fi

    # --- 2. nftables 安装与自启 ---
    echo -e "\n${BOLD}[2/7] nftables 状态${RESET}"
    if command -v nft >/dev/null 2>&1; then
        print_check OK "nft 命令" "$(nft --version 2>/dev/null | head -1)"
    else
        print_check FAIL "nft 命令" "未安装"
    fi
    if systemctl is-enabled nftables >/dev/null 2>&1; then
        print_check OK "nftables.service 开机自启" "enabled"
    else
        print_check FAIL "nftables.service 开机自启" "未启用，重启后规则不会自动加载"
    fi
    if systemctl is-active nftables >/dev/null 2>&1; then
        print_check OK "nftables.service 当前运行" "active"
    else
        print_check WARN "nftables.service 当前运行" "inactive（规则可能仍在内核中）"
    fi

    # --- 3. 转发规则加载状态 ---
    echo -e "\n${BOLD}[3/7] 转发规则加载状态${RESET}"
    local cfg_count loaded_count
    cfg_count=$(awk -F'|' 'NF>=3 && $1!~/^[[:space:]]*#/ && $1!=""' "$CONFIG_FILE" 2>/dev/null | wc -l)
    loaded_count=$(nft list table ip nf_manager_nat 2>/dev/null | grep -c 'dnat to')

    print_check OK "配置文件规则数" "$cfg_count"
    if [ "$cfg_count" -eq 0 ]; then
        print_check OK "内核加载数" "$loaded_count（无规则配置）"
    else
        # 估算应有的内核条数（按协议算 1 或 2）
        local expected=0 line
        while IFS= read -r line; do
            parse_rule "$line" || continue
            case "$P_PROTO" in tcp|udp) ((expected++)) ;; *) ((expected+=2)) ;; esac
        done < "$CONFIG_FILE"
        if [ "$loaded_count" -eq "$expected" ]; then
            print_check OK "内核加载数" "$loaded_count / 应有 $expected"
        else
            print_check WARN "内核加载数" "$loaded_count / 应有 $expected（可能存在解析失败的 dynamic 规则）"
        fi
    fi

    # --- 4. 其他防火墙冲突 ---
    echo -e "\n${BOLD}[4/7] 其他防火墙冲突检测${RESET}"
    local fw_found=0
    if systemctl is-active --quiet ufw 2>/dev/null; then
        print_check FAIL "ufw" "运行中，建议 systemctl disable --now ufw"
        fw_found=1
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        print_check FAIL "firewalld" "运行中，建议 systemctl disable --now firewalld"
        fw_found=1
    fi
    if command -v iptables >/dev/null 2>&1; then
        if iptables -t nat -L -n 2>/dev/null | grep -qE 'DOCKER|DNAT'; then
            print_check WARN "iptables nat 表" "检测到非空规则（Docker / iptables-services 等），可能干扰转发"
            fw_found=1
        fi
    fi
    [ $fw_found -eq 0 ] && print_check OK "其他防火墙" "未检测到冲突"

    # --- 5. 现有转发连通性测试 ---
    echo -e "\n${BOLD}[5/7] 转发规则连通性测试（TCP，超时 3s）${RESET}"
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "  ${YELLOW}无规则可测${RESET}"
    else
        local line
        while IFS= read -r line; do
            parse_rule "$line" || continue
            local rip
            if ! rip=$(resolve_target_ip "$P_TARGET" "$P_MODE" 2>/dev/null); then
                print_check FAIL "${P_LPORT} -> ${P_TARGET}:${P_RPORT}" "目标无法解析"
                continue
            fi
            case "$P_PROTO" in
                udp)
                    print_check WARN "${P_LPORT} -> ${rip}:${P_RPORT} (udp)" "UDP 无法可靠探测，跳过"
                    ;;
                *)
                    if timeout 3 bash -c "</dev/tcp/${rip}/${P_RPORT}" 2>/dev/null; then
                        print_check OK "${P_LPORT} -> ${rip}:${P_RPORT} (tcp)" "可达"
                    else
                        print_check FAIL "${P_LPORT} -> ${rip}:${P_RPORT} (tcp)" "不可达"
                    fi
                    ;;
            esac
        done < "$CONFIG_FILE"
    fi

    # --- 6. conntrack 水位 ---
    echo -e "\n${BOLD}[6/7] conntrack 连接追踪表${RESET}"
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ] && [ -r /proc/sys/net/nf_conntrack_max ]; then
        local cur max pct
        cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
        max=$(cat /proc/sys/net/nf_conntrack_max)
        pct=$((cur * 100 / max))
        if [ $pct -ge 80 ]; then
            print_check FAIL "conntrack 使用率" "$cur / $max ($pct%) - 接近爆表，扩容: sysctl -w net.nf_conntrack_max=…"
        elif [ $pct -ge 50 ]; then
            print_check WARN "conntrack 使用率" "$cur / $max ($pct%)"
        else
            print_check OK "conntrack 使用率" "$cur / $max ($pct%)"
        fi
    else
        print_check WARN "conntrack" "内核未加载 nf_conntrack 模块"
    fi

    # --- 7. resolver 状态 ---
    echo -e "\n${BOLD}[7/7] DDNS Resolver 状态${RESET}"
    if has_dynamic_rules; then
        if [ -f "$RESOLVER_TIMER" ] && systemctl is-active --quiet nf_manager_resolver.timer; then
            print_check OK "resolver timer" "运行中"
            local interval
            interval=$(cat "$RESOLVER_INTERVAL_FILE" 2>/dev/null || echo 60)
            print_check OK "解析间隔" "${interval}s"
        else
            print_check FAIL "resolver timer" "存在 dynamic 规则但 timer 未运行，运行: nf 菜单->DDNS 管理"
        fi
        # 缓存陈旧度
        if [ -s "$RESOLVER_CACHE" ]; then
            local oldest_age
            oldest_age=$(awk -F'|' -v now="$(date +%s)" '{age=now-$3; if(age>max) max=age} END {print max+0}' "$RESOLVER_CACHE")
            if [ "$oldest_age" -gt 600 ]; then
                print_check WARN "最旧缓存条目" "${oldest_age}s 未更新"
            else
                print_check OK "缓存新鲜度" "最旧 ${oldest_age}s 前"
            fi
        fi
    else
        print_check OK "resolver" "当前无 dynamic 规则，timer 未启用（正常）"
    fi

    echo
    echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
    echo "按任意键返回..."; read -n 1 -s
}

# =========================================================
# --- [9. 导出/导入] ---
# =========================================================

export_config() {
    local out="/root/nf_manager_export_$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "# NF-Manager 导出 $(date)"
        echo "# 格式: 本地端口|目标|目标端口|协议|模式|备注"
        cat "$CONFIG_FILE" 2>/dev/null
    } > "$out"
    echo -e "${GREEN}已导出到 $out${RESET}"
    log_msg INFO EXPORT "$out"
    sleep 2
}

import_config() {
    read -p "请输入导入文件绝对路径: " src
    [ ! -f "$src" ] && { echo -e "${RED}文件不存在${RESET}"; sleep 1; return; }
    backup_file "$CONFIG_FILE"
    # 过滤注释行
    grep -vE '^[[:space:]]*#' "$src" | grep -E '\|' > "$CONFIG_FILE"
    log_msg INFO IMPORT "从 $src 导入"
    echo -e "${GREEN}导入完成，正在重载...${RESET}"
    apply_rules
    sync_resolver_state
    sleep 2
}

# =========================================================
# --- [10. 卸载（两档）] ---
# =========================================================

uninstall_panel_only() {
    clear
    echo -e "${YELLOW}═══════════════════════════════════════════${RESET}"
    echo -e "${YELLOW}  仅卸载脚本本身（保留服务/规则/数据）  ${RESET}"
    echo -e "${YELLOW}═══════════════════════════════════════════${RESET}"
    echo "此操作将："
    echo "  ✓ 移除 /usr/local/bin/nf 命令"
    echo "  ✗ 保留 /etc/nf_manager/ 目录与所有数据"
    echo "  ✗ 保留 /etc/nftables.conf 当前规则（继续生效）"
    echo "  ✗ 保留 systemd resolver 服务（如有）"
    echo "  ✗ 保留日志与 logrotate 配置"
    read -p "确认继续？(y/N): " y
    [ "$y" != "y" ] && [ "$y" != "Y" ] && { echo "已取消"; sleep 1; return; }
    rm -f /usr/local/bin/nf
    log_msg INFO UNINSTALL "仅卸载脚本本身"
    echo -e "${GREEN}✅ 已移除 nf 命令${RESET}"
    echo -e "${YELLOW}提示：下次想完全卸载请手动 rm -rf /etc/nf_manager 并恢复 /etc/nftables.conf${RESET}"
    exit 0
}

uninstall_full() {
    clear
    echo -e "${RED}═══════════════════════════════════════════════${RESET}"
    echo -e "${RED}  ⚠️ 完全卸载 NF-Manager（不可逆）  ⚠️ ${RESET}"
    echo -e "${RED}═══════════════════════════════════════════════${RESET}"
    echo "此操作将："
    echo "  ✓ 停止并删除 resolver systemd unit + timer"
    echo "  ✓ 恢复 /etc/nftables.conf 备份（如有）或重置为空"
    echo "  ✓ 删除 /etc/nf_manager/（含所有备份）"
    echo "  ✓ 删除 /etc/my_allow_ips.nft"
    echo "  ✓ 删除 /usr/local/bin/nf"
    echo "  ✓ 删除 /var/log/nf_manager.log 与 logrotate 配置"
    echo "  ✓ 删除 /etc/sysctl.d/99-nf_manager.conf（内核转发持久化）"
    echo
    echo -e "  ${YELLOW}? 最后一步会询问是否同时卸载 nftables 软件包（默认保留）${RESET}"
    echo
    read -p "确认继续？(yes 完整输入): " y
    [ "$y" != "yes" ] && { echo "已取消"; sleep 1; return; }

    echo -e "\n${CYAN}[1/6] 停止 resolver 服务...${RESET}"
    if [ -f "$RESOLVER_TIMER" ]; then
        systemctl disable --now nf_manager_resolver.timer >/dev/null 2>&1
    fi
    rm -f "$RESOLVER_SERVICE" "$RESOLVER_TIMER"
    systemctl daemon-reload >/dev/null 2>&1

    echo -e "${CYAN}[2/6] 恢复 nftables 主配置...${RESET}"
    # 从 backups 找最早的 nftables.conf 备份恢复（最初装时的）
    local oldest_bak
    oldest_bak=$(find "$BACKUP_DIR" -maxdepth 1 -name 'nftables.conf.*.bak' 2>/dev/null | sort | head -1)
    if [ -n "$oldest_bak" ]; then
        cp -a "$oldest_bak" "$MAIN_CONF"
        echo -e "  使用 $oldest_bak 恢复"
    elif [ -f "${MAIN_CONF}.bak" ]; then
        mv "${MAIN_CONF}.bak" "$MAIN_CONF"
        echo -e "  使用旧版 .bak 恢复"
    else
        printf '#!/usr/sbin/nft -f\nflush ruleset\n' > "$MAIN_CONF"
        echo -e "  无备份可用，已重置为空 ruleset"
    fi
    nft -f "$MAIN_CONF" >/dev/null 2>&1 || nft flush ruleset >/dev/null 2>&1

    echo -e "${CYAN}[3/6] 删除脚本数据目录...${RESET}"
    rm -rf "$DIR_PATH"
    rm -f "$WHITELIST_DEF"

    echo -e "${CYAN}[4/6] 移除 nf 命令...${RESET}"
    rm -f /usr/local/bin/nf

    echo -e "${CYAN}[5/6] 删除日志、logrotate 与 sysctl 配置...${RESET}"
    rm -f "$LOGROTATE_CONF"
    rm -f /var/log/nf_manager.log*
    rm -f /etc/sysctl.d/99-nf_manager.conf

    echo -e "${CYAN}[6/6] 是否一并卸载 nftables 软件包?${RESET}"
    echo -e "${YELLOW}  ⚠️  注意：卸载后机器将完全没有防火墙，且其它服务（如 docker、k8s）可能依赖它${RESET}"
    read -p "  确认卸载 nftables 包? (y/N): " purge
    if [ "$purge" = "y" ] || [ "$purge" = "Y" ]; then
        remove_pkg nftables
        echo -e "  ${GREEN}已卸载 nftables${RESET}"
    else
        echo -e "  ${CYAN}已保留 nftables 包${RESET}"
    fi

    echo -e "\n${GREEN}✅ 完全卸载完成，系统已恢复${RESET}"
    exit 0
}

# =========================================================
# --- [11. 初始化] ---
# =========================================================

ensure_persistent_sysctl() {
    # 确保转发相关内核参数持久化，避免重启失效
    local conf="/etc/sysctl.d/99-nf_manager.conf"
    if [ ! -f "$conf" ]; then
        cat > "$conf" << 'EOF'
# Managed by NF-Manager
# ---- IPv4 转发（NAT/DNAT 必需） ----
net.ipv4.ip_forward = 1

# ---- IPv6 转发（用 v6 中转才需要；脚本目前 dnat 仅生成 v4 表，开着无副作用） ----
net.ipv6.conf.all.forwarding = 1

# ---- 反向路径过滤（防 IP 欺骗） ----
#   1 严格：包从哪个接口进，回流必须走同接口，否则丢弃
#          多网卡 / 非对称路由的中转机会误杀合法包
#   2 宽松：只要能从任一接口返回就放行 → 适合 NAT / 转发场景
net.ipv4.conf.all.rp_filter = 2

# ---- 允许 DNAT 目标地址落在 127.0.0.0/8 ----
#   默认禁止；若需要把外部流量转发到本机回环服务（如本机的 socks/proxy）必须开启
net.ipv4.conf.all.route_localnet = 1
EOF
        sysctl -p "$conf" >/dev/null 2>&1
        log_msg INFO INIT "已写入 sysctl 持久化 $conf"
    fi
}

install_logrotate() {
    [ -f "$LOGROTATE_CONF" ] && return 0
    cat > "$LOGROTATE_CONF" << 'EOF'
/var/log/nf_manager.log {
    weekly
    rotate 7
    size 1M
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
}

init_env() {
    [ "$EUID" -ne 0 ] && err_exit "请用 root 运行"

    mkdir -p "$DIR_PATH" "$BACKUP_DIR"
    touch "$CONFIG_FILE"
    [ ! -f "$STATUS_FILE" ] && echo "OFF" > "$STATUS_FILE"
    [ ! -f "$ACTION_FILE" ] && touch "$ACTION_FILE"
    [ ! -f "$MSS_STATUS_FILE" ] && echo "OFF" > "$MSS_STATUS_FILE"
    [ ! -f "$MSS_VALUE_FILE" ] && echo "1338" > "$MSS_VALUE_FILE"
    [ ! -f "$MSS_FILE" ] && touch "$MSS_FILE"
    [ ! -f "$RESOLVER_INTERVAL_FILE" ] && echo "60" > "$RESOLVER_INTERVAL_FILE"
    touch "$LOG_FILE" && chmod 0640 "$LOG_FILE"

    # 自我复制到 /usr/local/bin/nf
    if [ ! -f /usr/local/bin/nf ] || ! cmp -s "$0" /usr/local/bin/nf 2>/dev/null; then
        if [[ "$0" == *"bash"* || "$0" == *"/dev/fd/"* ]]; then
            curl -sL "https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh" \
                -o /usr/local/bin/nf 2>/dev/null
        else
            cp -a "$0" /usr/local/bin/nf
        fi
        chmod +x /usr/local/bin/nf 2>/dev/null
    fi

    # 安装 nftables
    if ! command -v nft >/dev/null 2>&1; then
        echo -e "${CYAN}正在安装 nftables...${RESET}"
        install_pkg nftables || err_exit "安装 nftables 失败"
    fi
    systemctl enable nftables >/dev/null 2>&1

    # 内核转发持久化
    ensure_persistent_sysctl

    # logrotate 配置
    install_logrotate

    # 白名单 CIDR 文件
    if [ ! -f "$WHITELIST_DEF" ]; then
        cat > "$WHITELIST_DEF" << 'EOF'
# 专线前置拦截白名单 - 由 NF-Manager 管理
define ALLOWED_CIDRS = {
    127.0.0.1/32
}
EOF
    fi

    # 旧格式迁移
    migrate_old_format

    # 首次安装 - 初始化 nftables.conf 框架
    if ! grep -q "nf_manager/rules.nft" "$MAIN_CONF" 2>/dev/null; then
        echo -e "${CYAN}正在初始化内核防火墙框架...${RESET}"
        local ssh_port
        read -p "【配置】当前机器 SSH 端口 (默认22): " ssh_port
        [ -z "$ssh_port" ] && ssh_port="22"
        validate_port "$ssh_port" || ssh_port="22"
        echo "$ssh_port" > "$SSH_PORT_FILE"

        read -p "【调优】是否默认开启 MTU 钳制? (y/N，回车=N 跳过): " mss_init
        if [ "$mss_init" = "y" ] || [ "$mss_init" = "Y" ]; then
            echo "tcp flags syn tcp option maxseg size set 1338" > "$MSS_FILE"
            echo "ON" > "$MSS_STATUS_FILE"
        fi

        backup_file "$MAIN_CONF"
        cat > "$MAIN_CONF" << EOF
#!/usr/sbin/nft -f
flush ruleset

# 1. 白名单 CIDR 集合定义
include "$WHITELIST_DEF"

table ip filter {
    # 动态访客集合（含超时）
    set temp_ips {
        type ipv4_addr
        flags timeout
    }

    # 【防御层】精准转发拦截
    chain prerouting_filter {
        type filter hook prerouting priority -150; policy accept;
        ct state established,related accept
        tcp dport $ssh_port accept
        include "$ACTION_FILE"
    }

    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        iifname "lo" accept
        ip protocol icmp accept
        tcp dport $ssh_port accept

        # 本地业务端口（不受白名单影响，按需修改）
        tcp dport { 80, 443, 2053, 2083, 8443 } accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
        include "$MSS_FILE"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

# 2. 引入 NAT 转发表
include "$RULES_FILE"
EOF
        # rules.nft 还没生成，先 apply 一次
        apply_rules
        log_msg INFO INIT "首次初始化完成，SSH 端口=$ssh_port"
        echo -e "${GREEN}✅ 初始化完成${RESET}"
        sleep 2
    else
        # 已初始化的情况，确保 rules.nft 存在
        [ ! -f "$RULES_FILE" ] && apply_rules >/dev/null 2>&1
    fi

    # 根据 dynamic 规则状态同步 resolver
    sync_resolver_state
}

# =========================================================
# --- [12. 主菜单] ---
# =========================================================

forward_submenu() {
    while true; do
        clear
        echo -e "${CYAN}═══ 转发规则管理 ═══${RESET}"
        list_rules
        echo
        echo -e "  ${GREEN}1)${RESET} 添加单条规则"
        echo -e "  ${GREEN}2)${RESET} 批量端口段添加"
        echo -e "  ${YELLOW}3)${RESET} 编辑规则"
        echo -e "  ${RED}4)${RESET} 删除规则（支持多选）"
        echo -e "  ${CYAN}5)${RESET} 手动热重载"
        echo -e "  ${CYAN}6)${RESET} 导出配置"
        echo -e "  ${CYAN}7)${RESET} 导入配置"
        echo -e "  ${CYAN}0)${RESET} 返回主菜单"
        read -p "请选择: " c
        case "$c" in
            1) add_rule ;;
            2) batch_add_rules ;;
            3) edit_rule ;;
            4) delete_rule ;;
            5) apply_rules; sleep 1 ;;
            6) export_config ;;
            7) import_config ;;
            0) return ;;
        esac
    done
}

defense_submenu() {
    while true; do
        clear
        local status_wl
        status_wl=$(cat "$STATUS_FILE" 2>/dev/null)
        echo -e "${CYAN}═══ 防御白名单管理 ═══${RESET}"
        echo
        echo -e "  作用：开启后，${BOLD}非白名单 IP 访问转发端口直接 drop${RESET}，本机业务端口（80/443/SSH 等）不受影响。"
        echo
        echo -e "  ${CYAN}1)${RESET} 编辑 CIDR 白名单 (允许访问转发端口的 IP 段)"
        echo -e "  ${CYAN}2)${RESET} 白名单拦截开关  [当前: $([ "$status_wl" = "ON" ] && echo -e "${GREEN}开启${RESET}" || echo -e "${RED}关闭${RESET}")]"
        echo -e "  ${CYAN}3)${RESET} 查看临时放行 IP 名单"
        echo -e "  ${CYAN}0)${RESET} 返回主菜单"
        read -p "请选择: " c
        case "$c" in
            1) edit_whitelist ;;
            2) toggle_whitelist ;;
            3) view_temp_ips ;;
            0) return ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        local status_wl status_mss
        status_wl=$(cat "$STATUS_FILE" 2>/dev/null)
        status_mss=$(cat "$MSS_STATUS_FILE" 2>/dev/null)
        local wl_text mss_text resolver_text
        [ "$status_wl" = "ON" ] && wl_text="${GREEN}开启${RESET}" || wl_text="${RED}关闭${RESET}"
        [ "$status_mss" = "ON" ] && mss_text="${GREEN}开启${RESET}" || mss_text="${RED}关闭${RESET}"
        if [ -f "$RESOLVER_TIMER" ] && systemctl is-active --quiet nf_manager_resolver.timer 2>/dev/null; then
            resolver_text="${GREEN}运行中${RESET}"
        else
            resolver_text="${YELLOW}未启用${RESET}"
        fi

        echo -e "${CYAN}╔══════════════════════════════════════════════════╗${RESET}"
        echo -e "${CYAN}║       NF-Manager 专线安全网关  ${VERSION}              ║${RESET}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════╝${RESET}"
        list_rules
        echo
        # 描述列统一补到显示宽度 34，状态列才能对齐
        printf '  %b%s%b %s\n' "$GREEN" " 1)" "$RESET" "$(pad_display "转发规则管理 (增/删/改/批量/导入导出)" 34)"
        printf '  %b%s%b %s [拦截: %b]\n' "$CYAN"   " 2)" "$RESET" "$(pad_display "防御白名单管理" 34)" "$wl_text"
        printf '  %b%s%b %s [当前: %b]\n' "$CYAN"   " 3)" "$RESET" "$(pad_display "MTU/MSS 钳制调优" 34)" "$mss_text"
        printf '  %b%s%b %s [状态: %b]\n' "$CYAN"   " 4)" "$RESET" "$(pad_display "DDNS 解析器管理" 34)" "$resolver_text"
        printf '  %b%s%b %s\n' "$CYAN"   " 5)" "$RESET" "$(pad_display "系统诊断 (内核/服务/规则/连通性)" 34)"
        printf '  %b%s%b %s\n' "$YELLOW" " 6)" "$RESET" "$(pad_display "查看操作日志" 34)"
        printf '  %b%s%b %s\n' "$YELLOW" " 7)" "$RESET" "$(pad_display "查看备份列表" 34)"
        printf '  %b%s%b %s\n' "$YELLOW" " 8)" "$RESET" "$(pad_display "仅卸载脚本本身 (保留服务与规则)" 34)"
        printf '  %b%s%b %s\n' "$RED"    "99)" "$RESET" "$(pad_display "⚠️  完全卸载 (清理全部，含可选 nftables)" 34)"
        printf '  %b%s%b %s\n' "$CYAN"   " 0)" "$RESET" "退出"
        echo -e "${CYAN}══════════════════════════════════════════════════${RESET}"
        read -p "请输入指令: " choice
        case "$choice" in
            1)  forward_submenu ;;
            2)  defense_submenu ;;
            3)  manage_mss ;;
            4)  manage_resolver ;;
            5)  diagnose ;;
            6)
                if [ -f "$LOG_FILE" ]; then
                    tail -50 "$LOG_FILE"
                    echo
                    echo -e "${YELLOW}（仅显示最近 50 行，完整日志: $LOG_FILE）${RESET}"
                else
                    echo "暂无日志"
                fi
                echo "按任意键返回..."; read -n 1 -s
                ;;
            7)
                if [ -d "$BACKUP_DIR" ]; then
                    ls -lhrt "$BACKUP_DIR" 2>/dev/null | tail -30
                    echo
                    echo -e "${YELLOW}（每种文件最多保留 ${BACKUP_KEEP} 份）${RESET}"
                else
                    echo "暂无备份"
                fi
                echo "按任意键返回..."; read -n 1 -s
                ;;
            8)  uninstall_panel_only ;;
            99) uninstall_full ;;
            0)  exit 0 ;;
            *)  echo -e "${RED}无效输入${RESET}"; sleep 1 ;;
        esac
    done
}

# =========================================================
# --- [13. 入口分发] ---
# =========================================================

case "${1:-}" in
    --resolver-tick)
        # systemd timer 调用：不需要全套 init
        [ "$EUID" -ne 0 ] && exit 1
        resolver_tick
        exit 0
        ;;
    --apply)
        [ "$EUID" -ne 0 ] && err_exit "请用 root 运行"
        apply_rules
        exit $?
        ;;
    --diagnose)
        [ "$EUID" -ne 0 ] && err_exit "请用 root 运行"
        init_env >/dev/null
        diagnose
        exit 0
        ;;
    --version|-v)
        echo "NF-Manager $VERSION"
        exit 0
        ;;
    --help|-h)
        echo "NF-Manager $VERSION"
        echo "用法: nf [选项]"
        echo "  无参数              进入交互菜单"
        echo "  --apply             热加载规则"
        echo "  --resolver-tick     DDNS 解析检查（systemd 调用）"
        echo "  --diagnose          直接运行诊断"
        echo "  --version           显示版本"
        exit 0
        ;;
esac

init_env
main_menu
