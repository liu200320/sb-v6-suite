#!/usr/bin/env bash
# ============================================================================
#  rollback.sh — sb-v6-suite 回滚
#
#  用于「出口地址设错导致 IPv6 不通 / 节点异常」时的快速恢复。
#
#  用法：
#    bash rollback.sh              # 交互式
#    bash rollback.sh --status     # 只看状态，不动
#    bash rollback.sh --reset      # 把默认路由的 src 去掉（改回内核自动选择）
#    bash rollback.sh --prune      # 额外清理 addipv6 记录之外的多余地址
#    bash rollback.sh --yes        # 不提问
# ============================================================================

STATE_DIR="/etc/sb-v6-suite"
STATE_FILE="${STATE_DIR}/state.json"
ADDIPV6_STATE="/var/lib/addipv6/state.json"

OPT_YES=0; OPT_MODE="interactive"

if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_B=$'\033[36m'; C_D=$'\033[2m';   C_N=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_N=""
fi
ok()   { printf "  ${C_G}✓${C_N} %s\n" "$*"; }
bad()  { printf "  ${C_R}✗${C_N} %s\n" "$*"; }
warn() { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
info() { printf "  ${C_B}·${C_N} %s\n" "$*"; }
dim()  { printf "    ${C_D}%s${C_N}\n" "$*"; }
die()  { printf "\n  ${C_R}错误：%s${C_N}\n\n" "$*" >&2; exit 1; }
hr()   { printf "\n${C_B}── %s ──────────────────────────────────────${C_N}\n" "$*"; }

ask_yn() {
  local prompt="$1" def="$2" ans=""
  if [ "$OPT_YES" = "1" ] || [ ! -t 0 ]; then
    [ "$def" = "y" ] && return 0 || return 1
  fi
  read -r -p "  ${prompt} [$([ "$def" = y ] && echo 'Y/n' || echo 'y/N')]: " ans || true
  ans="${ans:-$def}"
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

for a in "$@"; do
  case "$a" in
    --yes|-y)  OPT_YES=1 ;;
    --status)  OPT_MODE="status" ;;
    --reset)   OPT_MODE="reset" ;;
    --prune)   OPT_MODE="prune" ;;
    -h|--help)
      cat <<'EOF'
rollback.sh — 回滚 IPv6 出口设置

用法：
  bash rollback.sh             交互式
  bash rollback.sh --status    只看状态，不做任何改动
  bash rollback.sh --reset     去掉默认路由的 src（改回内核自动选择）
  bash rollback.sh --prune     附加清理非 addipv6 管理的多余地址
  bash rollback.sh --yes       不提问
EOF
      exit 0 ;;
    *) die "未知参数：$a" ;;
  esac
done

echo
echo "############################################################"
echo "#  sb-v6-suite  回滚"
echo "############################################################"

# ---------------------------------------------------------------------------
hr "1. 当前状态"

DEFLINE="$(ip -6 route show default 2>/dev/null | head -1)"
[ -n "$DEFLINE" ] || die "没有 IPv6 默认路由 —— 无法回滚，请检查网络配置"
dim "默认路由：$DEFLINE"

IFACE="$(echo "$DEFLINE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
GW="$(echo "$DEFLINE" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
SRC="$(echo "$DEFLINE" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
ONLINK=0
echo "$DEFLINE" | grep -q 'onlink' && ONLINK=1

[ -n "$IFACE" ] || die "默认路由里找不到网卡"
info "网卡：$IFACE"
[ -n "$GW" ] && info "网关：$GW" || info "点对点链路（无网关）"
[ "$ONLINK" = "1" ] && info "onlink 标记：有"
if [ -n "$SRC" ]; then
  warn "当前已把出口钉死在：$SRC"
else
  ok "当前未钉死出口（内核自动选择）"
fi

mapfile -t ADDRS < <(ip -6 addr show dev "$IFACE" scope global 2>/dev/null \
                     | awk '/inet6/{split($2,a,"/"); print a[1]}')
CIDR="$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null | awk '/inet6/{print $2}' | head -1)"
PLEN="${CIDR##*/}"
[ -n "$PLEN" ] || PLEN=64

info "网卡上的全局 IPv6 地址：${#ADDRS[@]} 个"
for a in "${ADDRS[@]:0:8}"; do
  if [ "$a" = "$SRC" ]; then dim "$a   ← 当前出口"
  else dim "$a"; fi
done
[ "${#ADDRS[@]}" -gt 8 ] && dim "…… 其余 $(( ${#ADDRS[@]} - 8 )) 个略"

NATIVE="${ADDRS[0]}"
info "判定为原生地址（第一个）：$NATIVE"

# 尝试从套件状态文件里读取更准确的原生地址
if [ -r "$STATE_FILE" ] && command -v python3 >/dev/null 2>&1; then
  N="$(python3 -c "
import json,sys
try:
    d=json.load(open('$STATE_FILE'))
    v=d.get('v6_native') or ''
    print(v)
except Exception:
    pass
" 2>/dev/null)"
  [ -n "$N" ] && NATIVE="$N" && info "状态文件记录的原生地址：$NATIVE"
fi

if [ "$OPT_MODE" = "status" ]; then
  hr "状态检查"
  EGRESS="$(curl -6 -s -m 12 https://api64.ipify.org 2>/dev/null)"
  [ -n "$EGRESS" ] && ok "对外 IPv6 出口 = $EGRESS" || bad "对外 IPv6 出口不通"
  echo
  exit 0
fi

# ---------------------------------------------------------------------------
hr "2. 恢复默认路由"
if [ -z "$SRC" ]; then
  ok "默认路由本来就没有 src，无需恢复"
else
  info "将把出口从 $SRC 改回 $NATIVE"
  dim "等价于： ip -6 route replace default via ${GW:-<无>} dev $IFACE src $NATIVE"

  if ! ask_yn "执行恢复？" y; then
    warn "已取消"
    exit 0
  fi

  # 先确认目标地址在网卡上
  if ! ip -6 addr show dev "$IFACE" 2>/dev/null | grep -q "$NATIVE"; then
    die "地址 $NATIVE 不在 $IFACE 上，无法设为出口"
  fi

  if ip -6 route replace default via "$GW" dev "$IFACE" src "$NATIVE" 2>/dev/null; then
    ok "已恢复（带 src=$NATIVE）"
  else
    # 点对点链路或没有网关的情况
    warn "带 src 的 replace 失败，尝试去掉 onlink 后重试"
    if ip -6 route replace default dev "$IFACE" src "$NATIVE" 2>/dev/null; then
      ok "已恢复（无网关，src=$NATIVE）"
    else
      bad "恢复失败"
      dim "手动命令： ip -6 route replace default via $GW dev $IFACE src $NATIVE"
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
hr "3. 验证"
DEFLINE2="$(ip -6 route show default 2>/dev/null | head -1)"
dim "$DEFLINE2"

CHOSEN="$(ip -6 route get 2a00:1450:4001:82f::200e 2>/dev/null \
          | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
[ -n "$CHOSEN" ] && ok "内核源地址 = $CHOSEN"

EGRESS="$(curl -6 -s -m 12 https://api64.ipify.org 2>/dev/null)"
if [ -n "$EGRESS" ]; then
  ok "对外 IPv6 出口 = $EGRESS"
else
  bad "仍拿不到 IPv6 出口"
  dim "进一步排查："
  dim "  ip -6 neigh                      查网关邻居状态"
  dim "  ping6 -c 3 <网关>                查二层是否通"
  dim "  用其他地址重试： bash rollback.sh --reset"
fi

echo
info "IPv6 目标可达性："
for u in "https://www.cloudflare.com" "https://www.google.com/generate_204"; do
  CODE="$(curl -6 -s -o /dev/null -w '%{http_code}' -m 10 "$u" 2>/dev/null)"
  if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then bad "$u"; else ok "$u  (HTTP $CODE)"; fi
done

# ---------------------------------------------------------------------------
if [ "$OPT_MODE" = "prune" ]; then
  hr "4. 清理多余地址"

  if [ ! -r "$ADDIPV6_STATE" ]; then
    warn "没有 /var/lib/addipv6/state.json，无法判断哪些是工具加的 —— 跳过清理"
    dim "手动删除： ip -6 addr del <地址>/$PLEN dev $IFACE"
  else
    warn "这将删除 addipv6 记录之外的所有全局 IPv6 地址"
    dim "网卡 $IFACE 上共 ${#ADDRS[@]} 个，清理前请确认还有别的路能进服务器"
    if ask_yn "确认清理？" n; then
      KEPT=0; DEL=0
      for a in "${ADDRS[@]}"; do
        if [ "$a" = "$NATIVE" ] || [ "$a" = "$SRC" ]; then
          KEPT=$((KEPT + 1)); dim "保留 $a （出口/原生）"; continue
        fi
        if grep -q "$a" "$ADDIPV6_STATE" 2>/dev/null; then
          KEPT=$((KEPT + 1)); dim "保留 $a （addipv6 管理）"
        else
          if ip -6 addr del "$a/$PLEN" dev "$IFACE" 2>/dev/null; then
            DEL=$((DEL + 1)); dim "已删 $a"
          else
            warn "删除失败 $a"
          fi
        fi
      done
      ok "保留 $KEPT 个，删除 $DEL 个"
    else
      warn "已取消"
    fi
  fi
fi

hr "完成"
cat <<EOF
  后续：
    bash verify.sh        重新体检
    systemctl status addipv6-restore

  如果 SSH 也断了：
    走服务商面板的 VNC / 救援模式，执行
    ip -6 route replace default via $GW dev $IFACE

EOF