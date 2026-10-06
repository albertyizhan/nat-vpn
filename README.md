# Alpine Xray 安装器与管理器

面向 Alpine Linux / OpenRC 的通用 Xray 工具集，包含两个脚本：

| 脚本 | 用途 |
| --- | --- |
| `xray-installer.sh` | 首次安装 Xray，并创建直连、中转或落地节点 |
| `xray-manager.sh` | 管理已有 Xray 配置、多个协议和多个用户 |

脚本不绑定台湾、美国或固定端口，适合 NAT 和非 NAT 机器。

## 快速开始

### 首次安装

在目标 Alpine 机器上以 `root` 执行：

```sh
apk add --no-cache ca-certificates
if command -v curl >/dev/null 2>&1; then
  curl -fL --connect-timeout 10 --max-time 120 \
    -o /root/xray-installer.sh \
    https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-installer.sh
else
  wget -q -O /root/xray-installer.sh \
    https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-installer.sh
fi
chmod +x /root/xray-installer.sh
/root/xray-installer.sh
```

安装器会：

- 动态获取 Xray 最新正式版本
- 优先从 GitHub 下载，失败后尝试同版本 SourceForge 镜像
- 安装 `unzip`、`openssl`、`jq` 等依赖；没有 `curl` 时使用 BusyBox `wget`
- 支持 VLESS + Reality、Hysteria2、Shadowsocks
- 支持直连、中转、落地模式
- 支持 NAT / 非 NAT，并分别记录内部监听端口和外部映射端口
- 自动生成 UUID、密码、Reality 密钥、Short ID 和导入链接
- 创建节点时要求填写名称：必须以英文字母开头，后续只能使用英文字母和数字
- 允许同一台 NAT 机器创建多个相同协议节点，但每个节点必须使用不同名称和内部端口
- VLESS + Reality 默认 SNI 为 `www.bing.com`，可通过 `SERVER_NAME` 自定义；脚本拒绝使用 Cloudflare 域名
- 创建 VLESS 节点时可扫描 Bing、Amazon、Yahoo、Samsung、NVIDIA 候选域名，或手动输入 SNI；选定域名同时作为 Reality 目标（443），Apple 不在自动候选列表中
- 扫描在当前服务器上检查 TLS 1.3、X25519、H2、证书验证及证书消息大小，按本轮 TLS 建连时间推荐；不是客户端到节点的延迟测试，也不保证后续一直可用
- 注册 OpenRC 开机自启
- Hysteria2 安装后创建每日证书续期任务，续期成功自动重载 Xray

默认端口：

| 协议 | 默认端口 | 传输 |
| --- | ---: | --- |
| VLESS + Reality | 443 | TCP |
| Hysteria2 | 443 | UDP |
| Shadowsocks | 8388 | TCP |

NAT 模式必须填写内部端口和外部映射端口。脚本不会自动创建路由器或服务商的 NAT 映射。已有配置会被保留，新节点会追加到现有配置；名称重复或内部端口冲突时脚本会停止。

### 后续管理

安装器完成后，在同一台机器运行管理器：

```sh
if command -v curl >/dev/null 2>&1; then
  curl -fL --connect-timeout 10 --max-time 120 \
    -o /root/xray-manager.sh \
    https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-manager.sh
else
  wget -q -O /root/xray-manager.sh \
    https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-manager.sh
fi
chmod +x /root/xray-manager.sh
/root/xray-manager.sh
```

管理器会读取 `/etc/xray/config.json`，自动检测已有入站和用户，不会直接覆盖原配置。修改配置前会生成带时间戳的备份。安装器生成的节点名称会显示为入站标签和导入链接名称。

## 管理器功能

- 列出已有入站、协议、端口和用户
- 管理多个 VLESS、VMess、Trojan、Shadowsocks、Hysteria2 入站
- 添加或删除用户
- 启用 Xray StatsService 和本地 Handler API
- 设置每月流量配额
- 保存每个用户的最大在线数限制参数
- 生成每小时运行的配额检查脚本
- 达到月流量上限后移除对应入站中的用户并重载 Xray
- 配置修改和配额任务使用锁，避免并发覆盖

统计 API 只绑定 `127.0.0.1:10085`，不会额外暴露公网管理端口。

## 限制说明

月流量限制依赖 Xray Stats API 和定时检查任务，不是内核瞬时硬断流。最大在线数会保存到管理器状态，供外部计费或人工策略使用；Xray 通用 API 没有可靠的按用户即时并发连接硬限制字段，因此管理器不会伪装成原生硬限制。

Hysteria2 使用受信任证书，不使用 `insecure=1`。使用 Hysteria2 时需要域名解析和证书申请所需的 TCP 80 访问。

## 服务管理

```sh
rc-service xray status
rc-service xray restart
/usr/local/bin/xray run -test -config /etc/xray/config.json
```

默认服务输出丢弃到 `/dev/null`，不创建额外持久化日志。
