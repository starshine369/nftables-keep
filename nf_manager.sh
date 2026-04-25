#!/bin/bash

# =========================================================
# 项目名称：NF-Manager 纯内核极速转发面板
# 仓库地址：https://github.com/starshine369/nftables-keep
# 版本：v1.2.3 (核心修复版)
# =========================================================

# --- [1. 路径定义] ---
CONFIG_FILE="/etc/nf_manager.list"
# 你的 GitHub 原始脚本地址 (请确保此处地址正确)
RAW_URL="https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- [2. 核心功能函数 - 必须置顶] ---

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
    local temp_conf="/etc/nftables.conf"
    cat > "$temp_conf" << EOF
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF

    while read -r l_port r_ip r_port; do
        if [ -n "$l_port" ]; then
            echo "        tcp dport $l_port dnat to $r_ip:$r_port" >> "$temp_conf"
            echo "        udp dport $l_port dnat to $r_ip:$r_port" >> "$temp_conf"
        fi
    done < "$CONFIG_FILE"

    cat >> "$temp_conf" << EOF
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
EOF

    awk '{print $2}' "$CONFIG_FILE" | sort | uniq | while read -r r_ip; do
        if [ -n "$r_ip" ]; then
            echo "        ip daddr $r_ip masquerade" >> "$temp_conf"
        fi
    done

    echo "    }" >> "$temp_conf"
    echo "}" >> "$temp_conf"

    systemctl restart nftables
    echo -e "${GREEN}✅ 转发规则已成功应用到内核！${RESET}"
}

add_rule() {
    read -p "请输入 [本地监听端口]: " l_port
    if grep -q "^${l_port} " "$CONFIG_FILE"; then
        echo -e "${RED}错误：端口 ${l_port} 已存在！${RESET}"
        sleep 2; return
    fi
    read -p "请输入 [目标机 IP]: " r_ip
    read -p "请输入 [目标机 端口]: " r_port
    if [ -n "$l_port" ] && [ -n "$r_ip" ] && [ -n "$r_port" ]; then
        echo "$l_port $r_ip $r_port" >> "$CONFIG_FILE"
        apply_rules
    else
        echo -e "${RED}输入不完整。${RESET}"
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
            echo -e "${GREEN}规则已移除。${RESET}"
        fi
    fi
    sleep 2
}

# --- [3. 智能环境初始化] ---

init_env() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}请用 root 运行！${RESET}"; exit 1; fi

    # 快捷命令安装逻辑修复
    # 判断当前是本地运行还是 curl 运行
    if [[ "$0" == *"bash"* || "$0" == "/dev/fd/"* ]]; then
        # 如果是 curl 运行，则重新下载完整版到快捷路径
        curl -sL "$RAW_URL" -o /usr/local/bin/nf
    else
        # 如果是本地文件运行，则直接复制
        cp "$0" /usr/local/bin/nf
    fi
    chmod +x /usr/local/bin/nf

    touch "$CONFIG_FILE"
    if ! command -v nft >/dev/null 2>&1; then
        apt-get update && apt-get install -y nftables
    fi
}

# --- [4. 主程序入口] ---
init_env

while true; do
    clear
    echo -e "${CYAN}=================================================${RESET}"
    echo -e "${CYAN}    NF-Manager 纯内核转发面板 v1.2.3           ${RESET}"
    echo -e "${CYAN}=================================================${RESET}"
    list_rules
    echo -e "\n请选择操作:"
    echo -e "  ${GREEN}1.${RESET} 添加规则"
    echo -e "  ${RED}2.${RESET} 删除规则"
    echo -e "  ${YELLOW}3.${RESET} 重载服务"
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
