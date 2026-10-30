#!/usr/bin/env bash
# Copy the plugin onto a mounted Kobo.
# Mount first with ~/Projects/kobo/scripts/kobo-mount.sh. Backs up KOReader
# settings first and never touches .adds/koreader/settings*.
set -euo pipefail
cd "$(dirname "$0")/.."
KOBO="${1:-/run/media/$USER/KOBOeReader}"
DEST="$KOBO/.adds/koreader/plugins/todoist.koplugin"

if [[ ! -d "$KOBO/.adds/koreader/plugins" ]]; then
	echo "No KOReader found at $KOBO. Mount the Kobo first (~/Projects/kobo/scripts/kobo-mount.sh)."
	exit 1
fi

"$HOME/Projects/kobo/scripts/backup-koreader.sh" "$KOBO"

mkdir -p "$DEST"
rsync -rt --delete --include='*.lua' --include='README.md' --include='LICENSE' --exclude='*' ./ "$DEST/"
sync

echo "* Checking the copy"
for f in *.lua README.md LICENSE; do
	cmp "$f" "$DEST/$f"
done
echo "* Installed to $DEST:"
ls -R "$DEST"
echo "  The API key goes in $KOBO/.adds/koreader/settings/todoist_token.txt (or Settings in KOReader)."
echo "  Now eject (~/Projects/kobo/scripts/kobo-mount.sh eject) and restart KOReader on the Kobo."
