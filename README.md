# NF-Manager (nftables-keep)

**基于 nftables + 可选 realm 的端口转发与管理面板。**

NF-Manager 面向 Linux VPS 的端口转发、DDNS 跟随、白名单拦截和系统诊断场景，默认走 nftables 内核转发；只有 IPv4/IPv6 跨协议族转发才需要 realm。

---

## 功能概览

- nftables 端口转发管理
- IPv4 / IPv6 同族转发
- IPv4 ↔ IPv6 跨协议族转发（可选 realm）
- 域名转发：静态解析 / 动态 DDNS
- IPv4 / IPv6 白名单拦截
- 规则备注、编辑、批量添加、导入导出
- DDNS resolver 自动跟随解析变化
- MTU / MSS 调优
- 系统诊断与状态检查
- 双档卸载：仅删脚本 / 完全卸载
- 集中备份与日志轮转

---

## 一键安装

### 官方直连

```bash
bash <(curl -sL https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh)
```

### 国内机器 / GitHub 访问较慢时

```bash
bash <(curl -sL https://ghproxy.net/https://raw.githubusercontent.com/starshine369/nftables-keep/main/nf_manager.sh)
```

> 系统支持：Debian / Ubuntu / CentOS / AlmaLinux / RockyLinux 等主流发行版（自动识别包管理器）

---

## 使用

安装后任意目录输入：

```bash
nf
```

打开交互面板。

### 命令行模式

```bash
nf --apply             # 重新热加载规则（排障时用）
nf --diagnose          # 直接跑系统诊断
nf --resolver-tick     # DDNS 解析检查（由 systemd timer 调用，一般不用手动跑）
nf --version           # 显示版本
nf --help              # 帮助
```

---

## 文件结构

```
/etc/nf_manager/
├── forward.list                       转发规则配置（| 分隔八段）
├── rules.nft                          自动生成的 nftables NAT 规则
├── whitelist_action.nft               IPv4 白名单拦截片段
├── whitelist_action6.nft              IPv6 白名单拦截片段
├── realm_input.nft                    IPv4 realm 监听端口 input 放行片段
├── realm_input6.nft                   IPv6 realm 监听端口 input 放行片段
├── resolver.cache                     DDNS 解析缓存（A/AAAA 分协议族）
├── realm/                             realm TCP/UDP 配置
├── backups/                           集中备份目录（每种文件保留 7 份）
│   ├── nftables.conf.20260526-153012.bak
│   ├── forward.list.20260526-153012.bak
│   └── ...
└── ...
/etc/nftables.conf                     主配置文件
/etc/my_allow_ips.nft                  IPv4 CIDR 白名单
/etc/my_allow_ips6.nft                 IPv6 CIDR 白名单
/etc/sysctl.d/99-nf_manager.conf       内核转发持久化
/etc/logrotate.d/nf_manager            日志轮转配置
/etc/systemd/system/nf_manager_resolver.{service,timer}   DDNS 后台服务
/var/log/nf_manager.log                操作日志
/usr/local/bin/nf                      主程序入口
```

---

## 规则文件格式

`forward.list` 每行一条规则，8 段以 `|` 分隔：

```
本地端口|目标(IP或域名)|目标端口|协议|模式|备注|本地协议族|目标协议族
```

- **协议**：`tcp` / `udp` / `tcp+udp`
- **模式**：`ip`（普通 IP） / `static`（域名首次解析后冻结） / `dynamic`（DDNS 持续跟随）
- **协议族**：`4` / `6`；同族转发走 nftables，跨 v4/v6 走 realm

旧版 3 段空格格式和 v5 六段格式会在首次启动时自动迁移并备份。

---

## 安全提醒

- 完全卸载（`99`）会清理所有数据，备份目录 `/etc/nf_manager/backups/` 也会一并删除，请在卸载前手动留存所需文件
- 添加 dynamic 域名规则时会自动启动 systemd timer，删除最后一条 dynamic 规则时自动停止
- 白名单拦截开启后，非白名单 IPv4/IPv6 无法访问对应协议族入口的转发端口，但本机业务端口（80/443/SSH 等）不受影响

---

## License

MIT License