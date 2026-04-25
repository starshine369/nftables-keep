#!/bin/bash

# =========================================================
# 项目名称：NF-Manager 纯内核极速转发面板
# 适用环境：Debian/Ubuntu (针对上海本地互联跳板机优化)
# 功能：内核级转发、高并发保活、快捷命令管理
# =========================================================

VERSION="v1.2.0"
CONFIG_FILE="/etc/nf_manager.list"
SYSCTL_FILE="/etc/sysctl.d/99-nftables-forward.conf"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# ---------------------------------------------------------
# 1. 核心功能函数定义 (必须在主程序运行前加载)
# ---------------------------------------------------------

# 查看当前规则
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
        done < $CONFIG_FILE
    fi
    echo "------------------------------------------------"
}

# 应用 nftables 规则到内核
apply_rules() {
    local temp_conf="/etc/nftables.conf.tmp"
    
    cat > $temp_conf << EOF
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF

    # 写入 DNAT 转发规则
    while read -r l_port r_ip r_port; do
        if [ -n "$l_port" ]; then
            echo "        tcp dport $l_port dnat to $r_ip:$r_port" >> $temp_conf
            echo "        udp dport $l_port dnat to $r_ip:$r_port" >> $temp_conf
        fi
    done < $CONFIG_FILE

    cat >> $temp_conf << EOF
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
EOF

    # SNAT 伪装：自动提取落地机 IP
    awk '{print $2}' $CONFIG_FILE | sort | uniq | while read -r r_ip; do
        if [ -n "$r_ip" ]; then
            echo "        ip daddr $r_ip masquerade" >> $temp_conf
        fi
    done

    echo "    }" >> $temp_conf
    echo "}" >> $temp_conf

    mv $temp_conf /etc/nftables.conf
    systemctl enable nftables >/dev/null 2>&1
    systemctl restart nftables
    echo -e "${GREEN}✅ 规则已成功应用到内核转发引擎！${RESET}"
}

# 添加新规则
add_rule() {
    read -p "请输入 [本地监听端口]: " l_port
    if grep -q "^${l_port} " "$CONFIG_FILE"; then
        echo -e "${RED}错误：端口 ${l_port} 已存在！${RESET}"
        sleep 2 && return
    fi
    
    read -p "请输入 [目标落地机 IP]: " r_ip
    read -p "请输入 [目标落地机 端口]: " r_port

    if [ -n "$l_port" ] && [ -n "$r_ip" ] && [ -n "$r_port" ]; then
        echo "$l_port $r_ip $r_port" >> $CONFIG_FILE
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
        read -p "请输入要删除的 [序号] (0取消): " del_idx
        if [[ "$del_idx" =~ ^[0-9]+$ ]] && [ "$del_idx" -gt 0 ]; then
            sed -i "${del_idx}d" $CONFIG_FILE
            apply_rules
            echo -e "${GREEN}规则已成功移除。${RESET}"
        fi
    fi
    sleep 2
}

# ---------------------------------------------------------
# 2. 系统初始化逻辑
# ---------------------------------------------------------

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请使用 root 用户运行此脚本！${RESET}"
        exit 1
    fi
}

init_system() {
    # 确保规则文件存在
    touch $CONFIG_FILE

    # 快捷命令安装/更新
    cp "$0" /usr/local/bin/nf
    chmod +x /usr/local/bin/nf

    # 安装 nftables
    if ! command -v nft >/dev/null 2>&1; then
        echo -e "${YELLOW}=> 正在安装 nftables 组件...${RESET}"
        apt-get update -y && apt-get install -y nftables
    fi

    # 转发与保活参数优化
    if [ ! -f "$SYSCTL_FILE" ]; then
        modprobe nf_conntrack 2>/dev/null
        cat > $SYSCTL_FILE << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.netfilter.nf_conntrack_max = 65536
net.ipv4.tcp_keepalive_time = 600
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
EOF
        sysctl --system >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------
# 3. 主程序入口
# ---------------------------------------------------------

check_root
init_system

while true; do
    clear
    echo -e "${CYAN}=================================================${RESET}"
    echo -e "${CYAN}    NF-Manager 纯内核转发面板 ${VERSION} (SH-Ali)    ${RESET}"
    echo -e "${CYAN}=================================================${RESET}"
    list_rules
    echo -e "\n请选择操作:"
    echo -e "  ${GREEN}1.${RESET} ➕ 添加新的转发规则"
    echo -e "  ${RED}2.${RESET} 🗑️  删除现有转发规则"
    echo -e "  ${YELLOW}3.${RESET} 🔄 强制重载/重启服务"
    echo -e "  ${CYAN}0.${RESET} 🚪 退出管理面板"
    echo -e "${CYAN}=================================================${RESET}"
    read -p "请输入指令 [0-3]: " choice

    case $choice in
        1) add_rule ;;
        2) delete_rule ;;
        3) apply_rules; sleep 2 ;;
        0) echo -e "${GREEN}已退出。以后在任意地方输入 'nf' 即可进入面板！${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效输入，请重试。${RESET}"; sleep 1 ;;
    esac
done
