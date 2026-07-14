# xraycli

[English](./README.md) | **简体中文**

一个小巧的、**纯用户级**（user-scope）的 [Xray-core](https://github.com/XTLS/Xray-core)
本地代理管理命令行工具。一个安装脚本、一个控制脚本、一个用户级服务 —— 所有文件都放在你的
`$HOME` 下。不需要 `sudo`，不动任何系统文件，并且支持一条命令彻底卸载。

```
install.sh  →  按 CPU 架构下载对应的 Xray-core，在空闲端口上建立本地
               SOCKS + HTTP 代理，并安装 xraycli。
xraycli     →  启动 / 停止 / 重启 / 状态 / 开机自启 / 日志 / 节点 / 卸载
```

---

## 特性

- **只在用户级**：二进制在 `~/.local/share`，配置在 `~/.config`，日志在
  `~/.local/state`，命令 `xraycli` 在 `~/.local/bin`。不写入 `/etc`、`/usr` 或任何系统服务。
- **自动识别架构**：`install.sh` 通过 `uname` 自动拉取匹配的版本
  （`x86_64`、`arm64`、`armv7`、`i386`、`s390x` …；支持 Linux 与 macOS）。
- **端口与用户名绑定**：SOCKS/HTTP 端口由 `$USER` 确定性地推导而来（用 `cksum` 哈希映射到
  `20000–27999` 区间），同一用户在任何机器、任何次重装都拿到同一对端口，不同用户则自然错开；
  被占用时自动 `+1` 探测。可用 `--socks-port` / `--http-port` 覆盖，或用 `--no-user-port`
  退回普通的空闲端口扫描。
- **两种服务方式**：优先用 systemd 用户服务（带崩溃自动重启）；当 systemd 不可用、或其单元目录
  不在你的 `$HOME` 下时，自动改用 xraycli 内置的守护进程（同样自动重启），一切仍留在 `$HOME` 内。
- **Shell 集成**：向 `~/.bashrc` 追加一小段带标记的内容，把 `~/.local/bin` 加入 `PATH`（让 `xraycli` 可直接调用）。
- **干净卸载**：`xraycli uninstall` 会移除服务、所有数据目录、`~/.bashrc` 里的片段以及命令本身。

---

## 安装

### 一行命令（推荐）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/kaln27/xraycli/main/install.sh)
```

这一条命令会自动完成所有事情：在有包管理器时自动安装缺失的依赖（`curl`/`unzip`/`jq`），
按 CPU 架构下载对应的 Xray-core，拉取 `xraycli` 控制脚本，挑选空闲端口，并配置好用户级服务。
**不需要 `git clone`**。安装参数可直接追加，例如 `… /install.sh) --no-service`。

> 建议用 `bash <(curl …)` 而不是 `curl … | bash`：前者会保留终端 stdin，交互确认才能正常工作。

在交互式运行时，安装脚本最后会进入一个简短的**设置向导**，依次引导你：(1) 导入订阅，
(2) 启动代理并设为开机自启，(3) 把 Claude Code / Codex 接到代理上。每一步都是可选的、
以后也能单独再来一遍；想整体跳过就加 `--no-wizard`。

### 从源码安装

```bash
git clone https://github.com/kaln27/xraycli.git
cd xraycli
./install.sh
```

无论哪种方式，装完后都重新加载一下 shell，让 `PATH` 与辅助函数生效：

```bash
source ~/.bashrc
```

### 安装参数

| 参数 | 含义 |
| --- | --- |
| `--version vX.Y.Z` | 指定 Xray-core 版本（默认：最新） |
| `--socks-port N` | 首选 SOCKS 端口（默认：由 `$USER` 推导） |
| `--http-port N` | 首选 HTTP 端口（默认：SOCKS 基准端口 + 1） |
| `--no-user-port` | 不按 `$USER` 推导端口；从 `10808`/`10809` 起扫描 |
| `--listen ADDR` | 本地监听地址（默认：`127.0.0.1`） |
| `--no-service` | 不安装/启用系统服务 |
| `--no-bashrc` | 不修改 `~/.bashrc` |
| `--no-deps` | 不自动安装缺失依赖 |
| `--no-wizard` | 跳过安装结束时的交互式设置向导 |
| `--mirror PREFIX` | 给 GitHub 下载地址加前缀（国内镜像加速用） |

---

## 快速上手（使用示例）

下面是从零开始的完整流程。

### 1. 添加订阅并拉取节点

支持两种订阅格式，**根据内容自动识别**（不看链接后缀）：base64（传统分享链接列表）与 Clash（YAML）。

```bash
# 保存订阅地址，然后拉取 / 更新节点列表
xraycli sub set 'https://你的机场/clash/xxxxxx'
xraycli update
```

输出示例：

```
==> updating from subscription: https://你的机场/clash/xxxxxx
==> detected subscription format: clash
 ✓  imported 1 node(s) [clash, mode=replace]
 !  skipped 1 node(s) Xray-core cannot run (hysteria2/tuic/…):
    - hy (hysteria2)
 ✓  active node set to: vless-reality-hk01
  [0] * vless-reality-hk01  (vless)
```

> 说明：Xray-core 不支持 hysteria2 / tuic 等协议，导入时会**自动跳过并明确提示**，只保留可用节点。

不保存、只临时导入一次（URL 或本地文件都行）：

```bash
xraycli import 'https://你的机场/sub/xxxxxx'   # base64 订阅
xraycli import ./my-nodes.txt                   # 本地文件
```

添加单个分享链接：

```bash
xraycli add 'vless://…#香港-01'
```

以后想更新节点，只要再跑一次（会自动保留当前选中的节点；REALITY 每次刷新变化的
`shortId`/`spiderX` 也会自动跟着更新）：

```bash
xraycli update
```

### 2. 查看节点

```bash
xraycli list
```

```
  [0] * vless-reality-hk01  (vless)
  [1]   trojan-jp02         (trojan)
  [2]   ss-us03             (shadowsocks)

  * = active   |   switch with: xraycli use <index|name>
```

切换当前使用的节点（用序号或名字都行，切换后会自动重启生效）：

```bash
xraycli use 1                 # 按序号
xraycli use vless-reality-hk01 # 按名字
xraycli current               # 打印当前节点
xraycli remove trojan-jp02    # 删除某个节点
xraycli direct                # 不走任何节点（直连透传）
```

### 3. 启动 & 查看状态

```bash
xraycli enable     # 现在就启动 + 开机自启（首选，长期运行用这个）
# 或者只临时启动本次：
xraycli start
```

查看状态：

```bash
xraycli status
```

```
xraycli status
  version : xraycli 0.1.0  /  xray 26.3.27
  listen  : 127.0.0.1   socks 10808   http 10809
  node    : vless-reality-hk01
  running : running
  mode    : systemd user service
```

验证代理确实能出网（会打印出口 IP）：

```bash
xraycli test
```

```
==> probing egress IP through http://127.0.0.1:10809 ...
 ✓  proxy works — egress IP: 203.0.113.45
```

其它常用：

```bash
xraycli stop        # 停止
xraycli restart     # 重启
xraycli log         # 跟随日志（error / access 也可：xraycli log error）
xraycli port        # 打印本地代理端口
```

### 4. 让程序走代理

`xraycli port` 会打印本地端口（HTTP `127.0.0.1:<http>`、SOCKS5 `127.0.0.1:<socks>`）。
把应用指过去即可，或者自己在 shell 里导出代理环境变量：

```bash
export http_proxy=http://127.0.0.1:<http> https_proxy=http://127.0.0.1:<http>
export all_proxy=socks5://127.0.0.1:<socks>
curl https://api.ip.sb/ip      # 走代理
```

### 让 Claude Code / Codex 走代理

**一条命令搞定** —— xraycli 会把当前的 HTTP 代理写进对应文件（也能再移除）：

```bash
xraycli claude        # -> ~/.claude/settings.json（合并进它的 "env" 块）
xraycli codex         # -> ~/.codex/.env
xraycli claude off    # 再把代理变量移除（codex off 同理）
```

它始终用本次安装的实际 HTTP 端口，保留文件里其它设置，并提示你重启对应应用。若你更想手动改，下面是等价做法：

这两个工具都认标准的 `HTTP_PROXY` / `HTTPS_PROXY` 变量 —— 把它们指向 xraycli 的 **HTTP** 入站
（端口用 `xraycli port` 查看；下面的 `10809` 只是默认值，请换成你自己的）。配置前先确认代理已在运行：
`xraycli status` / `xraycli test`。

**Claude Code** —— `~/.claude/settings.json` 里的 `env` 会应用到每次会话：

```json
{
  "env": {
    "HTTP_PROXY": "http://127.0.0.1:10809",
    "HTTPS_PROXY": "http://127.0.0.1:10809"
  }
}
```

如果该文件已存在，只需把 `env` 这一段合并进去（保持 JSON 合法）。

**Codex** —— `~/.codex/.env`，每行一个 `KEY=value`：

```dotenv
HTTP_PROXY=http://127.0.0.1:10809
HTTPS_PROXY=http://127.0.0.1:10809
```

> 用 `xraycli port` 查看实际端口。若想用 SOCKS5 而非 HTTP 入站，把值改成
> `socks5://127.0.0.1:<socks>` 即可。

---

## 命令速查

```text
生命周期
  xraycli start | stop | restart | status
  xraycli enable         # 现在启动 + 开机自启
  xraycli disable        # 停止 + 取消开机自启
  xraycli log [service|error|access]
  xraycli test           # 验证能否出网（打印出口 IP）

节点 / 订阅       （自动识别 base64 与 Clash；跳过 Xray 不支持的协议）
  xraycli add '<分享链接>'    # 添加单个节点（vless:// vmess:// trojan:// ss://）
  xraycli sub set '<url>'     # 保存订阅地址
  xraycli sub show | clear    # 查看 / 清除订阅地址
  xraycli update              # 拉取已保存的订阅并重建节点列表
  xraycli import <url|文件>   # 临时导入（不保存）
  xraycli list                # 列出节点（'*' 为当前）
  xraycli use <序号|名字>     # 选择当前节点
  xraycli remove <序号|名字>  # 删除节点
  xraycli current             # 打印当前节点
  xraycli direct              # 不走任何节点（直连）

配置
  xraycli port                # 打印本地代理端口
  xraycli config [show|path|edit|regen]
  xraycli version

应用集成
  xraycli claude [on|off]     # 把 HTTP 代理写入/移除 ~/.claude/settings.json
  xraycli codex  [on|off]     # 把 HTTP 代理写入/移除 ~/.codex/.env

维护
  xraycli uninstall [-y] [--keep-config] [--disable-linger]
```

---

## 订阅与节点导入

`update` / `import` 会**根据内容自动识别**订阅格式（不看链接后缀），同一条命令两种格式通吃：

| 格式 | 长什么样 | 如何解析 |
| --- | --- | --- |
| **base64 / raw** | 一串（base64 包裹的）`vless://`、`vmess://`、`trojan://`、`ss://`、`hysteria2://` 链接 | 解码后每行一个节点 |
| **Clash** | 含 `proxies:` 列表的 YAML | `proxies:` 下每个代理转成一个节点 |
| **Clash + provider** | 含 `proxy-providers:` 块的 YAML（可有可无 inline `proxies:`） | 取每个 provider 的 `url:` 再请求一次，解析它返回的 `proxies:`；inline 与 provider 的节点合并 |

对于 `proxy-providers` 这种：xraycli 会取每个 provider **自己的** `url:`（不是 `health-check` 里的
url），请求它，再解析返回内容里的 `proxies:`。多个 provider 会全部展开并合并。

### 支持的节点协议

Xray-core 支持 **VLESS**（含 REALITY + XTLS-Vision）、**VMess**、**Trojan**、**Shadowsocks**，
传输可为 `tcp` / `ws` / `grpc` / `h2`，加密可为 `tls` / `reality`；另外还支持 **Hysteria2**
（`hysteria2://` / `hy2://` 链接与 Clash `type: hysteria2`，含 `ports` 端口跳跃）。

> **Hysteria2 注意 —— Salamander obfs 混淆。** Xray-core 支持 Hysteria2,但**不支持 Salamander
> obfs**（[XTLS/Xray-core#5712](https://github.com/XTLS/Xray-core/issues/5712),已 *not planned* 关闭）。
> 带 `obfs: salamander` 的节点即使配置能加载,连接也会静默失败,所以 xraycli 会**跳过**带 obfs 的
> hysteria2 节点并给出明确原因。**不带** obfs 的 hysteria2 节点可正常导入并使用。
>（另外:Xray 26.x 移除了一刀切的 `allowInsecure`/`skip-cert-verify`,该选项会被忽略 —— 服务器需要
> 一张对其 SNI 有效的证书。）

Xray-core **真正没有对应出站**的协议 —— `tuic`、`wireguard`、`ssr`、`snell`、`hysteria`(v1) 等 ——
在导入时会被**识别并跳过**,并给出明确提示(`add` 也会拒绝),而不会悄悄把配置弄坏,并显示
`skipped N node(s) Xray-core can't run: …` 逐条列出。

每个节点在 `~/.config/xraycli/nodes.json` 里以 `{ "name": …, "outbound": { …Xray 出站… } }` 的形式保存。

---

## 服务运行方式（systemd 与自管理）

`enable`/`start` 会自动选择控制方式：

- **systemd 用户服务** —— 当 systemd `--user` 管理器的单元目录就在你的 `$HOME` 下时使用。
  `enable` 会写入 `xraycli.service`、打开 linger 并设为开机自启。这是常见情况。
- **自管理守护进程** —— 当没有 systemd、或其单元目录**不在**你的 `$HOME` 下时使用
  （例如你是 `root` 但 `$HOME` 被改过，导致管理器只扫描 `/root/.config/systemd/user`）。此时
  xraycli 不会往 `$HOME` 之外写任何东西，而是用自带的小型守护进程来跑 Xray（崩溃自动重启），
  **所有文件仍全部在 `$HOME` 内**：

  | 路径 | 内容 |
  | --- | --- |
  | `~/.local/state/xraycli/supervisor.pid` | 守护进程 |
  | `~/.local/state/xraycli/xray.pid` | 正在运行的 Xray 进程 |
  | crontab `@reboot` 项（标记 `# xraycli-autostart`） | 开机自启 |

  用 `XRAYCLI_NO_SYSTEMD=1` 可在任何环境强制使用该模式。

两种模式对外命令完全一致（`start`/`stop`/`restart`/`status`/`enable`/`disable`），
`uninstall` 也会自动清理实际用到的那一种。

---

## 文件布局

| 路径 | 内容 |
| --- | --- |
| `~/.local/bin/xraycli` | 控制脚本 |
| `~/.local/share/xraycli/core/` | `xray` 二进制 + `geoip.dat` / `geosite.dat` |
| `~/.config/xraycli/config.json` | 生成的 Xray 配置 |
| `~/.config/xraycli/xraycli.env` | 监听地址、端口、版本 |
| `~/.config/xraycli/nodes.json` | 保存的节点 |
| `~/.config/xraycli/active_outbound.json` | 当前节点对应的出站 |
| `~/.local/state/xraycli/*.log` | access / error 日志 |
| `~/.config/systemd/user/xraycli.service` | 用户服务单元 *（仅 systemd 模式）* |

---

## 卸载

```bash
xraycli uninstall            # 交互确认
xraycli uninstall -y         # 不确认直接卸载
./uninstall.sh               # 即使 ~/.local/bin 不在 PATH 也能用
```

卸载会停止并移除服务、删除所有 xraycli 数据目录、清掉 `~/.bashrc` 里的片段，并删除命令本身。

---

## 依赖

`bash`、`curl` 或 `wget`、`unzip`。节点管理需要 `jq`；系统服务需要 `systemd --user`
（没有时会自动改用内置守护进程）。缺失的依赖会在安装时自动尝试安装。

## 许可证

[MIT](./LICENSE)。Xray-core 在安装时按其自身许可证下载。
