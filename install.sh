#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION="rols-$(date -u '+%Y-%m-%d')-$(git rev-parse --short HEAD)"
BIN="$HOME/.local/bin"
SHARE="$HOME/.local/share/ols"

tmp="$(mktemp)"
odin build src/ -collection:src=src -out:"$tmp" -microarch:native -no-bounds-check -o:speed -define:VERSION="$VERSION"
mkdir -p "$BIN" "$SHARE"
install -m 755 "$tmp" "$BIN/ols-bin"
rm -f "$tmp"

rm -rf "$SHARE/builtin"
cp -R builtin "$SHARE/builtin"

# The binary finds builtins through OLS_BUILTIN_FOLDER, same as the Homebrew wrapper.
cat > "$BIN/ols" <<WRAP
#!/bin/sh
export OLS_BUILTIN_FOLDER="\$HOME/.local/share/ols/builtin"
exec "\$HOME/.local/bin/ols-bin" "\$@"
WRAP
chmod 755 "$BIN/ols"
echo "installed $VERSION to $BIN/ols"
