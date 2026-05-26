#!/bin/bash
# =========================================================
# 项目名称：NF-Manager 纯内核极速转发与安全面板
# 版本：v5.1
# 仓库：https://github.com/starshine369/nftables-keep
# =========================================================
#
# 设计要点：
#   - 转发规则字段：本地端口 | 目标(IP或域名) | 目标端口 | 协议 | 模式 | 备注 | 本地协议族 | 目标协议族
#     协议: tcp / udp / tcp+udp     模式: ip / static / dynamic     协议族: 4 / 6
#   - 同协议族走 nftables 内核转发，跨 IPv4/IPv6 走 realm 用户态转发
#   - 旧 3 段 / v5 六段格式启动时自动迁移
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
RESOLVER_CACHE="${DIR_PATH}/resolver.cache"      # 格式: domain|family|ip|epoch
WHITELIST_DEF="/etc/my_allow_ips.nft"
WHITELIST6_DEF="/etc/my_allow_ips6.nft"
ACTION_FILE="${DIR_PATH}/whitelist_action.nft"
ACTION6_FILE="${DIR_PATH}/whitelist_action6.nft"
REALM_INPUT_FILE="${DIR_PATH}/realm_input.nft"
REALM_INPUT6_FILE="${DIR_PATH}/realm_input6.nft"
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
REALM_BIN="/usr/local/bin/realm"
REALM_DIR="${DIR_PATH}/realm"
REALM_TCP_CONF="${REALM_DIR}/realm-tcp.toml"
REALM_UDP_CONF="${REALM_DIR}/realm-udp.toml"
REALM_MARKER="${REALM_DIR}/installed_by_nf_manager"
REALM_TCP_SERVICE="/etc/systemd/system/nf_manager_realm_tcp.service"
REALM_UDP_SERVICE="/etc/systemd/system/nf_manager_realm_udp.service"
BACKUP_KEEP=7                                    # 每种文件保留份数

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

VERSION="v5.1"

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

# 校验：IPv6，复杂合法性最终交给 nft/realm 兜底
validate_ipv6() {
    local ip="$1"
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ [[:space:]\|\[\]%] ]] && return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    return 0
}

# 校验：域名（不含尾点，至少一个点）
validate_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

detect_ip_family() {
    local value="$1"
    if validate_ipv4 "$value"; then
        echo 4
    elif validate_ipv6 "$value"; then
        echo 6
    elif validate_domain "$value"; then
        echo domain
    else
        echo unknown
    fi
}

normalize_family() {
    case "$1" in
        6|v6|V6|ipv6|IPv6|IPV6) echo 6 ;;
        *) echo 4 ;;
    esac
}

family_label() {
    [ "$1" = "6" ] && echo "IPv6" || echo "IPv4"
}

format_hostport() {
    local host="$1" port="$2" family="$3"
    [ "$family" = "6" ] && printf '[%s]:%s' "$host" "$port" || printf '%s:%s' "$host" "$port"
}

format_nft_dnat() {
    local host="$1" port="$2" family="$3"
    [ "$family" = "6" ] && printf '[%s]:%s' "$host" "$port" || printf '%s:%s' "$host" "$port"
}

rule_engine() {
    [ "$1" = "$2" ] && echo nft || echo realm
}

# 解析域名取指定协议族的第一个记录；family=4 取 A，family=6 取 AAAA
resolve_domain_family() {
    local domain="$1" family="$(normalize_family "$2")" ip="" rr="A" getent_db="ahostsv4"
    [ "$family" = "6" ] && { rr="AAAA"; getent_db="ahostsv6"; }

    if command -v getent >/dev/null 2>&1; then
        ip=$(getent "$getent_db" "$domain" 2>/dev/null | awk '/STREAM/ {print $1; exit}')
    fi
    if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
        if [ "$family" = "6" ]; then
            ip=$(dig +short +time=3 +tries=2 AAAA "$domain" 2>/dev/null | awk '/:/{print; exit}')
        else
            ip=$(dig +short +time=3 +tries=2 A "$domain" 2>/dev/null | awk '/^[0-9]+\./{print; exit}')
        fi
    fi
    if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
        if [ "$family" = "6" ]; then
            ip=$(host -t AAAA "$domain" 2>/dev/null | awk '/IPv6 address/ {print $5; exit}')
        else
            ip=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}')
        fi
    fi
    [ -z "$ip" ] && return 1
    [ "$family" = "6" ] && validate_ipv6 "$ip" || validate_ipv4 "$ip"
    echo "$ip"
}

resolve_domain() {
    resolve_domain_family "$1" 4
}

choose_listen_family() {
    local choice
    echo "请选择本地监听协议族：" >&2
    echo "  1) IPv4 (默认)" >&2
    echo "  2) IPv6" >&2
    read -p "选择 [1-2，默认1]: " choice
    [ "$choice" = "2" ] && echo 6 || echo 4
}

choose_domain_record() {
    local domain="$1" ip4="" ip6="" choice
    resolve_domain_family "$domain" 4 >/dev/null 2>&1 && ip4=$(resolve_domain_family "$domain" 4)
    resolve_domain_family "$domain" 6 >/dev/null 2>&1 && ip6=$(resolve_domain_family "$domain" 6)

    [ -z "$ip4$ip6" ] && return 1
    echo -e "${CYAN}检测到域名解析结果：${RESET}" >&2
    [ -n "$ip4" ] && echo "  1) 使用 IPv4 A 记录：$ip4 (默认)" >&2
    [ -n "$ip6" ] && echo "  2) 使用 IPv6 AAAA 记录：$ip6" >&2
    echo "  0) 取消" >&2

    while true; do
        read -p "选择: " choice >&2
        [ -z "$choice" ] && choice=1
        case "$choice" in
            1)
                [ -n "$ip4" ] || { echo -e "${YELLOW}未解析到 IPv4 A 记录${RESET}" >&2; continue; }
                CHOSEN_DOMAIN_IP="$ip4"; CHOSEN_TARGET_FAMILY="4"; return 0
                ;;
            2)
                [ -n "$ip6" ] || { echo -e "${YELLOW}未解析到 IPv6 AAAA 记录${RESET}" >&2; continue; }
                CHOSEN_DOMAIN_IP="$ip6"; CHOSEN_TARGET_FAMILY="6"; return 0
                ;;
            0) return 1 ;;
            *) echo -e "${RED}非法选择${RESET}" >&2 ;;
        esac
    done
}

ensure_realm_for_cross_family() {
    local listen_family="$1" target_family="$2"
    [ "$(rule_engine "$listen_family" "$target_family")" = "realm" ] || return 0
    is_realm_installed && return 0
    echo -e "${YELLOW}该规则为 IPv4/IPv6 跨协议族转发，需要安装 realm。${RESET}"
    echo -e "${YELLOW}说明：只有需要跨 v4/v6 才需要安装；同 v4 或同 v6 转发不需要。${RESET}"
    read -p "是否现在安装 realm？(y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        install_realm
        is_realm_installed && return 0
    fi
    echo -e "${RED}未安装 realm，已取消跨协议族规则操作。${RESET}"
    return 1
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
    P_LPORT="" P_TARGET="" P_RPORT="" P_PROTO="tcp+udp" P_MODE="ip" P_COMMENT="" P_LISTEN_FAMILY="4" P_TARGET_FAMILY="4" P_ENGINE="nft"

    if [[ "$line" == *"|"* ]]; then
        IFS='|' read -r P_LPORT P_TARGET P_RPORT P_PROTO P_MODE P_COMMENT P_LISTEN_FAMILY P_TARGET_FAMILY _ <<< "$line"
    else
        read -r P_LPORT P_TARGET P_RPORT _ <<< "$line"
    fi

    [ -z "$P_PROTO" ] && P_PROTO="tcp+udp"
    [ -z "$P_MODE" ]  && P_MODE="ip"
    [ -z "$P_COMMENT" ] && P_COMMENT=""
    P_LISTEN_FAMILY=$(normalize_family "$P_LISTEN_FAMILY")
    P_TARGET_FAMILY=$(normalize_family "$P_TARGET_FAMILY")
    P_ENGINE=$(rule_engine "$P_LISTEN_FAMILY" "$P_TARGET_FAMILY")
    return 0
}

format_rule_line() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$(normalize_family "$7")" "$(normalize_family "$8")"
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
    local need_migrate=0 line field_count
    while IFS= read -r line; do
        [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" != *"|"* ]]; then
            need_migrate=1
            break
        fi
        field_count=$(awk -F'|' '{print NF}' <<< "$line")
        [ "$field_count" -lt 8 ] && { need_migrate=1; break; }
    done < "$CONFIG_FILE"
    [ "$need_migrate" = "0" ] && return 0

    echo -e "${YELLOW}检测到旧版转发配置，正在自动迁移为 v6 八段格式...${RESET}"
    log_msg INFO MIGRATE "开始迁移 forward.list 到八段格式"
    backup_file "$CONFIG_FILE"

    local tmp count=0
    tmp=$(mktemp)
    while IFS= read -r line; do
        if [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        parse_rule "$line" || continue
        format_rule_line "$P_LPORT" "$P_TARGET" "$P_RPORT" "$P_PROTO" "$P_MODE" "$P_COMMENT" "$P_LISTEN_FAMILY" "$P_TARGET_FAMILY" >> "$tmp"
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
    local domain="$1" family="$(normalize_family "$2")" ip="$3"
    local tmp
    tmp=$(mktemp)
    awk -F'|' -v d="$domain" -v f="$family" '!(($1==d && $2==f) || ($1==d && NF==3 && f=="4"))' "$RESOLVER_CACHE" 2>/dev/null > "$tmp" || true
    printf '%s|%s|%s|%s\n' "$domain" "$family" "$ip" "$(date +%s)" >> "$tmp"
    mv "$tmp" "$RESOLVER_CACHE"
}

# 读缓存中域名对应 family 的 IP；兼容旧格式 domain|ip|epoch
cache_get() {
    local domain="$1" family="$(normalize_family "$2")"
    [ -f "$RESOLVER_CACHE" ] || return 1
    awk -F'|' -v d="$domain" -v f="$family" '
        $1==d && NF>=4 && $2==f {print $3; exit}
        $1==d && NF==3 && f=="4" {print $2; exit}
    ' "$RESOLVER_CACHE"
}

# 解析目标字段为实际 IP（处理三种模式）
resolve_target_ip() {
    local target="$1" mode="$2" family="$(normalize_family "$3")"
    case "$mode" in
        ip|static)
            local actual_family
            actual_family=$(detect_ip_family "$target")
            [ "$actual_family" = "$family" ] || return 1
            echo "$target"
            return 0
            ;;
        dynamic)
            local cached
            cached=$(cache_get "$target" "$family")
            if [ -n "$cached" ]; then
                echo "$cached"
                return 0
            fi
            local ip
            if ip=$(resolve_domain_family "$target" "$family"); then
                cache_set "$target" "$family" "$ip"
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
    # 按入口协议族和协议分别收集端口，避免纯 TCP 规则也 drop UDP
    local tcp4_ports="" udp4_ports="" tcp6_ports="" udp6_ports="" line
    while IFS= read -r line; do
        parse_rule "$line" || continue
        if [ "$P_LISTEN_FAMILY" = "6" ]; then
            case "$P_PROTO" in
                tcp)      tcp6_ports+="${P_LPORT}," ;;
                udp)      udp6_ports+="${P_LPORT}," ;;
                tcp+udp)  tcp6_ports+="${P_LPORT},"; udp6_ports+="${P_LPORT}," ;;
            esac
        else
            case "$P_PROTO" in
                tcp)      tcp4_ports+="${P_LPORT}," ;;
                udp)      udp4_ports+="${P_LPORT}," ;;
                tcp+udp)  tcp4_ports+="${P_LPORT},"; udp4_ports+="${P_LPORT}," ;;
            esac
        fi
    done < "$CONFIG_FILE"
    tcp4_ports="${tcp4_ports%,}"; udp4_ports="${udp4_ports%,}"
    tcp6_ports="${tcp6_ports%,}"; udp6_ports="${udp6_ports%,}"

    {
        echo "        # IPv4 核心防御：白名单与临时访客放行"
        echo "        ip saddr \$ALLOWED_CIDRS accept"
        echo "        ip saddr @temp_ips accept"
        [ -n "$tcp4_ports" ] && echo "        tcp dport { $tcp4_ports } drop"
        [ -n "$udp4_ports" ] && echo "        udp dport { $udp4_ports } drop"
        [ -z "$tcp4_ports$udp4_ports" ] && echo "        # 当前没有 IPv4 入口转发端口，白名单无生效目标"
    } > "$ACTION_FILE"

    {
        echo "        # IPv6 核心防御：白名单与临时访客放行"
        echo "        ip6 saddr \$ALLOWED_CIDRS6 accept"
        echo "        ip6 saddr @temp_ips6 accept"
        [ -n "$tcp6_ports" ] && echo "        tcp dport { $tcp6_ports } drop"
        [ -n "$udp6_ports" ] && echo "        udp dport { $udp6_ports } drop"
        [ -z "$tcp6_ports$udp6_ports" ] && echo "        # 当前没有 IPv6 入口转发端口，白名单无生效目标"
    } > "$ACTION6_FILE"
}

list_rules() {
    echo -e "\n${CYAN}--- 🚀 当前转发规则 ---${RESET}"
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}目前没有任何转发规则。${RESET}"
        echo "------------------------------------------------------------------------------------------------"
        return
    fi
    printf "${BOLD}%-4s %-7s %-30s %-7s %-9s %-8s %-7s %-6s %s${RESET}\n" \
        "序号" "本地" "目标" "目标端" "协议" "模式" "方向" "引擎" "备注"
    echo "------------------------------------------------------------------------------------------------"
    local idx=1 line
    while IFS= read -r line; do
        parse_rule "$line" || continue
        local target_show="$P_TARGET"
        if [ "$P_MODE" = "dynamic" ]; then
            local rip
            rip=$(cache_get "$P_TARGET" "$P_TARGET_FAMILY")
            [ -n "$rip" ] && target_show="${P_TARGET}(${rip})"
        fi
        local target_disp comment_disp direction row
        target_disp=$(printf '%-30.30s' "$target_show")
        comment_disp=$(printf '%-28.28s' "$P_COMMENT")
        direction=$(printf 'v%s→v%s' "$P_LISTEN_FAMILY" "$P_TARGET_FAMILY")
        row=$(printf '[%d] %-7s %s %-7s %-9s %-8s %-7s %-6s %s' "$idx" "$P_LPORT" "$target_disp" "$P_RPORT" "$P_PROTO" "$P_MODE" "$direction" "$P_ENGINE" "$comment_disp")
        echo "$row"
        ((idx++))
    done < "$CONFIG_FILE"
    echo "------------------------------------------------------------------------------------------------"
}

# 根据 CONFIG_FILE 生成 rules.nft 并热加载
apply_rules() {
    local old_rules tmp_rules
    tmp_rules=$(mktemp)
    if [ -f "$RULES_FILE" ]; then
        old_rules=$(mktemp)
        cp -a "$RULES_FILE" "$old_rules"
        backup_file "$RULES_FILE"
    fi

    {
        echo "table ip nf_manager_nat"
        echo "flush table ip nf_manager_nat"
        echo "table ip6 nf_manager_nat6"
        echo "flush table ip6 nf_manager_nat6"
        echo ""
        echo "table ip nf_manager_nat {"
        echo "    chain prerouting {"
        echo "        type nat hook prerouting priority dstnat; policy accept;"
    } > "$tmp_rules"

    local line resolved_v4="" resolved_v6="" v6_prerouting=""
    while IFS= read -r line; do
        parse_rule "$line" || continue
        [ "$P_ENGINE" = "nft" ] || continue

        local rip dnat_to
        if ! rip=$(resolve_target_ip "$P_TARGET" "$P_MODE" "$P_TARGET_FAMILY"); then
            echo -e "${YELLOW}⚠️  规则 ${P_LPORT} -> ${P_TARGET} 解析失败，本次跳过${RESET}"
            log_msg WARN APPLY "规则 ${P_LPORT}->${P_TARGET} family=${P_TARGET_FAMILY} 解析失败，跳过"
            continue
        fi
        dnat_to=$(format_nft_dnat "$rip" "$P_RPORT" "$P_TARGET_FAMILY")

        if [ "$P_TARGET_FAMILY" = "6" ]; then
            case "$P_PROTO" in
                tcp) v6_prerouting+="        tcp dport $P_LPORT dnat to ${dnat_to}\n" ;;
                udp) v6_prerouting+="        udp dport $P_LPORT dnat to ${dnat_to}\n" ;;
                *) v6_prerouting+="        tcp dport $P_LPORT dnat to ${dnat_to}\n        udp dport $P_LPORT dnat to ${dnat_to}\n" ;;
            esac
            resolved_v6+="${rip}\n"
        else
            case "$P_PROTO" in
                tcp) echo "        tcp dport $P_LPORT dnat to ${dnat_to}" >> "$tmp_rules" ;;
                udp) echo "        udp dport $P_LPORT dnat to ${dnat_to}" >> "$tmp_rules" ;;
                *)
                    echo "        tcp dport $P_LPORT dnat to ${dnat_to}" >> "$tmp_rules"
                    echo "        udp dport $P_LPORT dnat to ${dnat_to}" >> "$tmp_rules"
                    ;;
            esac
            resolved_v4+="${rip}\n"
        fi
    done < "$CONFIG_FILE"

    {
        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority srcnat; policy accept;"
    } >> "$tmp_rules"

    if [ -n "$resolved_v4" ]; then
        echo -e "$resolved_v4" | sort -u | while read -r rip; do
            [ -n "$rip" ] && echo "        ip daddr $rip masquerade" >> "$tmp_rules"
        done
    fi
    {
        echo "    }"
        echo "}"
        echo ""
        echo "table ip6 nf_manager_nat6 {"
        echo "    chain prerouting {"
        echo "        type nat hook prerouting priority dstnat; policy accept;"
        printf '%b' "$v6_prerouting"
        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority srcnat; policy accept;"
    } >> "$tmp_rules"

    if [ -n "$resolved_v6" ]; then
        echo -e "$resolved_v6" | sort -u | while read -r rip; do
            [ -n "$rip" ] && echo "        ip6 daddr $rip masquerade" >> "$tmp_rules"
        done
    fi
    {
        echo "    }"
        echo "}"
    } >> "$tmp_rules"

    mv "$tmp_rules" "$RULES_FILE"

    local status
    status=$(cat "$STATUS_FILE" 2>/dev/null)
    [ "$status" = "ON" ] && generate_whitelist_action

    local nft_err
    if ! nft_err=$(nft -c -f "$MAIN_CONF" 2>&1); then
        [ -n "$old_rules" ] && cp -a "$old_rules" "$RULES_FILE"
        echo -e "${RED}❌ 规则语法检查失败：${RESET}"
        echo -e "${RED}${nft_err}${RESET}"
        log_msg ERROR APPLY "nft -c 失败: ${nft_err}"
        return 1
    fi
    if ! nft_err=$(nft -f "$MAIN_CONF" 2>&1); then
        [ -n "$old_rules" ] && cp -a "$old_rules" "$RULES_FILE"
        echo -e "${RED}❌ 规则加载失败：${RESET}"
        echo -e "${RED}${nft_err}${RESET}"
        log_msg ERROR APPLY "nft -f 失败: ${nft_err}"
        return 1
    fi
    [ -n "$old_rules" ] && rm -f "$old_rules"
    sync_realm_state >/dev/null 2>&1 || true
    log_msg INFO APPLY "规则热加载成功"
    echo -e "${GREEN}✅ 转发规则已热加载至内核！${RESET}"
}

# 添加规则的交互流程
add_rule() {
    echo -e "\n${CYAN}--- ➕ 添加新转发规则 ---${RESET}"
    local l_port r_port target proto mode comment input_domain listen_family target_family detected

    while true; do
        read -p "请输入 [本地监听端口] (1-65535): " l_port
        validate_port "$l_port" || { echo -e "${RED}端口非法${RESET}"; continue; }
        if grep -qE "^${l_port}\|" "$CONFIG_FILE"; then
            echo -e "${RED}端口 ${l_port} 已存在！${RESET}"; continue
        fi
        if ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE ":${l_port}$"; then
            echo -e "${YELLOW}⚠️  端口 ${l_port} 当前被本机其他进程监听，继续可能冲突${RESET}"
            read -p "继续? (y/N): " yn
            [ "$yn" != "y" ] && [ "$yn" != "Y" ] && continue
        fi
        break
    done

    listen_family=$(choose_listen_family)

    echo "请选择目标类型："
    echo "  1) 固定 IP (默认)"
    echo "  2) 域名 - 静态：脚本解析一次，之后当 IP 用，IP 变了不跟随"
    echo "  3) 域名 - 动态 DDNS：后台定时解析，IP 变了自动热重载"
    read -p "选择 [1-3，默认1]: " tchoice
    [ -z "$tchoice" ] && tchoice=1

    case "$tchoice" in
        1)
            while true; do
                read -p "请输入 [目标 IPv4/IPv6]: " target
                detected=$(detect_ip_family "$target")
                case "$detected" in
                    4|6) target_family="$detected"; break ;;
                    *) echo -e "${RED}IP 格式非法${RESET}" ;;
                esac
            done
            mode="ip"
            ;;
        2|3)
            while true; do
                read -p "请输入 [目标域名]: " input_domain
                validate_domain "$input_domain" || { echo -e "${RED}域名格式非法${RESET}"; continue; }
                echo -e "${CYAN}正在解析 $input_domain ...${RESET}"
                if choose_domain_record "$input_domain"; then
                    target_family="$CHOSEN_TARGET_FAMILY"
                    if [ "$tchoice" = "2" ]; then
                        target="$CHOSEN_DOMAIN_IP"
                        mode="static"
                    else
                        target="$input_domain"
                        mode="dynamic"
                        cache_set "$input_domain" "$target_family" "$CHOSEN_DOMAIN_IP"
                    fi
                    echo -e "${GREEN}已选择 $(family_label "$target_family")：$CHOSEN_DOMAIN_IP${RESET}"
                    break
                fi
                echo -e "${RED}解析失败或已取消${RESET}"
                read -p "重试? (y/N): " yn
                [ "$yn" != "y" ] && [ "$yn" != "Y" ] && return
            done
            ;;
        *)
            echo -e "${RED}非法选择${RESET}"; sleep 1; return
            ;;
    esac

    ensure_realm_for_cross_family "$listen_family" "$target_family" || { sleep 1; return; }

    while true; do
        read -p "请输入 [目标端口] (1-65535): " r_port
        validate_port "$r_port" && break
        echo -e "${RED}端口非法${RESET}"
    done

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

    read -p "备注（回车跳过）: " comment
    comment=$(sanitize_comment "$comment")

    backup_file "$CONFIG_FILE"
    format_rule_line "$l_port" "$target" "$r_port" "$proto" "$mode" "$comment" "$listen_family" "$target_family" >> "$CONFIG_FILE"
    log_msg INFO ADD "$l_port(v${listen_family}) -> $target:$r_port(v${target_family}) $proto $mode 备注=${comment:--}"

    apply_rules
    sync_resolver_state
    sync_realm_state
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
    sync_realm_state
    echo -e "${GREEN}已删除 ${#to_delete[@]} 条规则${RESET}"
    sleep 1
}

edit_rule() {
    list_rules
    [ ! -s "$CONFIG_FILE" ] && { sleep 1; return; }
    read -p "请输入要编辑的序号 (0取消): " edit_idx
    [ "$edit_idx" = "0" ] || [ -z "$edit_idx" ] && return
    [[ ! "$edit_idx" =~ ^[0-9]+$ ]] && { echo -e "${RED}序号非法${RESET}"; sleep 1; return; }

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

    echo -e "\n${CYAN}当前值：${RESET}本地=$P_LPORT(v${P_LISTEN_FAMILY}) 目标=$P_TARGET(v${P_TARGET_FAMILY}) 目标端口=$P_RPORT 协议=$P_PROTO 模式=$P_MODE 引擎=$P_ENGINE 备注=$P_COMMENT"
    echo "（回车保留原值；切换目标协议族时会按 A/AAAA 重新解析或要求重填 IP）"

    local new_lport="$P_LPORT" new_target="$P_TARGET" new_rport="$P_RPORT" new_proto="$P_PROTO" new_comment="$P_COMMENT" new_listen_family="$P_LISTEN_FAMILY" new_target_family="$P_TARGET_FAMILY" new_mode="$P_MODE" v detected

    read -p "新本地端口 [$P_LPORT]: " v
    if [ -n "$v" ]; then
        validate_port "$v" || { echo -e "${RED}端口非法${RESET}"; sleep 1; return; }
        new_lport="$v"
    fi

    read -p "新本地协议族 (4/6) [$P_LISTEN_FAMILY]: " v
    [ -n "$v" ] && new_listen_family=$(normalize_family "$v")

    read -p "新目标端口 [$P_RPORT]: " v
    if [ -n "$v" ]; then
        validate_port "$v" || { echo -e "${RED}端口非法${RESET}"; sleep 1; return; }
        new_rport="$v"
    fi

    read -p "新协议 (tcp/udp/tcp+udp) [$P_PROTO]: " v
    [ -n "$v" ] && new_proto="$v"
    case "$new_proto" in tcp|udp|tcp+udp) ;; *) echo -e "${RED}协议非法${RESET}"; sleep 1; return ;; esac

    read -p "新备注 [$P_COMMENT]: " v
    [ -n "$v" ] && new_comment=$(sanitize_comment "$v")

    read -p "是否修改目标地址/域名或目标协议族? (y/N): " v
    if [ "$v" = "y" ] || [ "$v" = "Y" ]; then
        if [ "$P_MODE" = "dynamic" ]; then
            read -p "新目标域名 [$P_TARGET]: " v
            [ -n "$v" ] && new_target="$v"
            validate_domain "$new_target" || { echo -e "${RED}域名格式非法${RESET}"; sleep 1; return; }
            choose_domain_record "$new_target" || { echo -e "${RED}解析失败或取消${RESET}"; sleep 1; return; }
            new_target_family="$CHOSEN_TARGET_FAMILY"
            cache_set "$new_target" "$new_target_family" "$CHOSEN_DOMAIN_IP"
        else
            read -p "新目标 IPv4/IPv6 或域名 [$P_TARGET]: " v
            [ -n "$v" ] && new_target="$v"
            detected=$(detect_ip_family "$new_target")
            case "$detected" in
                4|6)
                    new_target_family="$detected"
                    ;;
                domain)
                    choose_domain_record "$new_target" || { echo -e "${RED}解析失败或取消${RESET}"; sleep 1; return; }
                    new_target="$CHOSEN_DOMAIN_IP"
                    new_target_family="$CHOSEN_TARGET_FAMILY"
                    new_mode="static"
                    ;;
                *) echo -e "${RED}目标格式非法${RESET}"; sleep 1; return ;;
            esac
        fi
    else
        read -p "新目标协议族 (4/6) [$P_TARGET_FAMILY]: " v
        if [ -n "$v" ]; then
            new_target_family=$(normalize_family "$v")
            if [ "$new_target_family" != "$P_TARGET_FAMILY" ]; then
                if [ "$P_MODE" = "dynamic" ]; then
                    choose_domain_record "$P_TARGET" || { echo -e "${RED}解析失败或取消${RESET}"; sleep 1; return; }
                    [ "$CHOSEN_TARGET_FAMILY" = "$new_target_family" ] || { echo -e "${RED}未选择目标协议族对应记录${RESET}"; sleep 1; return; }
                    cache_set "$P_TARGET" "$new_target_family" "$CHOSEN_DOMAIN_IP"
                else
                    read -p "切换目标族需要重新输入目标 $(family_label "$new_target_family") IP: " new_target
                    detected=$(detect_ip_family "$new_target")
                    [ "$detected" = "$new_target_family" ] || { echo -e "${RED}目标 IP 与协议族不匹配${RESET}"; sleep 1; return; }
                fi
            fi
        fi
    fi

    ensure_realm_for_cross_family "$new_listen_family" "$new_target_family" || { sleep 1; return; }

    if [ "$new_lport" != "$P_LPORT" ] && grep -qE "^${new_lport}\|" "$CONFIG_FILE"; then
        echo -e "${RED}新本地端口已存在${RESET}"
        sleep 1
        return
    fi

    backup_file "$CONFIG_FILE"
    local new_line
    new_line=$(format_rule_line "$new_lport" "$new_target" "$new_rport" "$new_proto" "$new_mode" "$new_comment" "$new_listen_family" "$new_target_family")
    new_line=${new_line%$'\n'}
    awk -v ln="$real_line" -v repl="$new_line" 'NR==ln{print repl; next} {print}' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    log_msg INFO EDIT "$found  =>  $new_line"
    apply_rules
    sync_resolver_state
    sync_realm_state
    sleep 1
}

# 批量端口段添加，简化中转配置
batch_add_rules() {
    echo -e "\n${CYAN}--- 📦 批量添加端口段 ---${RESET}"
    local start_p end_p target r_start proto mode comment input_domain fip listen_family target_family detected

    read -p "本地端口起始: " start_p
    validate_port "$start_p" || { echo -e "${RED}非法${RESET}"; sleep 1; return; }
    read -p "本地端口结束: " end_p
    validate_port "$end_p" || { echo -e "${RED}非法${RESET}"; sleep 1; return; }
    [ "$end_p" -lt "$start_p" ] && { echo -e "${RED}结束端口需 >= 起始${RESET}"; sleep 1; return; }
    [ $((end_p - start_p)) -gt 200 ] && { echo -e "${YELLOW}超过 200 个端口，请分批${RESET}"; sleep 1; return; }

    listen_family=$(choose_listen_family)

    read -p "目标 IP/域名: " input_domain
    detected=$(detect_ip_family "$input_domain")
    if [ "$detected" = "4" ] || [ "$detected" = "6" ]; then
        target="$input_domain"
        target_family="$detected"
        mode="ip"
    elif [ "$detected" = "domain" ]; then
        echo "  1) 静态域名 (默认)  2) 动态 DDNS"
        read -p "选择 [1-2]: " mc
        choose_domain_record "$input_domain" || { echo -e "${RED}解析失败或取消${RESET}"; sleep 1; return; }
        target_family="$CHOSEN_TARGET_FAMILY"
        fip="$CHOSEN_DOMAIN_IP"
        if [ "$mc" = "2" ]; then
            cache_set "$input_domain" "$target_family" "$fip"
            target="$input_domain"
            mode="dynamic"
        else
            target="$fip"
            mode="static"
        fi
    else
        echo -e "${RED}目标格式非法${RESET}"; sleep 1; return
    fi

    ensure_realm_for_cross_family "$listen_family" "$target_family" || { sleep 1; return; }

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
        format_rule_line "$p" "$target" "$rp" "$proto" "$mode" "$comment" "$listen_family" "$target_family" >> "$CONFIG_FILE"
        ((added++))
    done
    log_msg INFO BATCH "起始=$start_p 结束=$end_p 添加=$added 跳过=$skipped family=v${listen_family}->v${target_family}"
    echo -e "${GREEN}添加 $added 条，跳过 $skipped 条已存在${RESET}"
    apply_rules
    sync_resolver_state
    sync_realm_state
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
        old_ip=$(cache_get "$P_TARGET" "$P_TARGET_FAMILY")
        if ! new_ip=$(resolve_domain_family "$P_TARGET" "$P_TARGET_FAMILY"); then
            log_msg WARN RESOLVE "$P_TARGET family=${P_TARGET_FAMILY} 解析失败，沿用旧IP=${old_ip:-空}"
            continue
        fi
        if [ "$new_ip" != "$old_ip" ]; then
            log_msg INFO RESOLVE "$P_TARGET family=${P_TARGET_FAMILY} ${old_ip:-空} -> $new_ip"
            cache_set "$P_TARGET" "$P_TARGET_FAMILY" "$new_ip"
            changed=1
        fi
    done < "$CONFIG_FILE"

    if [ "$changed" = "1" ]; then
        log_msg INFO RESOLVE "检测到 IP 变化，触发 apply_rules + sync_realm_state"
        apply_rules >/dev/null 2>&1
        sync_realm_state >/dev/null 2>&1 || true
    fi
}

has_cross_family_rules() {
    [ -s "$CONFIG_FILE" ] || return 1
    local line
    while IFS= read -r line; do
        parse_rule "$line" || continue
        [ "$P_ENGINE" = "realm" ] && return 0
    done < "$CONFIG_FILE"
    return 1
}

is_realm_installed() {
    [ -x "$REALM_BIN" ]
}

realm_version() {
    [ -x "$REALM_BIN" ] && "$REALM_BIN" --version 2>/dev/null | head -1
}

realm_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo x86_64-unknown-linux-gnu ;;
        aarch64|arm64) echo aarch64-unknown-linux-gnu ;;
        armv7l|armv7*) echo armv7-unknown-linux-gnueabihf ;;
        *) return 1 ;;
    esac
}

install_realm() {
    if is_realm_installed; then
        echo -e "${GREEN}realm 已安装：$(realm_version)${RESET}"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || { echo -e "${RED}缺少 curl，无法下载 realm${RESET}"; return 1; }
    command -v tar >/dev/null 2>&1 || { echo -e "${RED}缺少 tar，无法解压 realm${RESET}"; return 1; }

    local arch url tmpdir archive bin_found
    arch=$(realm_arch) || { echo -e "${RED}暂不支持当前架构：$(uname -m)${RESET}"; return 1; }
    url="https://github.com/zhboner/realm/releases/latest/download/realm-${arch}.tar.gz"
    tmpdir=$(mktemp -d)
    archive="${tmpdir}/realm.tar.gz"

    echo -e "${CYAN}正在下载 realm：$url${RESET}"
    if ! curl -fL --connect-timeout 10 --retry 2 -o "$archive" "$url"; then
        rm -rf "$tmpdir"
        echo -e "${RED}下载 realm 失败${RESET}"
        return 1
    fi
    if ! tar -xzf "$archive" -C "$tmpdir"; then
        rm -rf "$tmpdir"
        echo -e "${RED}解压 realm 失败${RESET}"
        return 1
    fi
    bin_found=$(find "$tmpdir" -type f -name realm -perm /111 2>/dev/null | head -1)
    [ -n "$bin_found" ] || bin_found=$(find "$tmpdir" -type f -name realm 2>/dev/null | head -1)
    [ -n "$bin_found" ] || { rm -rf "$tmpdir"; echo -e "${RED}压缩包内未找到 realm 二进制${RESET}"; return 1; }

    mkdir -p "$REALM_DIR"
    install -m 0755 "$bin_found" "$REALM_BIN" || { rm -rf "$tmpdir"; echo -e "${RED}安装 realm 到 $REALM_BIN 失败${RESET}"; return 1; }
    touch "$REALM_MARKER"
    rm -rf "$tmpdir"
    install_realm_units
    echo -e "${GREEN}realm 安装完成：$(realm_version)${RESET}"
    log_msg INFO REALM "realm installed arch=$arch"
}

install_realm_units() {
    mkdir -p "$REALM_DIR"
    cat > "$REALM_TCP_SERVICE" << EOF
[Unit]
Description=NF-Manager realm TCP forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$REALM_BIN -c $REALM_TCP_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    cat > "$REALM_UDP_SERVICE" << EOF
[Unit]
Description=NF-Manager realm UDP forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$REALM_BIN -c $REALM_UDP_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
}

generate_realm_config() {
    mkdir -p "$REALM_DIR"
    local tcp_tmp udp_tmp input4_tmp input6_tmp line tcp_count=0 udp_count=0 tcp4_ports="" udp4_ports="" tcp6_ports="" udp6_ports=""
    tcp_tmp=$(mktemp)
    udp_tmp=$(mktemp)
    input4_tmp=$(mktemp)
    input6_tmp=$(mktemp)

    {
        echo "[network]"
        echo "no_tcp = false"
        echo "no_udp = true"
        echo ""
    } > "$tcp_tmp"
    {
        echo "[network]"
        echo "no_tcp = true"
        echo "no_udp = false"
        echo ""
    } > "$udp_tmp"

    while IFS= read -r line; do
        parse_rule "$line" || continue
        [ "$P_ENGINE" = "realm" ] || continue
        local rip listen remote
        if ! rip=$(resolve_target_ip "$P_TARGET" "$P_MODE" "$P_TARGET_FAMILY"); then
            echo -e "${YELLOW}⚠️  realm 规则 ${P_LPORT} -> ${P_TARGET} 解析失败，已跳过${RESET}"
            log_msg WARN REALM "规则 ${P_LPORT}->${P_TARGET} family=${P_TARGET_FAMILY} 解析失败，跳过"
            continue
        fi
        if [ "$P_LISTEN_FAMILY" = "6" ]; then
            listen="[::]:${P_LPORT}"
        else
            listen="0.0.0.0:${P_LPORT}"
        fi
        remote=$(format_hostport "$rip" "$P_RPORT" "$P_TARGET_FAMILY")
        case "$P_PROTO" in
            tcp)
                printf '[[endpoints]]\nlisten = "%s"\nremote = "%s"\n\n' "$listen" "$remote" >> "$tcp_tmp"
                [ "$P_LISTEN_FAMILY" = "6" ] && tcp6_ports+="${P_LPORT}," || tcp4_ports+="${P_LPORT},"
                ((tcp_count++))
                ;;
            udp)
                printf '[[endpoints]]\nlisten = "%s"\nremote = "%s"\n\n' "$listen" "$remote" >> "$udp_tmp"
                [ "$P_LISTEN_FAMILY" = "6" ] && udp6_ports+="${P_LPORT}," || udp4_ports+="${P_LPORT},"
                ((udp_count++))
                ;;
            *)
                printf '[[endpoints]]\nlisten = "%s"\nremote = "%s"\n\n' "$listen" "$remote" >> "$tcp_tmp"
                printf '[[endpoints]]\nlisten = "%s"\nremote = "%s"\n\n' "$listen" "$remote" >> "$udp_tmp"
                if [ "$P_LISTEN_FAMILY" = "6" ]; then
                    tcp6_ports+="${P_LPORT},"; udp6_ports+="${P_LPORT},"
                else
                    tcp4_ports+="${P_LPORT},"; udp4_ports+="${P_LPORT},"
                fi
                ((tcp_count++)); ((udp_count++))
                ;;
        esac
    done < "$CONFIG_FILE"

    tcp4_ports="${tcp4_ports%,}"; udp4_ports="${udp4_ports%,}"
    tcp6_ports="${tcp6_ports%,}"; udp6_ports="${udp6_ports%,}"
    {
        echo "        # IPv4 realm 用户态转发监听端口放行"
        [ -n "$tcp4_ports" ] && echo "        tcp dport { $tcp4_ports } accept"
        [ -n "$udp4_ports" ] && echo "        udp dport { $udp4_ports } accept"
        [ -z "$tcp4_ports$udp4_ports" ] && echo "        # 当前没有 IPv4 realm 监听端口"
    } > "$input4_tmp"
    {
        echo "        # IPv6 realm 用户态转发监听端口放行"
        [ -n "$tcp6_ports" ] && echo "        tcp dport { $tcp6_ports } accept"
        [ -n "$udp6_ports" ] && echo "        udp dport { $udp6_ports } accept"
        [ -z "$tcp6_ports$udp6_ports" ] && echo "        # 当前没有 IPv6 realm 监听端口"
    } > "$input6_tmp"

    mv "$tcp_tmp" "$REALM_TCP_CONF"
    mv "$udp_tmp" "$REALM_UDP_CONF"
    mv "$input4_tmp" "$REALM_INPUT_FILE"
    mv "$input6_tmp" "$REALM_INPUT6_FILE"
    REALM_TCP_COUNT=$tcp_count
    REALM_UDP_COUNT=$udp_count
}

sync_realm_state() {
    [ -f "$REALM_INPUT_FILE" ] || { mkdir -p "$DIR_PATH"; echo "        # 当前没有 IPv4 realm 监听端口" > "$REALM_INPUT_FILE"; }
    [ -f "$REALM_INPUT6_FILE" ] || { mkdir -p "$DIR_PATH"; echo "        # 当前没有 IPv6 realm 监听端口" > "$REALM_INPUT6_FILE"; }
    if ! has_cross_family_rules; then
        systemctl disable --now nf_manager_realm_tcp.service >/dev/null 2>&1 || true
        systemctl disable --now nf_manager_realm_udp.service >/dev/null 2>&1 || true
        echo "        # 当前没有 IPv4 realm 监听端口" > "$REALM_INPUT_FILE"
        echo "        # 当前没有 IPv6 realm 监听端口" > "$REALM_INPUT6_FILE"
        command -v nft >/dev/null 2>&1 && nft -f "$MAIN_CONF" >/dev/null 2>&1 || true
        return 0
    fi
    if ! is_realm_installed; then
        log_msg ERROR REALM "存在跨协议族规则但 realm 未安装"
        echo -e "${RED}存在跨 IPv4/IPv6 规则，但 realm 未安装，请到 realm 管理菜单安装。${RESET}"
        return 1
    fi
    install_realm_units
    generate_realm_config
    if [ "${REALM_TCP_COUNT:-0}" -gt 0 ]; then
        systemctl enable --now nf_manager_realm_tcp.service >/dev/null 2>&1 || return 1
        systemctl restart nf_manager_realm_tcp.service >/dev/null 2>&1 || return 1
    else
        systemctl disable --now nf_manager_realm_tcp.service >/dev/null 2>&1 || true
    fi
    if [ "${REALM_UDP_COUNT:-0}" -gt 0 ]; then
        systemctl enable --now nf_manager_realm_udp.service >/dev/null 2>&1 || return 1
        systemctl restart nf_manager_realm_udp.service >/dev/null 2>&1 || return 1
    else
        systemctl disable --now nf_manager_realm_udp.service >/dev/null 2>&1 || true
    fi
    command -v nft >/dev/null 2>&1 && nft -f "$MAIN_CONF" >/dev/null 2>&1 || true
    log_msg INFO REALM "sync tcp=${REALM_TCP_COUNT:-0} udp=${REALM_UDP_COUNT:-0}"
}

uninstall_realm() {
    if has_cross_family_rules; then
        echo -e "${RED}当前存在 IPv4/IPv6 跨协议族规则，卸载 realm 后这些规则将失效。${RESET}"
        read -p "确认继续卸载 realm？(yes): " y
        [ "$y" = "yes" ] || { echo "已取消"; return 1; }
    fi
    systemctl disable --now nf_manager_realm_tcp.service >/dev/null 2>&1 || true
    systemctl disable --now nf_manager_realm_udp.service >/dev/null 2>&1 || true
    rm -f "$REALM_TCP_SERVICE" "$REALM_UDP_SERVICE"
    systemctl daemon-reload >/dev/null 2>&1
    local remove_bin=0
    [ -f "$REALM_MARKER" ] && remove_bin=1
    rm -rf "$REALM_DIR"
    echo "        # 当前没有 IPv4 realm 监听端口" > "$REALM_INPUT_FILE"
    echo "        # 当前没有 IPv6 realm 监听端口" > "$REALM_INPUT6_FILE"
    if [ "$remove_bin" = "1" ] && [ -x "$REALM_BIN" ]; then
        rm -f "$REALM_BIN"
    elif [ -x "$REALM_BIN" ]; then
        echo -e "${YELLOW}检测到非脚本标记的 realm，已保留：$REALM_BIN${RESET}"
    fi
    log_msg INFO REALM "realm uninstalled"
    echo -e "${GREEN}realm 已卸载${RESET}"
}

realm_status_text() {
    if ! is_realm_installed; then
        echo "未安装"
    elif systemctl is-active --quiet nf_manager_realm_tcp.service 2>/dev/null || systemctl is-active --quiet nf_manager_realm_udp.service 2>/dev/null; then
        echo "运行中"
    else
        echo "已安装"
    fi
}

manage_realm() {
    echo -e "\n${CYAN}--- 🔁 realm 用户态转发管理 ---${RESET}"
    echo -e "${YELLOW}说明：只有需要跨 v4/v6 才需要安装；同 v4 或同 v6 转发默认使用 nftables 内核转发。${RESET}"
    local cross_count tcp_state udp_state installed
    cross_count=0
    while IFS= read -r line; do
        parse_rule "$line" || continue
        [ "$P_ENGINE" = "realm" ] && ((cross_count++))
    done < "$CONFIG_FILE"
    is_realm_installed && installed="已安装 $(realm_version)" || installed="未安装"
    systemctl is-active --quiet nf_manager_realm_tcp.service 2>/dev/null && tcp_state="运行中" || tcp_state="未运行"
    systemctl is-active --quiet nf_manager_realm_udp.service 2>/dev/null && udp_state="运行中" || udp_state="未运行"
    echo "  realm 安装：$installed"
    echo "  TCP 服务：$tcp_state"
    echo "  UDP 服务：$udp_state"
    echo "  跨协议族规则数：$cross_count"
    echo "------------------------------"
    echo "1) 安装 realm"
    echo "2) 卸载 realm"
    echo "3) 重生成 realm 配置并重启服务"
    echo "4) 查看 realm 服务状态"
    echo "0) 返回"
    read -p "选择: " c
    case "$c" in
        1) install_realm; sync_realm_state; sleep 1 ;;
        2) uninstall_realm; apply_rules; sleep 1 ;;
        3) sync_realm_state && echo -e "${GREEN}已同步 realm 配置${RESET}"; sleep 1 ;;
        4)
            systemctl status nf_manager_realm_tcp.service nf_manager_realm_udp.service --no-pager 2>/dev/null || true
            echo "按任意键返回..."; read -n 1 -s
            ;;
    esac
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
                echo -e "${CYAN}域名 | 协议族 | 当前IP | 最后更新${RESET}"
                while IFS='|' read -r d f ip ts; do
                    [ -z "$d" ] && continue
                    if [ -z "$ts" ]; then
                        ts="$ip"; ip="$f"; f="4"
                    fi
                    printf "%s | IPv%s | %s | %s\n" "$d" "$f" "$ip" "$(date -d "@$ts" '+%F %T' 2>/dev/null || echo "$ts")"
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
    echo -e "\n${CYAN}--- 编辑白名单 ---${RESET}"
    echo "1) 编辑 IPv4 白名单"
    echo "2) 编辑 IPv6 白名单"
    echo "0) 返回"
    read -p "选择: " c
    local file label
    case "$c" in
        1) file="$WHITELIST_DEF"; label="IPv4" ;;
        2) file="$WHITELIST6_DEF"; label="IPv6" ;;
        0) return ;;
        *) echo -e "${RED}非法选择${RESET}"; sleep 1; return ;;
    esac
    backup_file "$file"
    ${EDITOR:-nano} "$file"
    echo -e "\n${CYAN}正在语法检查...${RESET}"
    local err
    if err=$(nft -c -f "$MAIN_CONF" 2>&1); then
        nft -f "$MAIN_CONF" && echo -e "${GREEN}✅ ${label} 白名单已重载${RESET}"
        log_msg INFO WHITELIST "${label} 编辑后重载成功"
    else
        echo -e "${RED}❌ 语法错误：${err}${RESET}"
        echo -e "${RED}已拒绝重载，请修复后再试${RESET}"
        log_msg ERROR WHITELIST "${label} 语法错误: $err"
    fi
    echo "按任意键返回..."; read -n 1 -s
}

toggle_whitelist() {
    local status
    status=$(cat "$STATUS_FILE" 2>/dev/null)
    if [ "$status" = "ON" ]; then
        echo "" > "$ACTION_FILE"
        echo "" > "$ACTION6_FILE"
        echo "OFF" > "$STATUS_FILE"
        nft -f "$MAIN_CONF" && echo -e "${GREEN}🔓 IPv4/IPv6 白名单已关闭${RESET}"
        log_msg INFO WHITELIST "已关闭"
    else
        generate_whitelist_action
        echo "ON" > "$STATUS_FILE"
        nft -f "$MAIN_CONF" && echo -e "${RED}🛡️ IPv4/IPv6 白名单已开启${RESET}"
        log_msg INFO WHITELIST "已开启"
    fi
    sleep 1
}

view_temp_ips() {
    echo -e "\n${CYAN}--- ⏳ 临时放行名单 ---${RESET}"
    local info4 info6
    info4=$(nft list set ip filter temp_ips 2>/dev/null)
    info6=$(nft list set ip6 filter temp_ips6 2>/dev/null)

    echo -e "${CYAN}[IPv4]${RESET}"
    if [ -z "$info4" ]; then
        echo -e "${YELLOW}temp_ips 集合不存在${RESET}"
    elif echo "$info4" | grep -q "elements = { }"; then
        echo -e "${GREEN}当前无临时放行 IPv4${RESET}"
    else
        echo "$info4" | grep "expires" | sed 's/elements = { //g; s/ }//g' | tr ',' '\n' | while read -r line; do
            [ -n "$line" ] && echo " 🔓 $line"
        done
    fi

    echo -e "\n${CYAN}[IPv6]${RESET}"
    if [ -z "$info6" ]; then
        echo -e "${YELLOW}temp_ips6 集合不存在${RESET}"
    elif echo "$info6" | grep -q "elements = { }"; then
        echo -e "${GREEN}当前无临时放行 IPv6${RESET}"
    else
        echo "$info6" | grep "expires" | sed 's/elements = { //g; s/ }//g' | tr ',' '\n' | while read -r line; do
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
    local cfg_count loaded_v4 loaded_v6 realm_count expected_v4=0 expected_v6=0 expected_realm=0
    cfg_count=$(awk -F'|' 'NF>=3 && $1!~/^[[:space:]]*#/ && $1!=""' "$CONFIG_FILE" 2>/dev/null | wc -l)
    loaded_v4=$(nft list table ip nf_manager_nat 2>/dev/null | grep -c 'dnat to')
    loaded_v6=$(nft list table ip6 nf_manager_nat6 2>/dev/null | grep -c 'dnat to')
    realm_count=0

    print_check OK "配置文件规则数" "$cfg_count"
    local line inc
    while IFS= read -r line; do
        parse_rule "$line" || continue
        case "$P_PROTO" in tcp|udp) inc=1 ;; *) inc=2 ;; esac
        if [ "$P_ENGINE" = "realm" ]; then
            ((expected_realm+=inc))
        elif [ "$P_TARGET_FAMILY" = "6" ]; then
            ((expected_v6+=inc))
        else
            ((expected_v4+=inc))
        fi
    done < "$CONFIG_FILE"
    if [ -s "$REALM_TCP_CONF" ]; then
        local tcp_loaded
        tcp_loaded=$(grep -c '^\[\[endpoints\]\]' "$REALM_TCP_CONF" 2>/dev/null || true)
        realm_count=$((realm_count + ${tcp_loaded:-0}))
    fi
    if [ -s "$REALM_UDP_CONF" ]; then
        local udp_loaded
        udp_loaded=$(grep -c '^\[\[endpoints\]\]' "$REALM_UDP_CONF" 2>/dev/null || true)
        realm_count=$((realm_count + ${udp_loaded:-0}))
    fi
    print_check OK "IPv4 nft DNAT" "$loaded_v4 / 应有 $expected_v4"
    print_check OK "IPv6 nft DNAT" "$loaded_v6 / 应有 $expected_v6"
    if [ "$expected_realm" -gt 0 ]; then
        if is_realm_installed; then
            print_check OK "realm endpoint" "$realm_count / 应有 $expected_realm"
        else
            print_check FAIL "realm" "存在跨 v4/v6 规则但未安装 realm"
        fi
    else
        print_check OK "realm" "无跨协议族规则"
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
            if ! rip=$(resolve_target_ip "$P_TARGET" "$P_MODE" "$P_TARGET_FAMILY" 2>/dev/null); then
                print_check FAIL "${P_LPORT} -> ${P_TARGET}:${P_RPORT}" "目标无法解析"
                continue
            fi
            case "$P_PROTO" in
                udp)
                    print_check WARN "${P_LPORT} -> ${rip}:${P_RPORT} (udp)" "UDP 无法可靠探测，跳过"
                    ;;
                *)
                    if [ "$P_TARGET_FAMILY" = "6" ]; then
                        if command -v nc >/dev/null 2>&1; then
                            if nc -6 -z -w 3 "$rip" "$P_RPORT" 2>/dev/null; then
                                print_check OK "${P_LPORT} -> ${rip}:${P_RPORT} (tcp)" "可达"
                            else
                                print_check FAIL "${P_LPORT} -> ${rip}:${P_RPORT} (tcp)" "不可达"
                            fi
                        else
                            print_check WARN "${P_LPORT} -> ${rip}:${P_RPORT} (tcp)" "缺少 nc，跳过 IPv6 探测"
                        fi
                    elif timeout 3 bash -c "</dev/tcp/${rip}/${P_RPORT}" 2>/dev/null; then
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
            oldest_age=$(awk -F'|' -v now="$(date +%s)" '{ts=(NF>=4?$4:$3); age=now-ts; if(age>max) max=age} END {print max+0}' "$RESOLVER_CACHE")
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
        echo "# 格式: 本地端口|目标|目标端口|协议|模式|备注|本地协议族|目标协议族"
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
    local tmp line count=0
    tmp=$(mktemp)
    while IFS= read -r line; do
        [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
        parse_rule "$line" || continue
        validate_port "$P_LPORT" || { echo -e "${YELLOW}跳过非法本地端口规则：$line${RESET}"; continue; }
        validate_port "$P_RPORT" || { echo -e "${YELLOW}跳过非法目标端口规则：$line${RESET}"; continue; }
        case "$P_PROTO" in tcp|udp|tcp+udp) ;; *) echo -e "${YELLOW}跳过非法协议规则：$line${RESET}"; continue ;; esac
        case "$P_MODE" in ip|static|dynamic) ;; *) echo -e "${YELLOW}跳过非法模式规则：$line${RESET}"; continue ;; esac
        format_rule_line "$P_LPORT" "$P_TARGET" "$P_RPORT" "$P_PROTO" "$P_MODE" "$P_COMMENT" "$P_LISTEN_FAMILY" "$P_TARGET_FAMILY" >> "$tmp"
        ((count++))
    done < "$src"
    mv "$tmp" "$CONFIG_FILE"
    log_msg INFO IMPORT "从 $src 导入 $count 条"
    echo -e "${GREEN}导入完成 $count 条，正在重载...${RESET}"
    apply_rules
    sync_resolver_state
    sync_realm_state
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
    echo "  ✗ 保留 realm 服务与二进制（如有）"
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
    echo "  ✓ 停止并删除 realm systemd unit 与配置"
    echo "  ✓ 恢复 /etc/nftables.conf 备份（如有）或重置为空"
    echo "  ✓ 删除 /etc/nf_manager/（含所有备份）"
    echo "  ✓ 删除 /etc/my_allow_ips.nft 和 /etc/my_allow_ips6.nft"
    echo "  ✓ 删除 /usr/local/bin/nf"
    echo "  ✓ 删除 /var/log/nf_manager.log 与 logrotate 配置"
    echo "  ✓ 删除 /etc/sysctl.d/99-nf_manager.conf（内核转发持久化）"
    echo
    echo -e "  ${YELLOW}? 最后一步会询问是否同时卸载 nftables 软件包（默认保留）${RESET}"
    echo
    read -p "确认继续？(yes 完整输入): " y
    [ "$y" != "yes" ] && { echo "已取消"; sleep 1; return; }

    local remove_realm_bin=0
    [ -f "$REALM_MARKER" ] && remove_realm_bin=1

    echo -e "\n${CYAN}[1/6] 停止 resolver / realm 服务...${RESET}"
    if [ -f "$RESOLVER_TIMER" ]; then
        systemctl disable --now nf_manager_resolver.timer >/dev/null 2>&1
    fi
    systemctl disable --now nf_manager_realm_tcp.service >/dev/null 2>&1 || true
    systemctl disable --now nf_manager_realm_udp.service >/dev/null 2>&1 || true
    rm -f "$RESOLVER_SERVICE" "$RESOLVER_TIMER" "$REALM_TCP_SERVICE" "$REALM_UDP_SERVICE"
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
    rm -f "$WHITELIST_DEF" "$WHITELIST6_DEF"

    echo -e "${CYAN}[4/6] 移除 nf 命令...${RESET}"
    rm -f /usr/local/bin/nf

    echo -e "${CYAN}[5/6] 删除日志、logrotate 与 sysctl 配置...${RESET}"
    rm -f "$LOGROTATE_CONF"
    rm -f /var/log/nf_manager.log*
    rm -f /etc/sysctl.d/99-nf_manager.conf

    if [ "$remove_realm_bin" = "1" ] && [ -x "$REALM_BIN" ]; then
        rm -f "$REALM_BIN"
        echo -e "  ${GREEN}已删除脚本安装的 realm 二进制${RESET}"
    elif [ -x "$REALM_BIN" ]; then
        echo -e "  ${CYAN}检测到非脚本标记的 realm，默认保留：$REALM_BIN${RESET}"
    fi

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
        log_msg INFO INIT "已写入 sysctl 持久化 $conf"
    fi
    if sysctl --system >/dev/null 2>&1 || sysctl -p "$conf" >/dev/null 2>&1; then
        log_msg INFO INIT "已重载 sysctl 内核参数"
    else
        log_msg WARN INIT "sysctl 重载失败"
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

ensure_main_conf_v6_realm_support() {
    [ -f "$MAIN_CONF" ] || return 0
    grep -q "nf_manager/rules.nft" "$MAIN_CONF" 2>/dev/null || return 0
    local changed=0 tmp ssh_port ip6_block

    if ! grep -q "my_allow_ips6.nft" "$MAIN_CONF" 2>/dev/null; then
        backup_file "$MAIN_CONF"
        tmp=$(mktemp)
        awk -v inc="include \"$WHITELIST6_DEF\"" '
            {print}
            $0 ~ /include .*my_allow_ips\.nft/ && !done {print inc; done=1}
        ' "$MAIN_CONF" > "$tmp" && mv "$tmp" "$MAIN_CONF"
        changed=1
    fi

    if ! grep -q "realm_input.nft" "$MAIN_CONF" 2>/dev/null; then
        [ "$changed" = "0" ] && backup_file "$MAIN_CONF"
        tmp=$(mktemp)
        awk -v inc="        include \"$REALM_INPUT_FILE\"" '
            {print}
            /tcp dport \{ 80, 443, 2053, 2083, 8443 \} accept/ && !done {
                print ""
                print "        # IPv4 realm 跨协议族用户态转发监听端口"
                print inc
                done=1
            }
        ' "$MAIN_CONF" > "$tmp" && mv "$tmp" "$MAIN_CONF"
        changed=1
    fi

    if ! grep -q "table ip6 filter" "$MAIN_CONF" 2>/dev/null; then
        [ "$changed" = "0" ] && backup_file "$MAIN_CONF"
        ssh_port=$(cat "$SSH_PORT_FILE" 2>/dev/null)
        validate_port "$ssh_port" || ssh_port=22
        ip6_block=$(cat << EOF

table ip6 filter {
    # IPv6 动态访客集合（含超时）
    set temp_ips6 {
        type ipv6_addr
        flags timeout
    }

    # 【IPv6 防御层】精准转发拦截
    chain prerouting_filter {
        type filter hook prerouting priority -150; policy accept;
        ct state established,related accept
        meta l4proto ipv6-icmp accept
        include "$ACTION6_FILE"
    }

    chain input {
        type filter hook input priority filter; policy accept;
        ct state established,related accept
        iifname "lo" accept
        meta l4proto ipv6-icmp accept

        # IPv6 input 默认放行，白名单只在 prerouting 精准拦截转发/realm 入口端口
        include "$REALM_INPUT6_FILE"
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
        include "$MSS_FILE"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
)
        tmp=$(mktemp)
        awk -v block="$ip6_block" '
            /# 2\. 引入 NAT 转发表/ && !done {print block; done=1}
            {print}
            END {if (!done) print block}
        ' "$MAIN_CONF" > "$tmp" && mv "$tmp" "$MAIN_CONF"
        changed=1
    elif ! grep -q "realm_input6.nft" "$MAIN_CONF" 2>/dev/null; then
        echo -e "${YELLOW}检测到已有自定义 table ip6 filter，未自动插入 realm_input6，请按需手动加入 include \"$REALM_INPUT6_FILE\"${RESET}"
        log_msg WARN INIT "已有 table ip6 filter，未自动补充 realm_input6 include"
    fi

    [ "$changed" = "1" ] && log_msg INFO INIT "已为现有 nftables.conf 补充 IPv6 白名单 / realm 支持"
}

init_env() {
    [ "$EUID" -ne 0 ] && err_exit "请用 root 运行"

    mkdir -p "$DIR_PATH" "$BACKUP_DIR"
    touch "$CONFIG_FILE"
    [ ! -f "$STATUS_FILE" ] && echo "OFF" > "$STATUS_FILE"
    [ ! -f "$ACTION_FILE" ] && touch "$ACTION_FILE"
    [ ! -f "$ACTION6_FILE" ] && touch "$ACTION6_FILE"
    [ ! -f "$REALM_INPUT_FILE" ] && echo "        # 当前没有 IPv4 realm 监听端口" > "$REALM_INPUT_FILE"
    [ ! -f "$REALM_INPUT6_FILE" ] && echo "        # 当前没有 IPv6 realm 监听端口" > "$REALM_INPUT6_FILE"
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
# IPv4 专线前置拦截白名单 - 由 NF-Manager 管理
define ALLOWED_CIDRS = {
    127.0.0.1/32
}
EOF
    fi
    if [ ! -f "$WHITELIST6_DEF" ]; then
        cat > "$WHITELIST6_DEF" << 'EOF'
# IPv6 专线前置拦截白名单 - 由 NF-Manager 管理
define ALLOWED_CIDRS6 = {
    ::1/128
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

        echo -e "${YELLOW}【可选】realm 只在需要 IPv4/IPv6 跨协议族转发时才需要；同 v4 或同 v6 转发不需要。${RESET}"
        read -p "是否现在安装 realm？(y/N，回车=N 跳过): " realm_init
        if [ "$realm_init" = "y" ] || [ "$realm_init" = "Y" ]; then
            install_realm || echo -e "${YELLOW}realm 安装失败，基础 nftables 转发仍可继续使用。${RESET}"
        fi

        backup_file "$MAIN_CONF"
        cat > "$MAIN_CONF" << EOF
#!/usr/sbin/nft -f
flush ruleset

# 1. 白名单 CIDR 集合定义
include "$WHITELIST_DEF"
include "$WHITELIST6_DEF"

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

        # realm 跨 IPv4/IPv6 用户态转发监听端口
        include "$REALM_INPUT_FILE"
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
        include "$MSS_FILE"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table ip6 filter {
    # IPv6 动态访客集合（含超时）
    set temp_ips6 {
        type ipv6_addr
        flags timeout
    }

    # 【IPv6 防御层】精准转发拦截
    chain prerouting_filter {
        type filter hook prerouting priority -150; policy accept;
        ct state established,related accept
        meta l4proto ipv6-icmp accept
        include "$ACTION6_FILE"
    }

    chain input {
        type filter hook input priority filter; policy accept;
        ct state established,related accept
        iifname "lo" accept
        meta l4proto ipv6-icmp accept

        # IPv6 input 默认放行，白名单只在 prerouting 精准拦截转发/realm 入口端口
        include "$REALM_INPUT6_FILE"
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
        ensure_main_conf_v6_realm_support
    fi

    # 根据 dynamic / realm / 白名单状态同步后台服务和规则片段
    [ "$(cat "$STATUS_FILE" 2>/dev/null)" = "ON" ] && generate_whitelist_action
    sync_resolver_state
    sync_realm_state >/dev/null 2>&1 || true
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
        local wl_text mss_text resolver_text realm_text
        [ "$status_wl" = "ON" ] && wl_text="${GREEN}开启${RESET}" || wl_text="${RED}关闭${RESET}"
        [ "$status_mss" = "ON" ] && mss_text="${GREEN}开启${RESET}" || mss_text="${RED}关闭${RESET}"
        if [ -f "$RESOLVER_TIMER" ] && systemctl is-active --quiet nf_manager_resolver.timer 2>/dev/null; then
            resolver_text="${GREEN}运行中${RESET}"
        else
            resolver_text="${YELLOW}未启用${RESET}"
        fi
        case "$(realm_status_text)" in
            运行中) realm_text="${GREEN}运行中${RESET}" ;;
            已安装) realm_text="${YELLOW}已安装${RESET}" ;;
            *) realm_text="${YELLOW}未安装${RESET}" ;;
        esac

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
        printf '  %b%s%b %s [状态: %b]\n' "$CYAN"   " 5)" "$RESET" "$(pad_display "realm 管理(仅跨 v4/v6 需要)" 34)" "$realm_text"
        printf '  %b%s%b %s\n' "$CYAN"   " 6)" "$RESET" "$(pad_display "系统诊断 (内核/服务/规则/连通性)" 34)"
        printf '  %b%s%b %s\n' "$YELLOW" " 7)" "$RESET" "$(pad_display "查看操作日志" 34)"
        printf '  %b%s%b %s\n' "$YELLOW" " 8)" "$RESET" "$(pad_display "查看备份列表" 34)"
        printf '  %b%s%b %s\n' "$YELLOW" " 9)" "$RESET" "$(pad_display "仅卸载脚本本身 (保留服务与规则)" 34)"
        printf '  %b%s%b %s\n' "$RED"    "99)" "$RESET" "$(pad_display "⚠️  完全卸载 (清理全部，含可选 nftables/realm)" 34)"
        printf '  %b%s%b %s\n' "$CYAN"   " 0)" "$RESET" "退出"
        echo -e "${CYAN}══════════════════════════════════════════════════${RESET}"
        read -p "请输入指令: " choice
        case "$choice" in
            1)  forward_submenu ;;
            2)  defense_submenu ;;
            3)  manage_mss ;;
            4)  manage_resolver ;;
            5)  manage_realm ;;
            6)  diagnose ;;
            7)
                if [ -f "$LOG_FILE" ]; then
                    tail -50 "$LOG_FILE"
                    echo
                    echo -e "${YELLOW}（仅显示最近 50 行，完整日志: $LOG_FILE）${RESET}"
                else
                    echo "暂无日志"
                fi
                echo "按任意键返回..."; read -n 1 -s
                ;;
            8)
                if [ -d "$BACKUP_DIR" ]; then
                    ls -lhrt "$BACKUP_DIR" 2>/dev/null | tail -30
                    echo
                    echo -e "${YELLOW}（每种文件最多保留 ${BACKUP_KEEP} 份）${RESET}"
                else
                    echo "暂无备份"
                fi
                echo "按任意键返回..."; read -n 1 -s
                ;;
            9)  uninstall_panel_only ;;
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
