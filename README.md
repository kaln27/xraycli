# xraycli

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
- **Auto free-port selection.** Two unused local ports are chosen for the SOCKS
  and HTTP inbounds so it never clashes with anything already listening.
- **systemd user service** with auto-restart, plus a manual fallback when no
  user session bus is available.
- **Shell integration.** A small, clearly-marked block is appended to
  `~/.bashrc` that puts `~/.local/bin` on `PATH` and adds `proxyon` / `proxyoff`
  helpers to toggle this shell's proxy env vars.
- **Clean uninstall.** `xraycli uninstall` removes the service, all data dirs,
  the `~/.bashrc` block, and the command itself.

---

## Install

From a checkout of this repo:

```bash
git clone <this-repo-url> xraycli
cd xraycli
./install.sh
```

Then reload your shell so `PATH` and the helpers apply:

```bash
source ~/.bashrc
```

### Installer options

| Option | Meaning |
| --- | --- |
| `--version vX.Y.Z` | Pin a specific Xray-core version (default: latest) |
| `--socks-port N` | Preferred SOCKS port (default: auto from `10808`) |
| `--http-port N` | Preferred HTTP port (default: auto from `10809`) |
| `--listen ADDR` | Local listen address (default: `127.0.0.1`) |
| `--no-service` | Skip installing/enabling the systemd user service |
| `--no-bashrc` | Do not modify `~/.bashrc` |
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
| `~/.config/systemd/user/xraycli.service` | the user service unit |

---

## Subscriptions & node import — not wired up yet

The lifecycle, service, ports, config generation, and node **management**
(`list` / `use` / `remove` / `current` / `direct`) are fully functional. The
only intentionally-empty part is turning a **share link** or a **subscription**
into node entries, because the exact format hasn't been decided yet.

When you're ready, the integration points are:

- `parse_share_link()` in `bin/xraycli` — takes a `vmess://` / `vless://` /
  `trojan://` / `ss://` URI and prints one node object.
- `parse_subscription()` in `bin/xraycli` — fetches the subscription URL and
  prints a JSON array of node objects.

Each node object just needs this shape (everything else already consumes it):

```json
{ "name": "my-node", "outbound": { /* a valid Xray outbound object */ } }
```

Tell the maintainer the **subscription type** (base64 link-list, Clash YAML,
SIP008, …) and the **node protocols** you use, and these two functions get
filled in — no other code changes required.

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
