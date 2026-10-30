#!/usr/bin/env bash
# Build a release zip: .dev/todoist.koplugin-<version>.zip
# Usage: scripts/release.sh <version>    (e.g. 0.1.0)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/todoist.koplugin"
cp ./*.lua README.md LICENSE "$STAGE/todoist.koplugin/"
mkdir -p .dev
OUT="$PWD/.dev/todoist.koplugin-$VERSION.zip"
rm -f "$OUT"
(cd "$STAGE" && nix shell nixpkgs#zip -c zip -qr "$OUT" todoist.koplugin)
echo "* $OUT ($(du -h "$OUT" | cut -f1))"
nix shell nixpkgs#unzip -c unzip -l "$OUT"
