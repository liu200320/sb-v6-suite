#!/usr/bin/env bash
# ============================================================================
#  sb-v6-suite  links.sh — 只看节点链接 / 订阅地址（只读，不碰任何配置）
#
#  用法：
#    bash <(curl -fsSL https://raw.githubusercontent.com/liu200320/sb-v6-suite/main/links.sh)
#    bash links.sh              # 已经 clone 到本地时
#
#  认三种落法：
#    1) 明文        xray-cf-lite 的 /etc/xray-cf-lite/state.json、cf_lite_local_sub.txt
#    2) base64 整包 fscarmen/sing-box 的 /etc/sing-box/subscribe/v2rayn、throne、shadowrocket
#    3) 带颜色码的导出文本  /etc/sing-box/list（base64 混在框线里）
# ============================================================================
set -u

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_N=$'\033[0m'
else
  C_G=""; C_Y=""; C_B=""; C_D=""; C_N=""
fi
ok()   { printf "  ${C_G}✓${C_N} %s\n" "$*"; }
warn() { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
dim()  { printf "    ${C_D}%s${C_N}\n" "$*"; }
hr()   { printf "\n${C_B}── %s ──────────────────────────────────────${C_N}\n" "$*"; }

LINK_RE='(vless|vmess|trojan|ss|hysteria2|hy2|tuic|anytls|shadowtls)://[^"'"'"'[:space:]]+'
strip_ansi() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
grep_links() { grep -ahoE "$LINK_RE" 2>/dev/null; }

links_from_file() {
  local f="$1"
  [ -r "$f" ] || return 0
  strip_ansi < "$f" 2>/dev/null | grep_links
}

# 整份 base64，或文本里内嵌的长 base64 串
links_from_b64() {
  local f="$1" tok
  [ -r "$f" ] || return 0
  tr -d '\r\n' < "$f" 2>/dev/null | tr '_' '/' | tr '-' '+' | base64 -d 2>/dev/null | grep_links
  strip_ansi < "$f" 2>/dev/null | grep -oE '[A-Za-z0-9+/]{100,}={0,2}' 2>/dev/null \
    | while IFS= read -r tok; do printf '%s' "$tok" | base64 -d 2>/dev/null; done | grep_links
}

# 明文来源（文件 -> 直接抓）
PLAIN_FILES=(
  ./cf_lite_last_links.txt "${HOME:-/root}/cf_lite_last_links.txt" /root/cf_lite_last_links.txt
  /etc/xray-cf-lite/state.json /etc/xray-cf-lite/cf_lite_local_sub.txt
  /etc/sing-box/list /etc/sing-box/subscribe.txt
  /usr/local/etc/sing-box/subscribe.txt /etc/sb-v6-suite/links.txt
)
# 明文来源（目录 -> 递归抓）
PLAIN_DIRS=(
  /etc/xray-cf-lite /usr/local/etc/xray
  /etc/sing-box /usr/local/etc/sing-box /var/lib/sing-box
  /usr/local/etc "${HOME:-/root}"
)
# base64 来源
B64_FILES=(
  /etc/sing-box/list /usr/local/etc/sing-box/list
  /etc/sing-box/subscribe/v2rayn /etc/sing-box/subscribe/throne
  /etc/sing-box/subscribe/shadowrocket
  /usr/local/etc/sing-box/subscribe/v2rayn /usr/local/etc/sing-box/subscribe/throne
)

banner() {
  echo
  echo "############################################################"
  echo "#  sb-v6-suite  links.sh — 节点链接 / 订阅地址"
  echo "#  $(date '+%F %T %Z')   主机 $(hostname 2>/dev/null)"
  echo "############################################################"
}

banner

hr "扫描来源"
for f in "${PLAIN_FILES[@]}"; do
  [ -r "$f" ] || continue
  n="$(links_from_file "$f" | sort -u | wc -l | tr -d ' ')"
  if [ "$n" != "0" ]; then ok "$f  →  明文链接 ${n} 条"; else dim "$f  （存在，但没链接）"; fi
done
for d in "${PLAIN_DIRS[@]}"; do
  [ -d "$d" ] || continue
  n="$(grep -rahoE "$LINK_RE" "$d" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  [ "$n" != "0" ] && ok "$d  →  明文链接 ${n} 条（递归）"
done
for f in "${B64_FILES[@]}"; do
  [ -r "$f" ] || continue
  n="$(links_from_b64 "$f" | sort -u | wc -l | tr -d ' ')"
  if [ "$n" != "0" ]; then ok "$f  →  base64 解出 ${n} 条"; else dim "$f  （存在，解不出链接）"; fi
done
for f in /etc/sing-box/subscribe/* /usr/local/etc/sing-box/subscribe/*; do
  [ -f "$f" ] || continue
  case "${f##*/}" in clash|clash2|proxies|qr|sing-box|auto|auto2) continue ;; esac
  n="$(links_from_b64 "$f" | sort -u | wc -l | tr -d ' ')"
  [ "$n" != "0" ] && ok "$f  →  base64 解出 ${n} 条"
done

# ---------------- 汇总 ----------------
links="$(
  {
    for f in "${PLAIN_FILES[@]}"; do links_from_file "$f"; done
    for d in "${PLAIN_DIRS[@]}"; do [ -d "$d" ] && grep -rahoE "$LINK_RE" "$d" 2>/dev/null; done
    for f in "${B64_FILES[@]}"; do links_from_b64 "$f"; done
    for f in /etc/sing-box/subscribe/* /usr/local/etc/sing-box/subscribe/*; do
      [ -f "$f" ] || continue
      case "${f##*/}" in clash|clash2|proxies|qr|sing-box|auto|auto2) continue ;; esac
      links_from_b64 "$f"
    done
  } | sed 's/[",]*$//' | sort -u
)"

subs="$(
  {
    for f in /etc/sing-box/list /etc/xray-cf-lite/state.json ./cf_lite_last_links.txt \
             "${HOME:-/root}/cf_lite_last_links.txt" /root/cf_lite_last_links.txt \
             /usr/local/etc/sing-box/subscribe.txt /etc/sb-v6-suite/links.txt; do
      [ -r "$f" ] || continue
      strip_ansi < "$f" 2>/dev/null | grep -ahoE 'https?://[^"'"'"'[:space:]]+'
    done | grep -aviE 'githubusercontent|github\.com|qrserver|cloudflare\.com|ipify|ip-api|jsdelivr|amazonaws' \
       | sed 's/[",]*$//' | sort -u
  } | grep -aiE '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|/(auto2?|v2rayn|clash2?|sing-box|shadowrocket|throne|qr|sub)(/|$)' \
  || true
)"

hr "节点链接"
if [ -n "$links" ]; then
  while IFS= read -r L; do
    [ -n "$L" ] && printf "      ${C_G}%s${C_N}\n\n" "$L"
  done <<< "$links"
  printf '%s\n' "$links" > /tmp/sb-v6-suite-links.txt 2>/dev/null
  dim "已存一份到 /tmp/sb-v6-suite-links.txt"
else
  warn "没找到分享链接"
fi

hr "订阅地址"
if [ -n "$subs" ]; then
  while IFS= read -r S; do [ -n "$S" ] && printf "      ${C_B}%s${C_N}\n" "$S"; done <<< "$subs"
else
  warn "没找到订阅地址"
fi

if [ -z "$links" ] && [ -z "$subs" ]; then
  hr "手工兜底"
  if [ -d /etc/sing-box ]; then
    dim "fscarmen/sing-box 的导出文件："
    dim "  cat /etc/sing-box/list"
    dim "  base64 -d /etc/sing-box/subscribe/v2rayn 2>/dev/null"
  fi
  if [ -d /etc/xray-cf-lite ]; then
    dim "xray-cf-lite 的订阅快照："
    dim "  cat /etc/xray-cf-lite/state.json | python3 -c 'import json,sys;print(json.load(sys.stdin).get(\"links\"))'"
    dim "  bash <(curl -fsSL https://raw.githubusercontent.com/liu200320/xray-cf-lite-custom/main/xray_cf_lite.sh)   # 选「3. 查看订阅」"
  fi
  dim "全盘找：grep -rhoE '(vless|vmess|trojan|hysteria2)://[^\" ]+' /etc /usr/local/etc /root 2>/dev/null | sort -u"
  echo
  dim "如果上面都没有，说明节点脚本没跑到最后一步 —— 重跑一次它的菜单看输出"
fi
echo
