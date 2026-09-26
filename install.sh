#!/usr/bin/env bash
# ============================================================================
#  sb-v6-suite  —  节点 + IPv6 多地址出口 一键部署
#
#  设计要点：
#    1. 端口全部由本脚本交互式收集并直接配置好，不做「事后让你自己改」
#    2. NAT 机器自动识别，端口一律从服务商映射范围里分配
#    3. 上游脚本的官方交互流程完整保留，可随时切换过去
#    4. 结束时输出：节点分享链接 + addipv6 面板地址 + 密码
#
#  用法：
#    bash install.sh                    交互式
#    bash install.sh --yes              全默认，不提问
#    bash install.sh --port-range=47451-47470
#    bash install.sh --node=fscarmen --start-port=40000
# ============================================================================

VERSION="2.0.0"

# ---------------------------- 常量 ------------------------------------------
ADDIPV6_INSTALL_URL="https://raw.githubusercontent.com/byJoey/addipv6/main/install.sh"
NODE_XRAY_URL="https://raw.githubusercontent.com/byJoey/xray-cf-lite/main/xray_cf_lite.sh"
NODE_FSCARMEN_URL="https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh"

STATE_DIR="/etc/sb-v6-suite"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="${STATE_DIR}/install.log"
CONF_OUT="${STATE_DIR}/node-config.conf"

# ---------------------------- 可配置项 --------------------------------------
OPT_YES=0
OPT_NODE=""                 # xray | fscarmen | none
OPT_ADDIPV6_PORT=""         # 留空则交互/自动挑
OPT_START_PORT=""
OPT_PORT_RANGE=""
OPT_SKIP_PRECHECK=0
OPT_SKIP_ADDIPV6=0
OPT_ENABLE_RESTORE=1

# ---------------------------- 运行时状态 ------------------------------------
OS_ID=""; OS_VER=""; ARCH=""
TTY_AVAILABLE=0

# IPv6
V6_IFACE=""; V6_GW=""; V6_ONLINK=0
V6_ADDRS=(); V6_NATIVE=""; V6_PREFIX=""; V6_PLEN=""
V6_ROUTED=""

# NAT 与端口
NAT_DETECTED=0
NAT_LOCAL_IP=""
PUBLIC_IP=""
PORT_RANGE_START=""; PORT_RANGE_END=""
PORT_MAP_SAME=1
PLAN_RESERVED=()
PLAN_ADDIPV6_INT=""; PLAN_ADDIPV6_PUB=""
PLAN_NODE_INT=(); PLAN_NODE_PUB=()
PLAN_NGINX_INT=""; PLAN_NGINX_PUB=""
NODE_PROTOCOLS=""

# 节点安装结果
NODE_INSTALLED_RC=0

# ---------------------------- 输出 ------------------------------------------
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_B=$'\033[36m'; C_M=$'\033[35m'; C_D=$'\033[2m'; C_N=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_M=""; C_D=""; C_N=""
fi

ok()    { printf "  ${C_G}✓${C_N} %s\n" "$*"; }
bad()   { printf "  ${C_R}✗${C_N} %s\n" "$*"; }
warn()  { printf "  ${C_Y}!${C_N} %s\n" "$*"; }
info()  { printf "  ${C_B}·${C_N} %s\n" "$*"; }
dim()   { printf "    ${C_D}%s${C_N}\n" "$*"; }
note()  { printf "  ${C_M}→${C_N} %s\n" "$*"; }
die()   { printf "\n  ${C_R}错误：%s${C_N}\n\n" "$*" >&2; exit 1; }

hr()   { printf "\n${C_B}────────────────────────────────────────────────────────────${C_N}\n"; printf " %s\n" "$*"; printf "${C_B}────────────────────────────────────────────────────────────${C_N}\n"; }
step() { hr "[$1] $2"; }

log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null
}

# ---------------------------- 终端交互 --------------------------------------
# 脚本可能被这样运行： curl -fsSL ... | bash
# 此时 stdin 是脚本自身内容，任何普通 read 都会读到乱码。
# 所以一律显式指向 /dev/tty，不依赖 [ -t 0 ]。

detect_tty() {
  if { : < /dev/tty; } 2>/dev/null; then TTY_AVAILABLE=1; else TTY_AVAILABLE=0; fi
  return 0
}

tty_read() {
  local __var="$1" prompt="$2" ans=""
  [ "$TTY_AVAILABLE" = "1" ] || return 1
  read -r -p "$prompt" ans < /dev/tty || return 1
  printf -v "$__var" '%s' "$ans"
  return 0
}

ask() {
  # $1=提示 $2=默认 $3=结果变量
  local prompt="$1" def="$2" __var="$3" ans=""
  if [ "$OPT_YES" = "1" ]; then printf -v "$__var" '%s' "$def"; return 0; fi
  if tty_read ans "  ${prompt} [${def}]: "; then
    [ -z "$ans" ] && ans="$def"
    printf -v "$__var" '%s' "$ans"
    return 0
  fi
  printf "  ${prompt} [${def}]: %s ${C_D}(无终端，取默认)${C_N}\n" "$def"
  printf -v "$__var" '%s' "$def"
}

ask_yn() {
  local prompt="$1" def="$2" ans=""
  if [ "$OPT_YES" = "1" ]; then [ "$def" = "y" ] && return 0 || return 1; fi
  if tty_read ans "  ${prompt} [$([ "$def" = y ] && echo 'Y/n' || echo 'y/N')]: "; then
    ans="${ans:-$def}"
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
  fi
  printf "  ${prompt} ${C_D}(无终端，取默认 ${def})${C_N}\n"
  [ "$def" = "y" ] && return 0 || return 1
}

run_upstream() {
  # 进入上游脚本，把终端完整交给它（保留它的官方交互）
  local url="$1"; shift
  local rc=0
  if [ "$TTY_AVAILABLE" = "1" ]; then
    bash <(curl -fsSL "$url") "$@" < /dev/tty || rc=$?
  else
    bash <(curl -fsSL "$url") "$@" || rc=$?
  fi
  return "$rc"
}

# ---------------------------- 参数 ------------------------------------------
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --yes|-y)            OPT_YES=1 ;;
      --node=*)            OPT_NODE="${arg#*=}" ;;
      --addipv6-port=*)    OPT_ADDIPV6_PORT="${arg#*=}" ;;
      --start-port=*)      OPT_START_PORT="${arg#*=}" ;;
      --port-range=*)      OPT_PORT_RANGE="${arg#*=}" ;;
      --skip-precheck)     OPT_SKIP_PRECHECK=1 ;;
      --skip-addipv6)      OPT_SKIP_ADDIPV6=1 ;;
      --no-restore-service) OPT_ENABLE_RESTORE=0 ;;
      --version|-V)        echo "sb-v6-suite $VERSION"; exit 0 ;;
      --help|-h)           usage; exit 0 ;;
      *) die "未知参数：$arg（用 --help 看用法）" ;;
    esac
  done
}

usage() {
  cat <<EOF
sb-v6-suite $VERSION — 节点 + IPv6 多地址出口 一键部署

用法：
  bash install.sh [选项]

选项：
  -y, --yes                 全程默认值，不提问
      --node=NAME           节点脚本：xray | fscarmen | none
      --addipv6-port=PORT   指定 addipv6 面板端口（NAT 机器请填映射范围内的）
      --start-port=PORT     指定节点内部监听端口起始值
      --port-range=A-B      NAT 机器映射的端口范围，如 47451-47470
      --skip-precheck       跳过 IPv6 路由验证（不推荐）
      --skip-addipv6        只装节点
      --no-restore-service  不创建开机恢复服务
  -V, --version             显示版本
  -h, --help                显示帮助

流程：
  [1/7] 环境检查        [2/7] IPv6 能力预检    [3/7] 端口规划（全交互）
  [4/7] 安装 addipv6    [5/7] 安装节点         [6/7] 开机自动恢复
  [7/7] 出口设置与验证，并输出节点链接 + 面板地址 + 密码

说明：
  端口全部由本脚本交互式收集后直接写入配置，不需要你事后手工改。
  NAT 机器会自动要求你给出服务商映射的端口范围，并只在范围内分配。
EOF
}

# ---------------------------- 环境 ------------------------------------------
check_root() {
  [ "$(id -u)" = "0" ] || die "需要 root。请用 root 运行，或 sudo bash $0"
}

check_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"
  fi
  ARCH="$(uname -m)"
  info "系统：${OS_ID:-unknown} ${OS_VER}   架构：${ARCH}"
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    die "需要 Bash 4+（当前 ${BASH_VERSION}）。Alpine 请先： apk add bash"
  fi
  ok "Bash ${BASH_VERSION%%(*}"
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  local missing=() c
  for c in curl ip awk sed grep; do need_cmd "$c" || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] && { ok "基础命令齐全"; return 0; }
  warn "缺少：${missing[*]}，尝试安装"
  if need_cmd apt-get; then apt-get update -qq && apt-get install -y -qq curl iproute2 gawk >/dev/null 2>&1
  elif need_cmd apk; then apk add --no-cache curl iproute2 bash >/dev/null 2>&1
  elif need_cmd dnf; then dnf install -y -q curl iproute gawk >/dev/null 2>&1
  elif need_cmd yum; then yum install -y -q curl iproute gawk >/dev/null 2>&1
  fi
  for c in "${missing[@]}"; do need_cmd "$c" || die "仍缺少 $c，请手动安装"; done
  ok "依赖已就绪"
}

# ---------------------------- 端口工具 --------------------------------------
port_in_use() {
  local p="$1"
  if need_cmd ss; then ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif need_cmd netstat; then netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  else return 1; fi
}

port_owner() {
  need_cmd ss && ss -tlnp 2>/dev/null | grep -E "[:.]$1\b" | head -1 | sed -n 's/.*users:((("\([^"]*\)".*/\1/p'
}

port_owner_full() {
  need_cmd ss && ss -tlnp 2>/dev/null | grep -E "[:.]$1\b" | head -1
}

in_reserved() {
  local p="$1" x
  for x in "${PLAN_RESERVED[@]:-}"; do [ "$p" = "$x" ] && return 0; done
  return 1
}

# 在 [起,止] 内找一个既未被系统占用、也未被本脚本保留的端口
pick_in_range() {
  local s="$1" e="$2" p
  for p in $(seq "$s" "$e"); do
    in_reserved "$p" && continue
    port_in_use "$p" && continue
    echo "$p"; return 0
  done
  return 1
}

parse_port_range() {
  local in="$1"
  in="$(printf '%s' "$in" | tr -d '[:space:]')"
  if [[ "$in" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    PORT_RANGE_START="${BASH_REMATCH[1]}"; PORT_RANGE_END="${BASH_REMATCH[2]}"
  elif [[ "$in" =~ ^([0-9]{1,5})$ ]]; then
    PORT_RANGE_START="$in"; PORT_RANGE_END="$in"
  else
    return 1
  fi
  [ "$PORT_RANGE_START" -ge 1 ] && [ "$PORT_RANGE_END" -le 65535 ] \
    && [ "$PORT_RANGE_START" -le "$PORT_RANGE_END" ] || return 1
  return 0
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# ---------------------------- IPv6 ------------------------------------------
v6_expand() {
  # 把含 :: 的写法展开成标准 8 组
  local a="$1"
  local -a left=() right=() out=()
  local fill i l r
  if [[ "$a" == *"::"* ]]; then
    l="${a%%::*}"; r="${a##*::}"
    [ -n "$l" ] && IFS=':' read -r -a left  <<< "$l"
    [ -n "$r" ] && IFS=':' read -r -a right <<< "$r"
    fill=$(( 8 - ${#left[@]} - ${#right[@]} ))
    [ "$fill" -lt 0 ] && fill=0
    for ((i=0; i<${#left[@]};  i++)); do out+=("${left[$i]:-0}"); done
    for ((i=0; i<fill;         i++)); do out+=("0"); done
    for ((i=0; i<${#right[@]}; i++)); do out+=("${right[$i]:-0}"); done
  else
    IFS=':' read -r -a out <<< "$a"
  fi
  local IFS=':'
  printf '%s' "${out[*]}"
}

v6_prefix64_of() {
  local a="$1"
  local -a parts=()
  IFS=':' read -r -a parts <<< "$(v6_expand "$a")"
  printf '%s:%s:%s:%s' "${parts[0]:-0}" "${parts[1]:-0}" "${parts[2]:-0}" "${parts[3]:-0}"
}

rand_v6_in_prefix() {
  local pfx="$1" a b c d
  a=$(od -An -N2 -tx2 /dev/urandom 2>/dev/null | tr -d ' \n')
  b=$(od -An -N2 -tx2 /dev/urandom 2>/dev/null | tr -d ' \n')
  c=$(od -An -N2 -tx2 /dev/urandom 2>/dev/null | tr -d ' \n')
  d=$(od -An -N2 -tx2 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -z "$a" ] && a=$(printf '%04x' "$RANDOM")
  echo "${pfx}:${a}:${b}:${c}:${d}"
}

detect_v6() {
  hr "[2/7] IPv6 能力预检"

  local defline
  defline="$(ip -6 route show default 2>/dev/null | head -1)"
  if [ -z "$defline" ]; then
    bad "没有 IPv6 默认路由 —— 这台机器当前没有可用的 IPv6 出口"
    V6_ROUTED="no"; return 1
  fi

  V6_IFACE="$(echo "$defline" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
  V6_GW="$(echo "$defline" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
  echo "$defline" | grep -q 'onlink' && V6_ONLINK=1
  [ -n "$V6_IFACE" ] || { bad "默认路由里找不到网卡"; return 1; }

  info "默认路由：dev ${V6_IFACE}${V6_GW:+  via ${V6_GW}}"
  mapfile -t V6_ADDRS < <(ip -6 addr show dev "$V6_IFACE" scope global 2>/dev/null \
                          | awk '/inet6/{split($2,a,"/"); print a[1]}')
  if [ ${#V6_ADDRS[@]} -eq 0 ]; then
    bad "网卡 ${V6_IFACE} 上没有全局 IPv6 地址"
    V6_ROUTED="no"; return 1
  fi
  info "网卡 ${V6_IFACE} 上的全局 IPv6：${#V6_ADDRS[@]} 个"
  V6_NATIVE="${V6_ADDRS[0]}"
  dim "判定为原生地址（取第一个）：${V6_NATIVE}"

  local cidr
  cidr="$(ip -6 addr show dev "$V6_IFACE" scope global 2>/dev/null | awk '/inet6/{print $2}' | head -1)"
  V6_PLEN="${cidr##*/}"
  V6_PREFIX="$(v6_prefix64_of "$V6_NATIVE")"
  info "前缀：${V6_PREFIX}::/${V6_PLEN}"

  if [ "${V6_PLEN:-64}" -ge 128 ] 2>/dev/null; then
    warn "前缀是 /${V6_PLEN}，无法生成额外地址"
    V6_ROUTED="no"; return 1
  fi

  echo
  info "验证上游是否路由整个网段……"
  local probe="2606:4700:4700::1111" native_ok=0 rand_ok=0

  if ping6 -c 2 -W 3 -I "$V6_NATIVE" "$probe" >/dev/null 2>&1 \
     || curl -6 -s -o /dev/null -m 6 --interface "$V6_NATIVE" https://api64.ipify.org 2>/dev/null; then
    native_ok=1; ok "原生地址作源 → 通"
  else
    bad "原生地址作源 → 不通"
  fi

  local test_addr="" cleanup=0
  if [ ${#V6_ADDRS[@]} -gt 1 ]; then
    test_addr="${V6_ADDRS[1]}"
    dim "用已存在的非原生地址测试：${test_addr}"
  else
    test_addr="$(rand_v6_in_prefix "$V6_PREFIX")"
    dim "临时添加地址测试：${test_addr}"
    if ip -6 addr add "${test_addr}/${V6_PLEN}" dev "$V6_IFACE" 2>/dev/null; then
      cleanup=1; sleep 2
    else
      warn "临时地址添加失败，跳过网段验证"; test_addr=""
    fi
  fi

  if [ -n "$test_addr" ]; then
    if ping6 -c 2 -W 3 -I "$test_addr" "$probe" >/dev/null 2>&1 \
       || curl -6 -s -o /dev/null -m 6 --interface "$test_addr" https://api64.ipify.org 2>/dev/null; then
      rand_ok=1; ok "网段内随机地址作源 → 通"
    else
      bad "网段内随机地址作源 → 不通"
    fi
  fi

  if [ "$cleanup" = "1" ]; then
    ip -6 addr del "${test_addr}/${V6_PLEN}" dev "$V6_IFACE" 2>/dev/null && dim "已移除临时测试地址"
  fi

  echo
  if [ "$rand_ok" = "1" ]; then
    V6_ROUTED="yes"; ok "结论：上游路由整个网段 —— 多地址出口可行"; return 0
  elif [ "$native_ok" = "1" ]; then
    V6_ROUTED="no"
    bad "结论：上游只路由原生地址，网段内其他地址不可用"
    dim "addipv6 加的地址都会是死的，这套方案不适用"
    return 1
  else
    V6_ROUTED="unknown"
    bad "结论：当前 IPv6 出口整体不通 —— 先修好基础 IPv6"
    return 1
  fi
}

confirm_precheck() {
  [ "$OPT_SKIP_PRECHECK" = "1" ] && { warn "已按 --skip-precheck 跳过验证"; return 0; }
  [ "$V6_ROUTED" = "yes" ] && return 0
  echo
  warn "IPv6 预检未通过（结果：${V6_ROUTED:-未检测}）"
  dim "继续装也可以，但 addipv6 加的地址很可能不可用。"
  ask_yn "仍要继续吗？" n || die "已取消"
}

# ---------------------------- [3/7] 端口规划 --------------------------------
detect_nat() {
  local ip4=""
  ip4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
  [ -n "$ip4" ] || ip4="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')"
  NAT_LOCAL_IP="$ip4"
  case "$ip4" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-2][0-9].*)
      NAT_DETECTED=1 ;;
    *) NAT_DETECTED=0 ;;
  esac
  return 0
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4 -s -m 8 https://api.ipify.org 2>/dev/null)"
  [ -n "$ip" ] || ip="$(curl -4 -s -m 8 https://ifconfig.me 2>/dev/null)"
  [ -n "$ip" ] || ip="$(curl -4 -s -m 8 http://ip-api.com/line/?fields=query 2>/dev/null)"
  printf '%s' "$ip"
}

# 在范围里取端口，并登记保留
take_port() {
  local p
  p="$(pick_in_range "$PORT_RANGE_START" "$PORT_RANGE_END" 2>/dev/null)" || return 1
  PLAN_RESERVED+=("$p")
  printf '%s' "$p"
}

plan_ports() {
  hr "[3/7] 网络环境与端口规划"
  dim "这一步把 addipv6 面板和节点的端口全部定下来，装的时候直接用这些值"
  echo

  detect_nat
  PUBLIC_IP="$(detect_public_ip)"

  if [ "$NAT_DETECTED" = "1" ]; then
    warn "检测到 NAT 环境"
    dim "本机 IPv4 = ${NAT_LOCAL_IP}（私网地址）"
    [ -n "$PUBLIC_IP" ] && dim "公网出口 IP = ${PUBLIC_IP}（服务商共享）"
    echo
    printf "  ${C_R}只有服务商映射到公网的端口，外部才访问得到。${C_N}\n"
    printf "  ${C_R}用默认端口（addipv6 的 8688、节点的 40000 起）会直接连不上。${C_N}\n"
    echo
    if ! ask_yn "按「端口映射」规划端口？" y; then
      NAT_DETECTED=0
      warn "按「有公网 IP」处理 —— 如果其实是 NAT，后面会连不上"
    fi
  else
    ok "公网 IPv4：${NAT_LOCAL_IP:-<未取到>}"
    dim "看起来不是 NAT，端口可以自由选择"
  fi

  # ---------- 确定范围 ----------
  if [ "$NAT_DETECTED" = "1" ]; then
    echo
    dim "到服务商面板找「端口范围 / Port Range」那一栏"
    dim "格式填 起-止（如 47451-47470），只有单个端口就填数字"
    echo

    local ans="" tries=0
    if [ -n "$OPT_PORT_RANGE" ]; then
      parse_port_range "$OPT_PORT_RANGE" || die "--port-range 格式不对：$OPT_PORT_RANGE"
      info "使用命令行指定的范围：${PORT_RANGE_START}-${PORT_RANGE_END}"
    else
      while [ "$tries" -lt 3 ]; do
        ask "服务商映射的端口范围" "" ans
        if [ -z "$ans" ]; then
          warn "不能为空 —— NAT 机器必须指定，否则装完访问不到"
          tries=$((tries+1)); continue
        fi
        if parse_port_range "$ans"; then break; fi
        warn "格式不对，请填 起-止（如 47451-47470）"
        tries=$((tries+1)); ans=""
      done
      [ -n "$ans" ] || die "没有有效端口范围。NAT 机器请先到服务商面板确认"
    fi

    local span=$(( PORT_RANGE_END - PORT_RANGE_START + 1 ))
    ok "端口范围：${PORT_RANGE_START}-${PORT_RANGE_END}（共 ${span} 个）"
    if [ "$span" -lt 4 ]; then
      warn "范围只有 ${span} 个端口，addipv6 面板 + nginx + 节点至少需要 3 个"
    fi

    echo
    info "范围内已占用的端口："
    local p busy=0
    for p in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
      if port_in_use "$p"; then
        printf "      %-6s %s\n" "$p" "$(port_owner "$p")"
        PLAN_RESERVED+=("$p"); busy=1
      fi
    done
    [ "$busy" = "0" ] && dim "无"

    echo
    info "端口映射方式"
    printf "    ${C_B}1${C_N}) 公网端口 = 内部端口    ${C_D}(常见，如 公网 47454 → 内部 47454)${C_N}\n"
    printf "    ${C_B}2${C_N}) 公网端口 ≠ 内部端口    ${C_D}(如 公网 50001 → 内部 40001)${C_N}\n"
    echo
    local mm
    ask "输入编号" "1" mm
    case "$mm" in 2) PORT_MAP_SAME=0 ;; *) PORT_MAP_SAME=1 ;; esac
  else
    # 非 NAT：随便挑
    PORT_RANGE_START="${OPT_START_PORT:-40000}"
    PORT_RANGE_END=$(( PORT_RANGE_START + 500 ))
    PORT_MAP_SAME=1
    local p
    for p in $(seq 1 9000); do
      [ "$p" = "1" ] && continue
      port_in_use "$p" && PLAN_RESERVED+=("$p")
    done
  fi

  # ---------- 分配 addipv6 面板端口 ----------
  echo
  hr "端口分配"
  echo
  printf "  ${C_B}addipv6 面板端口${C_N}\n"
  dim "面板要在浏览器里打开，NAT 机器上必须落在映射范围内"
  echo

  local sug
  if [ -n "$OPT_ADDIPV6_PORT" ]; then
    sug="$OPT_ADDIPV6_PORT"
    info "命令行已指定：$sug"
  else
    sug="$(take_port)" || die "范围里没有空闲端口给 addipv6 面板"
    dim "自动挑到空闲端口：$sug"
  fi

  local pick
  ask "面板监听端口" "$sug" pick
  valid_port "$pick" || die "端口不合法：$pick"
  if port_in_use "$pick"; then die "端口 $pick 已被占用：$(port_owner "$pick")"; fi
  if [ "$NAT_DETECTED" = "1" ] && { [ "$pick" -lt "$PORT_RANGE_START" ] || [ "$pick" -gt "$PORT_RANGE_END" ]; }; then
    warn "端口 $pick 不在映射范围 ${PORT_RANGE_START}-${PORT_RANGE_END} 内"
    dim "面板从公网很可能打不开。"
    ask_yn "仍要用这个端口？" n || die "已取消，请换成范围内的端口"
  fi
  PLAN_ADDIPV6_INT="$pick"
  in_reserved "$pick" || PLAN_RESERVED+=("$pick")

  if [ "$NAT_DETECTED" = "1" ] && [ "$PORT_MAP_SAME" = "0" ]; then
    local pub
    ask "该端口的公网映射端口" "$pick" pub
    PLAN_ADDIPV6_PUB="$pub"
  else
    PLAN_ADDIPV6_PUB="$pick"
  fi
  ok "addipv6 面板：内部 ${PLAN_ADDIPV6_INT}  →  公网 ${PLAN_ADDIPV6_PUB}"

  # ---------- 分配节点端口 ----------
  echo
  printf "  ${C_B}节点端口${C_N}\n"
  dim "节点有「内部监听端口」和「公网映射端口」两个概念："
  dim "  内部监听：xray / sing-box 实际监听的，不需要在映射范围内"
  dim "  公网映射：写进 Cloudflare Origin Rules，必须在映射范围内"
  echo

  local nproto
  ask "要开几个协议" "1" nproto
  [[ "$nproto" =~ ^[0-9]+$ ]] && [ "$nproto" -ge 1 ] && [ "$nproto" -le 6 ] || { warn "按 1 处理"; nproto=1; }

  local intbase
  if [ -n "$OPT_START_PORT" ]; then
    intbase="$OPT_START_PORT"
  else
    intbase="$(pick_in_range 40000 41500 2>/dev/null || echo 40000)"
  fi
  ask "内部监听端口起始值" "$intbase" intbase
  valid_port "$intbase" || die "端口不合法：$intbase"

  local i p_int p_pub
  for ((i=0; i<nproto; i++)); do
    p_int=$((intbase + i))
    while port_in_use "$p_int" || in_reserved "$p_int"; do p_int=$((p_int + 1)); done
    PLAN_RESERVED+=("$p_int")
    PLAN_NODE_INT+=("$p_int")

    if [ "$NAT_DETECTED" = "1" ]; then
      p_pub="$(take_port)" || die "范围里没有空闲端口给节点用"
      PLAN_NODE_PUB+=("$p_pub")
    else
      PLAN_NODE_PUB+=("$p_int")
    fi
  done

  ok "节点端口："
  for ((i=0; i<nproto; i++)); do
    printf "      协议 %s   内部 %-6s →  公网 %s\n" "$((i+1))" "${PLAN_NODE_INT[$i]}" "${PLAN_NODE_PUB[$i]}"
  done

  # ---------- nginx（仅 WebSocket 协议需要）----------
  if [ "$NAT_DETECTED" = "1" ]; then
    echo
    printf "  ${C_B}nginx 端口${C_N}  ${C_D}(只有 VLESS+WS / VMess+WS 用到，用不到可跳过)${C_N}\n"
    if ask_yn "需要预留 nginx 端口吗？" n; then
      PLAN_NGINX_INT="$(take_port)" || warn "没有空闲端口了"
      if [ -n "$PLAN_NGINX_INT" ]; then
        if [ "$PORT_MAP_SAME" = "1" ]; then PLAN_NGINX_PUB="$PLAN_NGINX_INT"
        else ask "nginx 的公网映射端口" "$PLAN_NGINX_INT" PLAN_NGINX_PUB; fi
        ok "nginx：内部 ${PLAN_NGINX_INT}  →  公网 ${PLAN_NGINX_PUB}"
      fi
    else
      dim "跳过"
    fi
  fi

  PORT_MAP_SAME=$PORT_MAP_SAME
  echo
  ok "端口规划完成"
}

# 给用户看的速查表
show_port_plan() {
  echo
  printf "  ${C_B}══════════ 端口速查（装节点时对照填） ══════════${C_N}\n"
  printf "    addipv6 面板        内部 %-6s  公网 %s\n" "$PLAN_ADDIPV6_INT" "$PLAN_ADDIPV6_PUB"
  local i
  for ((i=0; i<${#PLAN_NODE_INT[@]}; i++)); do
    printf "    节点协议 %-11s 内部 %-6s  公网 %s\n" "$((i+1))" "${PLAN_NODE_INT[$i]}" "${PLAN_NODE_PUB[$i]}"
  done
  [ -n "$PLAN_NGINX_INT" ] && printf "    nginx               内部 %-6s  公网 %s\n" "$PLAN_NGINX_INT" "$PLAN_NGINX_PUB"
  if [ "$NAT_DETECTED" = "1" ]; then
    printf "    ${C_D}允许范围 %s-%s   映射方式 %s${C_N}\n" \
      "$PORT_RANGE_START" "$PORT_RANGE_END" \
      "$([ "$PORT_MAP_SAME" = 1 ] && echo '公网=内部' || echo '公网≠内部')"
  else
    printf "    ${C_D}网络环境：公网 IP，端口不受限${C_N}\n"
  fi
  printf "  ${C_B}════════════════════════════════════════════════${C_N}\n"
  echo
}

# ---------------------------- [4/7] addipv6 ---------------------------------
detect_addipv6_port() {
  local listen
  listen="$(ps -eo args 2>/dev/null | grep -m1 '[a]ddipv6 -listen' \
            | sed -n 's/.*-listen[[:space:]]*\([^[:space:]]*\).*/\1/p')"
  [ -n "$listen" ] || return 1
  printf '%s' "${listen##*:}"
}

detect_addipv6_service() {
  local u
  for u in addipv6; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${u}\.service" && { printf '%s' "$u"; return 0; }
  done
  return 1
}

install_addipv6() {
  hr "[4/7] 安装 addipv6"

  if [ "$OPT_SKIP_ADDIPV6" = "1" ]; then warn "已按 --skip-addipv6 跳过"; return 0; fi

  if need_cmd addipv6 || [ -x /usr/local/bin/addipv6 ]; then
    ok "addipv6 已安装"
    local cur
    cur="$(/usr/local/bin/addipv6 version 2>/dev/null | head -1)"
    [ -n "$cur" ] && dim "$cur"
    if ! ask_yn "重新安装 / 更新？" n; then
      OPT_ADDIPV6_PORT="${PLAN_ADDIPV6_INT}"
      return 0
    fi
  fi

  local port="$PLAN_ADDIPV6_INT"
  [ -n "$port" ] || port="${OPT_ADDIPV6_PORT:-8688}"

  echo
  printf "  面板端口已定为 ${C_G}%s${C_N}" "$port"
  [ "$PLAN_ADDIPV6_PUB" != "$port" ] && printf "（公网映射端口 %s）" "$PLAN_ADDIPV6_PUB"
  echo
  echo
  dim "选择安装方式："
  echo
  local defmode="2"
  printf "    ${C_B}1${C_N}) 进入 addipv6 官方菜单\n"
  printf "       ${C_D}装 / 更新 / 卸载 / 启停 / 改密码 / 改端口 都在里面${C_N}\n"
  if [ "$NAT_DETECTED" = "1" ]; then
    printf "       ${C_Y}NAT 提醒：装完必须再选「10) 改端口」改成 %s${C_N}\n" "$port"
  fi
  echo
  printf "    ${C_B}2${C_N}) 自动安装并把端口直接配好  ${C_G}(推荐)${C_N}\n"
  printf "       ${C_D}端口已是 %s，装完即用，不用再改${C_N}\n" "$port"
  echo
  local mode
  ask "输入编号" "$defmode" mode

  local rc=0
  if [ "$mode" = "1" ]; then
    info "进入 addipv6 官方菜单"
    echo
    [ "$NAT_DETECTED" = "1" ] && printf "      ${C_Y}★ 装完后记得选「10) 改端口」→ %s${C_N}\n" "$port"
    echo
    run_upstream "$ADDIPV6_INSTALL_URL" || rc=$?
  else
    info "自动安装（端口 ${port}）"
    echo
    run_upstream "$ADDIPV6_INSTALL_URL" install "$port" || rc=$?
  fi

  [ "$rc" != "0" ] && { warn "上游返回码 $rc"; dim "若其实已装好可忽略"; }
  echo

  local actual
  actual="$(detect_addipv6_port 2>/dev/null)"
  if [ -n "$actual" ]; then
    OPT_ADDIPV6_PORT="$actual"
    if [ "$actual" != "$port" ]; then
      warn "面板实际监听 ${actual}（与规划的 ${port} 不一致）"
      if [ "$NAT_DETECTED" = "1" ] && { [ "$actual" -lt "$PORT_RANGE_START" ] || [ "$actual" -gt "$PORT_RANGE_END" ]; }; then
        bad "该端口不在映射范围 ${PORT_RANGE_START}-${PORT_RANGE_END} 内 —— 公网打不开"
        dim "修：重跑本脚本并在菜单里选「10) 改端口」→ ${port}"
      fi
    else
      ok "面板监听端口：${actual}"
    fi
  else
    warn "未检测到面板监听端口（服务可能没起来）"
    local svc
    svc="$(detect_addipv6_service 2>/dev/null)"
    [ -n "$svc" ] && dim "启动： systemctl start ${svc}"
  fi

  log "addipv6 installed, port=$OPT_ADDIPV6_PORT"
}

# ---------------------------- [5/7] 节点 ------------------------------------
choose_node() {
  if [ -n "$OPT_NODE" ]; then return 0; fi
  hr "[5/7] 选择节点脚本"
  cat <<'EOF'

    1) byJoey/xray-cf-lite
       最小化 xray + Cloudflare 隐藏源站，NAT / Alpine / 低配友好
       协议：vless / trojan / vmess
       注意：它没有配置文件模式，端口要在它的交互流程里手填（本脚本会把值算好给你）

    2) fscarmen/sing-box
       协议最全的脚本，5700+ stars，活跃维护
       协议：Reality / Hysteria2 / TUIC / Trojan / SS / AnyTLS / ShadowTLS / VMess / VLESS / NaiveProxy
       支持配置文件模式，端口可由本脚本直接写进去，全自动

    3) 不装节点，只装 addipv6

EOF
  local ans
  ask "输入编号" "2" ans
  case "$ans" in
    1) OPT_NODE="xray" ;;
    3) OPT_NODE="none" ;;
    *) OPT_NODE="fscarmen" ;;
  esac
}

install_node() {
  hr "[5/7] 安装节点"

  case "$OPT_NODE" in
    none) warn "按选择跳过节点安装"; return 0 ;;
    xray)     run_node_xray ;;
    fscarmen) run_node_fscarmen ;;
    "")       warn "未指定节点，跳过"; return 0 ;;
    *)        die "未知节点类型：$OPT_NODE" ;;
  esac
}

# ---- xray-cf-lite：没有配置文件模式，给精确的填写清单 ----
run_node_xray() {
  if [ -f /usr/local/etc/xray/config.json ]; then
    ok "检测到 xray 已安装"
    if ! ask_yn "重新运行它的安装流程？" n; then
      NODE_INSTALLED_RC=0; return 0
    fi
  fi

  show_port_plan

  cat <<EOF
  ${C_B}xray-cf-lite 是纯交互脚本，没有配置文件模式。${C_N}
  ${C_B}它的每一步要填什么，对应关系如下：${C_N}

EOF
  printf "    ${C_Y}协议${C_N}          ${C_Y}「内部监听端口」填${C_N}   ${C_Y}「外部映射端口」填${C_N}\n"
  local i
  for ((i=0; i<${#PLAN_NODE_INT[@]}; i++)); do
    printf "    %-14s %-18s %s\n" "第 $((i+1)) 个" "${PLAN_NODE_INT[$i]}" "${PLAN_NODE_PUB[$i]}"
  done
  if [ -n "$PLAN_NGINX_INT" ]; then
    printf "    %-14s %-18s %s\n" "nginx 端口" "$PLAN_NGINX_INT" "$PLAN_NGINX_PUB"
  fi
  echo
  if [ "$NAT_DETECTED" = "1" ]; then
    printf "    ${C_R}外部映射端口必须是 ${PORT_RANGE_START}-${PORT_RANGE_END} 内的值${C_N}\n"
    dim "它会被写进 Cloudflare Origin Rules，填错节点直接连不上"
  else
    dim "你不是 NAT 机器，内外端口填一样即可"
  fi
  dim "域名、CF 邮箱 + Global API Key 按你自己的信息填"
  echo
  printf "  ${C_Y}接下来终端完全交给它，照着上面的表填。${C_N}\n"
  echo
  if ! ask_yn "准备好了，现在进入？" y; then
    warn "已跳过"
    dim "手动运行： bash <(curl -fsSL $NODE_XRAY_URL)"
    NODE_INSTALLED_RC=1; return 0
  fi
  echo

  local rc=0
  run_upstream "$NODE_XRAY_URL" || rc=$?
  NODE_INSTALLED_RC=$rc
  echo
  [ "$rc" != "0" ] && warn "xray-cf-lite 返回码 $rc" || ok "xray-cf-lite 流程结束"
  log "node=xray rc=$rc"
}

# ---- fscarmen/sing-box：用 config.conf 把端口直接写进去 ----
run_node_fscarmen() {
  if [ -d /etc/sing-box ] || [ -f /usr/local/bin/sing-box ]; then
    ok "检测到 sing-box 已安装"
    if ! ask_yn "重新运行它的安装流程？" n; then
      NODE_INSTALLED_RC=0; return 0
    fi
  fi

  show_port_plan

  cat <<EOF
  ${C_B}fscarmen/sing-box 的官方交互流程会被完整保留。${C_N}
  ${C_B}语言、协议选择、域名、订阅、Argo 全部由你在它的菜单里决定。${C_N}
  ${C_B}它问到端口时，照着上表填：${C_N}

EOF
  printf "    ${C_Y}它问的项${C_N}                      ${C_Y}填这个值${C_N}\n"
  printf "    %-28s %s\n" "起始端口 START_PORT" "${PLAN_NODE_PUB[0]:-$PLAN_NODE_INT_BASE}"
  [ -n "$PLAN_NGINX_PUB" ] && printf "    %-28s %s\n" "nginx 端口 PORT_NGINX" "$PLAN_NGINX_PUB"
  if [ "${#PLAN_NODE_INT[@]}" -gt 1 ]; then
    dim "（后续协议端口通常按 +1 递增：${PLAN_NODE_PUB[*]}）"
  fi
  echo
  if [ "$NAT_DETECTED" = "1" ]; then
    printf "    ${C_R}★ NAT 机器：起始端口必须在 ${PORT_RANGE_START}-${PORT_RANGE_END} 内${C_N}\n"
    dim "填错的话这个节点从公网连不上"
    dim "不想操心端口的话，ARGO 选 true 走 Cloudflare 隧道，就不需要端口映射"
  else
    dim "你不是 NAT 机器，端口不受限，填上面那个即可"
  fi
  echo
  dim "其它项（语言 / 协议 / 域名 / 订阅）按你自己的需求在它的菜单里选"
  echo

  printf "    ${C_B}1${C_N}) 进入它自己的交互流程                     ${C_G}(默认，推荐)${C_N}\n"
  printf "       ${C_D}配置项全部由它问你，本脚本不插手${C_N}\n"
  echo
  printf "    ${C_B}2${C_N}) 用本脚本收集的参数生成配置，直接装好\n"
  printf "       ${C_D}跳过它的菜单，端口/协议由本脚本写入 config.conf${C_N}\n"
  printf "       ${C_D}想完全自动化、不想一步步点的时候用${C_N}\n"
  echo
  local mode
  ask "输入编号" "1" mode

  if [ "$mode" != "2" ]; then
    echo
    printf "  ${C_Y}接下来终端完全交给它，按它的提示操作即可。${C_N}\n"
    echo
    if ! ask_yn "准备好了，现在进入？" y; then
      warn "已跳过"
      dim "手动运行： bash <(curl -fsSL $NODE_FSCARMEN_URL)"
      NODE_INSTALLED_RC=1; return 0
    fi
    echo
    local rc=0
    run_upstream "$NODE_FSCARMEN_URL" || rc=$?
    NODE_INSTALLED_RC=$rc
    echo
    [ "$rc" != "0" ] && warn "fscarmen/sing-box 返回码 $rc" || ok "fscarmen/sing-box 流程结束"
    log "node=fscarmen rc=$rc"
    return 0
  fi

  # ---- 生成 config.conf ----
  echo
  info "收集节点参数（回车用默认）"

  local lang protos start_port argo sub serverip
  ask "语言（c=中文 e=英文）" "c" lang
  ask "协议（a=全部，或组合如 b / bc / bcd；建议先 b）" "b" protos

  if [ "$NAT_DETECTED" = "1" ]; then
    dim "起始端口要用映射范围内的端口，否则公网连不上"
    ask "起始端口" "${PLAN_NODE_PUB[0]}" start_port
    if [ "$start_port" -lt "$PORT_RANGE_START" ] 2>/dev/null || [ "$start_port" -gt "$PORT_RANGE_END" ] 2>/dev/null; then
      warn "端口 ${start_port} 不在映射范围 ${PORT_RANGE_START}-${PORT_RANGE_END} 内"
      ask_yn "仍要用？" n || die "已取消"
    fi
  else
    ask "起始端口" "${PLAN_NODE_INT[0]}" start_port
  fi

  if [ "$NAT_DETECTED" = "1" ]; then
    dim "NAT 机器建议用 Argo 隧道（true）—— 入口走 Cloudflare，不需要公网端口"
    ask "是否启用 Argo 隧道（true/false）" "true" argo
  else
    ask "是否启用 Argo 隧道（true/false）" "false" argo
  fi

  ask "是否启用订阅（true/false）" "true" sub
  ask "服务器 IP（留空自动检测）" "$(detect_public_ip)" serverip

  mkdir -p "$STATE_DIR"
  cat > "$CONF_OUT" <<EOF
# 由 sb-v6-suite $VERSION 生成于 $(date '+%F %T')
# 端口来自本脚本的交互式端口规划
LANGUAGE='${lang}'
CHOOSE_PROTOCOLS='${protos}'
START_PORT='${start_port}'
PORT_NGINX='${PLAN_NGINX_PUB:-}'
SERVER_IP='${serverip}'
CDN=''
UUID_CONFIRM=''
SUBSCRIBE='${sub}'
ARGO='${argo}'
VMESS_HOST_DOMAIN=''
VLESS_HOST_DOMAIN=''
EOF
  chmod 600 "$CONF_OUT" 2>/dev/null
  ok "配置已写入：$CONF_OUT"
  echo
  dim "内容："
  sed 's/^/      /' "$CONF_OUT"
  echo

  if ! ask_yn "用这份配置安装？" y; then
    warn "已取消"
    dim "配置留在 $CONF_OUT，你可以自己改完再跑："
    dim "  bash <(curl -fsSL $NODE_FSCARMEN_URL) -f $CONF_OUT"
    NODE_INSTALLED_RC=1; return 0
  fi
  echo

  local rc=0
  # 注意：把 -f 配置 和终端一起交给上游
  run_upstream "$NODE_FSCARMEN_URL" -f "$CONF_OUT" || rc=$?
  NODE_INSTALLED_RC=$rc

  if [ "$rc" != "0" ]; then
    warn "带配置安装返回码 $rc"
    dim "可能它的 config.conf 格式有变，改用交互流程重试："
    if ask_yn "现在进入交互流程？" y; then
      echo
      run_upstream "$NODE_FSCARMEN_URL" || rc=$?
      NODE_INSTALLED_RC=$rc
    fi
  else
    ok "fscarmen/sing-box 安装结束"
  fi
  log "node=fscarmen rc=$rc conf=$CONF_OUT"
}

# ---------------------------- [6/7] 开机恢复 --------------------------------
setup_restore_service() {
  hr "[6/7] 配置开机自动恢复"

  if [ "$OPT_ENABLE_RESTORE" = "0" ]; then warn "已按 --no-restore-service 跳过"; return 0; fi
  if ! [ -x /usr/local/bin/addipv6 ] && ! need_cmd addipv6; then
    warn "addipv6 未安装，跳过"; return 0
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^addipv6-restore'; then
    ok "addipv6 自带的开机恢复服务已存在"
    systemctl is-enabled addipv6-restore >/dev/null 2>&1 && ok "已启用" \
      || { systemctl enable addipv6-restore >/dev/null 2>&1 && ok "已启用" || warn "启用失败"; }
    return 0
  fi

  if [ ! -d /etc/systemd/system ]; then
    warn "没有 systemd，无法创建开机恢复服务"
    dim "OpenRC 环境请自行加到 /etc/local.d/： addipv6 restore"
    return 0
  fi

  local bin="/usr/local/bin/addipv6"
  [ -x "$bin" ] || bin="$(command -v addipv6)"

  cat > /etc/systemd/system/addipv6-restore.service <<EOF
[Unit]
Description=addipv6 restore — 开机恢复 IPv6 地址与出口选择
Documentation=https://github.com/byJoey/addipv6
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${bin} restore
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload 2>/dev/null
  if systemctl enable addipv6-restore.service >/dev/null 2>&1; then
    ok "已创建并启用 addipv6-restore.service"
    dim "查看： systemctl status addipv6-restore"
    log "restore service enabled"
  else
    warn "服务创建失败 —— 重启后 IPv6 地址会丢失"
  fi
}

# ---------------------------- [7/7] 出口 ------------------------------------
guide_egress() {
  hr "[7/7] 出口地址设置与验证"

  if ! [ -x /usr/local/bin/addipv6 ] && ! need_cmd addipv6; then
    warn "addipv6 未安装，跳过"; return 0
  fi

  local defline src
  defline="$(ip -6 route show default 2>/dev/null | head -1)"
  src="$(echo "$defline" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  info "IPv6 默认路由：${defline:-无}"
  info "当前出口源地址：${src:-<内核自动选择>}"

  echo
  printf "  接下来在 addipv6 面板里操作：\n"
  dim "1. 打开面板 → 选网卡 → 填数量 → 点「随机生成」"
  dim "2. 点「加到网卡」"
  dim "3. 勾中想用的地址 → 点「设为出口」"
  echo
  dim "原理：它改的是内核默认路由的 src，节点进程自动继承，配置不用动。"
  echo

  if ask_yn "现在就验证一次出口吗？" y; then verify_egress; fi
}

verify_egress() {
  echo
  info "出口验证："
  local chosen egress
  chosen="$(ip -6 route get 2a00:1450:4001:82f::200e 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  [ -n "$chosen" ] && ok "内核源地址 = $chosen" || warn "拿不到内核源地址"

  egress="$(curl -6 -s -m 12 https://api64.ipify.org 2>/dev/null)"
  if [ -n "$egress" ]; then
    ok "对外 IPv6 出口 = $egress"
  else
    bad "拿不到 IPv6 出口 —— 当前 IPv6 不通"
    dim "回滚： bash rollback.sh --reset"
  fi

  echo
  info "IPv6 优先目标："
  local u code
  for u in "https://www.cloudflare.com" "https://www.google.com/generate_204"; do
    code="$(curl -6 -s -o /dev/null -w '%{http_code}' -m 10 "$u" 2>/dev/null)"
    if [ "$code" = "000" ] || [ -z "$code" ]; then bad "$u"; else ok "$u  (HTTP $code)"; fi
  done
}

# ---------------------------- 收集节点链接 ----------------------------------
collect_links() {
  local -a dirs=(
    /usr/local/etc/xray /etc/xray-cf-lite /usr/local/etc/sing-box
    /etc/sing-box /var/lib/sing-box /root /usr/local/etc
  )
  local f
  # 已生成的文件
  for f in ./cf_lite_last_links.txt /root/cf_lite_last_links.txt \
           "${STATE_DIR}/links.txt" /usr/local/etc/sing-box/subscribe.txt; do
    [ -r "$f" ] && grep -hoE '(vless|vmess|trojan|ss|hysteria2|hy2|tuic|anytls|shadowtls)://[^"[:space:]]+' "$f" 2>/dev/null
  done
  for f in "${dirs[@]}"; do
    [ -d "$f" ] || continue
    grep -rhoE '(vless|vmess|trojan|ss|hysteria2|hy2|tuic|anytls|shadowtls)://[^"'"'"'[:space:]]+' "$f" 2>/dev/null
  done | sed 's/[",]*$//' | sort -u
}

collect_sub_url() {
  local f
  for f in ./cf_lite_last_links.txt /root/cf_lite_last_links.txt \
           /usr/local/etc/sing-box/subscribe.txt "${STATE_DIR}/links.txt"; do
    [ -r "$f" ] || continue
    grep -hoE 'https?://[^"'"'"'[:space:]]+' "$f" 2>/dev/null
  done | sort -u
}

# ---------------------------- 最终汇总 --------------------------------------
final_report() {
  hr "完成 —— 汇总信息"

  local panel_host panel_url pass
  if [ "$NAT_DETECTED" = "1" ] && [ -n "$PUBLIC_IP" ]; then
    panel_host="$PUBLIC_IP"
  else
    panel_host="${PUBLIC_IP:-$NAT_LOCAL_IP}"
  fi
  [ -n "$OPT_ADDIPV6_PORT" ] || OPT_ADDIPV6_PORT="${PLAN_ADDIPV6_INT:-8688}"
  panel_url="http://${panel_host}:${PLAN_ADDIPV6_PUB:-$OPT_ADDIPV6_PORT}"

  printf "\n  ${C_B}═══════════════ IPv6 出口工具（addipv6）═══════════════${C_N}\n\n"
  if need_cmd addipv6 || [ -x /usr/local/bin/addipv6 ]; then
    printf "    面板地址   ${C_G}%s${C_N}\n" "$panel_url"
    if [ -f /etc/addipv6/password ]; then
      pass="$(cat /etc/addipv6/password 2>/dev/null)"
      printf "    登录密码   ${C_G}%s${C_N}\n" "$pass"
      printf "    密码文件   /etc/addipv6/password\n"
    else
      printf "    登录密码   ${C_Y}<未找到 /etc/addipv6/password>${C_N}\n"
    fi
    printf "    监听端口   %s" "${OPT_ADDIPV6_PORT}"
    [ "$PLAN_ADDIPV6_PUB" != "$OPT_ADDIPV6_PORT" ] && printf "（公网映射 %s）" "$PLAN_ADDIPV6_PUB"
    echo
    printf "    开机恢复   %s\n" "$(systemctl is-enabled addipv6-restore 2>/dev/null || echo '未配置')"
  else
    printf "    ${C_Y}未安装${C_N}\n"
  fi

  if [ "$NAT_DETECTED" = "1" ]; then
    echo
    printf "    ${C_Y}▲ 这是 NAT 机器${C_N}\n"
    dim "面板只能通过公网映射端口访问。如果上面地址打不开，改用 SSH 隧道："
    dim "  ssh -L ${OPT_ADDIPV6_PORT}:127.0.0.1:${OPT_ADDIPV6_PORT} root@${PUBLIC_IP:-<公网IP>}"
    dim "  然后浏览器开 http://127.0.0.1:${OPT_ADDIPV6_PORT}"
  fi

  printf "\n  ${C_B}═══════════════════ 节点信息 ═══════════════════${C_N}\n\n"

  local links subs found=0
  links="$(collect_links)"
  subs="$(collect_sub_url)"

  if [ -n "$links" ]; then
    printf "    分享链接：\n\n"
    while IFS= read -r L; do
      [ -n "$L" ] && printf "      ${C_G}%s${C_N}\n\n" "$L"
    done <<< "$links"
    found=1
    printf "    链接已同时保存到 ${STATE_DIR}/links.txt\n"
    printf '%s\n' "$links" > "${STATE_DIR}/links.txt" 2>/dev/null
    chmod 600 "${STATE_DIR}/links.txt" 2>/dev/null
  fi

  if [ -n "$subs" ]; then
    printf "    订阅地址：\n\n"
    while IFS= read -r S; do
      [ -n "$S" ] && printf "      ${C_B}%s${C_N}\n" "$S"
    done <<< "$subs"
    echo
    found=1
  fi

  if [ "$found" = "0" ]; then
    printf "    ${C_Y}没有自动找到分享链接${C_N}\n"
    echo
    if [ "$OPT_NODE" = "xray" ]; then
      dim "xray-cf-lite 的链接用它的菜单查看："
      dim "  bash <(curl -fsSL $NODE_XRAY_URL)"
      dim "  然后选「3) 查看订阅」"
      dim "  或者看 /etc/xray-cf-lite/state.json 和运行目录下的 cf_lite_last_links.txt"
    elif [ "$OPT_NODE" = "fscarmen" ]; then
      dim "fscarmen/sing-box 的链接一般在这些位置："
      dim "  /etc/sing-box/ 或 /usr/local/etc/sing-box/"
      dim "  也可以重跑脚本看它的菜单输出"
    else
      dim "没有安装节点"
    fi
    echo
    dim "也可以自己找："
    dim "  grep -rhoE '(vless|vmess|trojan|hysteria2)://[^\" ]+' /etc /usr/local/etc 2>/dev/null | sort -u"
  fi

  printf "\n  ${C_B}═══════════════════ 端口速查 ═══════════════════${C_N}\n\n"
  printf "    addipv6 面板   %s\n" "${PLAN_ADDIPV6_PUB:-$OPT_ADDIPV6_PORT}"
  local i
  for ((i=0; i<${#PLAN_NODE_INT[@]}; i++)); do
    printf "    节点协议 %-6s 内部 %-6s 公网 %s\n" "$((i+1))" "${PLAN_NODE_INT[$i]}" "${PLAN_NODE_PUB[$i]}"
  done
  if [ "$NAT_DETECTED" = "1" ]; then
    printf "    %s允许范围 %s-%s${C_N}\n" "$C_D" "$PORT_RANGE_START" "$PORT_RANGE_END"
  fi

  printf "\n  ${C_B}═══════════════════ 常用命令 ═══════════════════${C_N}\n\n"
  printf "    addipv6 version                     查看版本\n"
  printf "    addipv6 restore                     手动恢复地址\n"
  printf "    systemctl status addipv6-restore    开机恢复服务状态\n"
  printf "    journalctl -u addipv6-restore -n 50 看恢复日志\n"
  printf "    bash verify.sh                      一键体检\n"
  printf "    bash rollback.sh                    回滚出口设置\n"

  printf "\n  ${C_B}═══════════════════ 注意 ═══════════════════${C_N}\n\n"
  dim "· 每次切换出口后立刻跑一次 verify.sh，确认 IPv6 没断"
  dim "· addipv6 与节点脚本可能都用 Cloudflare 凭据，建议用不同子域名隔离"
  dim "· 面板不要长期暴露公网，建议 SSH 隧道访问"
  echo
}

# ---------------------------- 状态 ------------------------------------------
write_state() {
  mkdir -p "$STATE_DIR"
  local pub_ports int_ports
  pub_ports="$(IFS=,; echo "${PLAN_NODE_PUB[*]:-}")"
  int_ports="$(IFS=,; echo "${PLAN_NODE_INT[*]:-}")"
  cat > "$STATE_FILE" <<EOF
{
  "version": "$VERSION",
  "installed_at": "$(date -Iseconds)",
  "os": "${OS_ID} ${OS_VER}",
  "arch": "${ARCH}",
  "nat": ${NAT_DETECTED},
  "public_ip": "${PUBLIC_IP}",
  "port_range": "${PORT_RANGE_START}-${PORT_RANGE_END}",
  "port_map_same": ${PORT_MAP_SAME},
  "addipv6_port_int": ${PLAN_ADDIPV6_INT:-0},
  "addipv6_port_pub": ${PLAN_ADDIPV6_PUB:-0},
  "node": "${OPT_NODE}",
  "node_int_ports": "${int_ports}",
  "node_pub_ports": "${pub_ports}",
  "v6_iface": "${V6_IFACE}",
  "v6_gateway": "${V6_GW}",
  "v6_prefix": "${V6_PREFIX}",
  "v6_plen": "${V6_PLEN}",
  "v6_native": "${V6_NATIVE}",
  "v6_routed": "${V6_ROUTED}"
}
EOF
  chmod 600 "$STATE_FILE" 2>/dev/null
  ok "状态已记录：$STATE_FILE"
}

# ---------------------------- 主流程 ----------------------------------------
main() {
  parse_args "$@"
  mkdir -p "$STATE_DIR" 2>/dev/null

  echo
  echo "############################################################"
  echo "#  sb-v6-suite  $VERSION"
  echo "#  节点 + IPv6 多地址出口 一键部署"
  echo "############################################################"

  step "1/7" "环境检查"
  check_root

  detect_tty
  if [ "$TTY_AVAILABLE" = "1" ]; then
    ok "终端可交互"
  else
    warn "找不到 /dev/tty —— 交互会退化为默认值"
    echo
    dim "很可能是用管道运行的，例如："
    dim "  curl -fsSL .../install.sh | bash"
    dim "这时 stdin 是脚本自身内容，任何 read 都会失败。"
    echo
    dim "请改用："
    dim "  bash <(curl -fsSL <本脚本地址>)"
    echo
    if ! ask_yn "仍要在无终端模式下继续？" n; then
      die "已取消。请用 bash <(curl ...) 方式重新运行"
    fi
  fi

  check_os
  install_deps
  log "=== sb-v6-suite $VERSION start ==="

  detect_v6 || true
  confirm_precheck

  plan_ports

  install_addipv6
  choose_node
  install_node
  setup_restore_service
  guide_egress

  write_state
  final_report
}

main "$@"