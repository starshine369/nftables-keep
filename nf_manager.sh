#!/bin/bash

# =========================================================
# 项目名称：NF-Manager 纯内核极速转发与安全面板
# 版本：v3.0 (终极防线版)
# 特性：
# 1. 独立 NAT 转发模块，热加载无缝切换
# 2. 集成 IP 白名单一键编辑与防断网语法预检
# 3. 动态限时访客 (Temp IPs) 实时状态监控
# =========================================================

# --- [1. 路径定义] ---
DIR_PATH="/etc/nf_manager"
CONFIG_FILE="${DIR_PATH}/forward.list"
RULES_FILE="${DIR_PATH}/rules.nft"
WHITELIST_FILE="/etc/my_allow_ips.nft"
MAIN_CONF="/etc/nftables.conf"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- [2. 核心功能函数] ---

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

    nft -f "$RULES_FILE"
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

# --- [新增] 白名单管理模块 ---
edit_whitelist() {
    # 1. 检查并生成默认模板
    if [ ! -f "$WHITELIST_FILE" ]; then
        echo -e "${YELLOW}未检测到白名单文件，正在生成标准模板...${RESET}"
        cat > "$WHITELIST_FILE" << EOF
# 专线前置拦截白名单
# 注意：每行末尾必须加逗号，最后一行可不加。

define ALLOWED_CIDRS = {
    # 示例: 湖北电信网段
    113.56.0.0/15,
    
    # 示例: 山东特定IP
    1.2.3.4/32
}
EOF
    fi

    # 2. 调用 nano 编辑器 (简单易用)
    nano "$WHITELIST_FILE"

    # 3. 核心安全机制：语法预检 (Dry Run)
    echo -e "\n${CYAN}正在对配置文件进行内核级语法检查...${RESET}"
    if nft -c -f "$MAIN_CONF" >/dev/null 2>&1; then
        # 语法正确，正式应用
        nft -f "$MAIN_CONF"
        echo -e "${GREEN}✅ 语法校验通过！防火墙白名单已成功重载并生效。${RESET}"
    else
        # 语法错误，拒绝加载，保护机器不断网
        echo -e "${RED}❌ 致命错误：您刚才修改的文件存在语法错误（可能漏了逗号或大括号）。${RESET}"
        echo -e "${RED}⚠️ 为了防止机器断网，已拒绝重载规则。请重新编辑修复！${RESET}"
    fi
    echo "按任意键返回主菜单..."
    read -n 1 -s
}

# --- [新增] 限时访客查看模块 ---
view_temp_ips() {
    echo -e "\n${CYAN}--- ⏳ 当前处于临时放行的访客名单 ---${RESET}"
    
    # 尝试从内核提取 temp_ips 集合信息
    local temp_info=$(nft list set ip filter temp_ips 2>/dev/null)
    
    if [ -z "$temp_info" ]; then
         echo -e "${YELLOW}主配置文件中尚未配置 temp_ips 集合，或者集合不存在。${RESET}"
    elif echo "$temp_info" | grep -q "elements = { }"; then
         echo -e "${GREEN}当前没有任何临时放行的 IP。城墙紧闭！${RESET}"
    else
         # 提取并格式化输出 elements 里面的内容
         echo -e "${YELLOW}警告：以下 IP 拥有临时通行证！${RESET}"
         echo "$temp_info" | grep "expires" | sed 's/elements = { //g' | sed 's/ }//g' | tr ',' '\n' | while read -r line; do
             if [ -n "$line" ]; then
                 echo -e " 🔓 $line"
             fi
         done
    fi
    echo "------------------------------------------------"
    echo "按任意键返回主菜单..."
    read -n 1 -s
}

# --- [3. 模块化环境初始化] ---

init_env() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}请用 root 运行！${RESET}"; exit 1; fi

    mkdir -p "$DIR_PATH"
    touch "$CONFIG_FILE"

    if [[ "$0" == *"bash"* || "$0" == "/dev/fd/"* ]]; then
        # 如果你将其传到了 github，可以取消注释下面这行自动更新
        # curl -sL "https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh" -o /usr/local/bin/nf
        :
    else
        cp "$0" /usr/local/bin/nf
    fi
    chmod +x /usr/local/bin/nf

    if ! command -v nft >/dev/null 2>&1; then
        apt-get update && apt-get install -y nftables
    fi

    if [ ! -f "$RULES_FILE" ]; then
        apply_rules >/dev/null 2>&1
    fi

    # 不再重复向 main 写入 include
    if [ -f "$MAIN_CONF" ]; then
        if ! grep -q "include \"$RULES_FILE\"" "$MAIN_CONF"; then
            echo -e "\n# NF-Manager 转发模块注入" >> "$MAIN_CONF"
            echo "include \"$RULES_FILE\"" >> "$MAIN_CONF"
        fi
    fi
}

# --- [4. 主程序入口] ---
init_env

while true; do
    clear
    echo -e "${CYAN}=================================================${RESET}"
    echo -e "${CYAN}    🛡️ NF-Manager 专线安全网关面板 v3.0          ${RESET}"
    echo -e "${CYAN}=================================================${RESET}"
    list_rules
    echo -e "\n请选择操作:"
    echo -e "  ${GREEN}1.${RESET} ➕ 添加转发规则"
    echo -e "  ${RED}2.${RESET} ➖ 删除转发规则"
    echo -e "  ${YELLOW}3.${RESET} 🔄 手动热重载转发"
    echo -e "  ${CYAN}4.${RESET} 📝 编辑 CIDR 防御白名单 (自动重载主防火墙)"
    echo -e "  ${CYAN}5.${RESET} ⏳ 查看限时放行名单 (临时测试 IP)"
    echo -e "  ${CYAN}0.${RESET} 🚪 退出"
    echo -e "${CYAN}=================================================${RESET}"
    read -p "请输入指令 [0-5]: " choice
    case $choice in
        1) add_rule ;;
        2) delete_rule ;;
        3) apply_rules; sleep 2 ;;
        4) edit_whitelist ;;
        5) view_temp_ips ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; sleep 1 ;;
    esac
done
