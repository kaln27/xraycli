#!/usr/bin/env bash
#
# install.sh — user-scope installer for xraycli (an Xray-core proxy manager).
#
# What it does (everything stays under the invoking user's $HOME — nothing
# touches the system, no sudo/root is required):
#
#   * detects OS + CPU architecture and downloads the matching Xray-core release
#   * installs the core + geodata under  ~/.local/share/xraycli/core
#   * places the `xraycli` control script in  ~/.local/bin
#   * picks two local ports (SOCKS + HTTP) derived from $USER, +1 if busy
#   * generates an initial Xray config (pass-through until a node is added)
#   * installs a *user* systemd unit  ~/.config/systemd/user/xraycli.service
#   * appends a small, clearly-marked block to ~/.bashrc (adds ~/.local/bin to PATH)
#
# Re-running is safe (idempotent upgrade). Remove everything with:
#   xraycli uninstall        (or ./uninstall.sh)
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   --version <vX.Y.Z>   Install a specific Xray-core version (default: latest)
#   --socks-port <n>     Preferred SOCKS port   (default: derived from $USER)
#   --http-port  <n>     Preferred HTTP  port   (default: SOCKS base + 1)
#   --no-user-port       Do not derive ports from $USER; scan from 10808/10809
#   --listen <addr>      Local listen address   (default: 127.0.0.1)
#   --no-service         Do not install/enable the systemd user service
#   --no-bashrc          Do not modify ~/.bashrc
#   --no-wizard          Skip the interactive setup wizard at the end
#   --gh-proxy           Force GitHub downloads through the mirror (gh-proxy.org)
#   --no-gh-proxy        Force direct GitHub downloads (never use the mirror)
#   --mirror <prefix>    Use a custom mirror prefix instead of gh-proxy.org
#   -h, --help           Show this help
#
set -euo pipefail

# --------------------------------------------------------------------------- #
#  Constants & paths (XDG-based, all under $HOME)                             #
# --------------------------------------------------------------------------- #
readonly APP="xraycli"
readonly XRAY_REPO="XTLS/Xray-core"
readonly SINGBOX_REPO="SagerNet/sing-box"

# This project's repo — used to fetch the control script when install.sh is run
# piped (e.g. `bash <(curl -Ls .../install.sh)`) with no local checkout.
readonly REPO_SLUG="kaln27/xraycli"
readonly REPO_BRANCH="main"
: "${XRAYCLI_RAW_BASE:=https://raw.githubusercontent.com/$REPO_SLUG/$REPO_BRANCH}"

: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"

readonly BIN_DIR="$HOME/.local/bin"
readonly DATA_DIR="$XDG_DATA_HOME/$APP"
readonly CORE_DIR="$DATA_DIR/core"
readonly CONFIG_DIR="$XDG_CONFIG_HOME/$APP"
readonly STATE_DIR="$XDG_STATE_HOME/$APP"
readonly SYSTEMD_DIR="$XDG_CONFIG_HOME/systemd/user"
readonly ENV_FILE="$CONFIG_DIR/xraycli.env"
readonly SERVICE_NAME="$APP.service"
readonly BASHRC="$HOME/.bashrc"

# Tolerant of piped execution (bash <(curl …)), where BASH_SOURCE is a pipe and
# there is no local checkout — SCRIPT_DIR ends up empty and we fetch remotely.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

# --------------------------------------------------------------------------- #
#  Defaults / CLI options                                                     #
# --------------------------------------------------------------------------- #
XRAY_VERSION="latest"
CORE_KIND="xray"            # which proxy core to install: xray | sing-box
CORE_EXPLICIT=0            # 1 → user passed --core, so don't prompt
CORE_VERSION="latest"      # sing-box release tag (or 'latest')
PREF_SOCKS_PORT=""          # empty → derive from $USER (see user_port_base)
PREF_HTTP_PORT=""           # empty → derive from $USER (SOCKS base + 1)
USER_PORT=1                 # 1 → ports are a deterministic function of $USER
LISTEN_ADDR="127.0.0.1"
DO_SERVICE=1
DO_BASHRC=1
DO_DEPS=1
DO_WIZARD=1                 # 1 → run the interactive setup wizard at the end

# GitHub download routing. MIRROR is the effective prefix prepended to every
# github.com/raw.githubusercontent.com URL ("" = fetch directly). When flaky
# networks block GitHub, resolve_mirror() fills it with GH_PROXY_DEFAULT.
#   GH_PROXY_MODE: auto = probe GitHub, mirror only if unreachable
#                  on   = always mirror   ·   off = always direct
readonly GH_PROXY_DEFAULT="https://gh-proxy.org/"
GH_PROXY_MODE="auto"
MIRROR=""

# Username-derived port window. Same $USER always maps to the same SOCKS base,
# so ports are stable across reinstalls/machines. 20000–27998 (even) avoids the
# privileged (<1024) and Linux ephemeral (32768+) ranges. HTTP = base + 1.
PORT_WINDOW_START=20000
PORT_WINDOW_SLOTS=4000

# --------------------------------------------------------------------------- #
#  Pretty output                                                              #
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
  c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'
  c_blu=$'\033[34m'; c_dim=$'\033[2m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
else
  c_red=; c_grn=; c_ylw=; c_blu=; c_dim=; c_bld=; c_rst=
fi
info()  { printf '%s==>%s %s\n' "$c_blu"  "$c_rst" "$*"; }
ok()    { printf '%s ✓ %s %s\n' "$c_grn"  "$c_rst" "$*"; }
warn()  { printf '%s ! %s %s\n' "$c_ylw"  "$c_rst" "$*" >&2; }
die()   { printf '%s ✗ %s %s\n' "$c_red"  "$c_rst" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
install.sh — user-scope installer for xraycli (an Xray-core proxy manager)

Everything is installed under your $HOME; no system files are touched. The only
system-level action is auto-installing missing common tools (curl/unzip/jq) when
a package manager is available.

Usage:
  ./install.sh [options]
  bash <(curl -Ls https://raw.githubusercontent.com/kaln27/xraycli/main/install.sh) [options]

Options:
  --core <name>        Proxy core: xray (default) or sing-box. sing-box also runs
                       hysteria2 + Salamander obfs.
  --version <vX.Y.Z>   Install a specific core version (default: latest)
  --socks-port <n>     Preferred SOCKS port   (default: derived from $USER)
  --http-port  <n>     Preferred HTTP  port   (default: SOCKS base + 1)
  --no-user-port       Do not derive ports from $USER; scan from 10808/10809
  --listen <addr>      Local listen address   (default: 127.0.0.1)
  --no-service         Do not install/enable the systemd user service
  --no-bashrc          Do not modify ~/.bashrc
  --no-deps            Do not attempt to install missing dependencies
  --no-wizard          Skip the interactive setup wizard at the end
  --gh-proxy           Force GitHub downloads through the mirror (gh-proxy.org)
  --no-gh-proxy        Force direct GitHub downloads (never use the mirror)
  --mirror <prefix>    Use a custom mirror prefix instead of gh-proxy.org
  -h, --help           Show this help

By default GitHub reachability is probed first; the mirror engages only when
GitHub looks unreachable. Behind a firewall you can also fetch install.sh itself
through the mirror:
  bash <(curl -Ls https://gh-proxy.org/https://raw.githubusercontent.com/kaln27/xraycli/main/install.sh)
EOF
  exit "${1:-0}"
}

# --------------------------------------------------------------------------- #
#  Argument parsing                                                           #
# --------------------------------------------------------------------------- #
while [ $# -gt 0 ]; do
  case "$1" in
    --core)       CORE_KIND="${2:?}"; CORE_EXPLICIT=1; shift 2 ;;
    --version)    XRAY_VERSION="${2:?}"; CORE_VERSION="${2:?}"; shift 2 ;;
    --socks-port) PREF_SOCKS_PORT="${2:?}"; shift 2 ;;
    --http-port)  PREF_HTTP_PORT="${2:?}"; shift 2 ;;
    --no-user-port) USER_PORT=0; shift ;;
    --listen)     LISTEN_ADDR="${2:?}"; shift 2 ;;
    --mirror)     MIRROR="${2:?}"; shift 2 ;;
    --no-service) DO_SERVICE=0; shift ;;
    --no-bashrc)  DO_BASHRC=0; shift ;;
    --no-deps)    DO_DEPS=0; shift ;;
    --no-wizard)  DO_WIZARD=0; shift ;;
    --gh-proxy)   GH_PROXY_MODE=on; shift ;;
    --no-gh-proxy) GH_PROXY_MODE=off; shift ;;
    -h|--help)    usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$CORE_KIND" in
  xray) ;;
  sing-box|singbox) CORE_KIND="sing-box" ;;
  *) die "unknown --core '$CORE_KIND' (expected: xray or sing-box)" ;;
esac

# --------------------------------------------------------------------------- #
#  Helpers                                                                     #
# --------------------------------------------------------------------------- #
have() { command -v "$1" >/dev/null 2>&1; }

# Single temp dir, cleaned up once on exit (a RETURN trap would re-fire on every
# later function return and trip `set -u`).
TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

download() {  # download <url> <dest>
  local url="$1" dest="$2"
  if have curl; then
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url"
  elif have wget; then
    wget -q -O "$dest" "$url"
  else
    die "need curl or wget to download files"
  fi
}

fetch_stdout() {  # fetch_stdout <url> -> stdout
  if have curl; then curl -fsSL --retry 3 --connect-timeout 20 "$1"
  elif have wget; then wget -qO- "$1"
  else return 1; fi
}

# Can we reach GitHub directly? A cheap 1-byte GET of a raw file with a short
# cap. raw.githubusercontent.com is the right probe: releases sit behind a CDN
# that can resolve even when raw/api are blocked, and it's raw + api that the
# install actually stalls on.
github_reachable() {
  local u="https://raw.githubusercontent.com/$REPO_SLUG/$REPO_BRANCH/install.sh"
  if   have curl; then curl -fsS --max-time 6 -r 0-0 -o /dev/null "$u" 2>/dev/null
  elif have wget; then wget -q --timeout=6 --tries=1 -O /dev/null "$u" 2>/dev/null
  else return 0; fi   # no fetcher yet → don't force a mirror; download() will die later
}

# Decide the effective $MIRROR prefix for all GitHub downloads. Runs once, after
# ensure_deps (so curl/wget exist), before install_core.
resolve_mirror() {
  if [ -n "$MIRROR" ]; then info "using custom mirror: $MIRROR"; return; fi
  case "$GH_PROXY_MODE" in
    off) return ;;                                                    # forced direct
    on)  MIRROR="$GH_PROXY_DEFAULT"; info "GitHub proxy forced on: $MIRROR" ;;
    auto)
      info "Probing GitHub reachability"
      if github_reachable; then
        ok "GitHub reachable — downloading directly"
      else
        MIRROR="$GH_PROXY_DEFAULT"
        warn "GitHub looks unreachable — routing downloads via $MIRROR"
        warn "(force direct: --no-gh-proxy   ·   custom mirror: --mirror <prefix>)"
      fi ;;
  esac
}

latest_tag() {  # <owner/repo> -> latest release tag (e.g. v1.13.14)
  local repo="$1" tag
  # Direct API is primary: it names the true *latest release*.
  tag="$(fetch_stdout "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
         | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
  # Fallback when the API is unreachable (e.g. the mirror 403s api.github.com):
  # ls-remote the tag list — it inherits $MIRROR, so it works behind the proxy.
  if [ -z "$tag" ] && have git; then
    tag="$(git ls-remote --tags --refs "${MIRROR}https://github.com/$repo.git" 2>/dev/null \
           | awk -F/ '{print $NF}' | grep -E '^v?[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)"
  fi
  [ -n "$tag" ] && printf '%s\n' "$tag"
}

# Install packages via whatever system package manager exists. Uses sudo only if
# not root and sudo is available. Returns non-zero if it cannot install.
pkg_install() {
  local pkgs="$*" sudo=""
  [ "$(id -u)" -ne 0 ] && have sudo && sudo="sudo"
  if   have apt-get; then $sudo apt-get update -y >/dev/null 2>&1; $sudo apt-get install -y $pkgs
  elif have dnf;     then $sudo dnf install -y $pkgs
  elif have yum;     then $sudo yum install -y $pkgs
  elif have zypper;  then $sudo zypper --non-interactive install $pkgs
  elif have pacman;  then $sudo pacman -Sy --noconfirm $pkgs
  elif have apk;     then $sudo apk add $pkgs
  elif have brew;    then brew install $pkgs
  else return 1; fi
}

# Ensure the tools xraycli needs are present. unzip + a downloader are hard
# requirements at install time; jq is only needed later (subscriptions/nodes),
# so a missing jq is a warning, not fatal.
ensure_deps() {
  info "Checking dependencies"
  local missing=()
  have curl || have wget || missing+=(curl)
  if [ "$CORE_KIND" = sing-box ]; then have tar || missing+=(tar); else have unzip || missing+=(unzip); fi
  have jq    || missing+=(jq)
  if [ "${#missing[@]}" -eq 0 ]; then ok "all dependencies present"; return 0; fi

  if [ "$DO_DEPS" -eq 1 ]; then
    warn "missing: ${missing[*]} — attempting to install via the system package manager"
    if pkg_install "${missing[@]}"; then ok "dependencies installed"
    else warn "auto-install failed (no known package manager, or no permission)"; fi
  else
    warn "missing: ${missing[*]} (auto-install disabled via --no-deps)"
  fi

  have curl || have wget || die "curl or wget is required — please install one and re-run"
  if [ "$CORE_KIND" = sing-box ]; then
    have tar || die "tar is required to extract sing-box — please install it and re-run"
  else
    have unzip || die "unzip is required to extract Xray — please install it and re-run"
  fi
  have jq    || warn "jq not installed: subscription/node commands will need it (install jq later)"
}

port_in_use() {  # returns 0 when <port> is already listening
  local p="$1"
  if have ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
  elif have netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
  fi
  return 1
}

find_free_port() {  # find_free_port <start> [avoid]
  local start="$1" avoid="${2:-}" p
  for (( p=start; p<start+3000; p++ )); do
    [ "$p" = "$avoid" ] && continue
    port_in_use "$p" || { printf '%s\n' "$p"; return 0; }
  done
  die "could not find a free port starting at $start"
}

detect_asset() {  # echoes the Xray release asset name for this machine
  local os arch xos xarch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Linux)  xos="linux" ;;
    Darwin) xos="macos" ;;
    *) die "unsupported OS: $os (only Linux and macOS are supported)" ;;
  esac
  case "$arch" in
    x86_64|amd64)        xarch="64" ;;
    i386|i686)           xarch="32" ;;
    aarch64|arm64)       xarch="arm64-v8a" ;;
    armv7l|armv7|armhf)  xarch="arm32-v7a" ;;
    armv6l)              xarch="arm32-v6" ;;
    armv5*)              xarch="arm32-v5" ;;
    s390x)               xarch="s390x" ;;
    ppc64le)             xarch="ppc64le" ;;
    riscv64)             xarch="riscv64" ;;
    mips64el)            xarch="mips64le" ;;
    *) die "unsupported CPU architecture: $arch" ;;
  esac
  printf 'Xray-%s-%s.zip\n' "$xos" "$xarch"
}

# --------------------------------------------------------------------------- #
#  Steps                                                                       #
# --------------------------------------------------------------------------- #
preflight() {
  info "Preflight checks"
  [ -n "$HOME" ] || die "\$HOME is not set"
  ensure_deps
  if [ "$DO_SERVICE" -eq 1 ]; then
    if ! have systemctl; then
      warn "systemctl not found — skipping service install (use 'xraycli start')"
      DO_SERVICE=0
    fi
  fi
  ok "environment looks good"
}

install_core() {
  if [ "$CORE_KIND" = sing-box ]; then install_core_singbox; else install_core_xray; fi
}

install_core_xray() {
  info "Detecting platform and resolving Xray-core release"
  local asset base url tmp
  asset="$(detect_asset)"
  if [ "$XRAY_VERSION" = "latest" ]; then
    base="https://github.com/$XRAY_REPO/releases/latest/download"
  else
    base="https://github.com/$XRAY_REPO/releases/download/$XRAY_VERSION"
  fi
  url="${MIRROR}${base}/${asset}"
  ok "asset: $asset  (version: $XRAY_VERSION)"

  TMP_DIR="$(mktemp -d)"; tmp="$TMP_DIR"
  info "Downloading $url"
  download "$url" "$tmp/xray.zip" || die "download failed"

  info "Extracting core"
  unzip -oq "$tmp/xray.zip" -d "$tmp/x" || die "unzip failed"
  [ -f "$tmp/x/xray" ] || die "archive did not contain the xray binary"

  mkdir -p "$CORE_DIR"
  install -m 0755 "$tmp/x/xray" "$CORE_DIR/xray"
  for f in geoip.dat geosite.dat; do
    [ -f "$tmp/x/$f" ] && install -m 0644 "$tmp/x/$f" "$CORE_DIR/$f"
  done

  local ver
  ver="$(XRAY_LOCATION_ASSET="$CORE_DIR" "$CORE_DIR/xray" version 2>/dev/null | head -1 || true)"
  ok "installed core: ${ver:-unknown}"
}

# echoes the sing-box arch token for this machine
detect_singbox_arch() {
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)       echo amd64 ;;
    i386|i686)          echo 386 ;;
    aarch64|arm64)      echo arm64 ;;
    armv7l|armv7|armhf) echo armv7 ;;
    armv6l)             echo armv6 ;;
    s390x)              echo s390x ;;
    ppc64le)            echo ppc64le ;;
    riscv64)            echo riscv64 ;;
    loongarch64|loong64) echo loong64 ;;
    *) die "unsupported CPU architecture for sing-box: $arch" ;;
  esac
}

install_core_singbox() {
  [ "$(uname -s)" = Linux ] || die "sing-box auto-install here supports Linux only"
  have tar || die "tar is required to extract sing-box — please install it and re-run"
  info "Resolving sing-box release"
  local arch ver tag num url tmp
  arch="$(detect_singbox_arch)"
  if [ "$CORE_VERSION" = latest ]; then
    tag="$(latest_tag "$SINGBOX_REPO")" \
      || die "could not resolve latest sing-box version — install git, or pin one with --version <vX.Y.Z>"
  else
    tag="$CORE_VERSION"
  fi
  num="${tag#v}"
  url="${MIRROR}https://github.com/$SINGBOX_REPO/releases/download/${tag}/sing-box-${num}-linux-${arch}.tar.gz"
  ok "asset: sing-box-${num}-linux-${arch}.tar.gz  (version: $tag)"

  TMP_DIR="$(mktemp -d)"; tmp="$TMP_DIR"
  info "Downloading $url"
  download "$url" "$tmp/sb.tgz" || die "download failed"

  info "Extracting core"
  tar -xzf "$tmp/sb.tgz" -C "$tmp" || die "tar extract failed"
  local bin; bin="$(find "$tmp" -type f -name sing-box | head -1)"
  [ -n "$bin" ] || die "archive did not contain the sing-box binary"

  mkdir -p "$CORE_DIR"
  install -m 0755 "$bin" "$CORE_DIR/sing-box"
  local v; v="$("$CORE_DIR/sing-box" version 2>/dev/null | head -1 || true)"
  ok "installed core: ${v:-unknown}"
}

port_user() {  # the identity we hash: $USER, with sane fallbacks
  local u="${USER:-}"
  [ -n "$u" ] || u="$(id -un 2>/dev/null || whoami 2>/dev/null || printf 'user')"
  printf '%s' "$u"
}

user_port_base() {  # deterministic SOCKS base port for the current user
  local u h
  u="$(port_user)"
  # cksum: POSIX, no extra dependency, stable CRC of the name -> a 32-bit number.
  h="$(printf '%s' "$u" | cksum | awk '{print $1}')"
  printf '%s\n' "$(( PORT_WINDOW_START + (h % PORT_WINDOW_SLOTS) * 2 ))"
}

choose_ports() {
  local socks_start http_start base
  if [ "$USER_PORT" -eq 1 ]; then
    base="$(user_port_base)"
    socks_start="${PREF_SOCKS_PORT:-$base}"
    http_start="${PREF_HTTP_PORT:-$(( base + 1 ))}"
    info "Selecting proxy ports (base $base derived from user '$(port_user)')"
  else
    socks_start="${PREF_SOCKS_PORT:-10808}"
    http_start="${PREF_HTTP_PORT:-10809}"
    info "Selecting free local proxy ports"
  fi
  # Derived value is the starting point; a busy port just bumps +1 (find_free_port).
  SOCKS_PORT="$(find_free_port "$socks_start")"
  HTTP_PORT="$(find_free_port "$http_start" "$SOCKS_PORT")"
  ok "SOCKS -> $LISTEN_ADDR:$SOCKS_PORT   HTTP -> $LISTEN_ADDR:$HTTP_PORT"
}

write_env() {
  info "Writing environment file"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  local ver
  if [ "$CORE_KIND" = sing-box ]; then
    ver="$("$CORE_DIR/sing-box" version 2>/dev/null | head -1 | awk '{print $3}' || true)"
  else
    ver="$(XRAY_LOCATION_ASSET="$CORE_DIR" "$CORE_DIR/xray" version 2>/dev/null | head -1 | awk '{print $2}' || true)"
  fi
  cat > "$ENV_FILE" <<EOF
# Managed by xraycli install.sh — safe to edit ports/listen, then run: xraycli config regen
XRAYCLI_VERSION="${ver:-latest}"
XRAYCLI_CORE="$CORE_KIND"
XRAYCLI_LISTEN="$LISTEN_ADDR"
XRAYCLI_SOCKS_PORT="$SOCKS_PORT"
XRAYCLI_HTTP_PORT="$HTTP_PORT"
EOF
  ok "wrote $ENV_FILE"
}

install_script() {
  info "Installing xraycli control script"
  mkdir -p "$BIN_DIR"
  local src="${SCRIPT_DIR:-}/bin/xraycli"
  if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$src" ]; then
    install -m 0755 "$src" "$BIN_DIR/xraycli"       # local checkout
  else
    local rawurl="${MIRROR}$XRAYCLI_RAW_BASE/bin/xraycli"
    info "no local checkout — fetching from $rawurl"
    download "$rawurl" "$BIN_DIR/xraycli" \
      || die "could not download the control script from $rawurl"
    head -1 "$BIN_DIR/xraycli" | grep -q '^#!' \
      || die "downloaded control script looks invalid (got HTML? check the URL/branch)"
    chmod 0755 "$BIN_DIR/xraycli"
  fi
  ok "installed $BIN_DIR/xraycli"
}

generate_config() {
  info "Generating initial Xray config (pass-through until a node is added)"
  # Delegate to the freshly installed control script so config generation has a
  # single source of truth.
  "$BIN_DIR/xraycli" config regen >/dev/null
  ok "wrote $CONFIG_DIR/config.json"
}

install_service() {
  [ "$DO_SERVICE" -eq 1 ] || { warn "skipping systemd service (per --no-service)"; return 0; }
  info "Installing user systemd service"
  # Delegate to the control script so the unit lands in the directory the --user
  # manager actually scans (which may differ from \$HOME) and uses absolute paths.
  if "$BIN_DIR/xraycli" service install >/dev/null 2>&1; then
    ok "installed user service unit"
  else
    warn "could not install the service unit — you can still use 'xraycli start'"
  fi
}

patch_bashrc() {
  [ "$DO_BASHRC" -eq 1 ] || { warn "skipping ~/.bashrc (per --no-bashrc)"; return 0; }
  info "Updating ~/.bashrc"
  local begin="# >>> xraycli >>>" end="# <<< xraycli <<<"
  touch "$BASHRC"
  # Remove any previous block (idempotent).
  if grep -qF "$begin" "$BASHRC"; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1} !skip {print} $0==e {skip=0}
    ' "$BASHRC" > "$BASHRC.xraycli.tmp" && mv "$BASHRC.xraycli.tmp" "$BASHRC"
  fi
  cat >> "$BASHRC" <<EOF
$begin
# Managed by xraycli — remove with 'xraycli uninstall'. Do not edit by hand.
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) export PATH="\$HOME/.local/bin:\$PATH";; esac
$end
EOF
  ok "added xraycli block to ~/.bashrc (PATH only)"
}

summary() {
  local socks http
  socks="$SOCKS_PORT"; http="$HTTP_PORT"
  echo
  printf '%s%s installed successfully.%s\n' "$c_bld" "$APP" "$c_rst"
  echo
  echo "  Control script : $BIN_DIR/xraycli"
  echo "  Proxy core     : $CORE_KIND  ($CORE_DIR/$CORE_KIND)"
  echo "  Config         : $CONFIG_DIR/config.json"
  echo "  Logs           : $STATE_DIR/{access,error}.log"
  echo "  SOCKS proxy    : $LISTEN_ADDR:$socks"
  echo "  HTTP  proxy    : $LISTEN_ADDR:$http"
  echo
  echo "Next steps:"
  echo "  1) Reload your shell so PATH applies:            source ~/.bashrc"
  echo "  2) Add a node from a share link or subscription (base64 or Clash):"
  echo "         xraycli add     '<share-link>'"
  echo "         xraycli sub add '<subscription-url>'    # repeatable; 'xraycli update' refreshes all"
  echo "  3) Start it and check status:"
  echo "         xraycli enable      # start now + auto-start on boot"
  echo "         xraycli status"
  echo "  4) Proxy ports (point your apps/shell at these):  xraycli port"
  echo
  echo "Uninstall cleanly at any time:  xraycli uninstall"
}

# yes/no helper: prints "$1 [Y/n] " (default yes) or "[y/N] " (default no).
# Returns 0 for yes. Non-interactive → the default.
ask() {  # ask <prompt> <default:y|n>
  local prompt="$1" def="${2:-y}" ans hint
  case "$def" in y) hint="[Y/n]" ;; *) hint="[y/N]" ;; esac
  if [ ! -t 0 ]; then [ "$def" = y ]; return; fi
  read -rp "$prompt $hint " ans || true
  ans="${ans:-$def}"
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Pick the proxy core interactively, before anything is downloaded. Skipped when
# --core was given, when the wizard is off, or in a non-interactive session
# (piped installs default to xray).
choose_core() {
  { [ "$DO_WIZARD" -eq 1 ] && [ "$CORE_EXPLICIT" -eq 0 ] && [ -t 0 ]; } || return 0
  echo
  printf '%s— proxy core —%s  which core should run the tunnel?\n' "$c_bld" "$c_rst"
  printf '  1) xray      %s(default) VLESS/REALITY, VMess, Trojan, Shadowsocks, hysteria2 (no obfs)%s\n' "$c_dim" "$c_rst"
  printf '  2) sing-box  %sall of the above + hysteria2 with Salamander obfs%s\n' "$c_dim" "$c_rst"
  local ans; read -rp "  choose [1/2] (default 1): " ans || true
  case "${ans:-1}" in 2|sing-box|singbox|s) CORE_KIND="sing-box" ;; *) CORE_KIND="xray" ;; esac
  ok "core: $CORE_KIND"
}

run_wizard() {
  [ "$DO_WIZARD" -eq 1 ] || return 0
  local xr="$BIN_DIR/xraycli" url
  if [ ! -t 0 ]; then
    info "non-interactive session — skipping the setup wizard"
    return 0
  fi
  echo
  printf '%s— setup wizard —%s  (Enter takes the [default]; answers below are optional)\n' \
    "$c_bld" "$c_rst"

  # 1) subscription / first node
  echo
  if ask "1) Import a subscription now?" y; then
    while :; do
      read -rp "   Paste the subscription URL (blank = done): " url || true
      [ -n "${url:-}" ] || break
      # 'sub add' fetches, imports and prints the node list itself.
      "$xr" sub add "$url" || warn "import failed — retry later with:  xraycli sub add '<url>'"
      ask "   Add another subscription?" n || break
    done
  fi

  # 2) start now + auto-start on boot
  echo
  if ask "2) Start the proxy now and auto-start it on boot?" y; then
    "$xr" enable  || warn "could not enable — retry later with:  xraycli enable"
    "$xr" status  || true
  fi

  # 3) wire the proxy into Claude Code / Codex
  echo
  if ask "3) Route Claude Code through this proxy? (~/.claude/settings.json)" n; then
    "$xr" claude || warn "could not update ~/.claude/settings.json"
  fi
  if ask "   Route Codex through this proxy? (~/.codex/.env)" n; then
    "$xr" codex  || warn "could not update ~/.codex/.env"
  fi

  echo
  ok "wizard complete. Re-run any step later:  xraycli sub / enable / claude / codex"
}

# --------------------------------------------------------------------------- #
#  Run                                                                         #
# --------------------------------------------------------------------------- #
main() {
  printf '%s%s installer%s\n\n' "$c_bld" "$APP" "$c_rst"
  choose_core
  preflight
  resolve_mirror
  install_core
  choose_ports
  write_env
  install_script
  generate_config
  install_service
  patch_bashrc
  summary
  run_wizard
}
main "$@"
