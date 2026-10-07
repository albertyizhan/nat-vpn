# Alpine Xray 安装器与节点管理器

仓库只包含两个脚本：

- `xray-installer.sh`：首次安装 Xray，并创建 VLESS+Reality、Hysteria2 或 Shadowsocks 节点。
- `xray-manager.sh`：按节点名称管理已有入站。

支持 Alpine Linux / OpenRC、NAT 和非 NAT。

## 一键下载运行

在 Alpine 的 root 终端执行。先安装证书和 `wget`，再下载脚本运行。

```sh
apk add --no-cache ca-certificates wget
wget -O /root/xray-installer.sh \
  https://raw.githubusercontent.com/albertyizhan/nat-vpn/main/xray-installer.sh
chmod 700 /root/xray-installer.sh
sh /root/xray-installer.sh
```

管理器：

```sh
apk add --no-cache ca-certificates wget
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

节点会注册 OpenRC 开机自启。Hysteria2 使用受信任证书，不打开 `insecure=1`。

安装器会检查系统时间：缺少时安装 `chrony`，复用已有 `chronyd` 并等待同步；已有 `ntpd` 时保留服务，只查询时间偏差。同步未达标时可确认立即校时；无法确认校时成功时默认停止，只有明确确认才继续。NAT 需允许出站 UDP 123，不能修改系统时钟的容器需由宿主机校时。客户端时间也需要准确，改变时区不等于校时。

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

开启统计、日志、月流量限制或非零连接限制后，管理器会安装每分钟运行的采样任务。任务使用 BusyBox `crond`，并注册为 OpenRC 默认服务。不对公网开放 API，统计 API 只绑定本机回环地址。没有任何单独用户、IP 限制或备份菜单。

累计统计每分钟保存一次。意外退出、手动重启或掉电前尚未采样的流量可能丢失；统计不能用于要求零误差的账单。已有多凭据节点能按入站统计和启停，但不能自动选出唯一导入链接，管理器不会拆分用户。

## 月流量限制

节点菜单 `12` 设置整数 GiB 上限（1 GiB = 1073741824 字节），按上行加下行计算；`0` 取消限制。设置配额会自动开启该节点统计。

重置日可选 `1–31`，在 UTC 当日 `00:00` 开始新周期；没有该日期的月份取月末，例如 `31` 在四月取 30 日。首次设置从当时保存的累计值开始计算；修改已有配额上限或重置日保留当前周期用量，不清零历史累计统计。

每分钟采样并检查，达到上限时停用整个节点，因此不是即时硬限额，可能超出一个采样间隔的流量。重置跨界时尚未采样的流量计入新周期。新周期只自动启用因月流量超限停用的节点，不恢复手动停用或连接超限停用的节点。提高或取消配额后，符合额度的流量超限节点也会恢复。系统时间倒退不会额外重置额度。

## 最大连接数

`0` 表示无限制。非零值是每分钟检查一次的 TCP 节点软限制：超过上限时停用整个节点，不按 IP 限制，也不会即时拒绝第 N+1 条连接。HY2、UDP、Mux 内部逻辑流和共享端口节点不接受非零限制，避免伪装成 Xray 原生硬并发功能。

连接限制需要 `ss`，缺少时执行 `apk add --no-cache iproute2-ss`。计数针对本机端口的 TCP ESTABLISHED 连接，不代表人数；包含本地连接，也不能区分尚未认证的连接。超限停用后需手动启用，不自动反复重启。

## 默认文件

- Xray 配置：`/etc/xray/config.json`
- 管理器状态：`/etc/xray/manager-state.json`
- 访问日志：`/etc/xray/logs/access.log`
- 节点日志：`/etc/xray/logs/<节点名>-connections.log`
- 管理器采样副本：`/etc/xray/manager.sh`

--本脚本由gpt-6.1 sol创建，记得多提issues
