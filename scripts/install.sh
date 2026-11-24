#!/bin/bash
# Copies the built app to ~/Applications/Notch Prompter.app (no admin password needed) and opens it.
#   scripts/install.sh [path/to/NotchPrompter.app]
set -euo pipefail

SRC="${1:-$HOME/Library/Caches/MacTele/apps/NotchPrompter.app}"
DEST="$HOME/Applications/Notch Prompter.app"

[ -d "$SRC" ] || { echo "Build the app first: make app"; exit 1; }
mkdir -p "$HOME/Applications"
pkill -x NotchPrompter 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
ditto "$SRC" "$DEST"
# Only the installed copy should answer notchprompter:// links, not the build copy in the cache folder.
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -u "$SRC" 2>/dev/null || true
"$LSREG" -f "$DEST" 2>/dev/null || true
open "$DEST"
echo "Installed to $DEST"
