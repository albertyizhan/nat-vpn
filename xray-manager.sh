#!/bin/sh
set -eu
umask 077

XRAY_DIR="${XRAY_DIR:-/etc/xray}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
CONFIG="${CONFIG:-$XRAY_DIR/config.json}"
STATE="${STATE:-$XRAY_DIR/manager-state.json}"
SERVICE="${SERVICE:-xray}"
LOG_DIR="${LOG_DIR:-$XRAY_DIR/logs}"
RUNNER="$XRAY_DIR/manager.sh"
SELF="$(readlink -f "$0")"
TX=""
LOCK=""

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
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
        # Permit a protected root-owned child beneath a sticky temporary directory.
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
ask() { printf '%s: ' "$1" >&2; IFS= read -r answer || exit 1; printf '%s' "$answer"; }
confirm() { case "$(ask "$1 [y/N]")" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }
valid_name() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9]*$'; }
valid_host() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.:-]*$'; }
valid_number() {
  case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#1}" -le 9 ]
}
valid_port() { valid_number "$1" && [ "$1" -gt 0 ] && [ "$1" -le 65535 ]; }
valid_sni() {
  case "$1" in *[Cc][Ll][Oo][Uu][Dd][Ff][Ll][Aa][Rr][Ee]*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
}
uri() { jq -rn --arg v "$1" '$v | @uri'; }

cleanup() {
  if [ -n "$TX" ]; then
    rm -f "$TX/config.json"
    rm -f "$TX/state.json"
    rm -f "$TX/old-config.json"
    rm -f "$TX/old-state.json"
    rm -f "$TX/stats.json"
    rm -f "$TX/access.txt"
    rm -f "$TX/next.json"
    rm -f "$TX/connections.txt"
    rm -f "$TX/selected-node"
    rm -f "$TX/runner.sh"
    rmdir "$TX" 2>/dev/null || true
  fi
  [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

need_tools() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
  case "$SERVICE" in
    ''|[!A-Za-z]*|*[!A-Za-z0-9_-]*)
      die "服务名称只能以字母开头，包含字母、数字、下划线或连字符。" ;;
  esac
  for path in "$XRAY_DIR" "$LOG_DIR"; do
    trusted_path "$path" dir
  done
  for path in "$XRAY_BIN" "$CONFIG" "$STATE" "$RUNNER" "$LOG_DIR/access.log"; do
    trusted_path "$path" file
  done
  if [ -n "${MENU_RESULT:-}" ]; then
    case "$MENU_RESULT" in
      "$XRAY_DIR"/.menu-result.*) ;;
      *) die "菜单返回文件必须为当前配置目录中的临时文件。" ;;
    esac
    trusted_path "$MENU_RESULT" file
    [ -f "$MENU_RESULT" ] || die "菜单返回文件不存在。"
  fi
  command -v jq >/dev/null 2>&1 || die "缺少 jq，请执行 apk add --no-cache jq。"
  [ -x "$XRAY_BIN" ] || die "找不到 Xray: $XRAY_BIN"
  [ -r "$CONFIG" ] || die "找不到配置: $CONFIG"
  jq -e 'type=="object" and (.inbounds | type=="array")' "$CONFIG" >/dev/null ||
    die "配置格式不正确。"
  [ ! -e "$STATE" ] || jq -e 'type=="object" and ((.nodes // {}) | type=="object")' "$STATE" >/dev/null ||
    die "状态文件损坏，未覆盖: $STATE"
  command -v rc-service >/dev/null 2>&1 || die "需要 Alpine OpenRC 的 rc-service。"
}

# Each action owns the lock; idle menus do not block the sampler.
begin() {
  mkdir -p "$XRAY_DIR"
  if ! mkdir "$XRAY_DIR/.manager.lock" 2>/dev/null; then
    [ "${1:-}" = background ] && exit 0
    die "另一个安装/管理任务正在运行，请稍后重试。"
  fi
  LOCK="$XRAY_DIR/.manager.lock"
  TX="$(mktemp -d "$XRAY_DIR/.manager.XXXXXX")"
  cp "$CONFIG" "$TX/config.json"
  cp "$CONFIG" "$TX/old-config.json"
  if [ -e "$STATE" ]; then cp "$STATE" "$TX/old-state.json"; else printf '{}\n' > "$TX/old-state.json"; fi
  jq --slurpfile config "$CONFIG" '
    .nodes = (.nodes // {}) | del(.users) |
    reduce ($config[0].inbounds[] |
      select(.protocol=="vless" or .protocol=="shadowsocks" or .protocol=="hysteria") |
      select((.tag // "") | test("^[A-Za-z][A-Za-z0-9]*$"))) as $i
      (.; .nodes[$i.tag] = ((.nodes[$i.tag] // {}) +
        {inbound:$i, disabled:false}))
  ' "$TX/old-state.json" > "$TX/state.json"
}

state_edit() {
  local filter
  filter="$1"; shift
  jq "$@" "$filter" "$TX/state.json" > "$TX/next.json"
  mv "$TX/next.json" "$TX/state.json"
}
config_edit() {
  local filter
  filter="$1"; shift
  jq "$@" "$filter" "$TX/config.json" > "$TX/next.json"
  mv "$TX/next.json" "$TX/config.json"
}
node() { jq -c --arg tag "$1" '.nodes[$tag].inbound // empty' "$TX/state.json"; }
node_value() { node "$1" | jq -r "$2"; }
state_value() { jq -r --arg tag "$1" ".nodes[\$tag] | $2" "$TX/state.json"; }

api_address() {
  jq -er '
    .api.tag as $tag |
    .inbounds[] | select(.tag==$tag and .listen=="127.0.0.1" and .protocol=="dokodemo-door") |
    select(.port | type=="number") | "127.0.0.1:" + (.port | tostring)
  ' "$TX/config.json" 2>/dev/null | head -n1
}

sample_stats() {
  local addr epoch pid
  prepare_quota_cycles
  addr="$(api_address)" || return 0
  [ -n "$addr" ] || return 0
  "$XRAY_BIN" api statsquery --server="$addr" -pattern 'inbound>>>' > "$TX/stats.json" 2>/dev/null ||
    { echo "统计 API 暂不可用，保留已有计数。" >&2; return 0; }
  jq -e '(.stat // []) | type=="array"' "$TX/stats.json" >/dev/null ||
    { echo "统计响应无效，保留已有计数。" >&2; return 0; }
  epoch=""
  for pid in $(pidof xray 2>/dev/null || true); do
    [ -r "/proc/$pid/stat" ] || continue
    epoch="$epoch:$pid:$(awk '{print $22}' "/proc/$pid/stat")"
  done
  [ ! -r /proc/sys/kernel/random/boot_id ] || epoch="$epoch:$(cat /proc/sys/kernel/random/boot_id)"
  state_edit '
    ($stats[0].stat // [] | map({key:.name, value:((.value // 0)|tonumber)}) | from_entries) as $c |
    .nodes |= with_entries(
      .key as $tag | if .value.statistics==true then
        ($c["inbound>>>"+$tag+">>>traffic>>>uplink"] // 0) as $up |
        ($c["inbound>>>"+$tag+">>>traffic>>>downlink"] // 0) as $down |
        (if .value.epoch==$epoch and $up >= (.value.last_up // 0)
         then $up - (.value.last_up // 0) else $up end) as $du |
        (if .value.epoch==$epoch and $down >= (.value.last_down // 0)
         then $down - (.value.last_down // 0) else $down end) as $dd |
        .value.upload_bytes=((.value.upload_bytes // 0)+$du) |
        .value.download_bytes=((.value.download_bytes // 0)+$dd) |
        .value.last_up=$up | .value.last_down=$down | .value.epoch=$epoch |
        .value.sampled_at=$time
      else . end)
  ' --slurpfile stats "$TX/stats.json" --arg epoch "$epoch" --arg time "$(date -u +%FT%TZ)"
}

sample_logs() {
  local inode offset old_inode size bytes lines tag
  [ -r "$LOG_DIR/access.log" ] || return 0
  inode="$(stat -c %i "$LOG_DIR/access.log")"
  offset="$(jq -r '.log_offset // 0' "$TX/state.json")"
  old_inode="$(jq -r '.log_inode // ""' "$TX/state.json")"
  size="$(wc -c < "$LOG_DIR/access.log" | tr -d ' ')"
  if [ "$inode" != "$old_inode" ] || [ "$size" -lt "$offset" ]; then offset=0; fi
  [ "$size" -gt "$offset" ] || return 0
  # Leave a partial trailing line for the next sample.
  tail -c "+$((offset + 1))" "$LOG_DIR/access.log" |
    head -c "$((size - offset))" > "$TX/access.txt"
  # wc -l counts complete lines; head excludes a partially written last line.
  lines="$(wc -l < "$TX/access.txt" | tr -d ' ')"
  [ "$lines" -gt 0 ] || return 0
  head -n "$lines" "$TX/access.txt" > "$TX/connections.txt"
  bytes="$(wc -c < "$TX/connections.txt" | tr -d ' ')"
  for tag in $(jq -r '.nodes | to_entries[] | select(.value.logging==true) | .key' "$TX/state.json"); do
    valid_name "$tag" || continue
    trusted_path "$LOG_DIR/$tag-connections.log" file
    touch "$LOG_DIR/$tag-connections.log"
    chmod 600 "$LOG_DIR/$tag-connections.log"
    awk -v tag="$tag" '
      index($0, "[" tag " -> ") || index($0, "[" tag " >> ") || index($0, "[" tag " ==> ") {
        for (i=1;i<NF;i++) if ($i=="accepted" || $i=="rejected") {
          print $1 " " $2 "\ttarget=" $(i+1) "\tstatus=" $i; break
        }
      }
    ' "$TX/connections.txt" >> "$LOG_DIR/$tag-connections.log"
  done
  state_edit '.log_inode=$inode | .log_offset=$offset' --arg inode "$inode" --argjson offset "$((offset + bytes))"
}

save_only() {
  cp "$TX/state.json" "$TX/next.json"
  mv "$TX/next.json" "$STATE"
  chmod 600 "$STATE"
}

apply() {
  "$XRAY_BIN" run -test -format json -config "$TX/config.json" ||
    die "配置检查失败，未应用。"
  state_edit '.nodes |= with_entries(.value.epoch="" | .value.last_up=0 | .value.last_down=0)'
  cp "$TX/config.json" "$TX/next.json"
  mv "$TX/next.json" "$CONFIG"
  save_only
  chmod 600 "$CONFIG" "$STATE"
  if ! rc-service "$SERVICE" restart; then
    mv "$TX/old-config.json" "$CONFIG"
    mv "$TX/old-state.json" "$STATE"
    rc-service "$SERVICE" restart >/dev/null 2>&1 || true
    die "重启失败，已恢复本次操作前的配置与状态。"
  fi
}

persist_node() {
  # Enabled nodes live in config; disabled ones live only in manager state.
  config_edit '
    if $state[0].nodes[$tag].disabled==true then
      .inbounds |= map(select(.tag != $tag))
    elif any(.inbounds[]; .tag==$tag) then
      .inbounds |= map(if .tag==$tag then $state[0].nodes[$tag].inbound else . end)
    else .inbounds += [$state[0].nodes[$tag].inbound] end
  ' --arg tag "$1" --slurpfile state "$TX/state.json"
}

install_sampler() {
  command -v crontab >/dev/null 2>&1 || die "缺少 crontab，请安装 BusyBox。"
  command -v crond >/dev/null 2>&1 || die "缺少 crond，请安装 BusyBox。"
  trusted_path "$RUNNER" file
  if [ "$SELF" != "$RUNNER" ]; then
    cp "$SELF" "$TX/runner.sh"
    chmod 700 "$TX/runner.sh"
    mv "$TX/runner.sh" "$RUNNER"
  fi
  chmod 700 "$RUNNER"
  state_edit '.sampler=true'
  {
    crontab -l 2>/dev/null | awk '!/# xray-node-manager$/ && !/# xray-node-manager-boot$/'
    printf "* * * * * XRAY_DIR='%s' CONFIG='%s' STATE='%s' XRAY_BIN='%s' LOG_DIR='%s' SERVICE='%s' '%s' --sample # xray-node-manager\n" \
      "$XRAY_DIR" "$CONFIG" "$STATE" "$XRAY_BIN" "$LOG_DIR" "$SERVICE" "$RUNNER"
  } | crontab -
  rc-update add crond default
  rc-service crond status >/dev/null 2>&1 || rc-service crond start
}

configure_statistics() {
  local tag api_tag
  tag="$1"
  api_tag="$(jq -r '.api.tag // "NodeStatsAPI"' "$TX/config.json")"
  if jq -e '.api.tag != null' "$TX/config.json" >/dev/null; then
    [ -n "$(api_address)" ] || die "已有 API 不是本机 dokodemo-door 入站，未自动改写。"
  else
    jq -e --arg tag "$api_tag" '
      any(.inbounds[]?; .tag==$tag or .port==10085) or any(.outbounds[]?; .tag==$tag)
    ' "$TX/config.json" >/dev/null && die "统计 API 名称或端口 10085 已占用。"
    config_edit '
      .inbounds += [{tag:$tag,listen:"127.0.0.1",port:10085,
        protocol:"dokodemo-door",settings:{address:"127.0.0.1"}}] |
      .outbounds = ((.outbounds // []) + [{tag:$tag,protocol:"freedom"}]) |
      .routing.rules = [{type:"field",inboundTag:[$tag],outboundTag:$tag}] + (.routing.rules // [])
    ' --arg tag "$api_tag"
  fi
  config_edit '
    .api.tag=$tag | .api.services=((.api.services // [])+["StatsService"] | unique) |
    .stats=(.stats // {}) |
    .policy.system.statsInboundUplink=true | .policy.system.statsInboundDownlink=true
  ' --arg tag "$api_tag"
  state_edit '.nodes[$tag].statistics=true' --arg tag "$tag"
  install_sampler
}

enable_statistics() {
  configure_statistics "$1"
  apply
  echo "节点字节统计已开启；每分钟保存一次上下行累计值。"
}

enable_logging() {
  local tag existing
  tag="$1"
  echo "只记录目标域名/IP:端口和连接状态，不记录路径、正文或精确包数。"
  echo "Xray 原始访问日志是全局的；采样任务按精确入站标签分流为节点日志。"
  confirm "开启 $tag 的日志？" || return 0
  existing="$(jq -r '.log.access // ""' "$TX/config.json")"
  case "$existing" in ""|none|"$LOG_DIR/access.log") ;; *) die "已有自定义访问日志 ${existing}，未自动覆盖。";; esac
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  touch "$LOG_DIR/access.log"; chmod 600 "$LOG_DIR/access.log"
  config_edit '.log.access=$path | .log.dnsLog=false' --arg path "$LOG_DIR/access.log"
  state_edit '.nodes[$tag].logging=true' --arg tag "$tag"
  install_sampler
  apply
  echo "节点日志: $LOG_DIR/$tag-connections.log"
}

show_stats() {
  local tag
  tag="$1"
  jq -r --arg tag "$tag" '
    .nodes[$tag] |
    "统计开关: \(.statistics // false)",
    "累计上行: \(.upload_bytes // 0) 字节",
    "累计下行: \(.download_bytes // 0) 字节",
    "本周期使用: \([0, ((.upload_bytes // 0)+(.download_bytes // 0)-(.quota_base_bytes // 0))] | max) 字节",
    "月流量上限: \(.quota_gib // 0) GiB (0=不限，上下行合计)",
    "重置日: 每月 \(.reset_day // 1) 日 UTC 00:00（短月份取月末）",
    "当前周期: \(.quota_cycle // "未开通")",
    "停用原因: \(.disabled_reason // "无")",
    "最近采样: \(.sampled_at // "尚未采样")",
    "连接上限: \(.max_connections // 0) (0=无限制)",
    "节点日志: \(.logging // false)"
  ' "$TX/state.json"
  if [ -r "$LOG_DIR/$tag-connections.log" ]; then
    trusted_path "$LOG_DIR/$tag-connections.log" file
    echo "最近 30 条目标连接记录:"
    tail -n 30 "$LOG_DIR/$tag-connections.log"
  fi
}

tcp_limit_supported() {
  local proto network transport port count
  proto="$(node_value "$1" '.protocol')"
  network="$(node_value "$1" '.settings.network // "tcp,udp"')"
  transport="$(node_value "$1" '.streamSettings.network // "tcp"')"
  case "$proto:$network:$transport" in
    vless:*:tcp|vless:*:raw|shadowsocks:tcp:tcp) ;;
    *) die "此版本仅支持 TCP VLESS/SS 的连接数软限制；HY2、UDP 或其他传输不接受非零上限。" ;;
  esac
  port="$(node_value "$1" '.port')"
  valid_port "$port" || die "连接限制要求单个数值监听端口。"
  count="$(jq --argjson port "$port" '[.nodes[].inbound | select(.port==$port)] | length' "$TX/state.json")"
  [ "$count" -eq 1 ] || die "多个节点共享此端口，不能可靠按节点计数。"
}

set_max_connections() {
  local tag value port
  tag="$1"
  value="$(ask "最大连接数，0=无限制；当前 $(state_value "$tag" '.max_connections // 0')")"
  valid_number "$value" || die "请输入非负整数（不要加前导零）。"
  if [ "$value" -gt 0 ]; then
    tcp_limit_supported "$tag"
    port="$(node_value "$tag" '.port')"
    command -v ss >/dev/null 2>&1 || die "缺少 ss，请执行 apk add --no-cache iproute2-ss。"
    ss -Hnt state established "sport = :$port" > "$TX/connections.txt" ||
      die "当前环境无法读取 TCP 连接。"
    echo "每分钟检查本机该端口的 ESTABLISHED TCP 连接；超限会停用整个节点，需手动启用。"
    echo "不是按 IP 限制，不是即时拒绝新连接，不计 Mux 内部逻辑流，也不代表人数。"
    confirm "使用此软限制策略？" || return 0
    install_sampler
  fi
  state_edit '.nodes[$tag].max_connections=$value' --arg tag "$tag" --argjson value "$value"
  save_only
  echo "连接上限已保存。"
}

quota_period() {
  # Use Gregorian calendar arithmetic instead of GNU date extensions (BusyBox compatible).
  jq -nr --arg today "$(date -u +%Y-%m-%d)" --argjson day "$1" '
    def monthdays($y;$m):
      if $m==2 then
        if ($y%400==0 or ($y%4==0 and $y%100!=0)) then 29 else 28 end
      elif ([4,6,9,11] | index($m))!=null then 30 else 31 end;
    def pad: tostring | if length<2 then "0"+. else . end;
    ($today | split("-") | map(tonumber)) as $d |
    (if $d[2] >= ([$day,monthdays($d[0];$d[1])] | min) then $d[0:2]
     elif $d[1]==1 then [$d[0]-1,12] else [$d[0],$d[1]-1] end) as $p |
    ($p[0]|tostring)+"-"+($p[1]|pad)+"-"+([$day,monthdays($p[0];$p[1])] | min | pad)
  '
}

prepare_quota_cycles() {
  local tag period
  for tag in $(jq -r '.nodes | to_entries[] | select((.value.quota_gib // 0)>0) | .key' "$TX/state.json"); do
    period="$(quota_period "$(state_value "$tag" '.reset_day // 1')")"
    # A backwards clock jump must not give the node a second allowance.
    state_edit '
      .nodes[$tag] |= (
        if .quota_cycle==null or $period>.quota_cycle then
          .quota_cycle=$period |
          .quota_base_bytes=((.upload_bytes // 0)+(.download_bytes // 0)) |
          if .disabled_reason=="monthly_quota" then .quota_reset_pending=true else . end
        else . end)
    ' --arg tag "$tag" --arg period "$period"
  done
}

quota_exhausted() {
  jq -e --arg tag "$1" '.nodes[$tag] |
    (.quota_gib // 0)>0 and
    ((.upload_bytes // 0)+(.download_bytes // 0)-(.quota_base_bytes // 0)) >= (.quota_gib*1073741824)
  ' "$TX/state.json" >/dev/null
}

set_monthly_quota() {
  local tag quota day period previous_day
  tag="$1"
  quota="$(ask "月流量上限 GiB，0=不限；当前 $(state_value "$tag" '.quota_gib // 0')")"
  valid_number "$quota" || die "请输入非负整数 GiB（不要加前导零）。"
  if [ "$quota" -eq 0 ]; then
    state_edit '.nodes[$tag].quota_gib=0 |
      if .nodes[$tag].disabled_reason=="monthly_quota" then
        .nodes[$tag].quota_reset_pending=true else . end' --arg tag "$tag"
    check_limits
    echo "月流量限制已取消。"
    return
  fi
  day="$(ask "每月重置日 1–31，UTC 00:00；短月份取月末；当前 $(state_value "$tag" '.reset_day // 1')")"
  valid_number "$day" && [ "$day" -ge 1 ] && [ "$day" -le 31 ] || die "重置日必须为 1–31。"
  period="$(quota_period "$day")"
  previous_day="$(state_value "$tag" '.reset_day // 1')"
  echo "上行+下行合计，每分钟检查一次；超额停用，新周期自动恢复因流量超额停用的节点。"
  echo "首次开通从现在开始计费；已有配额改上限/重置日保留本周期用量，不清零累计统计。"
  confirm "保存月流量限制？" || return 0
  state_edit '
    .nodes[$tag] |= (
      if .quota_cycle==null then
        .quota_base_bytes=((.upload_bytes // 0)+(.download_bytes // 0)) | .quota_cycle=$period
      elif $day!=$previous_day then .quota_cycle=$period else . end |
      .quota_gib=$quota | .reset_day=$day |
      if .disabled_reason=="monthly_quota" then .quota_reset_pending=true else . end)
  ' --arg tag "$tag" --argjson quota "$quota" --argjson day "$day" \
    --argjson previous_day "$previous_day" --arg period "$period"
  if [ "$(state_value "$tag" '.statistics // false')" != true ]; then
    configure_statistics "$tag"
    apply
  else
    install_sampler
  fi
  check_limits
  echo "月流量策略已保存。"
}

check_limits() {
  local changed tag port count max
  changed=0
  for tag in $(jq -r '.nodes | to_entries[] |
    select(.value.quota_reset_pending==true or
      (.value.disabled!=true and (.value.quota_gib // 0)>0)) | .key' "$TX/state.json"); do
    if [ "$(state_value "$tag" '.quota_reset_pending // false')" = true ]; then
      state_edit 'del(.nodes[$tag].quota_reset_pending)' --arg tag "$tag"
      if [ "$(state_value "$tag" '.disabled_reason // ""')" = monthly_quota ] &&
         ! quota_exhausted "$tag"; then
        state_edit '.nodes[$tag].disabled=false | .nodes[$tag].disabled_reason=null' --arg tag "$tag"
        persist_node "$tag"
        changed=1
        echo "节点 $tag 的流量配额已恢复，自动启用。" >&2
      fi
    fi
    if [ "$(state_value "$tag" '.disabled // false')" != true ] && quota_exhausted "$tag"; then
      state_edit '.nodes[$tag].disabled=true | .nodes[$tag].disabled_reason="monthly_quota"' --arg tag "$tag"
      persist_node "$tag"
      changed=1
      echo "节点 $tag 已达到月流量上限，停用。" >&2
    fi
  done
  for tag in $(jq -r '.nodes | to_entries[] |
    select(.value.disabled!=true and (.value.max_connections // 0)>0) | .key' "$TX/state.json"); do
    port="$(node_value "$tag" '.port')"
    valid_port "$port" || continue
    command -v ss >/dev/null 2>&1 || { echo "缺少 ss，未执行 $tag 的连接限制。" >&2; continue; }
    ss -Hnt state established "sport = :$port" > "$TX/connections.txt" ||
      { echo "无法读取 $tag 的连接数，未判为零。" >&2; continue; }
    count="$(wc -l < "$TX/connections.txt" | tr -d ' ')"
    max="$(state_value "$tag" '.max_connections')"
    if [ "$count" -gt "$max" ]; then
      state_edit '.nodes[$tag].disabled=true | .nodes[$tag].disabled_reason="connection_limit"' --arg tag "$tag"
      persist_node "$tag"
      changed=1
      printf '%s 节点 %s 连接数 %s > %s，停用节点。\n' "$(date -u +%FT%TZ)" "$tag" "$count" "$max" >&2
    fi
  done
  if [ "$changed" -eq 1 ]; then apply; else save_only; fi
}

show_link() {
  local tag host port proto id flow sni sid private public method password userinfo
  tag="$1"
  confirm "导入链接包含节点凭据，显示 $tag 的链接？" || return 0
  host="$(state_value "$tag" '.public_host // ""')"
  port="$(state_value "$tag" '.public_port // ""')"
  if [ -z "$host" ]; then
    host="$(ask "客户端公网地址（域名/IP）")"
    valid_host "$host" || die "地址格式无效。"
  fi
  if [ -z "$port" ]; then
    port="$(ask "外部访问端口（NAT 填外部映射，不猜测内部端口）")"
    valid_port "$port" || die "端口无效。"
  fi
  state_edit '.nodes[$tag].public_host=$host | .nodes[$tag].public_port=$port' \
    --arg tag "$tag" --arg host "$host" --argjson port "$port"
  save_only
  case "$host" in *:*) host="[$host]" ;; esac
  proto="$(node_value "$tag" '.protocol')"
  case "$proto" in
    vless)
      [ "$(node_value "$tag" '.streamSettings.security')" = reality ] ||
        die "当前仅生成 VLESS+Reality 链接。"
      [ "$(node_value "$tag" '.settings.clients | length')" -eq 1 ] ||
        die "此节点有多个凭据，无法对应唯一链接；此管理器不管理单独用户。"
      id="$(node_value "$tag" '.settings.clients[0].id')"
      flow="$(node_value "$tag" '.settings.clients[0].flow // ""')"
      sni="$(node_value "$tag" '.streamSettings.realitySettings.serverNames[0]')"
      sid="$(node_value "$tag" '.streamSettings.realitySettings.shortIds[0] // ""')"
      private="$(node_value "$tag" '.streamSettings.realitySettings.privateKey')"
      public="$("$XRAY_BIN" x25519 -i "$private" | awk -F: '
        {key=tolower($1); gsub(/[[:space:]()]/,"",key)}
        key=="publickey" || key=="passwordpublickey" || key=="password" {
          gsub(/[[:space:]]/,"",$2); print $2; exit
        }')"
      [ -n "$public" ] || die "无法从 Reality 私钥推导公钥。"
      printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
        "$(uri "$id")" "$host" "$port" "$(uri "$flow")" "$(uri "$sni")" "$(uri "$public")" "$(uri "$sid")" "$tag"
      ;;
    shadowsocks)
      method="$(node_value "$tag" '.settings.method // ""')"
      password="$(node_value "$tag" '.settings.password // ""')"
      [ -n "$method" ] && [ -n "$password" ] || die "不是单密码 SS 节点，无法生成唯一链接。"
      userinfo="$(printf '%s' "$method:$password" | base64 | tr '+/' '-_' | tr -d '\n=')"
      printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "$tag"
      ;;
    hysteria)
      [ "$(node_value "$tag" '.settings.users | length')" -eq 1 ] ||
        die "HY2 节点必须只有一份认证凭据。"
      password="$(node_value "$tag" '.settings.users[0].auth // ""')"
      sni="$(state_value "$tag" '.sni // ""')"
      if [ -z "$sni" ]; then
        sni="$(ask "HY2 证书域名/SNI（必须匹配已有可信证书）")"
        valid_sni "$sni" || die "域名格式无效。"
        state_edit '.nodes[$tag].sni=$sni' --arg tag "$tag" --arg sni "$sni"
        save_only
      fi
      [ -n "$password" ] || die "HY2 auth 缺失。"
      printf 'hysteria2://%s@%s:%s/?sni=%s#%s\n' "$(uri "$password")" "$host" "$port" "$(uri "$sni")" "$tag"
      ;;
    *) die "不支持此协议的链接。" ;;
  esac
}

set_enabled() {
  local tag disabled
  tag="$1"; disabled="$2"
  if [ "$disabled" = false ] && quota_exhausted "$tag"; then
    die "本周期配额已用尽，请提高/取消月流量限制，或等待下次重置。"
  fi
  state_edit '.nodes[$tag].disabled=$disabled | .nodes[$tag].disabled_reason=
    (if $disabled then "manual" else null end)' --arg tag "$tag" --argjson disabled "$disabled"
  persist_node "$tag"
  apply
  echo "节点状态已更新；重载服务会中断此 Xray 进程的现有连接。"
}

rename_node() {
  local tag new
  tag="$1"; new="$(ask "新名称（英文字母开头，后续仅字母和数字）")"
  valid_name "$new" || die "名称无效。"
  [ "$new" != "$tag" ] || return 0
  trusted_path "$LOG_DIR/$tag-connections.log" file
  trusted_path "$LOG_DIR/$new-connections.log" file
  [ ! -e "$LOG_DIR/$new-connections.log" ] || die "新名称日志已存在，请先处理: $LOG_DIR/$new-connections.log"
  jq -e --arg new "$new" '
    .nodes[$new]!=null or any(.nodes[]; .inbound.tag==($new+"Out"))
  ' "$TX/state.json" >/dev/null && die "节点名称已存在。"
  jq -e --arg new "$new" 'any(.inbounds[]?; .tag==$new or .tag==($new+"Out")) or
    any(.outbounds[]?; .tag==$new or .tag==($new+"Out"))' "$TX/config.json" >/dev/null &&
    die "新名称或关联出口名称冲突。"
  config_edit '
    .inbounds |= map(if .tag==$old then .tag=$new else . end) |
    .outbounds = ((.outbounds // []) | map(if .tag==($old+"Out") then .tag=($new+"Out") else . end)) |
    walk(if type=="object" then
      (if (.inboundTag? | type)=="array" then .inboundTag |= map(if .==$old then $new else . end) else . end) |
      (if .outboundTag?==($old+"Out") then .outboundTag=($new+"Out") else . end) |
      (if .dialerProxy?==($old+"Out") then .dialerProxy=($new+"Out") else . end) |
      (if .proxySettings?.tag==($old+"Out") then .proxySettings.tag=($new+"Out") else . end)
    else . end)
  ' --arg old "$tag" --arg new "$new"
  state_edit '
    .nodes[$new]=.nodes[$old] | .nodes[$new].inbound.tag=$new | del(.nodes[$old])
  ' --arg old "$tag" --arg new "$new"
  apply
  if [ -e "$LOG_DIR/$tag-connections.log" ]; then
    mv "$LOG_DIR/$tag-connections.log" "$LOG_DIR/$new-connections.log"
  fi
  echo "已改名为 ${new}，请重新显示导入链接。"
  printf '%s\n' "$new" > "$TX/selected-node"
}

delete_node() {
  local tag
  tag="$1"
  confirm "永久删除 $tag 的配置与凭据？不生成备份，已有日志保留。" || return 0
  config_edit '
    .inbounds |= map(select(.tag!=$tag)) |
    .routing.rules = [(.routing.rules // [])[] |
      if (.inboundTag? | type)=="array" and (.inboundTag | index($tag))!=null
      then .inboundTag |= map(select(.!=$tag)) | select(.inboundTag | length>0) else . end] |
    ([.. | objects | .outboundTag?, .dialerProxy?, .proxySettings?.tag?] |
      any(.==($tag+"Out"))) as $used |
    if $used then . else .outbounds = [(.outbounds // [])[] | select(.tag!=($tag+"Out"))] end
  ' --arg tag "$tag"
  state_edit 'del(.nodes[$tag])' --arg tag "$tag"
  if ! jq -e 'any(.nodes[]; .logging==true)' "$TX/state.json" >/dev/null &&
     [ "$(jq -r '.log.access // ""' "$TX/config.json")" = "$LOG_DIR/access.log" ]; then
    config_edit '.log.access="none"'
  fi
  apply
  echo "节点已删除。"
}

edit_config() {
  local tag value proto cert host port password
  tag="$1"
  echo "1. 内部监听端口"
  echo "2. 外部访问/映射端口"
  echo "3. 客户端公网地址"
  echo "4. SNI / Reality 目标"
  echo "5. UUID / 节点密码"
  echo "6. 节点名称"
  echo "7. 中转出口的 SS 地址/端口/密码"
  echo "0. 返回"
  case "$(ask "选择配置项目")" in
    1)
      value="$(ask "新的内部端口（当前 $(node_value "$tag" '.port')）")"
      valid_port "$value" || die "端口无效。"
      jq -e --arg tag "$tag" --argjson port "$value" '
        any(.nodes | to_entries[]; .key!=$tag and .value.inbound.port==$port)
      ' "$TX/state.json" >/dev/null && die "端口已被另一节点保留。"
      jq -e --arg tag "$tag" --argjson port "$value" '
        any(.inbounds[]; .tag!=$tag and
          ((.port | type)!="number" or .port==$port))
      ' "$TX/config.json" >/dev/null && die "配置端口冲突或存在无法自动检查的端口范围。"
      state_edit '.nodes[$tag].inbound.port=$value' --arg tag "$tag" --argjson value "$value"
      persist_node "$tag"; apply
      echo "内部端口已修改，外部映射未改变；请同步服务商 NAT 映射。"
      ;;
    2)
      value="$(ask "新的外部端口（当前 $(state_value "$tag" '.public_port // "未设置"')）")"
      valid_port "$value" || die "端口无效。"
      state_edit '.nodes[$tag].public_port=$value' --arg tag "$tag" --argjson value "$value"; save_only
      ;;
    3)
      value="$(ask "新的客户端公网地址")"; valid_host "$value" || die "地址无效。"
      state_edit '.nodes[$tag].public_host=$value' --arg tag "$tag" --arg value "$value"; save_only
      ;;
    4)
      proto="$(node_value "$tag" '.protocol')"
      value="$(ask "新的 SNI")"; valid_sni "$value" || die "域名无效，禁止 Cloudflare。"
      case "$proto" in
        vless)
          [ "$(node_value "$tag" '.streamSettings.security')" = reality ] || die "不是 Reality 节点。"
          state_edit '.nodes[$tag].inbound.streamSettings.realitySettings |=
            (.serverNames=[$value] | .dest=($value+":443") | if has("target") then .target=($value+":443") else . end)' \
            --arg tag "$tag" --arg value "$value"
          persist_node "$tag"; apply
          echo "已更新 SNI 与目标；请确认新目标支持 Reality 所需 TLS 特性。"
          ;;
        hysteria)
          command -v openssl >/dev/null 2>&1 || die "缺少 openssl。"
          cert="$(node_value "$tag" '.streamSettings.tlsSettings.certificates[0].certificateFile // ""')"
          [ -r "$cert" ] || die "证书文件不可读。"
          openssl x509 -in "$cert" -noout -checkhost "$value" >/dev/null || die "新域名与现有证书不匹配，未修改。"
          state_edit '.nodes[$tag].sni=$value' --arg tag "$tag" --arg value "$value"; save_only
          ;;
        *) die "SS 没有 SNI。" ;;
      esac
      ;;
    5)
      value="$(ask "输入新 UUID/密码（更改后旧链接失效）")"
      [ -n "$value" ] || die "不能为空。"
      case "$(node_value "$tag" '.protocol')" in
        vless)
          printf '%s\n' "$value" | grep -Eq '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' || die "UUID 格式无效。"
          [ "$(node_value "$tag" '.settings.clients | length')" -eq 1 ] || die "多个凭据的节点不提供此快捷修改。"
          state_edit '.nodes[$tag].inbound.settings.clients[0].id=$value' --arg tag "$tag" --arg value "$value" ;;
        shadowsocks)
          [ "$(node_value "$tag" '.settings.password // ""')" != "" ] || die "不是单密码 SS。"
          state_edit '.nodes[$tag].inbound.settings.password=$value' --arg tag "$tag" --arg value "$value" ;;
        hysteria)
          [ "$(node_value "$tag" '.settings.users | length')" -eq 1 ] || die "多个凭据的节点不提供此快捷修改。"
          state_edit '.nodes[$tag].inbound.settings.users[0].auth=$value' --arg tag "$tag" --arg value "$value" ;;
      esac
      persist_node "$tag"; apply
      ;;
    6) rename_node "$tag" ;;
    7)
      jq -e --arg tag "$tag" 'any(.outbounds[]?; .tag==($tag+"Out") and .protocol=="shadowsocks")' "$TX/config.json" >/dev/null ||
        die "没有此节点专属的 SS 中转出口。"
      host="$(ask "落地公网地址")"; valid_host "$host" || die "地址无效。"
      port="$(ask "落地外部 SS 端口")"; valid_port "$port" || die "端口无效。"
      password="$(ask "落地 SS 密码")"; [ -n "$password" ] || die "密码不能为空。"
      config_edit '.outbounds |= map(if .tag==($tag+"Out") then
        .settings.servers[0] |= (.address=$host | .port=$port | .password=$password) else . end)' \
        --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg password "$password"
      apply
      ;;
    0) ;;
    *) echo "无效选项。" ;;
  esac
}

run_action() {
  local action tag
  action="$1"; tag="$2"
  begin
  [ -n "$(node "$tag")" ] || die "节点不存在。"
  sample_stats
  sample_logs
  case "$action" in
    link) show_link "$tag" ;;
    stats) show_stats "$tag"; save_only ;;
    enable_stats) enable_statistics "$tag" ;;
    enable_logs) enable_logging "$tag" ;;
    disable_logs)
      state_edit '.nodes[$tag].logging=false' --arg tag "$tag"
      if ! jq -e 'any(.nodes[]; .logging==true)' "$TX/state.json" >/dev/null &&
         [ "$(jq -r '.log.access // ""' "$TX/config.json")" = "$LOG_DIR/access.log" ]; then
        config_edit '.log.access="none"'; apply
      else save_only; fi
      echo "已停止此节点日志分流；其他节点开启日志时，全局原始日志仍包含此节点连接。" ;;
    max) set_max_connections "$tag" ;;
    quota) set_monthly_quota "$tag" ;;
    edit) edit_config "$tag" ;;
    rename) rename_node "$tag" ;;
    enable) set_enabled "$tag" false ;;
    disable) set_enabled "$tag" true ;;
    delete) delete_node "$tag" ;;
  esac
  # Send the committed identity back to the interactive parent (no persistent alias).
  if [ -n "${MENU_RESULT:-}" ]; then
    if [ -r "$TX/selected-node" ]; then
      cp "$TX/selected-node" "$MENU_RESULT"
    elif [ -n "$(node "$tag")" ]; then
      printf '%s\n' "$tag" > "$MENU_RESULT"
    else
      printf '\n' > "$MENU_RESULT"
    fi
  fi
}

list_nodes() {
  {
    [ ! -r "$STATE" ] || jq -c '.nodes // {} | to_entries[] | {tag:.key, protocol:.value.inbound.protocol,
      port:.value.inbound.port, disabled:(.value.disabled // false)}' "$STATE"
    jq -c '.inbounds[] | select(.protocol=="vless" or .protocol=="shadowsocks" or .protocol=="hysteria") |
      {tag,protocol,port,disabled:false}' "$CONFIG"
  } | jq -rs '
    group_by(.tag) | .[] | last |
    "\(.tag)  [\(.protocol)] 内部端口=\(.port)  \(if .disabled then "停用" else "启用" end)"
  '
}

node_exists() {
  jq -e --arg tag "$1" 'any(.inbounds[]; .tag==$tag)' "$CONFIG" >/dev/null && return 0
  [ -r "$STATE" ] && jq -e --arg tag "$1" '.nodes[$tag].inbound!=null' "$STATE" >/dev/null
}

node_menu() {
  local tag action result choice
  tag="$1"
  while node_exists "$tag"; do
    echo
    echo "节点: $tag"
    echo "1. 显示导入链接"
    echo "2. 查看流量统计与连接日志"
    echo "3. 开通节点流量统计"
    echo "4. 开启节点连接日志"
    echo "5. 关闭节点连接日志"
    echo "6. 月流量上限 / 重置日"
    echo "7. 设置最大连接数（0=无限制）"
    echo "8. 修改节点配置"
    echo "9. 改名"
    echo "10. 启用节点"
    echo "11. 停用节点"
    echo "12. 删除节点"
    echo "0. 返回完整列表，重新选择节点"
    choice="$(ask "选择节点操作")"
    case "$choice" in
      1) action=link ;; 2) action=stats ;; 3) action=enable_stats ;;
      4) action=enable_logs ;; 5) action=disable_logs ;; 6) action=quota ;;
      7) action=max ;; 8) action=edit ;; 9) action=rename ;;
      10) action=enable ;; 11) action=disable ;; 12) action=delete ;;
      0) return ;;
      *) echo "无效选项。"; continue ;;
    esac
    result="$(mktemp "$XRAY_DIR/.menu-result.XXXXXX")"
    if MENU_RESULT="$result" sh "$SELF" --action "$action" "$tag"; then
      [ ! -s "$result" ] || tag="$(cat "$result")"
    else
      echo "操作未完成，请查看上面的提示。"
    fi
    rm -f "$result"
  done
}

main() {
  need_tools
  if [ "${1:-}" = --action ]; then
    [ "$#" -eq 3 ] || die "操作参数不完整。"
    valid_name "$3" || die "节点名称无效。"
    case "$2" in
      link|stats|enable_stats|enable_logs|disable_logs|max|quota|edit|rename|enable|disable|delete)
        run_action "$2" "$3" ;;
      *) die "未知操作。" ;;
    esac
    exit 0
  fi
  if [ "${1:-}" = --sample ]; then
    begin background
    sample_stats; sample_logs; check_limits
    exit 0
  fi
  while :; do
    echo
    echo "Xray 节点管理器"
    list_nodes
    echo "1. 选择节点"
    echo "2. 检查当前配置"
    echo "0. 退出"
    case "$(ask "选择")" in
      0) exit 0 ;;
      2) "$XRAY_BIN" run -test -format json -config "$CONFIG" ;;
      1)
        tag="$(ask "节点名称")"
        valid_name "$tag" || { echo "名称必须以字母开头，后续仅字母和数字。"; continue; }
        node_exists "$tag" || { echo "节点不存在。"; continue; }
        node_menu "$tag"
        ;;
      *) echo "无效选项。" ;;
    esac
  done
}
main "$@"
