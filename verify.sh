#!/usr/bin/env bash
# ============================================================================
#  verify.sh — sb-v6-suite 一键体检
#
#  只读脚本：不改任何配置、不重启服务、不动网卡和路由。
#
#  用法： bash verify.sh
# ============================================================================

STATE_DIR="/etc/sb-v6-suite"
STATE_FILE="${STATE_DIR}/state.json"
PROBE_V6="2606:4700:4700::1111"           # Cloudflare
PROBE_V6_ALT="https://api64.ipify.org"

if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_B=$'\033[36m'; C_D=$'\033[2m';   C_N=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_N=""
fi

ok()    { printf "  ${C_G}✓${C_N} %s\n" "$*"; }
bad()   { printf "  ${C_R}✗${C_N} %s\n" "$*"; }
warn()  { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
info()  { printf "  ${C_B}·${C_N} %s\n" "$*"; }
dim()   { printf "    ${C_D}%s${C_N}\n" "$*"; }
hr()    { printf "\n${C_B}── %s ──────────────────────────────────────${C_N}\n" "$*"; }

ISSUES=0
note()  { ISSUES=$((ISSUES + 1)); }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

echo
echo "############################################################"
echo "#  sb-v6-suite  体检报告"
echo "#  $(date '+%F %T %Z')   主机 $(hostname 2>/dev/null)"
echo "############################################################"

# ---------------------------------------------------------------------------
hr "0. 套件状态"
if [ -r "$STATE_FILE" ]; then
  ok "找到状态文件 $STATE_FILE"
  if need_cmd python3; then
    python3 - "$STATE_FILE" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for k in ("version","installed_at","os","arch","nat","public_ip","addipv6_port",
              "node","node_ports","nginx_port","port_range",
              "v6_iface","v6_gateway","v6_prefix","v6_native","v6_routed"):
        if k in d and d[k] not in (None, ""):
            print("    %-14s %s" % (k + ":", d[k]))
except Exception as e:
    print("    状态文件解析失败:", e)
PYEOF
  fi
else
  warn "没有状态文件（可能不是用 install.sh 装的）"
fi

# ---------------------------------------------------------------------------
hr "1. 系统与权限"
info "用户：$(id -un)  uid=$(id -u)"
info "系统：$([ -r /etc/os-release ] && . /etc/os-release && echo "${PRETTY_NAME}")"
info "内核：$(uname -r)   架构：$(uname -m)"
if [ "$(id -u)" = "0" ]; then ok "root 权限"; else warn "非 root —— 部分检查会缺失"; fi
if [ -d /run/systemd/system ]; then info "init：systemd"; else info "init：非 systemd"; fi

# ---------------------------------------------------------------------------
hr "2. IPv6 地址"
IFACE=""
DEFLINE="$(ip -6 route show default 2>/dev/null | head -1)"
if [ -n "$DEFLINE" ]; then
  IFACE="$(echo "$DEFLINE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
  ok "IPv6 默认路由存在"
  dim "$DEFLINE"
else
  bad "没有 IPv6 默认路由"
  note
fi

if [ -n "$IFACE" ]; then
  mapfile -t ADDRS < <(ip -6 addr show dev "$IFACE" scope global 2>/dev/null \
                       | awk '/inet6/{split($2,a,"/"); print a[1]}')
  info "网卡 ${IFACE} 上的全局 IPv6 地址：${#ADDRS[@]} 个"
  for a in "${ADDRS[@]:0:6}"; do dim "$a"; done
  [ "${#ADDRS[@]}" -gt 6 ] && dim "…… 其余 $(( ${#ADDRS[@]} - 6 )) 个略"
  if [ "${#ADDRS[@]}" -le 1 ]; then
    warn "只有 1 个地址 —— 尚未用 addipv6 批量添加"
  fi
fi

# ---------------------------------------------------------------------------
hr "3. 出口源地址"
if [ -n "$DEFLINE" ]; then
  SRC="$(echo "$DEFLINE" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  if [ -n "$SRC" ]; then ok "默认路由已指定 src = $SRC"; else warn "默认路由未指定 src（内核自动选择）"; fi
fi

CHOSEN="$(ip -6 route get 2a00:1450:4001:82f::200e 2>/dev/null \
          | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
[ -n "$CHOSEN" ] && ok "内核实际会用的源地址 = $CHOSEN" || warn "拿不到内核源地址"

EGRESS="$(curl -6 -s -m 12 https://api64.ipify.org 2>/dev/null)"
if [ -n "$EGRESS" ]; then
  ok "对外 IPv6 出口 = $EGRESS"
  if [ -n "$CHOSEN" ] && [ "$EGRESS" != "$CHOSEN" ]; then
    warn "出口与内核选择的源地址不一致（可能有上游 NAT）"
  fi
else
  bad "拿不到对外 IPv6 出口 —— IPv6 出口不通"
  note
fi

# ---------------------------------------------------------------------------
hr "4. IPv6 连通性"
if ping6 -c 2 -W 3 "$PROBE_V6" >/dev/null 2>&1; then
  ok "ping6 Cloudflare 通"
else
  warn "ping6 Cloudflare 不通（可能被禁 ICMP）"
fi

for u in "https://www.cloudflare.com" "https://www.google.com/generate_204" "https://api64.ipify.org"; do
  CODE="$(curl -6 -s -o /dev/null -w '%{http_code}' -m 10 "$u" 2>/dev/null)"
  if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then
    bad "IPv6 → $u"
    note
  else
    ok "IPv6 → $u  (HTTP $CODE)"
  fi
done

# ---------------------------------------------------------------------------
hr "5. IPv4 连通性（对照）"
for u in "https://www.baidu.com" "https://github.com"; do
  CODE="$(curl -4 -s -o /dev/null -w '%{http_code}' -m 10 "$u" 2>/dev/null)"
  if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then bad "IPv4 → $u"; else ok "IPv4 → $u  (HTTP $CODE)"; fi
done

# ---------------------------------------------------------------------------
hr "6. addipv6"
if [ -x /usr/local/bin/addipv6 ] || need_cmd addipv6; then
  ok "已安装"
  V="$(/usr/local/bin/addipv6 version 2>/dev/null | head -1)"
  [ -n "$V" ] && dim "$V"
else
  bad "未找到 addipv6"
  note
fi

APID="$(ps -eo args 2>/dev/null | grep -m1 '[a]ddipv6 -listen' | awk '{for(i=1;i<=NF;i++) if($i=="-listen") print $(i+1)}')"
if [ -n "$APID" ]; then
  ok "面板运行中：$APID"
  case "$APID" in
    0.0.0.0:*|\[::\]:*|*:*) warn "面板监听在所有网卡上，建议改成 127.0.0.1 走 SSH 隧道" ;;
  esac
else
  warn "面板进程未运行"
fi

if [ -r /var/lib/addipv6/state.json ]; then
  SZ="$(wc -c < /var/lib/addipv6/state.json 2>/dev/null)"
  ok "地址记录存在（$SZ 字节）—— addipv6 restore 才能恢复"
else
  warn "没有地址记录 /var/lib/addipv6/state.json —— 重启后地址会全部丢失"
  note
fi

# ---------------------------------------------------------------------------
hr "7. 开机恢复服务"
if systemctl list-unit-files 2>/dev/null | grep -q '^addipv6-restore'; then
  E="$(systemctl is-enabled addipv6-restore 2>/dev/null)"
  A="$(systemctl is-active  addipv6-restore 2>/dev/null)"
  [ "$E" = "enabled" ] && ok "addipv6-restore 已启用" || { warn "addipv6-restore 未启用（=$E）"; note; }
  dim "状态：$A"
else
  bad "没有 addipv6-restore 服务 —— 重启后 IPv6 地址和出口设置都会丢失"
  note
fi

# ---------------------------------------------------------------------------
hr "8. 节点进程"
FOUND=0
for p in xray sing-box; do
  if pgrep -x "$p" >/dev/null 2>&1 || pgrep -f "[b]in/$p" >/dev/null 2>&1; then
    ok "$p 运行中"
    ps -eo pid,etime,args 2>/dev/null | grep -m2 "[${p:0:1}]${p#?}" | grep -v grep | while read -r L; do dim "$L"; done
    FOUND=1
  fi
done
for u in xray x-ui sing-box; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${u}\.service"; then
    S="$(systemctl is-active "$u" 2>/dev/null)"
    [ "$S" = "active" ] && ok "服务 $u 活跃" || { warn "服务 $u 状态：$S"; }
    FOUND=1
  fi
done
[ "$FOUND" = "0" ] && warn "没有检测到节点进程或服务"

# ---------------------------------------------------------------------------
hr "9. 监听端口"
if need_cmd ss; then
  ss -tlnp 2>/dev/null | awk 'NR==1 || /LISTEN/' | head -25 | while read -r L; do dim "$L"; done
fi

# ---------------------------------------------------------------------------
hr "10. DNS 污染检查"
SYS_A="$(getent ahostsv4 www.youtube.com 2>/dev/null | head -1 | awk '{print $1}')"
if [ -n "$SYS_A" ]; then
  case "$SYS_A" in
    31.13.*|104.244.*|243.185.*|59.24.*|0.0.0.0|127.0.0.1)
      bad "系统 DNS 解析 www.youtube.com → $SYS_A（疑似污染/劫持）"
      note
      dim "节点出站若走系统 DNS，Google 系站点会被解析到错误 IP"
      dim "建议给节点配独立 DNS（如 9.9.9.9）"
      ;;
    *) ok "系统 DNS 解析 www.youtube.com → $SYS_A" ;;
  esac
else
  warn "系统 DNS 解析失败"
fi

if need_cmd dig; then
  for r in 8.8.8.8 9.9.9.9; do
    A="$(dig +short +time=3 +tries=1 "@$r" www.youtube.com A 2>/dev/null | head -1)"
    [ -n "$A" ] && dim "via $r → $A"
  done
fi

# ---------------------------------------------------------------------------
hr "结论"
if [ "$ISSUES" -eq 0 ]; then
  printf "  ${C_G}没有发现问题。${C_N}\n\n"
else
  printf "  ${C_Y}发现 %s 处需要关注（上面标 ✗ / ! 的行）。${C_N}\n\n" "$ISSUES"
  cat <<'EOF'
  常见处理：

  · 没有 IPv6 默认路由 / 出口不通
      先修好基础 IPv6，再谈多地址出口。

  · 没有 addipv6-restore 服务
      install.sh 会创建它；或手动：
      systemctl enable --now addipv6-restore.service

  · 没有地址记录 state.json
      地址是从面板加的才会被记录，手动 ip addr add 的不会被 restore 恢复。

  · DNS 被污染
      给节点配独立 DNS 段（推荐 9.9.9.9，实测未被劫持）。

  · 出口设错导致不通
      bash rollback.sh

EOF
fi
echo