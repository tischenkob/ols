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

# Claude Code loads the plugin from its cache; a new version there needs a bump in plugin.json.
PLUGIN="$HOME/.claude/local-plugins/odin-lsp"
if [ -d "$(dirname "$PLUGIN")" ]; then
	rm -rf "$PLUGIN"
	cp -R misc/claude-plugin "$PLUGIN"
	# Claude Code does not search ~/.local/bin.
	sed -i '' "s|\"command\": \"ols\"|\"command\": \"$BIN/ols\"|" "$PLUGIN/.lsp.json"
	echo "copied plugin to $PLUGIN; run: claude plugin update odin-lsp@bogdan-local"
fi
