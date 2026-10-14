# Linux Xray 安装器与节点管理器

两个独立脚本，用于在 Linux 服务器上部署和维护 Xray 节点：

- `xray-installer.sh`：首次安装 Xray，并创建节点。
- `xray-manager.sh`：按节点名称查看、修改、启停和删除已有入站。

支持 Alpine（OpenRC）以及 Debian、Ubuntu、Rocky、AlmaLinux、Fedora（systemd）。需要 root、可用的软件包仓库和正在运行的 systemd/OpenRC；不支持 Windows、macOS 或没有服务管理器的精简容器。脚本不会配置云防火墙、安全组或 NAT 映射。

## 快速开始

在服务器 root 终端安装下载工具，然后下载脚本：

```sh
# Alpine
apk add --no-cache ca-certificates wget
# Debian / Ubuntu
apt-get update && apt-get install -y ca-certificates wget
# Rocky / AlmaLinux / Fedora
dnf install -y ca-certificates wget
```

```sh
wget -O /root/xray-installer.sh \
  https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-installer.sh
chmod 700 /root/xray-installer.sh
sh /root/xray-installer.sh
```

管理已有节点：

```sh
wget -O /root/xray-manager.sh \
  https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-manager.sh
chmod 700 /root/xray-manager.sh
sh /root/xray-manager.sh
```

下载后可先用 `less`、`sed` 或 `sha256sum` 检查脚本。安装器从 GitHub 获取 Xray 版本及同版本、同架构 `.dgst` 文件并校验 SHA-256；官方元数据或校验失败会停止，不会执行未经验证的压缩包。

## 节点类型

安装器按节点角色决定协议，不是任意组合：

| 角色 | 入站 | 出站 |
| --- | --- | --- |
| 直连 | VLESS + Reality（TCP） | 服务器直连 |
| 中转 | VLESS + Reality（TCP） | Shadowsocks 落地 |
| 落地 | Shadowsocks（TCP，aes-128-gcm） | 服务器直连 |

可创建多个节点，但名称和内部监听端口不能冲突（包括停用节点）。默认内部端口为 Reality `443`、Shadowsocks `8388`。NAT 环境需填写内部端口和服务商/路由器映射的外部端口；映射本身由你配置。

Reality 默认 SNI 为 `apps.apple.com`，也可从候选目标中测速选择；Cloudflare 仅允许 `speed.cloudflare.com`。客户端与服务器时间都必须准确，脚本会检查时间同步；NAT 需要允许出站 UDP 123，无法由容器修改时钟则应由宿主机校时。

安装器会安装所需依赖、注册 Xray 服务并尝试启用 BBR。内核不支持或容器无权修改时仅提示并继续，不会替换内核。

## 管理器功能

管理器以入站 `tag` 作为节点名称，不提供独立用户账号。每次操作后会回到当前节点菜单，输入 `0` 返回节点列表。

- 显示 VLESS/SS 导入链接。
- 修改名称、内部/外部端口、客户端地址、SNI、UUID/密码和中转 SS 出口。
- 开启/关闭连接日志与字节统计。
- 设置最大连接数（`0` 为不限）和月流量上限（`0` 为不限）。
- 停用、启用或删除节点。

配置变更会先运行 `xray run -test -format json`，通过后才重启服务；重启失败会恢复本次配置和状态。重启会中断同一 Xray 进程中所有节点的现有连接。

## 统计、日志与限制

StatsService 记录每个入站的累计上行/下行字节，不是抓包计费，也不是每个 HTTP 请求的精确数量。启用统计、日志、月流量或连接限制后，管理器会安装每分钟运行的 root crontab 采样任务，并按发行版启用 `cron`/`crond`。

- **月流量**：按 UTC 周期、上行加下行计算 GiB；达到上限后停用整个节点，最多可能多出一个采样间隔的流量。重置日为 `1–31`，不存在的日期按月末处理。新周期只自动恢复因月流量超限停用的节点。
- **最大连接数**：仅适用于 TCP 节点，是每分钟检查的软限制；统计本机 `ESTABLISHED` 连接，包含本地连接，不代表人数。超限后停用节点，不会即时拒绝第 N+1 条连接；UDP、Mux 和共享端口节点不接受非零限制。
- **连接日志**：节点日志只保存目标（域名/IP:端口）和状态，不保存 URL、查询参数或正文。原始 access log 仍可能包含来源地址；日志默认权限为目录 `700`、文件 `600`，不会自动轮转，请自行管理磁盘空间。

统计 API 仅绑定本机回环地址，不对公网开放。每分钟采样前异常退出、重启或掉电可能造成少量统计丢失，不适合作为零误差账单。

## 文件与服务

- 配置：`/etc/xray/config.json`
- 管理状态：`/etc/xray/manager-state.json`
- 原始访问日志：`/etc/xray/logs/access.log`
- 节点日志：`/etc/xray/logs/<节点名>-connections.log`
- 管理器采样副本：`/etc/xray/manager.sh`

Alpine：

```sh
rc-service xray status
rc-service xray restart
```

systemd：

```sh
systemctl status xray
systemctl restart xray
journalctl -u xray
```

请自行放行实际监听端口（Reality/SS 为 TCP）及 NAT 映射端口。RPM 系统遇到权限拒绝时，应检查 `journalctl -u xray` 和 SELinux 审计日志，不要直接关闭 SELinux。

## Reality 回落过滤

受管理的 Reality 节点会生成仅监听 `127.0.0.1` 的独立回落入口，并将未匹配的回落导向 `blackhole`，避免借共享 CDN 回落访问其他域名。过滤端口从 `20000–65535` 自动分配，避开已有配置和停用节点保留端口；请勿手动使用 `reality-filter-` 标签前缀。

该措施不是全局限速或 DDoS 防护，也不会阻止访问允许的目标。已有节点需更新管理脚本并执行一次应用配置的操作（例如修改 SNI）后才会生效；仅替换脚本不会立即改变正在运行的服务。

## 已移除 HY2

当前版本只创建和管理 VLESS + Reality、Shadowsocks。更新脚本不会自动删除服务器已有的 HY2 入站、证书、Cloudflare 凭据或旧续期任务；如需清理，请先备份并手动处理关联配置，避免影响现有 VLESS 节点。
