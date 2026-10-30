#!/usr/bin/env bash
# Prepare .dev/: KOReader v2026.03 (same version as the Kobo), its Lua sources
# for tests, and a separate KOReader home with this plugin linked in.
# Safe to re-run: only does what's missing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=v2026.03
APPIMAGE=".dev/koreader-$VERSION.AppImage"
mkdir -p .dev/home/plugins .dev/books

if [[ ! -f "$APPIMAGE" ]]; then
	echo "* Downloading KOReader $VERSION AppImage"
	curl -fL --progress-bar -o "$APPIMAGE.part" "https://github.com/koreader/koreader/releases/download/$VERSION/koreader-$VERSION-x86_64.AppImage"
	mv "$APPIMAGE.part" "$APPIMAGE"
	chmod +x "$APPIMAGE"
fi

if [[ ! -f .dev/squashfs-root/usr/lib/koreader/reader.lua ]]; then
	echo "* Extracting KOReader sources (for tests)"
	rm -rf .dev/squashfs-root
	(cd .dev && "./$(basename "$APPIMAGE")" --appimage-extract >/dev/null)
fi

ln -sfn "$PWD" .dev/home/plugins/todoist.koplugin

if [[ ! -f .dev/books/alice.epub ]]; then
	echo "* Downloading a public-domain test book"
	curl -fL --progress-bar -o .dev/books/alice.epub "https://www.gutenberg.org/ebooks/11.epub3.images"
fi
