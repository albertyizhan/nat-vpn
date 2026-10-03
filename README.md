# Alpine Xray 多模式安装器

面向 Alpine Linux / OpenRC 的交互式安装器，支持直连、中转和落地部署，以及 NAT / 非 NAT 网络。

## 快速开始

在目标 Alpine 机器的终端中，以 `root` 身份执行。脚本名称为 `xray-installer.sh`。

### 一键下载并运行

```sh
apk add --no-cache curl ca-certificates && curl -fL --connect-timeout 10 --max-time 120 -o /root/xray-installer.sh https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-installer.sh && sh /root/xray-installer.sh
```

只有下载成功才会运行。脚本从文件运行，终端输入保留给交互菜单；不要使用 `curl | sh`。

### 分步下载并运行

```sh
apk add --no-cache curl ca-certificates
curl -fL --connect-timeout 10 --max-time 120 \
  -o /root/xray-installer.sh \
  https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-installer.sh
sh /root/xray-installer.sh
```

已经下载脚本时，直接执行：

```sh
sh /root/xray-installer.sh
```

下载脚本本身需要能够访问 `raw.githubusercontent.com`；Xray 的镜像回退只在脚本启动后生效。

## 安装流程

1. 安装 `curl`、`unzip`、`openssl`、`jq` 和 CA 证书。
2. 动态查询并下载 Xray 最新正式发布，按 CPU 架构选择安装包。
3. 选择部署模式、角色和入站协议。
4. 选择 NAT / 非 NAT，填写端口及必要的节点参数。
5. 自动生成凭据和配置，检查配置并注册 OpenRC 开机自启。
6. 输出角色、协议、端口，以及可导入客户端的分享链接。

默认值会在每个输入提示中显示，按回车即可采用。公网 IP 自动探测结果用作连接地址默认值，可手动修改。

VLESS + Reality 默认使用 `xtls-rprx-vision`，服务端配置与生成的分享链接均包含此 Flow；客户端需支持 Vision。

## 部署模式

| 模式 | 角色 | 入站协议 | 出站 |
| --- | --- | --- | --- |
| 直连 | 直连节点 | VLESS + Reality + xtls-rprx-vision 或 Hysteria2 | 本机直连公网 |
| 中转 | 中转节点 | VLESS + Reality + xtls-rprx-vision 或 Hysteria2 | 用户指定的 Shadowsocks 落地节点 |
| 中转 | 落地节点 | Shadowsocks，默认 `aes-128-gcm`加密 | 本机直连公网 |

直连节点自动生成客户端凭据。落地节点自动生成 SS 密码；部署中转节点时，需要输入已有落地节点的地址、对外端口和相同密码。

两台机器部署时，先安装落地节点，再安装中转节点：

```text
客户端 -> 中转节点 VLESS + Reality / Hysteria2 -> 落地节点 Shadowsocks -> 公网
```

客户端使用中转节点输出的链接；落地节点的参数供中转节点连接。

## NAT 与端口

| 协议 | 传输 | 默认监听端口 |
| --- | --- | --- |
| VLESS + Reality + xtls-rprx-vision | TCP | `443` |
| Hysteria2 | UDP | `443` |
| Shadowsocks 落地 | TCP | `8388` |

- **非 NAT**：默认网络类型，监听端口也是公网访问端口，可修改。
- **NAT**：分别填写内部监听端口和实际外部映射端口；外部端口没有预设值，必须填写。
- Xray 配置使用内部端口，分享链接使用外部端口。
- 脚本不会创建路由器或服务商的 NAT 映射；需要自行配置对应的 TCP / UDP 映射和防火墙放行。

## Xray 版本与下载源

默认每次安装都查询 GitHub 官方最新正式发布，不写死版本号。API 不可用时，尝试通过最新发布页面的跳转获取版本。

优先从 GitHub 下载；失败时尝试 SourceForge 镜像中的**同一版本**。无法确认官方最新版，或两处均无法下载时，脚本报错并停止，不自动降级到固定旧版。

## Hysteria2 证书

Hysteria2 保持证书校验，不使用 `insecure=1`。选择此协议需要：

- 一个解析到该节点公网地址的域名。
- 用于证书通知的邮箱。
- 公网 TCP `80` 能到达本机 TCP `80`，供 Certbot 的 HTTP-01 验证使用；NAT 环境需额外配置这条映射。
- 节点服务端口的 UDP 访问可用。

脚本安装 Certbot 并申请受信任证书；申请失败时停止部署。证书有效期与续期需要另外管理。

## 服务管理

查看状态
```sh
rc-service xray status
```
重新启动
```sh
rc-service xray restart
```
测试配置
```sh
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

配置文件为 `/usr/local/etc/xray/config.json`。服务加入 OpenRC 的 `default` runlevel；服务输出丢弃到 `/dev/null`，不创建持久化日志文件。

---本脚本由GPT-6.1 sol编写，需反复改进
