#!/usr/bin/env bash
#
# uninstall.sh — thin wrapper so you can remove xraycli even if ~/.local/bin
# is not on your PATH. It simply delegates to the installed control script.
#
set -euo pipefail
: "${XDG_CONFIG_HOME:=$HOME/.config}"

CLI="$HOME/.local/bin/xraycli"
if [ -x "$CLI" ]; then
  exec "$CLI" uninstall "$@"
else
  echo "xraycli is not installed at $CLI (nothing to do)." >&2
  exit 0
fi
