# 🚀 NF-Manager (nftables-keep)

**基于纯内核态的极速端口转发与智能保活面板**

在跨境网络中转（NAT）场景下，传统的 `socat` 或 `gost` 会带来极高的 CPU 上下文切换开销，而普通的 `iptables/nftables` 转发又极其容易遇到“TCP 闲置超时断流”的假死问题。

**NF-Manager** 专为解决这些痛点而生。它完全运行在 Linux 系统最底层的黑盒中（Kernel Space），并独创性地注入了“智能探活 (Keep-Alive) 雷达”，是专为极弱 CPU、小内存 VPS 打造的终极转发方案。

---

## ✨ 核心特性

- ⚡️ **纯内核态极速转发**：拒绝用户态（User-Space）性能损耗。流量到达网卡后直接在底层完成目标地址转换（DNAT/SNAT），压榨最后一滴带宽，CPU 占用几乎为零。
- 🛡️ **智能防断流 (Keep-Alive 雷达)**：自动唤醒内核 TCP 探活机制。闲置 5 分钟后自动发送心跳包，完美解决 NAT 追踪表（conntrack）超时导致的“假死、断流”问题。
- 🧠 **底层极致去重优化**：无论你映射多少个端口到同一个落地机，底层的源地址伪装（Masquerade）规则永远只生成一条，将内核负担降到最低。
- 💾 **多端口持久化管理**：内置 `nf_manager.list` 数据库。机器意外重启？不怕，所有转发规则与保活状态开机自动无损恢复。
- ⌨️ **全局快捷唤醒**：安装后自动注入环境变量，在任意目录输入 `nf` 即可秒开控制面板。

---

## 📦 一键安装与运行

请使用 `root` 用户登录你的 Linux 服务器，并直接复制执行以下命令：

```bash
bash <(curl -sL [https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh](https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh))
```

> **系统支持**：Ubuntu / Debian / CentOS / AlmaLinux (自动识别并安装环境)

---

## 🕹️ 面板使用说明

首次安装完成后，或日后在服务器的任何目录下，只需输入两个字母：

```bash
nf
```

即可瞬间调出可视化交互面板，支持以下操作：
1. **添加新的转发规则**（只需输入本地端口、目标 IP、目标端口即可）
2. **删除现有转发规则**（可视化序号，一键防错删除）
3. **强制重启并重载规则**（用于手动刷新内核状态与重载配置）

---

## 🔬 Under the Hood (底层原理解析)

为什么它比普通转发更稳？本脚本对 Linux 内核 `nf_conntrack` 进行了以下深度魔改：

1. **扩充追踪表容量**：`nf_conntrack_max = 262144`，防止高并发测速或大流量时追踪表被打爆。
2. **主动出击代替被动死等**：
   - 将默认长达几天的 TCP 闲置超时强制缩短至 `7200` 秒（2小时），快速清理内存。
   - 激活 `tcp_keepalive_time = 300`。两小时的超时时间未到，第 5 分钟内核就会主动发送心跳包重置倒计时，**实现“只要双方活着，连接永不超时；一旦一方断网，光速回收资源”的完美闭环。**
3. **光速回收僵尸连接**：大幅缩短 `time_wait` 和 `close_wait` 状态的停留时间，防止恶意的半开连接耗尽端口。

---

## 📄 License

MIT License
