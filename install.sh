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
#   * picks two free local ports (SOCKS + HTTP) for the proxy inbounds
#   * generates an initial Xray config (pass-through until a node is added)
#   * installs a *user* systemd unit  ~/.config/systemd/user/xraycli.service
#   * appends a small, clearly-marked block to ~/.bashrc (PATH + proxyon/off)
#
# Re-running is safe (idempotent upgrade). Remove everything with:
#   xraycli uninstall        (or ./uninstall.sh)
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   --version <vX.Y.Z>   Install a specific Xray-core version (default: latest)
#   --socks-port <n>     Preferred SOCKS port   (default: auto, from 10808)
#   --http-port  <n>     Preferred HTTP  port   (default: auto, from 10809)
#   --listen <addr>      Local listen address   (default: 127.0.0.1)
#   --no-service         Do not install/enable the systemd user service
#   --no-bashrc          Do not modify ~/.bashrc
#   --mirror <prefix>    Prefix prepended to the GitHub download URL (for CN mirrors)
#   -h, --help           Show this help
#
set -euo pipefail

# --------------------------------------------------------------------------- #
#  Constants & paths (XDG-based, all under $HOME)                             #
# --------------------------------------------------------------------------- #
readonly APP="xraycli"
readonly XRAY_REPO="XTLS/Xray-core"

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
PREF_SOCKS_PORT=10808
PREF_HTTP_PORT=10809
LISTEN_ADDR="127.0.0.1"
DO_SERVICE=1
DO_BASHRC=1
DO_DEPS=1
MIRROR=""

# --------------------------------------------------------------------------- #
#  Pretty output                                                              #
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
  c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'
  c_blu=$'\033[34m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
else
  c_red=; c_grn=; c_ylw=; c_blu=; c_bld=; c_rst=
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
  --version <vX.Y.Z>   Install a specific Xray-core version (default: latest)
  --socks-port <n>     Preferred SOCKS port   (default: auto, from 10808)
  --http-port  <n>     Preferred HTTP  port   (default: auto, from 10809)
  --listen <addr>      Local listen address   (default: 127.0.0.1)
  --no-service         Do not install/enable the systemd user service
  --no-bashrc          Do not modify ~/.bashrc
  --no-deps            Do not attempt to install missing dependencies
  --mirror <prefix>    Prefix prepended to the GitHub download URL (CN mirrors)
  -h, --help           Show this help
EOF
  exit "${1:-0}"
}

# --------------------------------------------------------------------------- #
#  Argument parsing                                                           #
# --------------------------------------------------------------------------- #
while [ $# -gt 0 ]; do
  case "$1" in
    --version)    XRAY_VERSION="${2:?}"; shift 2 ;;
    --socks-port) PREF_SOCKS_PORT="${2:?}"; shift 2 ;;
    --http-port)  PREF_HTTP_PORT="${2:?}"; shift 2 ;;
    --listen)     LISTEN_ADDR="${2:?}"; shift 2 ;;
    --mirror)     MIRROR="${2:?}"; shift 2 ;;
    --no-service) DO_SERVICE=0; shift ;;
    --no-bashrc)  DO_BASHRC=0; shift ;;
    --no-deps)    DO_DEPS=0; shift ;;
    -h|--help)    usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

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
  have unzip || missing+=(unzip)
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
  have unzip || die "unzip is required to extract Xray — please install it and re-run"
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

choose_ports() {
  info "Selecting free local proxy ports"
  SOCKS_PORT="$(find_free_port "$PREF_SOCKS_PORT")"
  HTTP_PORT="$(find_free_port "$PREF_HTTP_PORT" "$SOCKS_PORT")"
  ok "SOCKS -> $LISTEN_ADDR:$SOCKS_PORT   HTTP -> $LISTEN_ADDR:$HTTP_PORT"
}

write_env() {
  info "Writing environment file"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  local ver
  ver="$(XRAY_LOCATION_ASSET="$CORE_DIR" "$CORE_DIR/xray" version 2>/dev/null | head -1 | awk '{print $2}' || true)"
  cat > "$ENV_FILE" <<EOF
# Managed by xraycli install.sh — safe to edit ports/listen, then run: xraycli config regen
XRAYCLI_VERSION="${ver:-$XRAY_VERSION}"
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
    info "no local checkout — fetching from $XRAYCLI_RAW_BASE/bin/xraycli"
    download "$XRAYCLI_RAW_BASE/bin/xraycli" "$BIN_DIR/xraycli" \
      || die "could not download the control script from $XRAYCLI_RAW_BASE/bin/xraycli"
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
  mkdir -p "$SYSTEMD_DIR"
  cat > "$SYSTEMD_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=Xray proxy (managed by xraycli)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=%h/.local/share/$APP/core
ExecStart=%h/.local/share/$APP/core/xray run -config %h/.config/$APP/config.json
Restart=on-failure
RestartSec=5
# Light user-scope hardening (kept minimal to avoid surprising failures)
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload 2>/dev/null || warn "systemctl --user daemon-reload failed (is a user session bus running?)"
  ok "installed $SYSTEMD_DIR/$SERVICE_NAME"
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
# proxyon / proxyoff: toggle this shell's proxy env vars to the xraycli inbounds.
proxyon() {
  local ef="\$HOME/.config/$APP/xraycli.env"
  [ -f "\$ef" ] && . "\$ef"
  local h="\${XRAYCLI_LISTEN:-127.0.0.1}" hp="\${XRAYCLI_HTTP_PORT:-10809}" sp="\${XRAYCLI_SOCKS_PORT:-10808}"
  export http_proxy="http://\$h:\$hp" https_proxy="http://\$h:\$hp"
  export HTTP_PROXY="\$http_proxy" HTTPS_PROXY="\$https_proxy"
  export all_proxy="socks5://\$h:\$sp" ALL_PROXY="\$all_proxy"
  export no_proxy="localhost,127.0.0.1,::1" NO_PROXY="\$no_proxy"
  echo "proxy ON  -> http://\$h:\$hp  (socks5://\$h:\$sp)"
}
proxyoff() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
  echo "proxy OFF"
}
$end
EOF
  ok "added xraycli block to ~/.bashrc (PATH + proxyon/proxyoff)"
}

summary() {
  local socks http
  socks="$SOCKS_PORT"; http="$HTTP_PORT"
  echo
  printf '%s%s installed successfully.%s\n' "$c_bld" "$APP" "$c_rst"
  echo
  echo "  Control script : $BIN_DIR/xraycli"
  echo "  Xray core      : $CORE_DIR/xray"
  echo "  Config         : $CONFIG_DIR/config.json"
  echo "  Logs           : $STATE_DIR/{access,error}.log"
  echo "  SOCKS proxy    : $LISTEN_ADDR:$socks"
  echo "  HTTP  proxy    : $LISTEN_ADDR:$http"
  [ "$DO_SERVICE" -eq 1 ] && echo "  Service        : systemctl --user … $SERVICE_NAME"
  echo
  echo "Next steps:"
  echo "  1) Reload your shell so PATH + helpers apply:   source ~/.bashrc"
  echo "  2) Add a server node (share link / subscription — coming once configured):"
  echo "         xraycli add   '<share-link>'"
  echo "         xraycli sub set '<subscription-url>' && xraycli update"
  echo "  3) Start it and check status:"
  echo "         xraycli enable      # start now + start on login (enables linger)"
  echo "         xraycli status"
  echo "  4) Point your shell at the proxy:               proxyon   (proxyoff to stop)"
  echo
  echo "Uninstall cleanly at any time:  xraycli uninstall"
}

# --------------------------------------------------------------------------- #
#  Run                                                                         #
# --------------------------------------------------------------------------- #
main() {
  printf '%s%s installer%s\n\n' "$c_bld" "$APP" "$c_rst"
  preflight
  install_core
  choose_ports
  write_env
  install_script
  generate_config
  install_service
  patch_bashrc
  summary
}
main "$@"
