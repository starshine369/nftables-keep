#!/bin/bash

# =========================================================
# 项目名称：nftables 纯内核极速转发管理面板 (NF-Manager)
# 特性：纯内核态 / 智能保活防断流 / 多端口管理 / 全局快捷键
# =========================================================

# 全局变量定义
CONFIG_FILE="/etc/nf_manager.list"
SYSCTL_FILE="/etc/sysctl.d/99-nftables-forward.conf"
VERSION="v1.0.0"

# 颜色输出
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# 1. 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本！${RESET}"
    exit 1
fi

# 2. 注入全局快捷命令 (nf)
install_shortcut() {
    if [ ! -f "/usr/local/bin/nf" ]; then
        cp "$0" /usr/local/bin/nf
        chmod +x /usr/local/bin/nf
        echo -e "${GREEN}✨ 已成功创建全局快捷命令！以后在任意目录输入 'nf' 即可唤出本面板。${RESET}"
        sleep 2
    fi
}

# 3. 初始化基础环境与底层的智能保活参数
init_env() {
    if ! command -v nft >/dev/null 2>&1; then
        echo -e "${YELLOW}=> 正在安装 nftables 核心组件...${RESET}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y nftables
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release && yum install -y nftables
        fi
    fi

    if [ ! -f "$SYSCTL_FILE" ]; then
        echo -e "${YELLOW}=> 正在写入内核级智能保活与转发参数...${RESET}"
        modprobe nf_conntrack 2>/dev/null
        echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

        cat > $SYSCTL_FILE << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.netfilter.nf_conntrack_max = 262144
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
EOF
        sysctl --system >/dev/null 2>&1
    fi
    
    # 确保配置文件存在
    touch $CONFIG_FILE
}

# 4. 根据配置文件重载 nftables 规则
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

    # 智能去重：提取唯一的落地机 IP 进行 SNAT 伪装
    awk '{print $2}' $CONFIG_FILE | sort | uniq | while read -r r_ip; do
        if [ -n "$r_ip" ]; then
            echo "        ip daddr $r_ip masquerade" >> $temp_conf
        fi
    done

    cat >> $temp_conf << EOF
    }
}
EOF

    mv $temp_conf /etc/nftables.conf
    systemctl enable nftables >/dev/null 2>&1
    systemctl restart nftables
    echo -e "${GREEN}✅ 规则已成功应用到系统内核！${RESET}"
}

# 5. 添加转发规则
add_rule() {
    read -p "请输入 [本地监听端口]: " l_port
    # 防呆检测：端口是否被占用或重复
    if grep -q "^${l_port} " "$CONFIG_FILE"; then
        echo -e "${RED}错误：本地端口 ${l_port} 已存在，请删除后再添加或使用其他端口！${RESET}"
        sleep 2
        return
    fi
    
    read -p "请输入 [目标落地机 IP]: " r_ip
    read -p "请输入 [目标落地机 端口]: " r_port

    if [ -n "$l_port" ] && [ -n "$r_ip" ] && [ -n "$r_port" ]; then
        echo "$l_port $r_ip $r_port" >> $CONFIG_FILE
        apply_rules
    else
        echo -e "${RED}参数输入不完整，取消添加。${RESET}"
    fi
    sleep 2
}

# 6. 查看当前规则
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

# 7. 删除转发规则
delete_rule() {
    list_rules
    if [ -s "$CONFIG_FILE" ]; then
        read -p "请输入要删除的 [序号] (输入 0 取消): " del_idx
        if [[ "$del_idx" =~ ^[0-9]+$ ]] && [ "$del_idx" -gt 0 ]; then
            # 使用 sed 删除对应行
            sed -i "${del_idx}d" $CONFIG_FILE
            echo -e "${GREEN}规则已删除。${RESET}"
            apply_rules
        fi
    fi
    sleep 2
}

# ================= 主菜单循环 =================
install_shortcut
init_env

while true; do
    clear
    echo -e "${CYAN}=================================================${RESET}"
    echo -e "${CYAN}       NF-Manager 纯内核极速转发面板 ${VERSION}       ${RESET}"
    echo -e "${CYAN}=================================================${RESET}"
    list_rules
    echo -e "\n请选择操作:"
    echo -e "  ${GREEN}1.${RESET} ➕ 添加新的转发规则"
    echo -e "  ${RED}2.${RESET} 🗑️  删除现有转发规则"
    echo -e "  ${YELLOW}3.${RESET} 🔄 强制重启并重载规则"
    echo -e "  ${CYAN}0.${RESET} 🚪 退出面板"
    echo -e "${CYAN}=================================================${RESET}"
    read -p "请输入数字 [0-3]: " choice

    case $choice in
        1) add_rule ;;
        2) delete_rule ;;
        3) apply_rules; sleep 2 ;;
        0) echo -e "${GREEN}已退出。随时输入 'nf' 再次唤醒本面板！${RESET}"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重试。${RESET}"; sleep 1 ;;
    esac
done