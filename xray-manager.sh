#!/bin/sh
set -eu
umask 077

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
CONFIG="${CONFIG:-$XRAY_DIR/config.json}"
STATE="${STATE:-$XRAY_DIR/manager-state.json}"
SERVICE="${SERVICE:-xray}"
API_TAG="${API_TAG:-api}"
API_PORT="${API_PORT:-10085}"
CHECKER="${CHECKER:-$XRAY_DIR/quota-check.sh}"
LOCK_DIR="${LOCK_DIR:-$XRAY_DIR/.manager.lock}"
LOCK_HELD=0

die() { echo "错误: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"; }
need_tools() {
  command -v jq >/dev/null 2>&1 || die "缺少 jq，请先执行: apk add --no-cache jq";
  [ -x "$XRAY_BIN" ] || die "找不到 Xray: $XRAY_BIN";
  [ -r "$CONFIG" ] || die "找不到配置: $CONFIG";
  jq empty "$CONFIG" >/dev/null 2>&1 || die "配置不是有效 JSON: $CONFIG";
  mkdir -p "$XRAY_DIR"
  touch "$STATE"
  if [ ! -s "$STATE" ]; then printf '%s\n' '{"users":{}}' > "$STATE"; fi
  jq empty "$STATE" >/dev/null 2>&1 || die "状态文件不是有效 JSON: $STATE";
  chmod 600 "$CONFIG" "$STATE"
}
ask() { printf "%s: " "$1" >&2; IFS= read -r value; printf '%s' "$value"; }
yesno() {
  answer="$(ask "$1 [y/N]")"
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
positive_or_zero() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 0 ] 2>/dev/null
}
valid_email() {
  [ -n "$1" ] && printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9._@-]+$'
}
config_tmp() { printf '%s.tmp.%s' "$CONFIG" "$$"; }
acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "检测到另一个管理器或配额任务正在修改配置，请稍后重试。"
  fi
  LOCK_HELD=1
  trap 'if [ "$LOCK_HELD" -eq 1 ]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi' EXIT INT TERM
}

restart_service() {
  command -v rc-service >/dev/null 2>&1 || {
    echo "未检测到 rc-service；配置已写入，请手动重启 Xray。"
    return 0
  }
  rc-service "$SERVICE" restart >/dev/null 2>&1 ||
    rc-service "$SERVICE" start >/dev/null 2>&1 ||
    return 1
}

commit_config() {
  candidate="$1"
  "$XRAY_BIN" run -test -config "$candidate" >/dev/null ||
    die "候选配置检查失败，原配置未改变。"
  backup="${CONFIG}.bak.$(date +%Y%m%d%H%M%S).$$"
  cp "$CONFIG" "$backup"
  chmod 600 "$backup"
  mv "$candidate" "$CONFIG"
  chmod 600 "$CONFIG"
  if ! restart_service; then
    cp "$backup" "$CONFIG"
    chmod 600 "$CONFIG"
    restart_service >/dev/null 2>&1 || true
    die "Xray 重启失败，已自动恢复原配置；备份保留在 $backup"
  fi
  echo "配置已应用；备份: $backup"
}

inbound_count() { jq -r '.inbounds // [] | length' "$CONFIG"; }
inbound_tag() { jq -r --argjson i "$1" '.inbounds[$i].tag // ("inbound-" + ($i|tostring))' "$CONFIG"; }
inbound_protocol() { jq -r --argjson i "$1" '.inbounds[$i].protocol // "unknown"' "$CONFIG"; }
user_path() {
  case "$1" in
    hysteria2) printf '.settings.users' ;;
    *) printf '.settings.clients' ;;
  esac
}
user_count() {
  path="$(user_path "$(inbound_protocol "$1")")"
  jq -r --argjson i "$1" "$path // [] | length" "$CONFIG"
}
user_email() {
  i="$1"; u="$2"; path="$(user_path "$(inbound_protocol "$i")")"
  jq -r --argjson i "$i" --argjson u "$u" "$path[\$u].email // $path[\$u].name // (\"user-\" + (\$u|tostring))" "$CONFIG"
}
select_inbound() {
  count="$(inbound_count)"
  [ "$count" -gt 0 ] || die "配置中没有入站。"
  echo "可用入站:"
  i=0
  while [ "$i" -lt "$count" ]; do
    tag="$(inbound_tag "$i")"
    proto="$(inbound_protocol "$i")"
    listen="$(jq -r --argjson i "$i" '.inbounds[$i].listen // "0.0.0.0"' "$CONFIG")"
    port="$(jq -r --argjson i "$i" '.inbounds[$i].port // "-"' "$CONFIG")"
    printf '  %s) %s [%s] %s:%s\n' "$i" "$tag" "$proto" "$listen" "$port"
    i=$((i + 1))
  done
  while :; do
    choice="$(ask "选择入站编号")"
    case "$choice" in ''|*[!0-9]*) ;; *) [ "$choice" -lt "$count" ] 2>/dev/null && { printf '%s' "$choice"; return; } ;; esac
    echo "编号无效。" >&2
  done
}

list_nodes() {
  count="$(inbound_count)"
  echo "配置: $CONFIG"
  i=0
  while [ "$i" -lt "$count" ]; do
    tag="$(inbound_tag "$i")"; proto="$(inbound_protocol "$i")"
    listen="$(jq -r --argjson i "$i" '.inbounds[$i].listen // "0.0.0.0"' "$CONFIG")"
    port="$(jq -r --argjson i "$i" '.inbounds[$i].port // "-"' "$CONFIG")"
    n="$(user_count "$i")"
    printf '入站[%s] name=%s tag=%s protocol=%s listen=%s port=%s users=%s\n' "$i" "$tag" "$tag" "$proto" "$listen" "$port" "$n"
    u=0
    while [ "$u" -lt "$n" ]; do
      printf '  user[%s] %s\n' "$u" "$(user_email "$i" "$u")"
      u=$((u + 1))
    done
    i=$((i + 1))
  done
}

ensure_stats() {
  tmp="$(config_tmp)"
  jq -e --arg tag "$API_TAG" --argjson port "$API_PORT" '
    any(.inbounds[]?; (.tag // "") != $tag and (.port // 0) == $port)
  ' "$CONFIG" >/dev/null &&
    die "API 端口 $API_PORT 已被其他入站占用，请设置 API_PORT 后重试。"
  api_index="$(jq -r --arg tag "$API_TAG" '(.inbounds // []) | to_entries[] | select(.value.tag == $tag) | .key' "$CONFIG" | head -n1)"
  if [ -n "$api_index" ]; then
    api_listen="$(jq -r --argjson i "$api_index" '.inbounds[$i].listen // "127.0.0.1"' "$CONFIG")"
    case "$api_listen" in 127.0.0.1|localhost|::1) ;; *) die "已有 API 没有绑定到本机，拒绝继续以免暴露管理接口。" ;; esac
  fi
  jq --arg tag "$API_TAG" --argjson port "$API_PORT" '
    .inbounds = (.inbounds // []) |
    if any(.inbounds[]?; .tag == $tag) then . else
      .inbounds += [{"listen":"127.0.0.1","port":$port,"protocol":"dokodemo-door",
        "settings":{"address":"127.0.0.1"},"tag":$tag}] end |
    .outbounds = (.outbounds // []) |
    if any(.outbounds[]?; .tag == "api") then . else
      .outbounds += [{"protocol":"freedom","tag":"api"}] end |
    .routing = (.routing // {}) |
    .routing.domainStrategy = (.routing.domainStrategy // "AsIs") |
    .routing.rules = (.routing.rules // []) |
    if any(.routing.rules[]?; .inboundTag? | index($tag)) then . else
      .routing.rules += [{"type":"field","inboundTag":[$tag],"outboundTag":"api"}] end |
    .api = (.api // {}) | .api.tag = $tag |
    .api.services = ((.api.services // []) + ["StatsService","HandlerService"] | unique) |
    .policy = (.policy // {}) |
    .policy.levels = ((.policy.levels // {}) | with_entries(.value.stats = {"userUplink":true,"userDownlink":true})) |
    .policy.system = ((.policy.system // {}) + {"statsInboundUplink":true,"statsInboundDownlink":true})
  ' "$CONFIG" > "$tmp"
  commit_config "$tmp"
}

show_credentials() {
  i="$(select_inbound)"
  n="$(user_count "$i")"
  [ "$n" -gt 0 ] || die "该入站没有用户。"
  u="$(ask "用户编号（0-$((n - 1))）")"
  case "$u" in ''|*[!0-9]*) die "编号无效。" ;; esac
  [ "$u" -lt "$n" ] || die "编号无效。"
  yesno "这会显示敏感凭据，并可能被终端记录。确认显示？" || return 0
  proto="$(inbound_protocol "$i")"
  jq -r --argjson i "$i" --argjson u "$u" --arg proto "$proto" '
    if $proto == "hysteria2" then .inbounds[$i].settings.users[$u]
    else .inbounds[$i].settings.clients[$u] end
  ' "$CONFIG"
}

add_user() {
  i="$(select_inbound)"; proto="$(inbound_protocol "$i")"
  email="$(ask "用户标识/email（仅字母、数字、._@-）")"
  valid_email "$email" || die "用户标识为空或包含不允许的字符。"
  path="$(user_path "$i")"
  jq -e --argjson i "$i" --arg email "$email" "$path // [] | any(.[]?; (.email // .name // \"\") == \$email)" "$CONFIG" >/dev/null &&
    die "该入站中已存在同名用户。"
  case "$proto" in
    vless|vmess|trojan)
      id="$("$XRAY_BIN" uuid)"
      tmp="$(config_tmp)"
      jq --argjson i "$i" --arg email "$email" --arg id "$id" '
        .inbounds[$i].settings.clients = (.inbounds[$i].settings.clients // []) +
        [{"id":$id,"email":$email}]
      ' "$CONFIG" > "$tmp"
      commit_config "$tmp"
      echo "新增用户: $email"
      echo "UUID: $id"
      ;;
    hysteria2)
      auth="$(openssl rand -base64 24 | tr -d '=+/')"
      tmp="$(config_tmp)"
      jq --argjson i "$i" --arg email "$email" --arg auth "$auth" '
        .inbounds[$i].settings.users = (.inbounds[$i].settings.users // []) +
        [{"name":$email,"password":$auth}]
      ' "$CONFIG" > "$tmp"
      commit_config "$tmp"
      echo "新增用户: $email"
      echo "密码: $auth"
      ;;
    shadowsocks)
      jq -e --argjson i "$i" '.inbounds[$i].settings.password? != null and (.inbounds[$i].settings.clients? == null)' "$CONFIG" >/dev/null &&
        die "当前 Shadowsocks 是单密码模式；为避免错误配置，未自动转换，请先改成 clients 多用户模式。"
      password="$(openssl rand -base64 24 | tr -d '=+/')"
      tmp="$(config_tmp)"
      jq --argjson i "$i" --arg email "$email" --arg password "$password" '
        .inbounds[$i].settings.clients = (.inbounds[$i].settings.clients // []) +
        [{"password":$password,"email":$email}]
      ' "$CONFIG" > "$tmp"
      commit_config "$tmp"
      echo "新增用户: $email"
      echo "密码: $password"
      ;;
    *) die "暂不支持为协议 $proto 添加用户。" ;;
  esac
  echo "请立即保存以上凭据；列表默认不会再次显示秘密。"
}

delete_user() {
  i="$(select_inbound)"; proto="$(inbound_protocol "$i")"; n="$(user_count "$i")"
  [ "$n" -gt 0 ] || die "该入站没有用户。"
  u="$(ask "要删除的用户编号（0-$((n - 1))）")"
  case "$u" in ''|*[!0-9]*) die "编号无效。" ;; esac
  [ "$u" -lt "$n" ] || die "编号无效。"
  email="$(user_email "$i" "$u")"
  yesno "将删除 $(inbound_tag "$i") 上的 $email，确认吗？" || return 0
  path="$(user_path "$i")"; tmp="$(config_tmp)"
  jq --argjson i "$i" --argjson u "$u" "$path = ($path // [] | del(.[$u]))" "$CONFIG" > "$tmp"
  commit_config "$tmp"
  tag="$(inbound_tag "$i")"
  jq --arg key "$tag::$email" 'del(.users[$key])' "$STATE" > "$STATE.tmp.$$"
  mv "$STATE.tmp.$$" "$STATE"; chmod 600 "$STATE"
}

set_limit() {
  i="$(select_inbound)"; tag="$(inbound_tag "$i")"; n="$(user_count "$i")"
  [ "$n" -gt 0 ] || die "该入站没有用户。"
  u="$(ask "用户编号（0-$((n - 1))）")"
  case "$u" in ''|*[!0-9]*) die "编号无效。" ;; esac
  [ "$u" -lt "$n" ] || die "编号无效。"
  email="$(user_email "$i" "$u")"
  quota="$(ask "月流量上限，单位 GiB，0 表示不限")"; positive_or_zero "$quota" || die "请输入非负整数。"
  online="$(ask "最大在线数，0 表示不限；这是周期检查软限制")"; positive_or_zero "$online" || die "请输入非负整数。"
  month="$(date +%Y-%m)"
  jq --arg key "$tag::$email" --arg tag "$tag" --arg email "$email" --arg month "$month" \
    --argjson quota "$quota" --argjson online "$online" '
    .users = (.users // {}) |
    .users[$key] = ((.users[$key] // {}) + {inbound_tag:$tag,email:$email,quota_gib:$quota,max_online:$online,month:$month,base_bytes:0,disabled:false})
  ' "$STATE" > "$STATE.tmp.$$"
  mv "$STATE.tmp.$$" "$STATE"; chmod 600 "$STATE"
  echo "限制已保存：$tag::$email"
}

show_stats() {
  get_api_addr >/dev/null || die "尚未启用本地统计 API，请先选择菜单 2。"
  "$XRAY_BIN" api statsquery --server "$API_ADDR" 2>/dev/null || die "统计查询失败，请确认 API 已启用且服务正常。"
}
get_api_addr() {
  API_ADDR="$(jq -r --arg tag "$API_TAG" '
    (.inbounds // [])[] | select(.tag == $tag) |
    ((.listen // "127.0.0.1") + ":" + ((.port // 10085)|tostring))
  ' "$CONFIG" | head -n1)"
  [ -n "${API_ADDR:-}" ] || return 1
  api_host="${API_ADDR%:*}"
  case "$api_host" in 127.0.0.1|localhost|::1) return 0 ;; *) return 1 ;; esac
}

install_checker() {
  cat > "$CHECKER" <<'EOF'
#!/bin/sh
set -eu
umask 077
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
CONFIG="$XRAY_DIR/config.json"
STATE="$XRAY_DIR/manager-state.json"
SERVICE="${SERVICE:-xray}"
LOCK_DIR="$XRAY_DIR/.manager.lock"
[ -r "$CONFIG" ] && [ -r "$STATE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
month="$(date +%Y-%m)"
tmp="$CONFIG.tmp.$$"
changed=0
api_addr="$(jq -r '
  (.inbounds // [])[] | select(.tag == "api") |
  ((.listen // "127.0.0.1") + ":" + ((.port // 10085)|tostring))
' "$CONFIG" | head -n1)"
case "${api_addr%:*}" in 127.0.0.1|localhost|::1) ;; *) exit 0 ;; esac
while IFS="$(printf '\t')" read -r key tag email quota online base saved_month disabled; do
  [ -n "$key" ] || continue
  [ "$disabled" = "true" ] && continue
  [ "$saved_month" = "$month" ] || {
    jq --arg key "$key" --arg month "$month" '.users[$key].month=$month | .users[$key].base_bytes=0' "$STATE" > "$STATE.tmp.$$"
    mv "$STATE.tmp.$$" "$STATE"; continue
  }
  [ "$quota" -gt 0 ] 2>/dev/null || continue
  # The stats API is queried only when configured; quota enforcement is conservative.
  used="$( "$XRAY_BIN" api stats --server "$api_addr" -name "user>>>${email}>>>traffic>>>downlink" 2>/dev/null | awk '/value:/ {print $2}' | tail -n1 )" || used=0
  case "$used" in ''|*[!0-9]*) used=0 ;; esac
  limit=$((quota * 1073741824))
  if [ "$used" -ge "$limit" ]; then
    jq --arg tag "$tag" --arg email "$email" '
      .inbounds = [.inbounds[] | if .tag == $tag then
        if .protocol == "hysteria2" then
          .settings.users = [(.settings.users // [])[] | select((.name // .email // "") != $email)]
        else
          .settings.clients = [(.settings.clients // [])[] | select((.email // .name // "") != $email)]
        end
      else . end]
    ' "$CONFIG" > "$tmp"
    "$XRAY_BIN" run -test -config "$tmp" >/dev/null || continue
    backup="$CONFIG.bak.quota.$(date +%Y%m%d%H%M%S).$$"
    cp "$CONFIG" "$backup"
    chmod 600 "$backup"
    mv "$tmp" "$CONFIG"; changed=1
    if command -v rc-service >/dev/null 2>&1 &&
       ! rc-service "$SERVICE" restart >/dev/null 2>&1; then
      cp "$backup" "$CONFIG"
      chmod 600 "$CONFIG"
      rc-service "$SERVICE" restart >/dev/null 2>&1 || true
      changed=0
      continue
    fi
    jq --arg key "$key" '.users[$key].disabled=true | .users[$key].disabled_reason="monthly quota exceeded"' "$STATE" > "$STATE.tmp.$$"
    mv "$STATE.tmp.$$" "$STATE"
  fi
done <<EOF_USERS
$(jq -r '.users // {} | to_entries[] | [.key,.value.inbound_tag,.value.email,(.value.quota_gib//0),(.value.max_online//0),(.value.base_bytes//0),(.value.month//""),(.value.disabled//false)] | @tsv' "$STATE")
EOF_USERS
chmod 600 "$CONFIG" "$STATE"
EOF
  chmod 700 "$CHECKER"
  if command -v crond >/dev/null 2>&1; then
    mkdir -p /etc/periodic/hourly
    ln -sf "$CHECKER" /etc/periodic/hourly/xray-quota-check
    rc-service crond start >/dev/null 2>&1 || true
    rc-update add crond default >/dev/null 2>&1 || true
  fi
  echo "检查任务已安装: $CHECKER"
  echo "说明：配额是周期检查软限制；达到上限后会移除对应入站中的用户并重载。"
}

restore_backup() {
  latest="$(ls -1t "$CONFIG".bak.* 2>/dev/null | head -n1 || true)"
  [ -n "$latest" ] || die "没有找到备份。"
  "$XRAY_BIN" run -test -config "$latest" >/dev/null || die "备份配置检查失败，未恢复。"
  current="${CONFIG}.restore-current.$$"
  cp "$CONFIG" "$current"; chmod 600 "$current"
  cp "$latest" "$CONFIG"; chmod 600 "$CONFIG"
  if ! restart_service; then cp "$current" "$CONFIG"; chmod 600 "$CONFIG"; restart_service >/dev/null 2>&1 || true; die "恢复后重启失败，已回滚。"; fi
  rm -f "$current"
  echo "已恢复: $latest"
}

check_config() { "$XRAY_BIN" run -test -config "$CONFIG"; }

main() {
  need_root; need_tools; acquire_lock
  while :; do
    echo
    echo "Xray 管理器 | 配置: $CONFIG | 服务: $SERVICE"
    if get_api_addr; then echo "本地 API: $API_ADDR"; else echo "本地 API: 未启用"; fi
    echo "1. 查看节点和用户"
    echo "2. 启用流量统计与本地 API"
    echo "3. 添加用户"
    echo "4. 删除用户"
    echo "5. 设置用户限制"
    echo "6. 查看当前统计"
    echo "7. 安装/更新月度检查任务"
    echo "8. 查看单个用户凭据"
    echo "9. 检查当前配置"
    echo "10. 恢复最近一次备份"
    echo "0. 退出"
    choice="$(ask "请选择")"
    case "$choice" in
      1) list_nodes ;;
      2) ensure_stats ;;
      3) add_user ;;
      4) delete_user ;;
      5) set_limit ;;
      6) show_stats ;;
      7) install_checker ;;
      8) show_credentials ;;
      9) check_config ;;
      10) restore_backup ;;
      0) exit 0 ;;
      *) echo "无效选项。" ;;
    esac
  done
}
main "$@"
