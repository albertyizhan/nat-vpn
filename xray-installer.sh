#!/bin/sh
set -eu

# Interactive Linux Xray installer.
# Modes:
#   1 direct  - VLESS+Reality -> freedom
#   2 relay   - relay (VLESS+Reality -> SS) or landing (SS -> freedom)

XRAY_DIR="${XRAY_DIR:-/etc/xray}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
SERVICE_NAME="xray"
WORK_DIR=""
GENERATED_CONFIG=""
CANDIDATE_CONFIG=""
CANDIDATE_STATE=""
PREVIOUS_CONFIG=""
CREATION_LOCK=""
XRAY_VERSION="${XRAY_VERSION:-}"
PUBLIC_PORT="${PUBLIC_PORT:-}"
LISTEN_PORT="${LISTEN_PORT:-}"
SERVER_NAME="${SERVER_NAME:-apps.apple.com}"
PUBLIC_HOST=""
NODE_NAME=""

die() { echo "错误: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"; }

# Keep platform helpers in both scripts so each remains independently runnable.
detect_platform() {
  [ "$(uname -s)" = Linux ] || die "仅支持 Linux。"
  [ -r /etc/os-release ] || die "缺少 /etc/os-release，无法识别发行版。"
  . /etc/os-release
  case "$ID" in
    alpine) PKG=apk; TIME_SERVICE=chronyd; CRON_SERVICE=crond ;;
    debian|ubuntu) PKG=apt; TIME_SERVICE=chrony; CRON_SERVICE=cron ;;
    rocky|almalinux|fedora) PKG=dnf; TIME_SERVICE=chronyd; CRON_SERVICE=crond ;;
    *) die "不支持的发行版: $ID（支持 Alpine、Debian、Ubuntu、Rocky、AlmaLinux、Fedora）。" ;;
  esac
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT=systemd
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    INIT=openrc
  else
    die "需要运行中的 systemd 或 OpenRC；不支持无服务管理器的容器。"
  fi
}
install_packages() {
  case "$PKG" in
    apk) apk add --no-cache "$@" ;;
    apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
  esac
}
service_action() {
  if [ "$INIT" = systemd ]; then
    case "$2" in
      status) systemctl is-active --quiet "$1" ;;
      *) systemctl "$2" "$1" ;;
    esac
  else
    rc-service "$1" "$2"
  fi
}
service_enable() {
  if [ "$INIT" = systemd ]; then systemctl enable "$1"; else rc-update add "$1" default; fi
}
ensure_cron() {
  case "$PKG" in
    apk) command -v crontab >/dev/null 2>&1 || install_packages busybox ;;
    apt) install_packages cron ;;
    dnf) install_packages cronie ;;
  esac
  service_enable "$CRON_SERVICE"
  service_action "$CRON_SERVICE" status >/dev/null 2>&1 || service_action "$CRON_SERVICE" start
}

enable_bbr() {
  local available old_qdisc old_cc
  echo "检测 BBR 支持..."
  if ! command -v sysctl >/dev/null 2>&1; then
    echo "警告: 缺少 sysctl，跳过 BBR。" >&2
    return 0
  fi
  # A supported module may not yet be loaded, so try it before checking.
  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || :
  fi
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)" || available=""
  case " $available " in
    *" bbr "*) ;;
    *) echo "警告: 当前内核不提供 BBR，跳过；不会自动更换内核。" >&2; return 0 ;;
  esac
  old_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)" || old_qdisc=""
  old_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" || old_cc=""
  if [ -n "$old_qdisc" ]; then
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 ||
      echo "警告: 无法设置 fq，继续尝试开启 BBR。" >&2
  else
    echo "提示: 当前环境未暴露 default_qdisc，跳过 fq 设置。"
  fi
  if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 ||
     [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != bbr ]; then
    [ -z "$old_qdisc" ] || sysctl -w "net.core.default_qdisc=$old_qdisc" >/dev/null 2>&1 || :
    [ -z "$old_cc" ] || sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || :
    echo "警告: 无法开启 BBR（容器可能需要宿主机配置），未写入持久化配置。" >&2
    return 0
  fi
  trusted_path /etc/sysctl.d dir
  trusted_path /etc/sysctl.d/99-xray-bbr.conf file
  if ! mkdir -p /etc/sysctl.d || ! (
    umask 022
    {
      if [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = fq ]; then
        printf '%s\n' 'net.core.default_qdisc = fq'
      fi
      printf '%s\n' 'net.ipv4.tcp_congestion_control = bbr'
    } > /etc/sysctl.d/99-xray-bbr.conf
  ); then
    echo "警告: BBR 已开启，但持久化配置写入失败。" >&2
    return 0
  fi
  echo "BBR 已开启并验证，持久化配置: /etc/sysctl.d/99-xray-bbr.conf"
}

trusted_path() {
  local path="$1" kind="${2:-any}" part owner mode child=0
  case "$path" in
    /*) ;;
    *) die "路径必须为绝对路径: $path" ;;
  esac
  if [ -e "$path" ]; then
    case "$kind" in
      file) [ -f "$path" ] || die "需要普通文件路径: $path" ;;
      dir) [ -d "$path" ] || die "需要目录路径: $path" ;;
    esac
  fi
  case "$path" in
    *[!A-Za-z0-9_./-]*|*//*|*/../*|*/./*|*/..|*/.|*/)
      die "路径仅允许字母、数字、下划线、点、连字符和单个斜杠: $path" ;;
  esac
  part="$path"
  while :; do
    [ ! -L "$part" ] || die "不能使用符号链接路径: $part"
    if [ -e "$part" ]; then
      [ -d "$part" ] || [ -f "$part" ] || die "路径不是普通文件或目录: $part"
      owner="$(stat -c %u "$part")"
      mode="$(stat -c %a "$part")"
      [ "$owner" = 0 ] || die "路径必须属于 root: $part"
      if [ "$((0$mode & 022))" -ne 0 ]; then
        # A root-owned child under a sticky temporary directory cannot be replaced by other users.
        [ "$child" = 1 ] && [ -d "$part" ] && [ "$((0$mode & 01000))" -ne 0 ] ||
          die "路径不能允许组或其他用户写入: $part"
      fi
      if [ -f "$part" ]; then
        [ "$(stat -c %h "$part")" = 1 ] || die "不能写入硬链接文件: $part"
      fi
      child=1
    else
      child=0
    fi
    [ "$part" != / ] || break
    part="${part%/*}"
    [ -n "$part" ] || part=/
  done
}
validate_reality_server_name() {
  case "$(printf '%s' "$SERVER_NAME" | tr '[:upper:]' '[:lower:]')" in
    speed.cloudflare.com) ;;
    *[Cc][Ll][Oo][Uu][Dd][Ff][Ll][Aa][Rr][Ee]*)
      die "VLESS + Reality 的 SNI 仅允许 speed.cloudflare.com，其他 Cloudflare 域名禁止使用。" ;;
  esac
  printf '%s\n' "$SERVER_NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*$' ||
    die "Reality SNI 格式无效。"
}
ask() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf "%s（默认 %s，回车使用默认值）: " "$prompt" "$default" >&2
  else
    printf "%s: " "$prompt" >&2
  fi
  if ! IFS= read -r answer; then
    # ask() is commonly executed in $(...), so signal the parent shell too.
    [ "${PPID:-}" -gt 1 ] 2>/dev/null && kill -TERM "$PPID" 2>/dev/null || true
    exit 143
  fi
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
ask_node_name() {
  local value
  while :; do
    value="$(ask "节点名称（英文字母开头，只能包含英文字母和数字）")"
    printf '%s\n' "$value" | grep -Eq '^[A-Za-z][A-Za-z0-9]*$' &&
      { printf '%s' "$value"; return; }
    echo "名称无效：必须以英文字母开头，后续只能使用英文字母和数字。" >&2
  done
}
ask_endpoint() {
  local value
  while :; do
    value="$(ask "$1" "${2:-}")"
    printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:-]*$' &&
      { printf '%s' "$value"; return; }
    echo "地址格式无效：只允许字母、数字、点、冒号、下划线和连字符。" >&2
  done
}
ask_secret() {
  local value
  while :; do
    value="$(ask "$1")"
    printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9._~+/=-]+$' &&
      { printf '%s' "$value"; return; }
    echo "密钥包含不安全字符，请使用字母、数字和常见密码字符。" >&2
  done
}
fetch_to() {
  local output="$1" url="$2"
  timeout 180 wget --timeout=15 --tries=2 -O "$output" "$url"
}
fetch_text() {
  output="$1"; url="$2"
  fetch_to "$output" "$url"
  tr -d '\r' < "$output"
}
rand_hex() { openssl rand -hex "$1"; }
rand_password() { openssl rand -base64 24 | tr -d '=+/'; }
sni_valid() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    speed.cloudflare.com) ;;
    *[Cc][Ll][Oo][Uu][Dd][Ff][Ll][Aa][Rr][Ee]*) return 1 ;;
  esac
  printf '%s\n' "$1" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
}
probe_sni() {
  local host="$1" log="$WORK_DIR/sni-probe.txt" cert_hex cert_bytes speed
  # Probe with X25519 and leave headroom below older REALITY's 8192-byte buffer.
  timeout 10 openssl s_client -connect "$host:443" -servername "$host" \
    -tls1_3 -groups X25519 -alpn h2 -verify_hostname "$host" \
    -verify_return_error -msg < /dev/null > "$log" 2>&1 || true
  if ! grep -q 'ALPN protocol: h2' "$log" ||
     ! grep -q 'Verify return code: 0 (ok)' "$log" ||
     ! grep -Eq '^<<< .*Finished' "$log"; then
    echo "$host: 未通过 TLS 1.3 / H2 / 证书校验或连接超时。" >&2
    return 1
  fi
  cert_hex="$(awk '/^<<< .*], Certificate$/ {
    for (i=1;i<=NF;i++) if ($i=="[length") {
      v=$(i+1); gsub(/[^0-9a-fA-F]/,"",v); print v; exit
    }
  }' "$log")"
  case "$cert_hex" in ''|*[!0-9a-fA-F]*) echo "$host: 无法检查证书消息大小，跳过。" >&2; return 1 ;; esac
  cert_bytes="$(printf '%d' "0x$cert_hex")"
  if [ "$cert_bytes" -gt 7000 ]; then
    echo "$host: 证书消息 ${cert_bytes} 字节，超过保守阈值 7000，跳过。" >&2
    return 1
  fi
  speed="$(curl --noproxy '*' --connect-timeout 5 --max-time 10 \
      --tlsv1.3 --tls-max 1.3 -sS -o /dev/null -w '%{time_appconnect}' \
      "https://$host/" 2>/dev/null)" || {
        echo "$host: HTTPS 测速失败，跳过。" >&2; return 1;
      }
  printf '%s\n' "$speed" | grep -Eq '^[0-9]+\.[0-9]+$' || return 1
  echo "$host: 通过；TLS 建连 ${speed}s；证书消息 ${cert_bytes} 字节。" >&2
  printf '%s\t%s\n' "$speed" "$host"
}
choose_reality_sni() {
  local mode host selected choice recommended index
  command -v timeout >/dev/null 2>&1 || die "缺少 timeout，请安装 BusyBox。"
  echo "Reality 目标/SNI：默认 $SERVER_NAME；Cloudflare 仅允许 speed.cloudflare.com。"
  mode="$(ask '1. 使用默认目标  2. 测试候选网站并推荐  3. 手动输入 SNI' 1)"
  case "$mode" in
    1)
      if sni_valid "$SERVER_NAME" && probe_sni "$SERVER_NAME" > "$WORK_DIR/sni-results.tsv"; then
        return
      fi
      echo "默认目标未通过检查，请选择其他候选。"
      ;;
    2|3) ;;
    *) die "SNI 模式只能是 1、2 或 3。" ;;
  esac
  case "$mode" in
    1|2)
      : > "$WORK_DIR/sni-results.tsv"
      # These are candidates, not a permanent compatibility allowlist.
      for host in apps.apple.com speed.cloudflare.com www.bing.com www.amazon.com www.yahoo.com www.samsung.com www.nvidia.com; do
        probe_sni "$host" >> "$WORK_DIR/sni-results.tsv" || true
      done
      sort -n "$WORK_DIR/sni-results.tsv" > "$WORK_DIR/sni-ranked.tsv"
      if [ -s "$WORK_DIR/sni-ranked.tsv" ]; then
        recommended="$(awk 'NR==1 {print $2}' "$WORK_DIR/sni-ranked.tsv")"
        echo "推荐: ${recommended}（本轮通过检查且 TLS 建连最快，不代表端到端代理延迟最佳）。"
        awk '{printf "  %d. %s (%ss)\n", NR, $2, $1}' "$WORK_DIR/sni-ranked.tsv"
        echo "  0. 手动输入"
        while :; do
          choice="$(ask '选择候选编号' 1)"
          case "$choice" in
            0) break ;;
            ''|*[!0-9]*) echo "请输入列表中的编号。" ;;
            *)
              selected="$(awk -v n="$choice" 'NR==n {print $2}' "$WORK_DIR/sni-ranked.tsv")"
              if [ -n "$selected" ]; then SERVER_NAME="$selected"; return; fi
              echo "编号无效。"
              ;;
          esac
        done
      else
        echo "没有候选通过检查，请手动输入并测试。"
      fi
      ;;
    3) ;;
  esac
  while :; do
    host="$(ask '自定义 SNI 域名（目标同为此域名:443）' "$SERVER_NAME")"
    if ! sni_valid "$host"; then
      echo "请输入有效域名，不能使用 IP、通配符；Cloudflare 仅允许 speed.cloudflare.com。"
      continue
    fi
    if probe_sni "$host" > "$WORK_DIR/sni-results.tsv"; then
      SERVER_NAME="$host"
      return
    fi
    echo "目标未通过检查，请换一个域名。"
  done
}
reality_key_field() {
  awk -F ':' -v field="$1" '
    {
      label = tolower($1)
      gsub(/[[:space:]()]/, "", label)
      if ((field == "private" && label == "privatekey") ||
          (field == "public" && (label == "publickey" ||
                                label == "passwordpublickey" || label == "password"))) {
        value = $2
        gsub(/[[:space:]]/, "", value)
        print value
        exit
      }
    }
  '
}
detect_public_host() {
  public_host=""
  for endpoint in https://api.ipify.org https://ifconfig.me/ip; do
    public_host="$(fetch_text "$WORK_DIR/public-ip" "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$public_host" ] && break
  done
  printf "%s" "$public_host"
}

cleanup() {
  if [ -n "$WORK_DIR" ]; then
    rm -f "$WORK_DIR/release.json"
    rm -f "$WORK_DIR/xray.zip"
    rm -f "$WORK_DIR/xray.zip.dgst"
    rm -f "$WORK_DIR/xray"
    rm -f "$WORK_DIR/node.json"
    rm -f "$WORK_DIR/node-state.json"
    rm -f "$WORK_DIR/time-probe.conf"
    rm -f "$WORK_DIR/time-probe.log"
    rm -f "$WORK_DIR/sni-probe.txt"
    rm -f "$WORK_DIR/sni-results.tsv"
    rm -f "$WORK_DIR/sni-ranked.tsv"
    rm -f "$WORK_DIR/filter-state.json"
    rm -f "$WORK_DIR/filtered-config.json"
    rm -f "$WORK_DIR/public-ip"
    rmdir "$WORK_DIR" 2>/dev/null || true
  fi
  [ -z "$CANDIDATE_CONFIG" ] || rm -f "$CANDIDATE_CONFIG"
  [ -z "$CANDIDATE_STATE" ] || rm -f "$CANDIDATE_STATE"
  [ -z "$PREVIOUS_CONFIG" ] || rm -f "$PREVIOUS_CONFIG"
  [ -z "$CREATION_LOCK" ] || rmdir "$CREATION_LOCK" 2>/dev/null || true
}
trap cleanup EXIT
# Convert interrupts into a normal shell exit so the EXIT cleanup removes the
# transaction files and lock directory even while waiting for interactive input.
trap 'exit 130' INT
trap 'exit 143' TERM

install_deps() {
  echo "[1/6] 准备校时与基础依赖..."
  detect_platform
  check_system_time
  mkdir -p "$XRAY_DIR"
  case "$PKG" in
    apk) install_packages ca-certificates wget curl unzip openssl jq libstdc++ libgcc coreutils ;;
    apt) install_packages ca-certificates wget curl unzip openssl jq libstdc++6 libgcc-s1 coreutils procps ;;
    dnf) install_packages ca-certificates wget curl unzip openssl jq libstdc++ libgcc coreutils procps-ng ;;
  esac
  if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates; else update-ca-trust; fi
  PUBLIC_HOST="$(detect_public_host)"
  if [ -n "$PUBLIC_HOST" ]; then
    echo "探测到公网地址: ${PUBLIC_HOST}"
  else
    echo "未能自动探测公网地址，稍后手动输入。"
  fi
}

check_system_time() {
  local attempt peers
  echo "检查系统时间（当前 UTC: $(date -u '+%Y-%m-%d %H:%M:%S')）..."
  # CAP_SYS_TIME is bit 25; inspect its hex digit without 64-bit arithmetic.
  if [ -r /proc/self/status ] && awk '
    /^CapEff:/ {
      digit=tolower(substr($2, length($2)-6, 1))
      value=index("0123456789abcdef", digit)-1
      if (value>=0 && int(value/2)%2==0) missing=1
    }
    END {exit !missing}' /proc/self/status; then
    echo "当前环境无校时权限，时间由宿主机管理；跳过校时并继续安装（未验证同步状态）。"
    return 0
  fi
  if [ "$INIT" = systemd ] && systemctl is-active --quiet systemd-timesyncd; then
    echo "复用 systemd-timesyncd，等待同步（最多约 30 秒）。"
    attempt=0
    while [ "$attempt" -lt 15 ]; do
      if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
        echo "已有服务报告系统时间已同步。"
        return
      fi
      sleep 2
      attempt=$((attempt + 1))
    done
  elif { command -v pidof >/dev/null 2>&1 && pidof ntpd >/dev/null 2>&1; } ||
       { [ "$INIT" = systemd ] && { systemctl is-active --quiet ntp || systemctl is-active --quiet ntpd || systemctl is-active --quiet ntpsec; }; }; then
    echo "复用已有 ntpd，不安装或替换校时服务。"
    if command -v ntpq >/dev/null 2>&1; then
      attempt=0
      while [ "$attempt" -lt 15 ]; do
        peers="$(ntpq -pn 2>/dev/null || true)"
        if printf '%s\n' "$peers" | awk '
          /^\*/ && NF>=10 {v=$9; if(v<0)v=-v; if(v<=1000) ok=1}
          END {exit !ok}'; then
          echo "ntpd 已选择同步源，时间偏差不超过 1 秒。"
          return
        fi
        sleep 2
        attempt=$((attempt + 1))
      done
    else
      echo "缺少 ntpq，无法确认已有 ntpd 的同步状态。"
    fi
  else
    # Do not install chrony while another time service is active.
    if ! command -v chronyc >/dev/null 2>&1 || ! command -v chronyd >/dev/null 2>&1; then
      install_packages chrony ||
        die "无法安装校时工具。若系统时间错误导致 HTTPS 失败，请先从宿主机或控制台修正时间，再重试；不会关闭 TLS 校验。"
    fi
    if [ "$PKG" = apk ]; then
      [ -x /etc/init.d/chronyd ] || install_packages chrony-openrc
    fi
    echo "使用 chronyd 持续校时，等待 NTP 同步（最多约 30 秒）。"
    service_enable "$TIME_SERVICE"
    if service_action "$TIME_SERVICE" status >/dev/null 2>&1 || service_action "$TIME_SERVICE" start; then
      if chronyc waitsync 15 1 0 2; then
        echo "系统时间已同步，剩余校正不超过 1 秒。"
        chronyc tracking
        return
      fi
      echo "同步未达标；如果主机允许校时，可立即校正已选定的 NTP 偏差。"
      chronyc tracking || true
      case "$(ask '允许 chronyc makestep 立即跳变系统时间？可能影响本机其他服务 [y/N]' N)" in
        y|Y)
          if chronyc makestep && chronyc waitsync 5 1 0 2; then
            echo "校时完成（UTC: $(date -u '+%Y-%m-%d %H:%M:%S')）。"
            return
          fi
          ;;
      esac
    fi
  fi
  echo "未能确认系统时间准确。NAT 需允许出站 UDP 123；容器可能只能由宿主机校时。"
  echo "客户端也需要准确时间；修改时区不能修正系统时钟偏差。"
  case "$(ask '尚未校时成功，仍继续安装？[y/N]' N)" in
    y|Y) echo "按你的选择继续，请在使用节点前修复主机时间。" ;;
    *) die "已停止，请校准宿主机时间或恢复 NTP 后再运行。" ;;
  esac
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
  echo "查询 GitHub 官方最新正式发布..."
  if fetch_to "$WORK_DIR/release.json" \
    "https://api.github.com/repos/XTLS/Xray-core/releases/latest"; then
    XRAY_VERSION="$(jq -er \
      'select(.draft == false and .prerelease == false) | .tag_name | select(type == "string" and length > 0)' \
      "$WORK_DIR/release.json" 2>/dev/null || true)"
  fi
  [ -n "$XRAY_VERSION" ] ||
    die "无法确认官方最新版；已停止，不会使用写死版本或镜像旧版。请恢复 GitHub 访问后重试。"
}

verify_xray_archive() {
  local expected actual
  expected="$(awk -F= '
    $1 ~ /^[[:space:]]*SHA(2-)?256[[:space:]]*$/ {
      value=$2; gsub(/[[:space:]\r]/, "", value); print tolower(value)
    }' "$WORK_DIR/xray.zip.dgst")"
  printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$' &&
    [ "${#expected}" -eq 64 ] || die "官方 SHA256 校验文件格式无效，未安装。"
  actual="$(sha256sum "$WORK_DIR/xray.zip")"
  actual="${actual%% *}"
  [ "$actual" = "$expected" ] || die "Xray 下载包 SHA256 不匹配，未解压或执行。"
  echo "官方 SHA256 校验通过。"
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
  echo "获取 GitHub 官方同版本、同架构校验文件..."
  fetch_to "$WORK_DIR/xray.zip.dgst" "$github_url.dgst" ||
    die "无法取得官方校验文件，已停止；不会使用镜像提供的校验值。"
  if fetch_to "$WORK_DIR/xray.zip" "$github_url"; then
    echo "Xray 下载成功: GitHub"
  else
    echo "GitHub 下载失败，尝试 SourceForge 的同一版本 ${XRAY_VERSION}..."
    rm -f "$WORK_DIR/xray.zip"
    fetch_to "$WORK_DIR/xray.zip" "$mirror_url" ||
      die "无法下载 ${XRAY_VERSION}，镜像可能尚未同步；已停止，不自动降级。"
  fi
  verify_xray_archive
  unzip -oq "$WORK_DIR/xray.zip" xray -d "$WORK_DIR"
  mkdir -p "${XRAY_BIN%/*}"
  install -m 0755 "$WORK_DIR/xray" "$XRAY_BIN"
  "$XRAY_BIN" version | head -n1
}

write_service() {
  if [ "$INIT" = systemd ]; then
    trusted_path "/etc/systemd/system/${SERVICE_NAME}.service" file
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray proxy service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_DIR}/config.json
Restart=on-failure
RestartSec=3
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    service_enable "$SERVICE_NAME"
    return
  fi
  trusted_path "/etc/init.d/${SERVICE_NAME}" file
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
  local uuid keys private public short_id ss_address ss_port ss_password
  uuid="$("$XRAY_BIN" uuid)"
  keys="$("$XRAY_BIN" x25519)"
  private="$(printf '%s\n' "$keys" | reality_key_field private)"
  public="$(printf '%s\n' "$keys" | reality_key_field public)"
  printf '%s\n' "$private" | grep -Eq '^[A-Za-z0-9_-]{43}$' ||
    die "未提取到有效 Reality 私钥，已停止；请检查 xray x25519 输出格式，不要公开私钥。"
  printf '%s\n' "$public" | grep -Eq '^[A-Za-z0-9_-]{43}$' ||
    die "未提取到有效 Reality 公钥，已停止；请检查 xray x25519 输出格式。"
  short_id="$(rand_hex 8)"
  if [ "$role" = relay ]; then
    echo "上游落地协议: Shadowsocks，aes-128-gcm；请先部署落地节点。"
    ss_address="$(ask_endpoint '落地节点公网 IP/域名')"
    ss_port="$(ask_port '落地节点对外 SS 端口（NAT 时填写外部映射端口）')"
    ss_password="$(ask_secret '落地节点生成的 SS 密码')"
    [ -n "$ss_password" ] || die "SS 密码不能为空"
    cat > "$GENERATED_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "${NODE_NAME}",
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "vless",
    "settings": {"clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}], "decryption": "none"},
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
    cat > "$GENERATED_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "${NODE_NAME}",
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "vless",
    "settings": {"clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}], "decryption": "none"},
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
  CLIENT_HOST="$(ask_endpoint '客户端连接地址（公网 IP/域名）' "$PUBLIC_HOST")"
  LINK="vless://${uuid}@${CLIENT_HOST}:${PUBLIC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${public}&sid=${short_id}&type=tcp#${NODE_NAME}"
}

make_landing_config() {
  local password method client_host userinfo
  password="$(rand_password)"
  method="aes-128-gcm"
  cat > "$GENERATED_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "${NODE_NAME}",
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "shadowsocks",
    "settings": {"method": "${method}", "password": "${password}", "network": "tcp"}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
  CLIENT_HOST="$(ask_endpoint '客户端连接地址（公网 IP/域名）' "$PUBLIC_HOST")"
  userinfo="$(printf '%s' "${method}:${password}" | openssl base64 -A)"
  LINK="ss://${userinfo}@${CLIENT_HOST}:${PUBLIC_PORT}#${NODE_NAME}"
  echo "落地协议: Shadowsocks ${method}"
  echo "SS 密码: ${password}"
}

check_existing_config() {
  [ -e "$XRAY_DIR/config.json" ] || return 0
  jq -e '
    type == "object" and
    ((.inbounds // []) | type == "array") and
    ((.outbounds // []) | type == "array")
  ' "$XRAY_DIR/config.json" >/dev/null ||
    die "已有配置不是可解析的 JSON 对象，已停止，不会覆盖。"
}

name_available() {
  if [ -e "$XRAY_DIR/manager-state.json" ]; then
    jq -e --arg name "$1" '
      .nodes[$name] == null and .nodes[$name+"Out"] == null and
      ([.nodes[]?.inbound.tag] | any(. == $name or . == ($name+"Out")) | not)
    ' "$XRAY_DIR/manager-state.json" >/dev/null || return 1
  fi
  [ -e "$XRAY_DIR/config.json" ] || return 0
  jq -e --arg name "$1" '
    ([.inbounds[]?.tag, .outbounds[]?.tag] |
      any(. == $name or . == ($name + "Out"))) | not
  ' "$XRAY_DIR/config.json" >/dev/null
}

port_available() {
  if [ -e "$XRAY_DIR/manager-state.json" ]; then
    jq -e --argjson port "$1" '
      [.nodes[]?.inbound.port | . != $port] | all
    ' "$XRAY_DIR/manager-state.json" >/dev/null || return 1
  fi
  [ -e "$XRAY_DIR/config.json" ] || return 0
  # Conservatively reserve an internal port across all transports/listeners.
  jq -e --argjson port "$1" '
    [.inbounds[]?.port |
      if type == "number" then . != $port
      elif type == "string" then
        split(",") | all(
          split("-") | map(tonumber) |
          if length == 1 then .[0] != $port
          else ($port < .[0] or $port > .[1]) end)
      else false end] | all
  ' "$XRAY_DIR/config.json" >/dev/null
}

merge_node_config() {
  local existing="$1" node="$2" candidate="$3"
  jq --arg name "$NODE_NAME" --slurpfile node "$node" '
    $node[0] as $new |
    .inbounds = ((.inbounds // []) + $new.inbounds) |
    .outbounds = ((.outbounds // []) +
      ($new.outbounds | map(.tag = ($name + "Out")))) |
    .routing = (.routing // {}) |
    .routing.rules = [{
      type: "field", inboundTag: [$name], outboundTag: ($name + "Out")
    }] + (.routing.rules // [])
  ' "$existing" > "$candidate"
}

# Rebuild private fallback listeners and exact-SNI routes from active REALITY nodes.
sync_reality_filters() {
  local config="$1" state="$2" output="$3"
  jq --slurpfile state "$state" '
    def owned: startswith("reality-filter-");
    .inbounds = [(.inbounds // [])[] | select(((.tag // "") | owned) | not)] |
    .outbounds = [(.outbounds // [])[] | select(((.tag // "") | owned) | not)] |
    .routing.rules = [(.routing.rules // [])[] |
      select((any(.inboundTag[]?; owned) or ((.outboundTag // "") | owned)) | not)] |
    ([.inbounds[].port, $state[0].nodes[]?.inbound.port] | map(select(. != null))) as $reserved |
    if any($reserved[]; type != "number") then error("Cannot allocate fallback port with port ranges") else . end |
    [.inbounds[] | select(.protocol=="vless" and .streamSettings.security=="reality" and
      ((.tag // "") | test("^[A-Za-z][A-Za-z0-9]*$")))] as $nodes |
    reduce $nodes[] as $node ({config:., used:$reserved};
      ([range(20000;65536)] - .used | .[0]) as $port |
      if $port==null then error("No free fallback port") else . end |
      ("reality-filter-"+$node.tag) as $tag |
      ($node.streamSettings.realitySettings.serverNames) as $names |
      if ($names | type)!="array" or ($names | length)==0 or any($names[]; .=="")
      then error("REALITY requires nonempty serverNames") else . end |
      .used += [$port] |
      .config.inbounds |= map(if .tag==$node.tag then
        .streamSettings.realitySettings.dest=("127.0.0.1:"+($port|tostring)) |
        del(.streamSettings.realitySettings.target) else . end) |
      .config.inbounds += [{tag:$tag,listen:"127.0.0.1",port:$port,protocol:"dokodemo-door",
        settings:{address:$names[0],port:443,network:"tcp"},
        sniffing:{enabled:true,destOverride:["tls"],routeOnly:true}}] |
      .config.routing.rules = [
        {type:"field",inboundTag:[$tag],domain:($names|map("full:"+.)),outboundTag:"reality-filter-direct"},
        {type:"field",inboundTag:[$tag],outboundTag:"reality-filter-block"}
      ] + .config.routing.rules
    ) | .config |
    if ($nodes|length)>0 then .outbounds += [
      {tag:"reality-filter-direct",protocol:"freedom"},
      {tag:"reality-filter-block",protocol:"blackhole"}
    ] else . end
  ' "$config" > "$output"
}

stage_node_config() {
  CANDIDATE_CONFIG="$(mktemp "$XRAY_DIR/.config-candidate.XXXXXX")"
  if [ -e "$XRAY_DIR/config.json" ]; then
    merge_node_config "$XRAY_DIR/config.json" "$GENERATED_CONFIG" "$CANDIDATE_CONFIG"
  else
    # The generated config is also the base for a first install.
    jq --arg name "$NODE_NAME" '
      .outbounds |= map(.tag = ($name + "Out")) |
      .routing = {rules:[{
        type:"field", inboundTag:[$name], outboundTag:($name + "Out")
      }]}
    ' "$GENERATED_CONFIG" > "$CANDIDATE_CONFIG"
  fi
}

stage_node_state() {
  CANDIDATE_STATE="$(mktemp "$XRAY_DIR/.state-candidate.XXXXXX")"
  if [ -e "$XRAY_DIR/manager-state.json" ]; then
    cp "$XRAY_DIR/manager-state.json" "$CANDIDATE_STATE"
  else
    printf '{"nodes":{}}\n' > "$CANDIDATE_STATE"
  fi
  jq --arg name "$NODE_NAME" --arg host "$CLIENT_HOST" --argjson port "$PUBLIC_PORT" \
    --arg sni "$SERVER_NAME" --slurpfile node "$CANDIDATE_CONFIG" '
    .nodes = (.nodes // {}) |
    .nodes[$name] = {inbound:($node[0].inbounds[] | select(.tag==$name)), disabled:false,
      public_host:$host, public_port:$port, sni:$sni, max_connections:0}
  ' "$CANDIDATE_STATE" > "$WORK_DIR/node-state.json"
  mv "$WORK_DIR/node-state.json" "$CANDIDATE_STATE"
}

main() {
  need_root
  validate_reality_server_name
  umask 077
  trusted_path "$XRAY_DIR" dir
  trusted_path "$XRAY_BIN" file
  trusted_path "$XRAY_DIR/config.json" file
  trusted_path "$XRAY_DIR/manager-state.json" file
  mkdir -p "$XRAY_DIR"
  mkdir "$XRAY_DIR/.manager.lock" 2>/dev/null ||
    die "另一个安装/管理任务正在运行，或上次异常退出留下了 $XRAY_DIR/.manager.lock；确认无人运行后手动处理。"
  CREATION_LOCK="$XRAY_DIR/.manager.lock"
  WORK_DIR="$(mktemp -d /tmp/xray-installer.XXXXXX)"
  GENERATED_CONFIG="$WORK_DIR/node.json"
  install_deps
  enable_bbr
  if [ -e "$XRAY_DIR/manager-state.json" ]; then
    jq -e 'type=="object" and ((.nodes // {}) | type=="object")' "$XRAY_DIR/manager-state.json" >/dev/null ||
      die "管理器状态文件损坏，未覆盖。请检查 $XRAY_DIR/manager-state.json"
  fi
  check_existing_config
  if [ -x "$XRAY_BIN" ]; then
    echo "[2/6] 复用已安装的 Xray，不自动替换正在使用的程序。"
    "$XRAY_BIN" version | head -n1
  else
    download_xray
  fi
  echo "[3/6] 选择部署模式"
  echo "允许多个同协议节点；每个节点使用独立名称和内部端口。"
  while :; do
    NODE_NAME="$(ask_node_name)"
    name_available "$NODE_NAME" && break
    echo "名称或对应出口标签已存在，请使用其他名称。"
  done
  mode="$(ask '1. 直连模式  2. 中转模式' 1)"
  case "$mode" in 1|2) ;; *) die "模式只能是 1 或 2" ;; esac
  if [ "$mode" = 1 ]; then
    protocol=1
    role="direct"
  else
    role_choice="$(ask '选择角色: 1. 中转  2. 落地' 1)"
    case "$role_choice" in
      1) role="relay"; protocol=1 ;;
      2) role="landing"; protocol="ss" ;;
      *) die "角色只能是 1 或 2" ;;
    esac
  fi
  case "$protocol" in
    1) protocol_name="VLESS + Reality (xtls-rprx-vision)"; transport="TCP"; default_listen=443 ;;
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
  while ! port_available "$LISTEN_PORT"; do
    echo "内部端口 ${LISTEN_PORT} 已被配置中的入站占用，请换一个端口。"
    LISTEN_PORT="$(ask_port '新的内部监听端口')"
    if [ "$network_mode" = 2 ]; then PUBLIC_PORT="$LISTEN_PORT"; fi
  done
  echo "部署参数: ${role_name} / ${protocol_name}"
  echo "本机监听 ${transport} ${LISTEN_PORT}；对外访问 ${transport} ${PUBLIC_PORT}"
  case "$protocol:$role" in
    1:direct|1:relay) choose_reality_sni; make_vless_config "$role" ;;
    ss:landing) make_landing_config ;;
    *) die "无效的协议选择" ;;
  esac
  echo "[4/6] 检查配置..."
  stage_node_config
  if [ -e "$XRAY_DIR/manager-state.json" ]; then
    cp "$XRAY_DIR/manager-state.json" "$WORK_DIR/filter-state.json"
  else
    printf '{"nodes":{}}\n' > "$WORK_DIR/filter-state.json"
  fi
  sync_reality_filters "$CANDIDATE_CONFIG" "$WORK_DIR/filter-state.json" "$WORK_DIR/filtered-config.json"
  mv "$WORK_DIR/filtered-config.json" "$CANDIDATE_CONFIG"
  "$XRAY_BIN" run -test -format json -config "$CANDIDATE_CONFIG"
  stage_node_state
  if [ -e "$XRAY_DIR/config.json" ]; then
    PREVIOUS_CONFIG="$(mktemp "$XRAY_DIR/.previous-config.XXXXXX")"
    cp "$XRAY_DIR/config.json" "$PREVIOUS_CONFIG"
  fi
  mv "$CANDIDATE_CONFIG" "$XRAY_DIR/config.json"
  CANDIDATE_CONFIG=""
  echo "[5/6] 注册 $INIT 服务..."
  write_service
  if ! service_action "$SERVICE_NAME" restart >/dev/null 2>&1 &&
     ! service_action "$SERVICE_NAME" start; then
    if [ -n "$PREVIOUS_CONFIG" ]; then
      cp "$PREVIOUS_CONFIG" "$XRAY_DIR/config.json"
      service_action "$SERVICE_NAME" restart >/dev/null 2>&1 || true
      die "启动失败，已恢复本次操作前的配置。"
    fi
    die "启动失败，请检查端口占用和服务配置。"
  fi
  mv "$CANDIDATE_STATE" "$XRAY_DIR/manager-state.json"
  CANDIDATE_STATE=""
  echo "[6/6] 完成"
  echo
  echo "节点名称: ${NODE_NAME}"
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
