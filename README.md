# Alpine Xray 多模式安装器

脚本：

```sh
chmod +x alpine-xray-installer.sh
./alpine-xray-installer.sh
```

脚本会自动：

- 安装 `curl`、`unzip`、`openssl`、CA 证书
- 先探测 GitHub API 和 Release 下载
- GitHub 失败时尝试 SourceForge 镜像
- 按 CPU 架构下载 Xray
- 自动探测公网 IP，并作为客户端地址默认值（可手动覆盖）
- 区分 NAT 与非 NAT；NAT 模式分别记录内部监听端口和外部访问端口
- 生成配置、OpenRC 开机自启和导入链接

## 模式

### 直连模式

- `VLESS + Reality -> freedom`
- `Hysteria2 -> freedom`

### 中转模式

- 中转：`VLESS + Reality -> Shadowsocks`
- 中转：`Hysteria2 -> Shadowsocks`
- 落地：`Shadowsocks -> freedom`

落地模式默认使用 `aes-128-gcm`，密码自动生成。中转模式需要填写落地节点地址、实际对外 SS 端口和落地节点生成的密码，不绑定地区或服务商。请先部署落地节点，再部署中转节点。

## NAT 与端口

Xray 本身只监听机器内部端口，外部端口由路由器端口映射提供；脚本会把外部端口写入最终分享链接。

- 每个带默认值的提示都会明确显示默认值，按回车即可采用
- 默认网络类型为非 NAT；VLESS/Reality 与 Hysteria2 默认端口为 `443`，Shadowsocks 为 `8388`，均可修改
- NAT 模式：内部端口默认值同上；外部端口必须按实际映射填写，不预设某台机器的映射
- VLESS/Reality 和落地 Shadowsocks 使用 TCP；Hysteria2 使用 UDP
- 开始生成配置前及安装完成后，脚本显示所选角色、协议、内部端口和对外端口

选择 NAT + Hysteria2 时，证书申请还需要额外确保公网 TCP `80` 映射到本机 TCP `80`。

## Hysteria2 证书

Hysteria2 不使用 `insecure=1`。脚本会要求一个已解析到本机的域名和邮箱，安装 Alpine 的 Certbot 并通过 HTTP-01 自动申请受信任证书，因此申请时公网 TCP 80 必须能到达本机。没有域名或 80 端口不可用时，脚本会停止而不是生成不安全配置。

脚本默认不写持久化日志，OpenRC 服务输出丢弃到 `/dev/null`。请先确认路由器映射与脚本提示的内部端口一致。
