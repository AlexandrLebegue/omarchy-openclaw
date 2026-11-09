#!/bin/sh
# Install the OpenClaw logo into the user's hicolor icon theme so the
# notification daemon can resolve `-i openclaw`.
set -eu

src="$1"
dir="$HOME/.local/share/icons/hicolor"

install -Dm644 "$src" "$dir/256x256/apps/openclaw.png"
install -Dm644 "$src" "$dir/512x512/apps/openclaw.png"

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$dir" >/dev/null 2>&1 || true
fi
