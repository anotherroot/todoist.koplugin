# Todoist for KOReader

Send a passage or an idea to your Todoist Inbox from your e-reader in a few
taps, without leaving the book. Quotes keep the book, author and page they came
from. Everything is saved on the device first, so nothing is lost when there is
no Wi-Fi: it is sent later, on its own, and the plugin tells you if it keeps
failing.

Status: experimental. Tested on a Kobo with KOReader v2026.03.

## What you can do

| Where in KOReader | What it does |
|---|---|
| Select text, then **Send to Todoist** | sends the selection as a quote (no highlight is left behind) |
| Tap an existing highlight, then **…** → **Send to Todoist** | sends the highlight as a quote, with its note if it has one |
| Menu → Tools → Todoist → **New idea…** | type an idea and send it (also works in the file browser) |
| Any gesture → **Todoist: new idea** | the same, from a gesture: Settings → Taps and gestures → Gesture manager → pick a gesture → General |
| Menu → Tools → Todoist → **Sent items** | the history of everything you sent, newest first |
| Menu → Tools → Todoist → **Not sent** | only what is still waiting or failed |
| Menu → Tools → Todoist → **Settings** | API key, **Test connection**, options |

The menu title shows a count when something is stuck, for example
"Todoist (2 not sent)".

## Install

1. Download `todoist.koplugin-<version>.zip` from the Releases page of this
   repository and unpack `todoist.koplugin` into KOReader's `plugins/` folder
   (on a Kobo: `.adds/koreader/plugins/`).
2. Restart KOReader.
3. Add your API key (below).

## API key

The plugin needs your personal Todoist API token. Get it in Todoist at
[Settings → Integrations → Developer](https://app.todoist.com/app/settings/integrations).

Give it to the plugin in either way:

- **File:** put the token alone in a text file named `todoist_token.txt` in
  KOReader's `settings/` folder (on a Kobo: `.adds/koreader/settings/`).
  Surrounding spaces and line breaks are ignored.
- **In KOReader:** Menu → Tools → Todoist → Settings → **API key**, then type
  or paste it.

If both exist, the file wins; Settings shows which one is in use and only the
last four characters of the key. Use **Test connection** to check it: it shows
"Connected as …" or the reason it failed. Changing the key retries items that
were stopped by a bad key. Saving an empty field changes nothing; to delete a
key set there, use **Remove key** (shown only when one is set).

## What a task looks like

Everything goes to the Inbox. The first line of the description tells quotes
and ideas apart.

A quote:

```
Title:        the quoted text (cut at a word with "…" if it is very long)
Description:  📖 Kobo quote
              Book: <title>
              Author: <author>
              Page: <page>
              Captured: 2026-10-30 21:14
              Note: <your note>        (only for a highlight that has one)
```

An idea:

```
Title:        the idea
Description:  💡 Kobo idea
              Captured: 2026-10-30 21:14
```

Lines with no information (a book without an author, say) are left out. When
the title had to be shortened, the full text is added at the end of the
description. In Settings, **Add book and page to ideas** (off by default) adds
the Book, Author and Page lines to ideas too.

## Statuses, retries and alerts

Every item in the history has a status in words:

- **waiting**: saved on the device, not sent yet
- **sending**: sent to Todoist, no answer yet
- **sent**: Todoist confirmed it
- **failed**: the last try failed; the reason is shown on the item

Tap an item to see its full text, book, author, page, time and status, with
**Send again** and, for quotes, **Go to** (opens the book at that place). An
item is created with a unique id once and keeps it for every retry, so retrying
does not create duplicates in Todoist. **Send again** on an item that was
already sent makes a second copy on purpose.

Temporary problems (no network, a timeout, Todoist being busy) are retried
automatically: right away when Wi-Fi connects, and otherwise every few
minutes, up to every 30 minutes. The plugin never turns Wi-Fi on in the
background. Pressing **Send** or **Send again** while offline follows
KOReader's "Action when Wi-Fi is off" setting, so it may ask to turn Wi-Fi on.
Problems that retrying cannot fix (for example a wrong or revoked key) stop
that item until you fix the key or tap **Send again**.

When items are not getting through, a popup you have to dismiss says how many
are not sent and why, with **Show items** (and **Settings** for key problems).
It appears after a bad key at once, or after three failed tries in a row, and
it is not repeated for every retry.

Settings → **Clear sent items…** removes the sent items from the history
(after a confirmation); items not sent yet are kept.

The history is the file `todoist_history.json` in KOReader's `settings/`
folder, with the previous version kept next to it as `todoist_history.json.old`.
If the file is ever damaged (say, by a power cut), it is set aside as
`todoist_history.json.bad-<date-time>`, the previous version is used, and a
message tells you so.

## Privacy

Your API key stays on the device (in `todoist_token.txt` or KOReader's
settings) and is only sent to Todoist: it goes with every request, as the
authorization header. It is never written to logs or to the history. The only
other thing that leaves the device is the text of each task described above,
sent to `api.todoist.com`. There is no other server and no tracking.

Like other KOReader network plugins, the connection uses KOReader's default
TLS settings, which don't verify Todoist's certificate, so avoid untrusted
Wi-Fi if that matters to you.

## Development

Needs Nix (luajit, busted, luacheck).

- `scripts/test.sh`: luacheck and busted. Downloads KOReader v2026.03 into
  `.dev/` the first time.
- `scripts/dev-run.sh`: KOReader on the computer with the plugin and its own
  settings in `.dev/home` (put a token in `.dev/home/settings/todoist_token.txt`).
- `scripts/install-kobo.sh`: copy onto a mounted Kobo (the author's setup).
- `scripts/release.sh <version>`: release zip in `.dev/`.

## License

MIT.
