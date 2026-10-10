# flycut-copyq-bridge

Syncs a Linux machine's [CopyQ](https://hluk.github.io/CopyQ/) clipboard history with Flycut through
[flycut-sync-server](../sync-server/README.md). Python 3 standard library only; talks to CopyQ with `copyq eval`.

## What syncs

| Change | Result |
|---|---|
| Text copied on Linux (or copied again) | Newest clipping on every Mac |
| Clipping copied on a Mac within the last hour | Inserted on top of the CopyQ tab |
| Older Mac clipping (first sync) | Appended at the bottom of the tab |
| Clipping deleted or history cleared on a Mac | Removed from the tab if among its top 5000 rows |

Not synced: favorites, images and other non-text items, deletions made in CopyQ, CopyQ's ordering of older items.
Items already in CopyQ when the bridge first starts stay local; `--export-existing N` shares the top N (max 20) once.

## Run

```sh
mkdir -p ~/.local/share/flycut-copyq-bridge
cp flycut-copyq-bridge.py ~/.local/share/flycut-copyq-bridge/
sed 's|SERVER|http://100.x.y.z:8742|' flycut-copyq-bridge.service > ~/.config/systemd/user/flycut-copyq-bridge.service
systemctl --user daemon-reload && systemctl --user enable --now flycut-copyq-bridge
journalctl --user -u flycut-copyq-bridge -f
```

The token file is the server's own (`--token-file`); on another machine, copy it there with mode 0600.
State (machine id, read positions, which clipping is which) is in `~/.local/share/flycut-copyq-bridge/`.
