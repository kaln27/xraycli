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
  `~/.bashrc` that puts `~/.local/bin` on `PATH` and adds `proxyon` / `proxyoff`
  helpers to toggle this shell's proxy env vars.
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

When run interactively, the installer finishes with a short **setup wizard** that
offers to (1) import a subscription, (2) start the proxy and enable boot
auto-start, and (3) route Claude Code / Codex through it. Every step is optional
and repeatable later; skip the whole thing with `--no-wizard`.

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
| `--version vX.Y.Z` | Pin a specific Xray-core version (default: latest) |
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
  xraycli sub set '<url>'         # save a subscription URL
  xraycli sub show | clear
  xraycli update                  # fetch + parse the subscription (import: see below)
  xraycli list                    # list saved nodes ('*' = active)
  xraycli use <index|name>        # select the active node
  xraycli remove <index|name>
  xraycli current
  xraycli direct                  # use no proxy node (pass-through)

Config
  xraycli port                    # print local proxy ports
  xraycli config [show|path|edit|regen]
  xraycli version

App integration
  xraycli claude [on|off]         # write/remove HTTP proxy in ~/.claude/settings.json
  xraycli codex  [on|off]         # write/remove HTTP proxy in ~/.codex/.env

Maintenance
  xraycli uninstall [-y] [--keep-config] [--disable-linger]
```

### Point programs at the proxy

After `source ~/.bashrc`:

```bash
proxyon      # exports http_proxy/https_proxy/all_proxy for THIS shell
curl https://api.ip.sb/ip
proxyoff     # unset them again
```

Or configure an app directly with the ports shown by `xraycli port`
(SOCKS5 at `127.0.0.1:<socks>`, HTTP at `127.0.0.1:<http>`).

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
| **base64 / raw** | a (base64-wrapped) list of `vless://`, `vmess://`, `trojan://`, `ss://` links | decoded, one node per link |
| **Clash** | a YAML doc with a `proxies:` list | each proxy under `proxies:` becomes a node |

```bash
xraycli sub set 'https://example.com/sub/xxxx'   # save your subscription URL
xraycli update                                    # fetch + rebuild the node list
# or one-off, without saving:
xraycli import 'https://example.com/clash/xxxx'
xraycli import ./my-nodes.txt                      # also works on a local file
xraycli add 'vless://…#my-node'                    # add a single share link
```

`update` replaces the node list from the subscription and keeps your previously
active node selected if it still exists (REALITY `shortId`/`spiderX` that rotate
per fetch are picked up automatically); otherwise it selects the first node.

### Supported node protocols

Xray-core runs **VLESS** (incl. REALITY + XTLS-Vision), **VMess**, **Trojan**,
and **Shadowsocks**, over `tcp` / `ws` / `grpc` / `h2` with `tls` / `reality`.

Protocols Xray-core has **no outbound for** — `hysteria2`, `tuic`, `wireguard`,
`ssr`, … — are recognised and **skipped** on import with a clear report (and
refused by `add`), rather than silently breaking the config. If your
subscription mixes, say, a VLESS and a hysteria2 node, only the VLESS one is
imported and you'll see `skipped 1 node(s) …`.

Each stored node has the shape `{ "name": …, "outbound": { …Xray outbound… } }`
in `~/.config/xraycli/nodes.json`.

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
