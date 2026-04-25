#!/bin/bash

# =========================================================
# 项目名称：NF-Manager 纯内核极速转发面板
# 仓库地址：https://github.com/starshine369/nftables-keep
# 特性：函数预载优化 / 仅管理规则 / 不修改内核参数 / 纯内核态转发
# =========================================================

# --- [1. 路径与变量定义] ---
CONFIG_FILE="/etc/nf_manager.list"
VERSION="v1.2.2"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# --- [2. 核心功能函数] ---
# 注意：所有函数必须写在脚本最上方，确保 Bash 预先加载

# 查看转发规则
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

# 将规则应用到 nftables
apply_rules() {
    local temp_conf="/etc/nftables.conf"
    
    # 构建 nftables 配置文件头部
    cat > "$temp_conf" << EOF
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF

    # 动态写入 DNAT 规则
    while read -r l_port r_ip r_port; do
        if [ -n "$l_port" ]; then
            echo "        tcp dport $l_port dnat to $r_ip:$r_port" >> "$temp_conf"
            echo "        udp dport $l_port dnat to $r_ip:$r_port" >> "$temp_conf"
        fi
    done < "$CONFIG_FILE"

    # 构建中间部分
    cat >> "$temp_conf" << EOF
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
EOF

    # 动态写入 SNAT (Masquerade) 规则
    awk '{print $2}' "$CONFIG_FILE" | sort | uniq | while read -r r_ip; do
        if [ -n "$r_ip" ]; then
            echo "        ip daddr $r_ip masquerade" >> "$temp_conf"
        fi
    done

    # 封口
    echo "    }" >> "$temp_conf"
    echo "}" >> "$temp_conf"

    # 重启服务使内核规则生效
    systemctl restart nftables
    echo -e "${GREEN}✅ 转发规则已同步至内核！${RESET}"
}

# 添加规则
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
        echo -e "${RED}输入不完整，取消添加。${RESET}"
    fi
    sleep 2
}

# 删除规则
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

# --- [3. 环境初始化] ---
init_env() {
    # 检查 Root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 运行！${RESET}"; exit 1
    fi

    # 强制同步快捷命令 (确保本地运行的代码与快捷键一致)
    cp "$0" /usr/local/bin/nf
    chmod +x /usr/local/bin/nf

    # 确保规则文件存在
    touch "$CONFIG_FILE"

    # 安装组件
    if ! command -v nft >/dev/null 2>&1; then
        echo -e "${YELLOW}=> 正在安装 nftables...${RESET}"
        apt-get update && apt-get install -y nftables
    fi
}

# --- [4. 主程序入口] ---
init_env

while true; do
    clear
    echo -e "${CYAN}=================================================${RESET}"
    echo -e "${CYAN}    NF-Manager 纯内核转发面板 ${VERSION}           ${RESET}"
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
