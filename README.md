# xraycli

**English** | [简体中文](./README_zh.md)

A tiny, **user-scope** command-line manager for an [Xray-core](https://github.com/XTLS/Xray-core)
local proxy. One installer, one control script, one *user* systemd service —
everything lives under your `$HOME`. No `sudo`, no system files touched, and a
clean one-command uninstall.

```
install.sh  →  downloads the right Xray-core for your CPU, sets up a local
               SOCKS + HTTP proxy on free ports, and installs `xraycli`.
xraycli     →  start / stop / restart / status / enable / logs / nodes / uninstall
```

---

## Highlights

- **Pick your core — Xray or sing-box.** Choose at install (`--core` or the
  wizard). Xray is the default; **sing-box** additionally runs **hysteria2 with
  Salamander obfs**. Switch anytime with `xraycli core sing-box`.
- **User scope only.** Binaries in `~/.local/share`, config in `~/.config`,
  logs in `~/.local/state`, a `--user` systemd unit, and the `xraycli` command
  in `~/.local/bin`. Nothing goes to `/etc`, `/usr`, or any system unit.
- **Auto architecture detection.** `install.sh` reads `uname` and pulls the
  matching release (`x86_64`, `arm64`, `armv7`, `i386`, `s390x`, …; Linux & macOS).
- **Username-derived ports.** The SOCKS/HTTP ports are a deterministic function
  of `$USER` (a `cksum` hash into the `20000–27999` window), so the same user
  always gets the same pair across reinstalls and machines — and different users
  land on different ports. A busy port just bumps `+1`. Override with
  `--socks-port` / `--http-port`, or fall back to a plain free-port scan with
  `--no-user-port`.
- **systemd user service** with auto-restart, plus a manual fallback when no
  user session bus is available.
- **Shell integration.** A small, clearly-marked block is appended to
  `~/.bashrc` that puts `~/.local/bin` on `PATH` (so `xraycli` is on your path).
- **Clean uninstall.** `xraycli uninstall` removes the service, all data dirs,
  the `~/.bashrc` block, and the command itself.

---

## Install

### One line (recommended)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/kaln27/xraycli/main/install.sh)
```

That single command bootstraps everything: it installs missing dependencies
(`curl`/`unzip`/`jq`) if a package manager is available, downloads the right
Xray-core for your CPU, fetches the `xraycli` control script, picks free ports,
and sets up the user service. No `git clone` needed. Pass installer options
straight through, e.g. `… /install.sh) --no-service`.

> Prefer `bash <(curl …)` over `curl … | bash` — it keeps your terminal on
> stdin, so confirmation prompts still work.

When run interactively, the installer first asks **which core** to install
(Xray or sing-box; default Xray), then at the end runs a short **setup wizard**
that offers to (1) import one or more subscriptions, (2) start the proxy and
enable boot auto-start, and (3) route Claude Code / Codex through it. Every step is optional
and repeatable later; skip the wizard (and the core prompt) with `--no-wizard`,
or preselect the core with `--core sing-box`.

### From a checkout

```bash
git clone https://github.com/kaln27/xraycli.git
cd xraycli
./install.sh
```

Either way, reload your shell so `PATH` and the helpers apply:

```bash
source ~/.bashrc
```

### Installer options

| Option | Meaning |
| --- | --- |
| `--core NAME` | Proxy core: `xray` (default) or `sing-box` (adds hy2 + Salamander obfs) |
| `--version vX.Y.Z` | Pin a specific core version (default: latest) |
| `--socks-port N` | Preferred SOCKS port (default: derived from `$USER`) |
| `--http-port N` | Preferred HTTP port (default: SOCKS base + 1) |
| `--no-user-port` | Don't derive ports from `$USER`; scan from `10808`/`10809` |
| `--listen ADDR` | Local listen address (default: `127.0.0.1`) |
| `--no-service` | Skip installing/enabling the systemd user service |
| `--no-bashrc` | Do not modify `~/.bashrc` |
| `--no-deps` | Do not auto-install missing dependencies |
| `--no-wizard` | Skip the interactive setup wizard at the end |
| `--mirror PREFIX` | Prefix prepended to the GitHub download URL (for CN mirrors) |

---

## Usage

```text
Lifecycle
  xraycli start | stop | restart | status
  xraycli enable        # start now + on login (enables systemd linger)
  xraycli disable
  xraycli log [service|error|access]
  xraycli test          # confirm the proxy reaches the internet (prints egress IP)

Nodes / subscription
  xraycli add '<share-link>'      # add a node from a share link   (import: see below)
  xraycli sub add '<url>'         # subscribe + import its nodes (repeatable)
  xraycli sub list                # subscriptions with their node counts
  xraycli sub rm <#|url>          # unsubscribe + drop that subscription's nodes
  xraycli sub set '<url>'         # make this the only subscription
  xraycli sub clear               # forget every subscription (keeps the nodes)
  xraycli update                  # re-fetch every subscription, rebuild the list
  xraycli list                    # list saved nodes ('●' = active)
  xraycli use <index|name>        # select the active node
  xraycli remove <index|name>
  xraycli current
  xraycli direct                  # use no proxy node (pass-through)

Config
  xraycli port                    # print local proxy ports
  xraycli core [show|xray|sing-box]   # show / switch the proxy core
  xraycli config [show|path|edit|regen]
  xraycli version

App integration
  xraycli claude [on|off]         # write/remove HTTP proxy in ~/.claude/settings.json
  xraycli codex  [on|off]         # write/remove HTTP proxy in ~/.codex/.env

Maintenance
  xraycli uninstall [-y] [--keep-config] [--disable-linger]
```

### Point programs at the proxy

`xraycli port` prints the local ports — HTTP at `127.0.0.1:<http>`, SOCKS5 at
`127.0.0.1:<socks>`. Point any app at those, e.g.:

```bash
curl -x "http://127.0.0.1:$(xraycli port | awk '/http/{print $2}' | cut -d: -f2)" https://api.ip.sb/ip
```

or export the proxy vars for your shell yourself:

```bash
export http_proxy=http://127.0.0.1:<http> https_proxy=http://127.0.0.1:<http>
export all_proxy=socks5://127.0.0.1:<socks>
```

### Route Claude Code / Codex through the proxy

**The one-command way** — xraycli writes the current HTTP proxy into the right
file for you (and can remove it again):

```bash
xraycli claude        # -> ~/.claude/settings.json   (merges into its "env" block)
xraycli codex         # -> ~/.codex/.env
xraycli claude off    # remove the proxy vars again (codex off likewise)
```

It always uses this install's live HTTP port, preserves any other settings in
those files, and reminds you to restart the app. The manual equivalent, if you
prefer to edit by hand:

Both tools honour the standard `HTTP_PROXY` / `HTTPS_PROXY` variables — point them
at xraycli's **HTTP** inbound (the port from `xraycli port`; `10809` below is just
the default — use yours). Make sure the proxy is up first: `xraycli status` / `xraycli test`.

**Claude Code** — `~/.claude/settings.json` applies its `env` block to every session:

```json
{
  "env": {
    "HTTP_PROXY": "http://127.0.0.1:10809",
    "HTTPS_PROXY": "http://127.0.0.1:10809"
  }
}
```

If the file already exists, merge just the `env` block into it (keep it valid JSON).

**Codex** — `~/.codex/.env`, one `KEY=value` per line:

```dotenv
HTTP_PROXY=http://127.0.0.1:10809
HTTPS_PROXY=http://127.0.0.1:10809
```

> Find the exact port with `xraycli port`. To use SOCKS5 instead of the HTTP
> inbound, set the value to `socks5://127.0.0.1:<socks>`.

---

## On-disk layout

| Path | Contents |
| --- | --- |
| `~/.local/bin/xraycli` | the control script |
| `~/.local/share/xraycli/core/` | `xray` binary + `geoip.dat` / `geosite.dat` |
| `~/.config/xraycli/config.json` | generated Xray config |
| `~/.config/xraycli/xraycli.env` | listen address, ports, version |
| `~/.config/xraycli/nodes.json` | saved server nodes |
| `~/.config/xraycli/active_outbound.json` | outbound used by the active node |
| `~/.local/state/xraycli/*.log` | access / error logs |
| `~/.config/systemd/user/xraycli.service` | the user service unit *(systemd mode only)* |

---

## How the service runs (systemd vs self-managed)

`enable`/`start` pick a control method automatically:

- **systemd user service** — used when the systemd `--user` manager's unit
  directory is under your `$HOME`. `enable` writes `xraycli.service`, turns on
  linger, and starts on boot. This is the normal case.
- **self-managed supervisor** — used when systemd isn't available, or when its
  unit directory is **not** under your `$HOME` (e.g. you're `root` with a custom
  `$HOME`, so the manager only scans `/root/.config/systemd/user`). Instead of
  writing anything outside your home, xraycli runs Xray under its own small
  supervisor (restarts it if it crashes) with **everything kept under `$HOME`**:

  | Path | Contents |
  | --- | --- |
  | `~/.local/state/xraycli/supervisor.pid` | the supervisor process |
  | `~/.local/state/xraycli/xray.pid` | the running Xray process |
  | crontab `@reboot` entry (tagged `# xraycli-autostart`) | boot auto-start |

  Force this mode anywhere with `XRAYCLI_NO_SYSTEMD=1`.

Both modes present the identical `start`/`stop`/`restart`/`status`/`enable`/
`disable` interface, and `uninstall` cleans up whichever was used.

---

## Subscriptions & node import

`update` / `import` **auto-detect** the subscription shape from its content
(not from the URL), so the same command handles both formats:

| Format | What it looks like | How it's parsed |
| --- | --- | --- |
| **base64 / raw** | a (base64-wrapped) list of `vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://` links | decoded, one node per link |
| **Clash** | a YAML doc with a `proxies:` list | each proxy under `proxies:` becomes a node |
| **Clash + providers** | a YAML doc with a `proxy-providers:` block (with or without an inline `proxies:` list) | each provider's `url:` is fetched and its `proxies:` parsed too — inline and provider nodes are merged |

For the `proxy-providers` case, xraycli reads each provider's own `url:` (not the
`health-check` URL), fetches it, and parses the `proxies:` it returns. Multiple
providers are all expanded and combined.

```bash
xraycli sub add 'https://example.com/sub/xxxx'   # subscribe + import its nodes
xraycli sub add 'https://other.com/clash/yyyy'   # repeat for as many as you like
xraycli sub list                                  # see them, numbered, with node counts
xraycli update                                    # re-fetch them all, rebuild the list
# or one-off, without subscribing:
xraycli import 'https://example.com/clash/xxxx'
xraycli import ./my-nodes.txt                      # also works on a local file
xraycli add 'vless://…#my-node'                    # add a single share link
```

### Multiple subscriptions

`sub add` is repeatable — every subscription's nodes live in one list, and a
single `xraycli update` re-fetches all of them. When more than one is in play,
`list` grows a `SUB` column with each node's subscription number from
`sub list`. Names that collide across subscriptions get a `#2` suffix.

`update` rebuilds every subscription's nodes and keeps your previously active
node selected if it still exists (REALITY `shortId`/`spiderX` that rotate per
fetch are picked up automatically); otherwise it selects the first node. A
subscription that fails to fetch is reported and skipped — the others still
update.

Nodes you added by hand with `xraycli add` are never touched by `update`,
`import` or `sub set`. `sub rm <#>` drops a subscription along with exactly the
nodes that came from it; `sub clear` forgets the URLs but leaves the nodes.

### Supported node protocols

Both cores run **VLESS** (incl. REALITY + XTLS-Vision), **VMess**, **Trojan**,
**Shadowsocks**, over `tcp` / `ws` / `grpc` with `tls` / `reality`, plus
**Hysteria2** (`hysteria2://` / `hy2://` links and Clash `type: hysteria2`, incl.
port-hopping). The difference is **obfs** and a few extra protocols:

| Node | Xray | sing-box |
| --- | --- | --- |
| VLESS / VMess / Trojan / Shadowsocks | ✅ | ✅ |
| Hysteria2 (no obfs) | ✅ | ✅ |
| **Hysteria2 + Salamander obfs** | ❌ skipped | ✅ |

> **Why obfs needs sing-box.** Xray-core has **no Salamander obfs**
> ([XTLS/Xray-core#5712](https://github.com/XTLS/Xray-core/issues/5712), *not planned*):
> such a node would load but silently fail, so under Xray it is **skipped** with a
> reason pointing you to `xraycli core sing-box`. sing-box runs it natively.
> (Xray 26.x also removed blanket `skip-cert-verify`; sing-box keeps `tls.insecure`.)

Import **auto-detects** which node types the active core can run and **skips** the
rest with a clear report (`skipped N node(s) the '<core>' core can't run: …`).
Switching core and re-running `xraycli update` re-evaluates previously-skipped nodes.

Each stored node is `{ "name": …, "descriptor": { …neutral node fields… } }` in
`~/.config/xraycli/nodes.json`; the active core compiles the descriptor to its own
config on `use`/`regen`.

---

## Uninstall

```bash
xraycli uninstall            # prompts for confirmation
xraycli uninstall -y         # no prompt
./uninstall.sh               # works even if ~/.local/bin isn't on PATH
```

This stops and removes the service, deletes all `xraycli` data directories,
strips the block from `~/.bashrc`, and removes the command. User *linger* is
left enabled by default (it is user-global and other services may rely on it);
pass `--disable-linger` to turn it off too.

---

## Requirements

`bash`, `curl` or `wget`, `unzip`. `jq` is needed for node management, and
`systemd --user` for the service (a manual `nohup` fallback is used otherwise).

## License

[MIT](./LICENSE). Xray-core is downloaded at install time under its own license.
