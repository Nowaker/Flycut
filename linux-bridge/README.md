# flycut-copyq-bridge

Syncs a Linux machine's [CopyQ](https://hluk.github.io/CopyQ/) clipboard history with Flycut through
[flycut-sync-server](../sync-server/README.md). Python 3 with the `cryptography` package (Arch: `python-cryptography`);
talks to CopyQ with `copyq eval`.

## What syncs

| Change | Result |
|---|---|
| Anything copied on Linux (or copied again): text, rich text, an image | Newest clipping on every Mac, with every format |
| Clipping copied on a Mac within the last hour | Inserted on top of the CopyQ tab, with its HTML, RTF, image or PDF |
| Older Mac clipping (first sync) | Appended at the bottom of the tab |
| Clipping deleted or history cleared on a Mac | Removed from the tab if among its top 5000 rows |

Credentials (`credential-rules.json`, the same rules Flycut uses) are sealed in the server log and in the
bridge's state, and opened again when they reach CopyQ; see [Credentials](../sync-server/README.md#credentials).

Formats map between MIME types and macOS pasteboard types (`text/html` and `public.html`, `image/png` and
`public.png`, and so on); other Linux formats travel under their MIME name, and macOS-only types stay out of CopyQ.
An image copied in CopyQ gets Flycut's label, e.g. `[image: PNG, 1920×1080, 1.2 MB]`. The data goes through the
server as blobs (see [Pasteboard data](../sync-server/README.md#pasteboard-data)); the bridge keeps its own in
`blobs/` under its state directory until no line of its log refers to them.

Not synced: favorites, deletions made in CopyQ, CopyQ's ordering of older items.
Items already in CopyQ when the bridge first starts stay local; `--export-existing N` shares the top N (max 20) once.

## Run

```sh
mkdir -p ~/.local/share/flycut-copyq-bridge
cp flycut-copyq-bridge.py ../FlycutEngine/credential-rules.json ~/.local/share/flycut-copyq-bridge/
sed 's|SERVER|http://desktop.example.ts.net:8742|' flycut-copyq-bridge.service > ~/.config/systemd/user/flycut-copyq-bridge.service
systemctl --user daemon-reload && systemctl --user enable --now flycut-copyq-bridge
journalctl --user -u flycut-copyq-bridge -f
```

The token file is the server's own (`--token-file`); on another machine, copy it there with mode 0600.
State (machine id, read positions, which clipping is which) is in `~/.local/share/flycut-copyq-bridge/`.
