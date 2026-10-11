# Linux Xray 安装器与节点管理器

仓库只包含两个脚本：

- `xray-installer.sh`：首次安装 Xray，并创建 VLESS+Reality、Hysteria2 或 Shadowsocks 节点。
- `xray-manager.sh`：按节点名称管理已有入站。

支持 Alpine Linux（OpenRC），以及 Debian、Ubuntu、Rocky Linux、AlmaLinux、Fedora（systemd）；支持 NAT 和非 NAT。需要 root 和运行中的 systemd / OpenRC，不支持 Windows、macOS 或没有服务管理器的精简容器。

脚本根据 `/etc/os-release` 选择 `apk`、`apt-get` 或 `dnf`，未知发行版会停止。Rocky / AlmaLinux 安装 Certbot 时会启用 EPEL；软件包需在当前版本的仓库中可用。系统版本已停止维护或仓库不可用时，应先升级系统或修复仓库。

## 一键下载运行

在服务器的 root 终端执行。先按发行版安装下载工具：

```sh
# Alpine
apk add --no-cache ca-certificates wget
# Debian / Ubuntu
apt-get update && apt-get install -y ca-certificates wget
# Rocky / AlmaLinux / Fedora
dnf install -y ca-certificates wget
```

然后下载并运行安装器：

```sh
wget -O /root/xray-installer.sh \
  https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-installer.sh
chmod 700 /root/xray-installer.sh
sh /root/xray-installer.sh
```

管理器：

```sh
wget -O /root/xray-manager.sh \
  https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-manager.sh
chmod 700 /root/xray-manager.sh
sh /root/xray-manager.sh
```

脚本是仓库源码，下载后可以先用 `less`、`sed` 或 `sha256sum` 自行查看；不需要额外的固定哈希参数。安装器下载 Xray 官方压缩包时仍会取得对应版本和架构的官方 `.dgst` 文件并校验 SHA256，校验失败不会安装或执行。

## 安装器

安装器通过 GitHub 官方 API 动态查询 Xray 最新正式版本，安装包优先 GitHub，下载失败时尝试 SourceForge 同版本镜像。所有下载使用 `wget`，显示下载进度，并有超时和重试限制。会安装 `wget`、`curl`、`unzip`、`openssl`、`jq`、证书包、`libstdc++`、`libgcc` 及其依赖，给精简系统补齐运行环境；`curl` 仅用于 SNI 建连测速。

解压前必须通过 GitHub 官方同版本、同架构 `.dgst` 文件中的 SHA256 校验；镜像不提供信任依据。官方版本信息或校验文件无法取得时停止，不能在完全访问不了 GitHub 的情况下凭镜像自动猜测最新版。校验不匹配时不会解压、安装或执行。已有 Xray 会复用，不自动升级或重新下载校验。

创建节点时会询问：

- 节点名称：英文字母开头，后续只能英文字母和数字。
- 直连或中转模式。
- VLESS+Reality、Hysteria2 或落地 Shadowsocks。
- NAT 时填写内部监听端口和外部映射端口；非 NAT 时两者相同。
- 客户端公网地址。
- VLESS Reality SNI：可测试候选并推荐，也可以手动填写。禁止 Cloudflare 域名，默认不是 Microsoft。

节点会按当前服务管理器注册 systemd 或 OpenRC 开机自启。Hysteria2 使用受信任证书，不打开 `insecure=1`。

### NAT 下 HY2 为什么需要选择证书方式？

HY2 使用 TLS，需要服务器证书。证书申请和 HY2 流量传输是两件事：HY2 使用服务商分配的 **UDP 映射端口**；传统 HTTP-01 证书验证却必须从公网 **TCP 80** 访问验证文件，不能改成任意映射端口。为了适配 NAT，本脚本不使用 HTTP-01，而是在安装 HY2 时提供四种选择，默认选择 1：

| 选择 | 适合谁 | 是否需要域名 | 续期责任 |
| --- | --- | --- | --- |
| 1. Cloudflare 自动 DNS 验证 | DNS 已托管在 Cloudflare，希望自动续期 | 需要 | 脚本配置每日自动续期 |
| 2. 手动 DNS 验证 | 使用其他 DNS 服务商，不想提供 API Token | 需要，可添加 TXT 即可 | 用户手动验证和续期 |
| 3. 导入已有受信任证书 | 已有外部签发、续期或证书同步流程 | 需要与证书匹配的 SNI | 外部流程续期，用户更新本机副本 |
| 4. 自签名 + 客户端指纹校验 | 没有域名，客户端支持证书指纹 | 不需要购买域名 | 用户在到期前更换证书并更新客户端指纹 |

四种方式都不要求本机有公网 TCP 80/443。自动 DNS API 目前只内置 Cloudflare，**不代表 HY2 必须依赖 Cloudflare**；其他服务商可以使用手动 DNS，或在外部通过对应 API 自动申请后导入。脚本不会自动配置其他 DNS 服务商的 API。

#### 1. Cloudflare 自动 DNS 验证

证书域名的权威 DNS 必须由 Cloudflare 托管。安装时输入 Let's Encrypt 邮箱和 Cloudflare API Token（隐藏输入）：Token 需要 `Zone / DNS / Edit` 和 `Zone / Zone / Read` 权限，资源仅限该域名所在 Zone，不要使用 Global API Key。Certbot 自动创建验证 TXT，等待 DNS 传播 60 秒并完成验证。

Token 保存在服务器 `/etc/letsencrypt/cloudflare-<证书域名>.ini`，权限为 `600`，供自动续期使用；再次安装相同域名时复用凭据。不要公开或删除该文件；Token 失效时需在服务器更新文件内容。每日续期脚本（Alpine 为 `/etc/periodic/daily/xray-cert-renew`，其他支持的发行版为 `/etc/cron.daily/xray-cert-renew`） 使用 Certbot 保存的 DNS 验证配置，证书成功续期后重启 Xray。旧 HTTP 验证证书重新安装该域名时强制续签一次，以迁移验证方式。避免反复重新签发，以免触发 CA 频率限制。

Cloudflare 在这里仅用于 DNS 验证，不中转 HY2 流量。节点连接域名应保持“仅 DNS”（灰云），指向 NAT 公网入口，并配置服务商分配的 UDP 映射端口；DNS 验证本身不要求 A/AAAA 指向安装机器。

#### 2. 手动 DNS 验证

此选项适用于任何允许添加 TXT 的 DNS 服务商。Certbot 会显示 `_acme-challenge.<域名>` 的名称和值；到服务商控制台添加 TXT，确认 DNS 已生效后再按回车。服务商可能要求只填 `_acme-challenge.hy2`，而不是完整域名，请按其控制台格式填写。验证成功后，可手动移除本次添加的那一条验证 TXT，不要影响其他记录。

没有自动认证 hook 的手动证书不能无人值守续期，脚本不会为此模式新建自动续期任务。在到期前，在服务器运行以下命令，按提示添加新的 TXT，成功后重启 Xray（将示例域名替换为自己的）：

```sh
certbot certonly --manual --preferred-challenges dns --agree-tos \
  --force-renewal --cert-name hy2.example.com -d hy2.example.com
rc-service xray restart
```

若服务器已为其他自动 DNS 证书配置续期任务，任务仍会保留；`certbot renew` 不会自动完成此手动证书的验证，可能报告该证书续期失败，不要把任务存在当成手动证书可以自动续期。

#### 3. 导入已有受信任证书

输入服务器上现有 `fullchain.pem` 和未加密私钥 PEM 的绝对路径。填写的 TLS SNI 必须被证书覆盖。安装器检查证书未过期、SNI 匹配及证书与私钥一致，再复制到 `/etc/xray/certs/<节点名称>/`，目录权限 `700`，文件权限 `600`。安装器不会证明证书链受客户端信任，请提供可信 CA 签发的完整证书链。

此方式不会自动续期，也不会跟踪原始文件的变化。外部证书更新后，需要同步更新上述目录的 `fullchain.pem` 和 `privkey.pem`，维持权限，并执行 `rc-service xray restart`。可以在其他机器上用任何 DNS 服务商 API 申请，再通过安全渠道同步到 NAT VPS；私钥不要发送到公开聊天或仓库。

#### 4. 自签名 + 指纹校验

无需购买域名，SNI 可以填写 `hy2.internal`；这只是 TLS 名称，不需要将它解析到公网。客户端连接地址另外填写 NAT 公网 IP 或可解析域名，端口填写外部 UDP 映射端口。

安装器在明确确认客户端支持指纹后生成有效期 365 天的自签名证书，并在最终输出中显示 **SHA256 证书指纹**。必须在客户端按其文档单独配置证书指纹校验：不同客户端的字段、格式和与 TLS 选项的组合可能不同。默认导入链接不携带指纹，不能仅导入链接就认为配置完成。不支持指纹校验的客户端请使用前三种方式，不要只开启 `insecure` 而放弃身份校验。

自签名证书也会过期。更换证书后指纹会改变，必须通过可信渠道同步更新所有客户端指纹；证书与私钥保存在 `/etc/xray/certs/<节点名称>/`，该模式不配置 CA 自动续期。

安装器在第一阶段、安装其余依赖和探测公网地址之前检查系统时间：优先复用正在运行的 systemd-timesyncd 或 ntpd，不为它们安装或替换 chrony。timesyncd 等待系统同步标志；ntpd 使用已有的 ntpq 检查选中的同步源及偏差，缺少 ntpq 时无法自动确认。没有这些服务时，复用已有 chrony，或先通过系统包管理器安装 chrony，再启动并等待同步。未确认同步时默认停止，只有明确确认才继续；chrony 需要立即跳变校时时另行询问。若错误时间导致包仓库 HTTPS 失败，先从宿主机或控制台校正时间，再重试，脚本不会关闭 TLS 证书校验。NAT 需允许出站 UDP 123，不能修改系统时钟的容器需由宿主机校时。客户端时间也需要准确，改变时区不等于校时。

默认内部端口：VLESS TCP `443`、Hysteria2 UDP `443`、Shadowsocks TCP `8388`。Reality 默认候选为 `www.bing.com`；候选测试也包含 Amazon、Yahoo、Samsung、NVIDIA。NAT 映射必须由服务商或路由器配置，脚本不会替你建立映射。同协议可以创建多个节点，但名称和内部端口不能冲突，包括已停用的节点。

## 节点管理器

管理器不按用户、email 或单独账号管理，只把入站 `tag` 作为节点名称。它会检测 `/etc/xray/config.json` 中已有的 VLESS、Shadowsocks 和 Hysteria 入站。

操作完成后会重新显示当前节点的完整功能菜单，可以连续操作；改名后跟随新名称。输入 `0` 返回首页，重新显示完整节点列表，再选择其他节点。删除当前节点后也会返回列表。

每个节点可以：

- 再次显示 `vless://`、`ss://` 或 `hysteria2://` 直接导入链接。
- 保存客户端公网地址和外部端口；NAT 不会把内部端口误当成外部端口。
- 开通节点字节统计，保存累计上行和下行字节。
- 开启或关闭节点连接日志。
- 设置最大连接数（`0` 表示无限制）。
- 设置月流量上限和每月重置日（`0` 表示不限流量）。
- 修改内部端口、外部端口、客户端地址、SNI、UUID/密码、中转 SS 出口。
- 修改节点名称，并同步关联出口和路由标签。
- 停用、启用或删除节点。

配置修改先执行 `xray run -test -format json`，通过后才重载服务；重载失败会恢复本次操作前的临时配置。不会生成 `.bak` 或提供备份恢复菜单。重载会中断同一 Xray 进程中所有节点的现有连接。

## 统计与日志说明

节点统计使用 Xray 的 StatsService，按节点入站保存上下行**字节数**。它不是内核级瞬时计费，也不是每个 HTTP 请求的精确包数。

分流后的节点日志只保存连接目标（域名/IP:端口）和连接状态，不保存 URL 路径、查询参数或请求正文。Xray 原始 access log 是全局文件，仍含来源地址和所有节点连接；管理器按精确入站标签采样到 `/etc/xray/logs/<节点名>-connections.log`。只在所有节点均关闭日志后，才关闭全局原始日志。无法辨识入站标签的日志行不会猜测归属。若客户端使用 Mux，底层连接日志不等于应用请求数。

统计不是抓包：不能提供逐目标包数量或 HTTPS 完整网址。域名由客户端目标决定，客户端传 IP 时记录 IP，不额外打开嗅探。日志没有自动轮转，需要定期管理磁盘空间。日志默认权限为 `600`，目录为 `700`。

开启统计、日志、月流量限制或非零连接限制后，管理器会安装每分钟运行的采样任务。任务使用 root 的 crontab；自动安装或启用对应的 cron 服务（Alpine/RPM 系统为 `crond`，Debian/Ubuntu 为 `cron`）。不对公网开放 API，统计 API 只绑定本机回环地址。没有任何单独用户、IP 限制或备份菜单。

累计统计每分钟保存一次。意外退出、手动重启或掉电前尚未采样的流量可能丢失；统计不能用于要求零误差的账单。已有多凭据节点能按入站统计和启停，但不能自动选出唯一导入链接，管理器不会拆分用户。

## 月流量限制

节点菜单 `12` 设置整数 GiB 上限（1 GiB = 1073741824 字节），按上行加下行计算；`0` 取消限制。设置配额会自动开启该节点统计。

重置日可选 `1–31`，在 UTC 当日 `00:00` 开始新周期；没有该日期的月份取月末，例如 `31` 在四月取 30 日。首次设置从当时保存的累计值开始计算；修改已有配额上限或重置日保留当前周期用量，不清零历史累计统计。

每分钟采样并检查，达到上限时停用整个节点，因此不是即时硬限额，可能超出一个采样间隔的流量。重置跨界时尚未采样的流量计入新周期。新周期只自动启用因月流量超限停用的节点，不恢复手动停用或连接超限停用的节点。提高或取消配额后，符合额度的流量超限节点也会恢复。系统时间倒退不会额外重置额度。

## 最大连接数

`0` 表示无限制。非零值是每分钟检查一次的 TCP 节点软限制：超过上限时停用整个节点，不按 IP 限制，也不会即时拒绝第 N+1 条连接。HY2、UDP、Mux 内部逻辑流和共享端口节点不接受非零限制，避免伪装成 Xray 原生硬并发功能。

连接限制需要 `ss`；Alpine 安装 `iproute2-ss`，Debian/Ubuntu 安装 `iproute2`，RPM 系统安装 `iproute`。计数针对本机端口的 TCP ESTABLISHED 连接，不代表人数；包含本地连接，也不能区分尚未认证的连接。超限停用后需手动启用，不自动反复重启。

## 默认文件

- Xray 配置：`/etc/xray/config.json`
- 管理器状态：`/etc/xray/manager-state.json`
- 访问日志：`/etc/xray/logs/access.log`
- 节点日志：`/etc/xray/logs/<节点名>-connections.log`
- 管理器采样副本：`/etc/xray/manager.sh`

--本脚本由gpt-6.1 sol创建，记得多提issues

## 服务操作与网络放行

Alpine 使用 `rc-service xray restart`；systemd 系统使用 `systemctl restart xray`。本文证书更新示例中的 `rc-service` 命令，在 systemd 系统上需按此替换。服务状态分别用 `rc-service xray status` 或 `systemctl status xray` 查看。

脚本不修改系统防火墙、云安全组或 SELinux 策略。请自行放行实际内部监听端口（VLESS/SS 为 TCP，HY2 为 UDP）及服务商的公网映射。RPM 系统如遇权限拒绝，请检查 `journalctl -u xray` 和 SELinux 审计日志，不要直接关闭 SELinux。
