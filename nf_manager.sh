#!/bin/bash

# =========================================================
# 项目名称：NF-Manager 纯内核极速转发面板
# 版本：v2.0 (独立模块版 / 非侵入式)
# 特性：
# 1. 独立 Table (nf_manager_nat)，绝对不干扰系统原生规则
# 2. nft -f 热加载，修改规则无需重启 nftables 服务
# 3. 开机自启模块化注入
# =========================================================

# --- [1. 路径定义] ---
DIR_PATH="/etc/nf_manager"
CONFIG_FILE="${DIR_PATH}/forward.list"
RULES_FILE="${DIR_PATH}/rules.nft"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- [2. 核心功能函数] ---

list_rules() {
    echo -e "\n${CYAN}--- 当前正在运行的转发规则 ---${RESET}"
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
    # 动态生成独立的 nftables 配置文件
    cat > "$RULES_FILE" << EOF
# 声明独立的表，确保它存在
table ip nf_manager_nat

# 只清空我们自己的这块“自留地”，绝对不碰系统其他规则
flush table ip nf_manager_nat

table ip nf_manager_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF

    # 写入 DNAT 规则
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

    # 写入 SNAT 伪装规则
    awk '{print $2}' "$CONFIG_FILE" | sort | uniq | while read -r r_ip; do
        if [ -n "$r_ip" ]; then
            echo "        ip daddr $r_ip masquerade" >> "$RULES_FILE"
        fi
    done

    echo "    }" >> "$RULES_FILE"
    echo "}" >> "$RULES_FILE"

    # 【核心改动】：使用 nft -f 直接热加载文件到内核，不重启系统服务！
    nft -f "$RULES_FILE"
    echo -e "${GREEN}✅ 转发规则已热加载至内核独立区域！不影响现有防火墙。${RESET}"
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

# --- [3. 模块化环境初始化] ---

init_env() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}请用 root 运行！${RESET}"; exit 1; fi

    # 创建独立工作目录
    mkdir -p "$DIR_PATH"
    touch "$CONFIG_FILE"

    # 安装/更新快捷键
    if [[ "$0" == *"bash"* || "$0" == "/dev/fd/"* ]]; then
        # 你的 GitHub 仓库地址 (需根据实际情况修改)
        curl -sL "https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh" -o /usr/local/bin/nf
    else
        cp "$0" /usr/local/bin/nf
    fi
    chmod +x /usr/local/bin/nf

    # 安装依赖
    if ! command -v nft >/dev/null 2>&1; then
        apt-get update && apt-get install -y nftables
    fi

    # 首次运行生成空的规则文件
    if [ ! -f "$RULES_FILE" ]; then
        apply_rules >/dev/null 2>&1
    fi

    # 【开机自启模块化注入】
    # 将我们的独立文件 include 到主配置文件中，实现共存
    MAIN_CONF="/etc/nftables.conf"
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
    echo -e "${CYAN}    NF-Manager 非侵入式转发面板 v2.0           ${RESET}"
    echo -e "${CYAN}=================================================${RESET}"
    list_rules
    echo -e "\n请选择操作:"
    echo -e "  ${GREEN}1.${RESET} 添加规则"
    echo -e "  ${RED}2.${RESET} 删除规则"
    echo -e "  ${YELLOW}3.${RESET} 手动热重载"
    echo -e "  ${CYAN}0.${RESET} 退出"
    echo -e "${CYAN}=================================================${RESET}"
    read -p "请输入指令 [0-3]: " choice
    case $choice in
        1) add_rule ;;
        2) delete_rule ;;
        3) apply_rules; sleep 2 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; sleep 1 ;;
    esac
done
