#!/usr/bin/env bash
# Run KOReader v2026.03 on this laptop with the plugin loaded. Uses its own
# home folder (.dev/home), so nothing touches a real KOReader install.
# Pass at most ONE argument (a book or folder): the AppImage launcher joins
# several arguments into one string.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/setup-dev.sh
KO_HOME="$PWD/.dev/home" XDG_DOCUMENTS_DIR="$PWD/.dev" exec nix run nixpkgs#appimage-run -- \
	".dev/koreader-v2026.03.AppImage" "${@:-$PWD/.dev/books}"
