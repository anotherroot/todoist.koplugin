#!/usr/bin/env bash
# All tests: luacheck + busted, with KOReader's own json module from the
# extracted AppImage.
# Extra arguments go to busted, e.g. scripts/test.sh spec/td_safe_spec.lua
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/setup-dev.sh
export KOREADER_DIR="$PWD/.dev/squashfs-root/usr/lib/koreader"
exec nix shell nixpkgs#luajitPackages.busted nixpkgs#luajitPackages.luacheck \
	-c sh -c 'luacheck -q . && busted "$@"' sh "$@"
