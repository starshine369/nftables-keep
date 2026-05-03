#!/bin/bash

# =========================================================
# 项目名称：NF-Manager 纯内核极速转发与安全面板
# =========================================================

# --- [1. 路径定义] ---
DIR_PATH="/etc/nf_manager"
CONFIG_FILE="${DIR_PATH}/forward.list"
RULES_FILE="${DIR_PATH}/rules.nft"
WHITELIST_DEF="/etc/my_allow_ips.nft"
ACTION_FILE="${DIR_PATH}/whitelist_action.nft"
STATUS_FILE="${DIR_PATH}/whitelist.status"
MSS_FILE="${DIR_PATH}/mss.nft"
MSS_STATUS_FILE="${DIR_PATH}/mss.status"
MSS_VALUE_FILE="${DIR_PATH}/mss.value"
MAIN_CONF="/etc/nftables.conf"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- [2. 核心功能函数] ---

# 动态生成白名单拦截动作
generate_whitelist_action() {
    # 提取所有当前正在转发的本地端口，并拼接成逗号分隔格式 (例如: 8301,8302)
    local ports=$(awk '{print $1}' "$CONFIG_FILE" | grep -v '^[[:space:]]*$' | tr '\n' ',' | sed 's/,$//')
    
    if [ -z "$ports" ]; then
        echo "# 当前没有任何转发端口，白名单无生效目标" > "$ACTION_FILE"
    else
        cat > "$ACTION_FILE" << EOF
        # 核心防御：白名单与临时访客放行
        ip saddr \$ALLOWED_CIDRS accept
        ip saddr @temp_ips accept
        # 精准狙击：非白名单IP访问【转发端口】直接抛弃，其余端口正常放行至本机
        tcp dport { $ports } drop
        udp dport { $ports } drop
EOF
    fi
}

list_rules() {
    echo -e "\n${CYAN}--- 🚀 当前正在运行的转发规则 ---${RESET}"
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}目前没有任何转发规则。${RESET}"
    else
        printf "%-5s | %-12s | %-20s\n" "序号" "本地端口" "目标地址:端口"
        echo "------------------------------------------------"
        local idx=1
        while read -r l_port r_ip r_port; do
            if [ -n "$l_port" ]; then
                printf "%-4s | %-12s | %-20s\n" "[$idx]" "$l_port" "$r_ip:$r_port"
                ((idx++))
            fi
        done < "$CONFIG_FILE"
    fi
    echo "------------------------------------------------"
}

apply_rules() {
    cat > "$RULES_FILE" << EOF
table ip nf_manager_nat
flush table ip nf_manager_nat

table ip nf_manager_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF

    while read -r l_port r_ip r_port; do
        if [ -n "$l_port" ]; then
            echo "        tcp dport $l_port dnat to $r_ip:$r_port" >> "$RULES_FILE"
            echo "        udp dport $l_port dnat to $r_ip:$r_port" >> "$RULES_FILE"
        fi
    done < "$CONFIG_FILE"

    cat >> "$RULES_FILE" << EOF
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
EOF

    awk '{print $2}' "$CONFIG_FILE" | sort | uniq | while read -r r_ip; do
        if [ -n "$r_ip" ]; then
            echo "        ip daddr $r_ip masquerade" >> "$RULES_FILE"
        fi
    done

    echo "    }" >> "$RULES_FILE"
    echo "}" >> "$RULES_FILE"

    # 【新增逻辑】：如果白名单处于开启状态，规则变动时自动更新拦截端口
    local status=$(cat "$STATUS_FILE" 2>/dev/null)
    if [ "$status" == "ON" ]; then
        generate_whitelist_action
    fi

    nft -f "$MAIN_CONF" >/dev/null 2>&1
    echo -e "${GREEN}✅ 转发规则已热加载至内核独立区域！${RESET}"
}

add_rule() {
    read -p "请输入 [本地监听端口]: " l_port
    if grep -q "^${l_port} " "$CONFIG_FILE"; then
        echo -e "${RED}错误：端口 ${l_port} 已存在！${RESET}"
        sleep 2; return
    fi
    read -p "请输入 [目标落地机 IP]: " r_ip
    read -p "请输入 [目标落地机 端口]: " r_port

    if [ -n "$l_port" ] && [ -n "$r_ip" ] && [ -n "$r_port" ]; then
        echo "$l_port $r_ip $r_port" >> "$CONFIG_FILE"
        apply_rules
    else
        echo -e "${RED}输入不完整，操作取消。${RESET}"
    fi
    sleep 2
}

delete_rule() {
    list_rules
    if [ -s "$CONFIG_FILE" ]; then
        read -p "请输入要删除的序号 (0取消): " del_idx
        if [[ "$del_idx" =~ ^[0-9]+$ ]] && [ "$del_idx" -gt 0 ]; then
            sed -i "${del_idx}d" "$CONFIG_FILE"
            apply_rules
            echo -e "${GREEN}指定规则已移除并热更新！${RESET}"
        fi
    fi
    sleep 2
}

edit_whitelist() {
    nano "$WHITELIST_DEF"
    echo -e "\n${CYAN}正在对配置文件进行内核级语法检查...${RESET}"
    if nft -c -f "$MAIN_CONF" >/dev/null 2>&1; then
        nft -f "$MAIN_CONF"
        echo -e "${GREEN}✅ 语法校验通过！白名单已成功重载并生效。${RESET}"
    else
        echo -e "${RED}❌ 致命错误：语法错误（可能漏了逗号或大括号）。${RESET}"
        echo -e "${RED}⚠️ 为了防止断网，已拒绝重载。请重新编辑修复！${RESET}"
    fi
    echo "按任意键返回主菜单..."
    read -n 1 -s
}

toggle_whitelist() {
    local status=$(cat "$STATUS_FILE" 2>/dev/null)
    if [ "$status" == "ON" ]; then
        echo "" > "$ACTION_FILE"
        echo "OFF" > "$STATUS_FILE"
        nft -f "$MAIN_CONF"
        echo -e "${GREEN}🔓 防御已撤除：所有 IP 均可访问转发端口！${RESET}"
    else
        generate_whitelist_action
        echo "ON" > "$STATUS_FILE"
        nft -f "$MAIN_CONF"
        echo -e "${RED}🛡️ 精准防御启动：仅白名单 IP 可访问中转端口，本机业务正常放行！${RESET}"
    fi
    sleep 2
}

manage_mss() {
    local status=$(cat "$MSS_STATUS_FILE" 2>/dev/null)
    local current_val=$(cat "$MSS_VALUE_FILE" 2>/dev/null)
    [ -z "$current_val" ] && current_val="1338"

    echo -e "\n${CYAN}--- 🛠️ MTU/MSS 钳制调优 ---${RESET}"
    echo -e "当前状态: $([ "$status" == "ON" ] && echo -e "${GREEN}开启${RESET}" || echo -e "${RED}关闭${RESET}")"
    echo -e "当前参数: ${YELLOW}set maxseg size $current_val${RESET}"
    echo -e "--------------------------"
    echo -e "1. 切换 开启/关闭"
    echo -e "2. 修改 MSS 数值"
    echo -e "0. 返回主菜单"
    read -p "请选择: " mss_choice

    case $mss_choice in
        1)
            if [ "$status" == "ON" ]; then
                echo "" > "$MSS_FILE"
                echo "OFF" > "$MSS_STATUS_FILE"
            else
                echo "tcp flags syn tcp option maxseg size set $current_val" > "$MSS_FILE"
                echo "ON" > "$MSS_STATUS_FILE"
            fi
            nft -f "$MAIN_CONF"
            echo -e "${GREEN}设置已生效！${RESET}"
            sleep 1
            ;;
        2)
            read -p "请输入新的 MSS 数值 (推荐 1300-1400): " new_val
            if [[ "$new_val" =~ ^[0-9]+$ ]]; then
                echo "$new_val" > "$MSS_VALUE_FILE"
                if [ "$status" == "ON" ]; then
                    echo "tcp flags syn tcp option maxseg size set $new_val" > "$MSS_FILE"
                    nft -f "$MAIN_CONF"
                fi
                echo -e "${GREEN}数值已更新！${RESET}"
            else
                echo -e "${RED}输入非法。${RESET}"
            fi
            sleep 1
            ;;
    esac
}

view_temp_ips() {
    echo -e "\n${CYAN}--- ⏳ 当前处于临时放行的访客名单 ---${RESET}"
    local temp_info=$(nft list set ip filter temp_ips 2>/dev/null)
    
    if [ -z "$temp_info" ]; then
         echo -e "${YELLOW}主配置文件中尚未配置 temp_ips 集合。${RESET}"
    elif echo "$temp_info" | grep -q "elements = { }"; then
         echo -e "${GREEN}当前没有任何临时放行的 IP。城墙紧闭！${RESET}"
    else
         echo -e "${YELLOW}警告：以下 IP 拥有临时通行证！${RESET}"
         echo "$temp_info" | grep "expires" | sed 's/elements = { //g' | sed 's/ }//g' | tr ',' '\n' | while read -r line; do
             if [ -n "$line" ]; then echo -e " 🔓 $line"; fi
         done
    fi
    echo "------------------------------------------------"
    echo "按任意键返回主菜单..."
    read -n 1 -s
}

uninstall_script() {
    clear
    echo -e "${RED}=================================================${RESET}"
    echo -e "${RED}              ⚠️ 危险操作：完全卸载 ⚠️               ${RESET}"
    echo -e "${RED}=================================================${RESET}"
    echo -e "此操作将彻底删除 NF-Manager 面板，并清空所有转发与拦截规则。"
    read -p "您确定要继续吗？(y/n): " confirm_un
    if [[ "$confirm_un" != "y" && "$confirm_un" != "Y" ]]; then
        echo -e "${GREEN}已取消卸载。${RESET}"
        sleep 2
        return
    fi

    echo -e "\n${CYAN}[1/4] 正在清理内核规则与恢复主配置文件...${RESET}"
    if [ -f "${MAIN_CONF}.bak" ]; then
        echo -e "${YELLOW}发现初始备份文件，正在为您还原...${RESET}"
        mv "${MAIN_CONF}.bak" "$MAIN_CONF"
        nft -f "$MAIN_CONF" >/dev/null 2>&1
    else
        echo -e "${YELLOW}未发现备份，正在为您重置为空白状态...${RESET}"
        echo -e "#!/usr/sbin/nft -f\nflush ruleset" > "$MAIN_CONF"
        nft flush ruleset >/dev/null 2>&1
    fi

    echo -e "${CYAN}[2/4] 正在删除脚本目录与配置文件...${RESET}"
    rm -rf "$DIR_PATH"
    rm -f "$WHITELIST_DEF"

    echo -e "${CYAN}[3/4] 正在移除全局 nf 命令...${RESET}"
    rm -f /usr/local/bin/nf

    echo -e "${CYAN}[4/4] 环境清理选项...${RESET}"
    read -p "是否需要同时彻底卸载 nftables 软件包？(如果您不再使用任何防火墙，请选y。默认n): " purge_nft
    if [[ "$purge_nft" == "y" || "$purge_nft" == "Y" ]]; then
        echo -e "${YELLOW}正在卸载 nftables...${RESET}"
        apt-get remove --purge -y nftables >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
    fi

    echo -e "\n${GREEN}✅ 卸载完毕！系统已恢复纯净状态。指挥官，江湖再见！${RESET}"
    exit 0
}

# --- [3. 自动架构初始化] ---
init_env() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}请用 root 运行！${RESET}"; exit 1; fi

    mkdir -p "$DIR_PATH"
    touch "$CONFIG_FILE"
    [ ! -f "$STATUS_FILE" ] && echo "OFF" > "$STATUS_FILE"
    [ ! -f "$ACTION_FILE" ] && touch "$ACTION_FILE"
    
    [ ! -f "$MSS_STATUS_FILE" ] && echo "OFF" > "$MSS_STATUS_FILE"
    [ ! -f "$MSS_VALUE_FILE" ] && echo "1338" > "$MSS_VALUE_FILE"
    [ ! -f "$MSS_FILE" ] && touch "$MSS_FILE"

    if [[ "$0" == *"bash"* || "$0" == *"/dev/fd/"* ]]; then
        curl -sL "https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh" -o /usr/local/bin/nf 2>/dev/null
    else
        cp "$0" /usr/local/bin/nf 2>/dev/null
    fi
    chmod +x /usr/local/bin/nf 2>/dev/null

    if ! command -v nft >/dev/null 2>&1; then
        apt-get update && apt-get install -y nftables
    fi

    if [ ! -f "$WHITELIST_DEF" ]; then
        cat > "$WHITELIST_DEF" << EOF
# 专线前置拦截白名单
define ALLOWED_CIDRS = {
    127.0.0.1/32
}
EOF
    fi

    if [ ! -f "$RULES_FILE" ]; then apply_rules >/dev/null 2>&1; fi

    if ! grep -q "nf_manager/rules.nft" "$MAIN_CONF" 2>/dev/null; then
        echo -e "${CYAN}正在初始化内核防火墙框架...${RESET}"
        read -p "【配置】请输入当前机器的 SSH 端口 (默认22): " ssh_port
        [ -z "$ssh_port" ] && ssh_port="22"
        
        read -p "【调优】是否默认开启 MTU 钳制? (y/n, 默认n): " mss_init
        if [ "$mss_init" == "y" ]; then
            echo "tcp flags syn tcp option maxseg size set 1338" > "$MSS_FILE"
            echo "ON" > "$MSS_STATUS_FILE"
        fi

        [ -f "$MAIN_CONF" ] && cp "$MAIN_CONF" "${MAIN_CONF}.bak"
        
        cat > "$MAIN_CONF" << EOF
#!/usr/sbin/nft -f
flush ruleset

# 1. 引入白名单 CIDR 集合文件
include "$WHITELIST_DEF"

table ip filter {
    # 动态访客集合
    set temp_ips {
        type ipv4_addr
        flags timeout
    }

    # 【防御层：精准转发拦截】
    chain prerouting_filter {
        type filter hook prerouting priority -150; policy accept;
        
        ct state established,related accept
        tcp dport $ssh_port accept

        # 动态挂载精准白名单策略
        include "$ACTION_FILE"
    }

    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        iifname "lo" accept
        ip protocol icmp accept
        
        tcp dport $ssh_port accept
        
        # 本地业务 (此处放行的端口不受到白名单的影响)
        tcp dport { 80, 443, 2053, 2083, 8443, 35782, 42755, 51294 } accept
        udp dport 35782 accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
        include "$MSS_FILE"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

# 引入 NAT 转发规则
include "$RULES_FILE"
EOF
        nft -f "$MAIN_CONF"
        echo -e "${GREEN}✅ 框架初始化完成！${RESET}"
        sleep 2
    fi
}

# --- [4. 主程序入口] ---
init_env

while true; do
    clear
    status_wl=$(cat "$STATUS_FILE" 2>/dev/null)
    status_mss=$(cat "$MSS_STATUS_FILE" 2>/dev/null)
    
    echo -e "${CYAN}=================================================${RESET}"
    echo -e "${CYAN}          NF-Manager 专线安全网关面板 v4.4          ${RESET}"
    echo -e "${CYAN}=================================================${RESET}"
    list_rules
    echo -e "\n请选择操作:"
    echo -e "  ${GREEN}1.${RESET} 添加转发规则"
    echo -e "  ${RED}2.${RESET} 删除转发规则"
    echo -e "  ${YELLOW}3.${RESET} 手动热重载全局网络"
    echo -e "  ${CYAN}4.${RESET} 编辑 CIDR 防御白名单"
    echo -e "  ${CYAN}5.${RESET} 白名单拦截开关  [当前: $([ "$status_wl" == "ON" ] && echo -e "${GREEN}开启${RESET}" || echo -e "${RED}关闭${RESET}")]"
    echo -e "  ${CYAN}6.${RESET} MTU/MSS 钳制调优 [当前: $([ "$status_mss" == "ON" ] && echo -e "${GREEN}开启${RESET}" || echo -e "${RED}关闭${RESET}")]"
    echo -e "  ${CYAN}7.${RESET} 查看限时放行名单 (Temp IPs)"
    echo -e "  ${RED}8. 完全卸载面板 (清理全部规则及文件)${RESET}"
    echo -e "  ${CYAN}0.${RESET} 退出"
    echo -e "${CYAN}=================================================${RESET}"
    read -p "请输入指令 [0-8]: " choice
    case $choice in
        1) add_rule ;;
        2) delete_rule ;;
        3) nft -f "$MAIN_CONF"; echo -e "${GREEN}已重载！${RESET}"; sleep 1 ;;
        4) edit_whitelist ;;
        5) toggle_whitelist ;;
        6) manage_mss ;;
        7) view_temp_ips ;;
        8) uninstall_script ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; sleep 1 ;;
    esac
done