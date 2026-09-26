# sb-v6-suite

**节点 + IPv6 多地址出口 一键部署**

把 [addipv6](https://github.com/byJoey/addipv6) 和节点脚本串成一套可交互安装的部署流程，
并补上原项目没有的 **IPv6 路由预检**、**开机恢复服务**、**一键体检** 和 **回滚**。

---

## 它解决什么

VPS 只给了一个 IPv6，但你想让节点换一个出口 IP。做法是：

```
addipv6 批量加地址 ──> 点「设为出口」──> 改内核默认路由的 src
                                              │
                                              ▼
                        节点进程（xray / sing-box）自动继承
                                              │
                                              ▼
                                    节点出口 IP 变成你选的那个
```

**关键点：这是操作系统层的联动，节点配置一个字都不用改。**

---

## 它不做什么

设计上刻意保持简单，有几件事**故意不做**，装之前请确认符合预期：

| 不做 | 原因 |
|---|---|
| **多出口分发**（每个协议/用户走不同 IP） | 需要额外的分发层。默认路由是全机共用的，**同时只能有一个 IPv6 出口** |
| **改节点配置** | 不需要。改了反而会被上游脚本重建时冲掉 |
| **改 DNS / resolv.conf** | PVE 等环境会自动覆盖。节点 DNS 请在上游脚本里单独配 |
| **碰 Cloudflare 配置** | addipv6 会管 AAAA 记录；节点脚本可能也管 CF。建议用不同子域名隔离 |

---

## 前置条件

| 项 | 要求 |
|---|---|
| 权限 | **root**（addipv6 和两个节点脚本都要求） |
| 系统 | Debian / Ubuntu / Alpine / CentOS 等，Bash 4+ |
| **IPv6** | **上游必须路由整个 /64** ← 硬门槛，见下方验证 |
| 网络 | 能访问 raw.githubusercontent.com |

### 先确认上游给了你 /64

这是**唯一决定方案能否成立**的条件。装上之后才发现在这儿卡住，就白折腾了：

```bash
# 找出网卡上的全局 IPv6
ip -6 addr show scope global | grep inet6
ip -6 route show default

# 用「原生地址」做源 ping —— 应该通
ping6 -c 3 -I <原生地址> 2606:4700:4700::1111

# 用「网段内随机地址」做源 ping —— 通了才说明整个 /64 可用
ping6 -c 3 -I <随机地址> 2606:4700:4700::1111
```

**随机地址不通 = 上游只路由你单个地址，这个方案不适用，别装。**

> 好消息：`install.sh` 会自动做这个验证，不通过会提示你确认。但提前知道能省时间。

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/sb-v6-suite/main/install.sh)
```

### 交互流程

```
[1/7] 环境检查          root / 系统 / 架构 / 依赖 / 终端可交互性
[2/7] IPv6 能力预检  ★  探测 /64、实测上游是否路由整个网段
[3/7] 端口规划        ★  NAT 检测 + 交互式收集所有端口
[4/7] 安装 addipv6      端口已配好，装完即用
[5/7] 安装节点          官方交互流程，端口照速查表填
[6/7] 开机自动恢复      创建 addipv6-restore.service
[7/7] 出口设置与验证 + 最终汇总
                        输出：节点链接 / 面板地址 / 密码 / 端口速查
```

### ★ NAT 机器的端口规划（重点）

**NAT 机器上默认端口是连不通的。** 例如服务商只映射了 `47451-47470`，
那 addipv6 装到默认 `8688`、节点用 `40000` 起，**面板和节点都访问不到**。

所以 `[3/7]` 这一步会交互式地把端口全部定下来：

```
── 网络环境与端口规划 ──
! 检测到 NAT 环境
    本机 IPv4 = 172.16.61.49（私网地址）
    公网出口 IP = 188.253.125.104

  只有服务商映射到公网的端口，外部才访问得到。

  服务商映射的端口范围 [47451-47470]:
  ✓ 端口范围：47451-47470（共 20 个）

  范围内已占用的端口：
      47451  sshd
      47452  x-ui
      47453  xray
      47454  addipv6
      47455  xray

  端口映射方式
    1) 公网端口 = 内部端口    (常见)
    2) 公网端口 ≠ 内部端口

── 端口分配 ──
  addipv6 面板端口 [47456]:
  ✓ addipv6 面板：内部 47456  →  公网 47456

  节点端口
    要开几个协议 [1]: 1
    内部监听端口起始值 [40000]:
  ✓ 节点端口：
      协议 1   内部 40000  →  公网 47457
```

**范围里已被占用的端口会自动识别并避开**（能看到是谁占的），不会撞车。

规划完会生成一张速查表，装节点时照着填：

```
══════════ 端口速查（装节点时对照填） ══════════
  addipv6 面板        内部 47456   公网 47456
  节点协议 1          内部 40000   公网 47457
  允许范围 47451-47470   映射方式 公网=内部
════════════════════════════════════════════════
```

### 上游脚本的交互被完整保留

**本套件不替上游脚本做决定**，端口由本脚本收集，其余配置项全部交给上游脚本问你。

**addipv6 —— 两种模式**

```
请选择安装方式：

  1) 进入 addipv6 官方菜单
     装 / 更新 / 卸载 / 启停 / 改密码 / 改端口 都在里面
     NAT 提醒：装完必须再选「10) 改端口」改成 47456

  2) 自动安装并把端口直接配好  (推荐)
     端口已是 47456，装完即用，不用再改
```

非 NAT 机器上默认推荐 1；**NAT 机器上默认推荐 2**，因为官方菜单默认装到 8688 公网访问不到。

**xray-cf-lite —— 官方交互流程 + 端口对照表**

它没有配置文件模式，所以给出精确的对应关系，其余全部由它问你：

```
xray-cf-lite 是纯交互脚本，没有配置文件模式。
它的每一步要填什么，对应关系如下：

    协议           「内部监听端口」填   「外部映射端口」填
    第 1 个        40000               47457

    外部映射端口必须是 47451-47470 内的值
    它会被写进 Cloudflare Origin Rules，填错节点直接连不上

  接下来终端完全交给它，照着上面的表填。
```

**fscarmen/sing-box —— 默认走它的官方菜单，不删任何一步**

```
fscarmen/sing-box 的官方交互流程会被完整保留。
语言、协议选择、域名、订阅、Argo 全部由你在它的菜单里决定。

    它问的项                      填这个值
    起始端口 START_PORT           47457

    ★ NAT 机器：起始端口必须在 47451-47470 内

    1) 进入它自己的交互流程                     (默认，推荐)
       配置项全部由它问你，本脚本不插手

    2) 用本脚本收集的参数生成配置，直接装好
       跳过它的菜单，端口/协议由本脚本写入 config.conf
       想完全自动化、不想一步步点的时候用
```

**注意 fscarmen 的默认是 1（进入它的交互流程）** —— 它的语言选择、协议选择、
域名、订阅、Argo 开关等全部保留，本脚本只在旁边给出端口值。
选 2 才会生成 `config.conf` 走 `-f` 非交互模式。

**节点脚本的交互式选择配置不会被删除或跳过。**

### ⚠️ 必须用 `bash <(curl ...)` 方式运行

```bash
# ✅ 正确 —— stdin 是终端，交互正常
bash <(curl -fsSL https://raw.githubusercontent.com/<你>/sb-v6-suite/main/install.sh)

# ❌ 错误 —— stdin 变成脚本自身内容，所有 read 都会失败
curl -fsSL https://raw.githubusercontent.com/<你>/sb-v6-suite/main/install.sh | bash
```

第二种写法下，子进程的 stdin 是管道，**任何 `read` 都读不到你的输入**，
上游脚本也会因此静默走默认值 —— 表现就是「交互界面不见了」。

本套件对这一点做了两层防护：

1. **所有交互显式指向 `/dev/tty`**，不依赖 `[ -t 0 ]` 判断
2. **启动时检测终端**，拿不到就明确告诉你原因和正确用法，而不是默默退化

```
✓ 终端可交互（/dev/tty 可用）
```

或

```
! 找不到 /dev/tty —— 所有交互会退化为默认值
  常见原因：脚本是通过管道运行的，例如
    curl -fsSL .../install.sh | bash
  请改用下面这种方式运行，交互就正常了：
    bash <(curl -fsSL <本脚本地址>)
```

---

## 非交互安装

全部用默认值：

```bash
bash install.sh --yes
```

指定参数：

```bash
bash install.sh \
  --node=fscarmen \
  --addipv6-port=9000 \
  --start-port=40000
```

### 参数表

| 参数 | 默认 | 说明 |
|---|---|---|
| `-y, --yes` | — | 全程默认值，不提问 |
| `--node=NAME` | 交互选择 | `xray` / `fscarmen` / `none` |
| `--addipv6-port=PORT` | `9000` | addipv6 面板端口；占用时自动换 |
| `--start-port=PORT` | `40000` | 节点协议起始端口 |
| `--skip-precheck` | — | 跳过 IPv6 路由验证（不推荐） |
| `--skip-addipv6` | — | 只装节点 |
| `--no-restore-service` | — | 不创建开机恢复服务 |
| `-V, --version` | — | 显示版本 |
| `-h, --help` | — | 显示帮助 |

---

## 节点脚本怎么选

| | `--node=xray` | `--node=fscarmen` |
|---|---|---|
| 来源 | [byJoey/xray-cf-lite](https://github.com/byJoey/xray-cf-lite) | [fscarmen/sing-box](https://github.com/fscarmen/sing-box) |
| 协议 | vless / trojan / vmess | Reality / Hysteria2 / TUIC / Trojan / SS / AnyTLS / ShadowTLS / VMess / VLESS / NaiveProxy |
| 特点 | 最小化，Cloudflare 隐藏源站，NAT / 低配友好 | 协议最全，5700+ stars，活跃维护 |
| 适合 | 只想快速有一个能用的节点 | 想要多种协议、长期维护 |

**建议先只开一个协议（VLESS + Reality 最稳），跑通了再加。**

安装时两个上游脚本都是**交互式**的，`install.sh` 会把终端交给它们，按提示填写即可。

---

## 安装后要做什么

### 1. 在面板里设置出口

1. 打开 `http://<服务器IP>:9000`
2. 选网卡 → 填数量 → **「随机生成」**
3. **「加到网卡」**
4. 勾中想用的地址 → **「设为出口」**

> ⚠️ 面板默认监听 `0.0.0.0`。建议改到 `127.0.0.1`，用 SSH 隧道访问：
> ```bash
> ssh -L 9000:127.0.0.1:9000 root@你的服务器
> ```

### 2. 立刻验证

```bash
bash verify.sh
```

或者手动三条：

```bash
ip -6 route show default                      # ① 看 src 是不是你选的
ip -6 route get 2a00:1450:4001:82f::200e      # ② 内核实际会用的源
curl -6 -s https://api64.ipify.org            # ③ ★ 真实出口 IP
```

**③ 出不来 = 选到了坏地址，立刻 `bash rollback.sh`。**

### 3. 确认开机恢复已启用

```bash
systemctl is-enabled addipv6-restore
systemctl status addipv6-restore
journalctl -u addipv6-restore -n 50
```

> **不装这个，重启后 51 个地址和出口设置全部丢失。** 这是最容易漏的一步。

---

## 体检与回滚

### `verify.sh` — 只读体检

```bash
bash verify.sh
```

检查 10 项：套件状态、权限、IPv6 地址、出口源地址、v6/v4 连通性、
addipv6 进程与记录、开机恢复服务、节点进程、监听端口、**DNS 污染**。

### `rollback.sh` — 出口恢复

```bash
bash rollback.sh              # 交互式
bash rollback.sh --status     # 只看状态
bash rollback.sh --reset      # 去掉默认路由的 src
bash rollback.sh --prune      # 附加清理多余地址
```

**SSH 走 IPv4 的话，IPv6 出口炸了 SSH 通常还在，救援窗口是有的** —— 但操作前还是建议先确认服务商面板的 VNC / 救援模式能用。

---

## 端口规划

安装时请避开 NAT 端口映射段。示例：

| 用途 | 端口 |
|---|---|
| SSH | 47451 |
| x-ui 面板 | 47452 |
| x-ui 入站 | 47453 / 47455 |
| addipv6 面板 | 9000 |
| 节点脚本 | 40000 起 |

---

## 常见问题

### IPv6 出口不通了

```bash
bash rollback.sh --reset
```

### 重启后地址全没了

开机恢复服务没装或没启用：

```bash
systemctl enable --now addipv6-restore.service
addipv6 restore          # 手动先恢复一次
```

### 节点能连上但某些站点打不开

先查 DNS 是否被劫持。`verify.sh` 第 10 项会检测。

有些上游会劫持 `8.8.8.8` / `1.1.1.1` 的查询（返回同一个中继 IP），
但 `9.9.9.9` / `208.67.222.222` 是干净的。**在节点配置里改用 9.9.9.9。**

### 想每个协议走不同出口 IP

那需要额外的分发层，本套件不做。默认路由改的是全机共用的源地址。

### 上游脚本重装会不会冲掉出口设置

**不会。** 出口绑定在**内核路由**里，不在节点的 `config.json` 里。
上游脚本重建配置时不会碰到它 —— 这是走内核层而非配置层的额外好处。

---

## 目录结构

```
sb-v6-suite/
├── install.sh     主安装脚本（交互 + 非交互）
├── verify.sh      只读体检
├── rollback.sh    出口回滚
└── README.md
```

安装后会在服务器上生成：

```
/etc/sb-v6-suite/state.json           本次安装的参数与探测结果
/etc/sb-v6-suite/install.log          安装日志
/etc/systemd/system/addipv6-restore.service   开机恢复服务
```

---

## 设计说明

**为什么不做节点配置层的适配？**

因为没必要。`addipv6` 的「设为出口」实际执行的是
（见 [`netif_linux.go`](https://github.com/byJoey/addipv6/blob/main/internal/netif/netif_linux.go)）：

```go
route := &netlink.Route{ ..., Src: net.IP(src.AsSlice()) }
netlink.RouteReplace(route)
```

它写的是**内核默认路由的 `src` 字段**。节点进程只是普通进程，
`connect()` 时源地址由内核按路由表决定 —— **自动继承，零配置**。

**代价**：默认路由全机共用，所以同时只能有一个 IPv6 出口。
需要「多用户多 IP」时必须额外加分发层。

---

## 许可

MIT