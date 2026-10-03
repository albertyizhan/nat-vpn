#!/bin/sh
set -eu

# Interactive Alpine Xray installer.
# Modes:
#   1 direct  - VLESS+Reality or Hysteria2 -> freedom
#   2 relay   - relay (VLESS+Reality or Hysteria2 -> SS) or landing (SS -> freedom)

XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
SERVICE_NAME="xray"
WORK_DIR="/tmp/xray-installer"
XRAY_VERSION="${XRAY_VERSION:-}"
PUBLIC_PORT="${PUBLIC_PORT:-}"
LISTEN_PORT="${LISTEN_PORT:-}"
SERVER_NAME="${SERVER_NAME:-www.cloudflare.com}"
PUBLIC_HOST=""

die() { echo "错误: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"; }
ask() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf "%s（默认 %s，回车使用默认值）: " "$prompt" "$default" >&2
  else
    printf "%s: " "$prompt" >&2
  fi
  IFS= read -r answer
  printf "%s" "${answer:-$default}"
}
ask_port() {
  local value
  while :; do
    value="$(ask "$1" "${2:-}")"
    case "$value" in
      ''|*[!0-9]*) echo "请输入 1–65535 的端口号。" >&2; continue ;;
    esac
    if [ "${#value}" -le 5 ] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then
      printf "%s" "$value"
      return
    fi
    echo "请输入 1–65535 的端口号。" >&2
  done
}
rand_hex() { openssl rand -hex "$1"; }
rand_password() { openssl rand -base64 24 | tr -d '=+/'; }
detect_public_host() {
  public_host=""
  for endpoint in https://api.ipify.org https://ifconfig.me/ip; do
    public_host="$(curl -fL --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$public_host" ] && break
  done
  printf "%s" "$public_host"
}

cleanup() {
  rm -f "$WORK_DIR/release.json"
  rm -f "$WORK_DIR/xray.zip"
  rm -f "$WORK_DIR/xray"
  rmdir "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

install_deps() {
  echo "[1/6] 安装依赖..."
  apk add --no-cache ca-certificates curl unzip openssl jq
  update-ca-certificates
  PUBLIC_HOST="$(detect_public_host)"
  if [ -n "$PUBLIC_HOST" ]; then
    echo "探测到公网地址: ${PUBLIC_HOST}"
  else
    echo "未能自动探测公网地址，稍后手动输入。"
  fi
}

arch_name() {
  case "$(uname -m)" in
    x86_64) echo 64 ;;
    aarch64) echo arm64-v8a ;;
    armv7|armhf) echo arm32-v7a ;;
    i386|i686) echo 32 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

resolve_latest_version() {
  local latest_url
  echo "查询 GitHub 官方最新正式发布..."
  if curl -fL --connect-timeout 10 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -o "$WORK_DIR/release.json" \
    "https://api.github.com/repos/XTLS/Xray-core/releases/latest"; then
    XRAY_VERSION="$(jq -er \
      'select(.draft == false and .prerelease == false) | .tag_name | select(type == "string" and length > 0)' \
      "$WORK_DIR/release.json" 2>/dev/null || true)"
  fi
  if [ -z "$XRAY_VERSION" ]; then
    echo "官方 API 未返回版本，尝试最新发布页面..."
    if latest_url="$(curl -fIL --connect-timeout 10 --max-time 30 \
      -o /dev/null -w '%{url_effective}' \
      "https://github.com/XTLS/Xray-core/releases/latest")"; then
      case "$latest_url" in
        https://github.com/XTLS/Xray-core/releases/tag/*)
          XRAY_VERSION="${latest_url##*/}"
          ;;
      esac
    fi
  fi
  [ -n "$XRAY_VERSION" ] ||
    die "无法确认官方最新版；已停止，不会使用写死版本或镜像旧版。请恢复 GitHub 访问后重试。"
}

download_xray() {
  echo "[2/6] 检查 Xray 下载源..."
  mkdir -p "$WORK_DIR"
  machine="$(arch_name)"
  if [ -z "$XRAY_VERSION" ]; then
    resolve_latest_version
    echo "官方最新正式版本: ${XRAY_VERSION}"
  else
    echo "使用用户明确指定的版本: ${XRAY_VERSION}"
  fi
  case "$XRAY_VERSION" in v*) ;; *) XRAY_VERSION="v${XRAY_VERSION}" ;; esac
  printf '%s\n' "$XRAY_VERSION" | grep -Eq '^v[0-9][A-Za-z0-9._-]*$' ||
    die "版本标签格式无效: ${XRAY_VERSION}"

  github_url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${machine}.zip"
  mirror_url="https://sourceforge.net/projects/xray-core.mirror/files/${XRAY_VERSION}/Xray-linux-${machine}.zip/download"
  echo "目标版本: ${XRAY_VERSION}"
  if curl -fL --connect-timeout 10 --max-time 180 --retry 1 \
    -o "$WORK_DIR/xray.zip" "$github_url"; then
    echo "Xray 下载成功: GitHub"
  else
    echo "GitHub 下载失败，尝试 SourceForge 的同一版本 ${XRAY_VERSION}..."
    rm -f "$WORK_DIR/xray.zip"
    curl -fL --connect-timeout 10 --max-time 180 --retry 1 \
      -o "$WORK_DIR/xray.zip" "$mirror_url" ||
      die "无法下载 ${XRAY_VERSION}，镜像可能尚未同步；已停止，不自动降级。"
  fi
  unzip -oq "$WORK_DIR/xray.zip" xray -d "$WORK_DIR"
  install -m 0755 "$WORK_DIR/xray" "$XRAY_BIN"
  "$XRAY_BIN" version | head -n1
}

write_service() {
  cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
command="${XRAY_BIN}"
command_args="run -config ${XRAY_DIR}/config.json"
command_background="yes"
pidfile="/run/${SERVICE_NAME}.pid"
output_log="/dev/null"
error_log="/dev/null"
depend() { need net; }
EOF
  chmod 0755 "/etc/init.d/${SERVICE_NAME}"
  rc-update add "$SERVICE_NAME" default >/dev/null
}

make_vless_config() {
  local role="$1"
  local uuid private public short_id ss_address ss_port ss_password
  uuid="$("$XRAY_BIN" uuid)"
  keys="$("$XRAY_BIN" x25519)"
  private="$(printf '%s\n' "$keys" | sed -n 's/^Private key:[[:space:]]*//p')"
  public="$(printf '%s\n' "$keys" | sed -n 's/^Public key:[[:space:]]*//p')"
  short_id="$(rand_hex 8)"
  if [ "$role" = relay ]; then
    echo "上游落地协议: Shadowsocks，aes-128-gcm；请先部署落地节点。"
    ss_address="$(ask '落地节点公网 IP/域名')"
    ss_port="$(ask_port '落地节点对外 SS 端口（NAT 时填写外部映射端口）')"
    ss_password="$(ask '落地节点生成的 SS 密码')"
    [ -n "$ss_password" ] || die "SS 密码不能为空"
    cat > "$XRAY_DIR/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "vless",
    "settings": {"clients": [{"id": "${uuid}"}], "decryption": "none"},
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SERVER_NAME}:443",
        "xver": 0,
        "serverNames": ["${SERVER_NAME}"],
        "privateKey": "${private}",
        "shortIds": ["${short_id}"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "shadowsocks",
    "settings": {"servers": [{
      "address": "${ss_address}",
      "port": ${ss_port},
      "method": "aes-128-gcm",
      "password": "${ss_password}"
    }]}
  }]
}
EOF
  else
    cat > "$XRAY_DIR/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "vless",
    "settings": {"clients": [{"id": "${uuid}"}], "decryption": "none"},
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SERVER_NAME}:443",
        "xver": 0,
        "serverNames": ["${SERVER_NAME}"],
        "privateKey": "${private}",
        "shortIds": ["${short_id}"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
  fi
  CLIENT_HOST="$(ask '客户端连接地址（公网 IP/域名）' "$PUBLIC_HOST")"
  LINK="vless://${uuid}@${CLIENT_HOST}:${PUBLIC_PORT}?encryption=none&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${public}&sid=${short_id}&type=tcp#Alpine-Xray"
}

make_hy2_config() {
  local role="$1"
  local password cert_key cert_pem uuid email ss_address ss_port ss_password
  password="$(rand_password)"
  cert_cn="$(ask 'Hysteria2 证书域名（必须已解析到本机，不能填 IP）')"
  [ -n "$cert_cn" ] || die "Hysteria2 必须使用域名证书"
  case "$cert_cn" in *.*) ;; *) die "证书域名格式不正确: ${cert_cn}" ;; esac
  email="$(ask 'Let''s Encrypt 通知邮箱')"
  [ -n "$email" ] || die "邮箱不能为空"
  echo "安装 Certbot 并申请受信任证书；请确保公网 TCP 80 已转发到本机。"
  apk add --no-cache certbot
  certbot certonly --standalone --non-interactive --agree-tos \
    --preferred-challenges http --email "$email" -d "$cert_cn"
  cert_key="/etc/letsencrypt/live/${cert_cn}/privkey.pem"
  cert_pem="/etc/letsencrypt/live/${cert_cn}/fullchain.pem"
  [ -s "$cert_key" ] && [ -s "$cert_pem" ] || die "证书申请成功但文件不存在"
  if [ "$role" = relay ]; then
    echo "上游落地协议: Shadowsocks，aes-128-gcm；请先部署落地节点。"
    ss_address="$(ask '落地节点公网 IP/域名')"
    ss_port="$(ask_port '落地节点对外 SS 端口（NAT 时填写外部映射端口）')"
    ss_password="$(ask '落地节点生成的 SS 密码')"
    [ -n "$ss_password" ] || die "SS 密码不能为空"
    cat > "$XRAY_DIR/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "hysteria",
    "settings": {"version": 2, "users": [{"auth": "${password}"}]},
    "streamSettings": {
      "network": "hysteria",
      "security": "tls",
      "tlsSettings": {"certificates": [{"certificateFile": "${cert_pem}", "keyFile": "${cert_key}"}]},
      "hysteriaSettings": {"version": 2}
    }
  }],
  "outbounds": [{
    "protocol": "shadowsocks",
    "settings": {"servers": [{"address": "${ss_address}", "port": ${ss_port}, "method": "aes-128-gcm", "password": "${ss_password}"}]}
  }]
}
EOF
  else
    cat > "$XRAY_DIR/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "hysteria",
    "settings": {"version": 2, "users": [{"auth": "${password}"}]},
    "streamSettings": {
      "network": "hysteria",
      "security": "tls",
      "tlsSettings": {"certificates": [{"certificateFile": "${cert_pem}", "keyFile": "${cert_key}"}]},
      "hysteriaSettings": {"version": 2}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
  fi
  CLIENT_HOST="$(ask '客户端连接地址（公网 IP/域名）' "$PUBLIC_HOST")"
  LINK="hysteria2://${password}@${CLIENT_HOST}:${PUBLIC_PORT}/?sni=${cert_cn}#Alpine-Hysteria2"
}

make_landing_config() {
  local password method client_host userinfo
  password="$(rand_password)"
  method="aes-128-gcm"
  cat > "$XRAY_DIR/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "shadowsocks",
    "settings": {"method": "${method}", "password": "${password}", "network": "tcp"}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
  client_host="$(ask '客户端连接地址（公网 IP/域名）' "$PUBLIC_HOST")"
  userinfo="$(printf '%s' "${method}:${password}" | openssl base64 -A)"
  LINK="ss://${userinfo}@${client_host}:${PUBLIC_PORT}#Alpine-SS"
  echo "落地协议: Shadowsocks ${method}"
  echo "SS 密码: ${password}"
}

main() {
  need_root
  install_deps
  download_xray
  mkdir -p "$XRAY_DIR"
  echo "[3/6] 选择部署模式"
  mode="$(ask '1. 直连模式  2. 中转模式' 1)"
  case "$mode" in 1|2) ;; *) die "模式只能是 1 或 2" ;; esac
  if [ "$mode" = 1 ]; then
    protocol="$(ask '选择协议: 1. VLESS+Reality  2. Hysteria2' 1)"
    role="direct"
  else
    role_choice="$(ask '选择角色: 1. 中转  2. 落地' 1)"
    case "$role_choice" in
      1) role="relay"; protocol="$(ask '选择中转入站协议: 1. VLESS+Reality  2. Hysteria2' 1)" ;;
      2) role="landing"; protocol="ss" ;;
      *) die "角色只能是 1 或 2" ;;
    esac
  fi
  case "$protocol" in
    1) protocol_name="VLESS + Reality"; transport="TCP"; default_listen=443 ;;
    2) protocol_name="Hysteria2"; transport="UDP"; default_listen=443 ;;
    ss) protocol_name="Shadowsocks (aes-128-gcm)"; transport="TCP"; default_listen=8388 ;;
    *) die "协议选择无效" ;;
  esac
  case "$role" in
    direct) role_name="直连"; route_name="本机直连公网" ;;
    relay) role_name="中转"; route_name="转发到用户指定的 SS 落地节点" ;;
    landing) role_name="落地"; route_name="本机直连公网" ;;
  esac
  echo "已选角色: ${role_name}；协议: ${protocol_name}；传输: ${transport}"
  echo "默认监听端口: ${default_listen}；出口: ${route_name}"
  echo "NAT：需已有端口映射；非 NAT：公网地址直接位于本机。"
  network_mode="$(ask '网络类型: 1. NAT  2. 非 NAT' 2)"
  case "$network_mode" in
    1)
      echo "请按服务商或路由器的实际映射填写；脚本不会创建 NAT 映射。"
      LISTEN_PORT="$(ask_port '内部监听端口' "$default_listen")"
      PUBLIC_PORT="$(ask_port '外部访问/映射端口（必填）')"
      ;;
    2)
      LISTEN_PORT="$(ask_port '监听/公网端口' "$default_listen")"
      PUBLIC_PORT="$LISTEN_PORT"
      ;;
    *) die "网络类型只能是 1 或 2" ;;
  esac
  echo "部署参数: ${role_name} / ${protocol_name}"
  echo "本机监听 ${transport} ${LISTEN_PORT}；对外访问 ${transport} ${PUBLIC_PORT}"
  case "$protocol:$role" in
    1:direct|1:relay) make_vless_config "$role" ;;
    2:direct|2:relay) make_hy2_config "$role" ;;
    ss:landing) make_landing_config ;;
    *) die "无效的协议选择" ;;
  esac
  echo "[4/6] 检查配置..."
  "$XRAY_BIN" run -test -config "$XRAY_DIR/config.json"
  echo "[5/6] 注册 OpenRC..."
  write_service
  rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start
  echo "[6/6] 完成"
  echo
  echo "角色: ${role_name}；协议: ${protocol_name}"
  echo "监听端口: ${transport} ${LISTEN_PORT}"
  if [ "$network_mode" = 1 ]; then
    echo "请确认 NAT 映射: 公网 ${transport} ${PUBLIC_PORT} -> 本机 ${transport} ${LISTEN_PORT}"
  else
    echo "公网访问端口: ${transport} ${PUBLIC_PORT}"
  fi
  echo "导入链接:"
  echo "$LINK"
}

main "$@"
