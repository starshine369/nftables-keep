# 🚀 NF-Manager (nftables-keep) · v5.0

**基于纯内核态的极速端口转发与智能管理面板**

在跨境网络中转（NAT）场景下，传统的 `socat` 或 `gost` 会带来极高的 CPU 上下文切换开销，而普通的 `iptables/nftables` 转发又极其容易遇到"TCP 闲置超时断流"的假死问题。

**NF-Manager** 专为解决这些痛点而生。完全运行在 Linux 内核态（Kernel Space），独创"智能探活 (Keep-Alive) 雷达"，专为极弱 CPU、小内存 VPS 打造的终极转发方案。

---

## ✨ 核心特性

- ⚡️ **纯内核态极速转发**：流量到达网卡后直接在底层完成目标地址转换（DNAT/SNAT），CPU 占用几乎为零。
- 🛡️ **智能防断流 Keep-Alive**：自动唤醒内核 TCP 探活机制，闲置 5 分钟后发送心跳包，解决 conntrack 超时假死。
- 🧠 **Masquerade 自动去重**：相同目标 IP 的多端口转发，底层 SNAT 规则只生成一条。
- 💾 **配置持久化**：所有规则开机自动恢复。
- ⌨️ **全局快捷唤醒**：在任意目录输入 `nf` 即可调出面板。

### v5.0 新增

- 📝 **规则备注**：每条转发规则可附带备注，方便查阅
- 🔀 **协议精细控制**：每条规则可选 `TCP+UDP` / 仅 TCP / 仅 UDP
- 🌐 **域名转发支持**：
  - **静态域名**：脚本解析一次后当 IP 用
  - **动态 DDNS**：后台 systemd timer 周期解析，IP 变了自动热重载（默认 60s，可配置）
  - **智能启停**：无 dynamic 规则时 timer 不运行，零额外开销
- 🩺 **系统诊断**：一键检查内核转发参数、nftables 自启、规则加载状态、其他防火墙冲突、转发连通性、conntrack 水位、resolver 状态
- 📋 **批量端口段**：一次性添加 `8000-8010` 这种连续端口段
- ✏️ **规则编辑**：直接修改备注 / 目标 / 协议，无需"删了重加"
- 📦 **导出/导入配置**：跨机器迁移更轻松
- 🧰 **多发行版兼容**：自动适配 `apt` / `dnf` / `yum`
- 💾 **集中备份**：所有备份统一放 `/etc/nf_manager/backups/`，每种文件最多保留 7 份自动清理
- 📜 **完整日志**：所有操作记录到 `/var/log/nf_manager.log`，由 `logrotate` 自动按周/1MB 轮转保留 7 份
- 🔄 **卸载分两档**：
  - `8` 仅删脚本本身（保留服务/规则/数据）
  - `99` 完全卸载（清理一切，环境恢复纯净）
- 🐛 **大量 bug 修复**：删除序号映射错误、白名单协议不精确、`nft -f` 错误被吞、规则未严格校验等

---

## 📦 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh)
```

> **系统支持**：Debian / Ubuntu / CentOS / AlmaLinux / RockyLinux 等主流发行版（自动识别包管理器）

---

## 🕹️ 使用

安装后任意目录输入：

```bash
nf
```

调出可视化面板。

### 命令行模式

```bash
nf --apply             # 重新热加载规则（排障时用）
nf --diagnose          # 直接跑系统诊断
nf --resolver-tick     # DDNS 解析检查（由 systemd timer 调用，一般不用手动跑）
nf --version           # 显示版本
nf --help              # 帮助
```

---

## 🗂️ 文件结构

```
/etc/nf_manager/
├── forward.list                       转发规则配置（| 分隔六段）
├── rules.nft                          自动生成的 nftables NAT 规则
├── resolver.cache                     DDNS 解析缓存
├── backups/                           集中备份目录（每种文件保留 7 份）
│   ├── nftables.conf.20260526-153012.bak
│   ├── forward.list.20260526-153012.bak
│   └── ...
└── ...
/etc/nftables.conf                     主配置文件
/etc/my_allow_ips.nft                  CIDR 白名单
/etc/sysctl.d/99-nf_manager.conf       内核转发持久化
/etc/logrotate.d/nf_manager            日志轮转配置
/etc/systemd/system/nf_manager_resolver.{service,timer}   DDNS 后台服务
/var/log/nf_manager.log                操作日志
/usr/local/bin/nf                      主程序入口
```

### 规则文件格式

`forward.list` 每行一条规则，6 段以 `|` 分隔：

```
本地端口|目标(IP或域名)|目标端口|协议|模式|备注
```

- **协议**：`tcp` / `udp` / `tcp+udp`
- **模式**：`ip`（普通 IP） / `static`（域名首次解析后冻结） / `dynamic`（DDNS 持续跟随）

旧版 3 段空格格式会在首次启动时自动迁移并备份。

---

## 🔒 安全提醒

- 完全卸载（`99`）会清理所有数据，备份目录 `/etc/nf_manager/backups/` 也会一并删除，请在卸载前手动留存所需文件
- 添加 dynamic 域名规则时会自动启动 systemd timer，删除最后一条 dynamic 规则时自动停止
- 白名单拦截开启后，非白名单 IP 无法访问任何转发端口，但本机业务端口（80/443/SSH 等）不受影响

---

## 📄 License

MIT License
