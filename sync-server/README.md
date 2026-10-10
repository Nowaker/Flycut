# flycut-sync-server

Keeps each machine's Flycut history log so Macs (and the Linux bridge) can sync without a shared folder.
It stores one append-only `<machine>.jsonl` per machine and does no merging; clients do that.

## Run

```sh
go build -o flycut-sync-server .
mkdir -p ~/.local/share/flycut-sync-server
mv flycut-sync-server ~/.local/share/flycut-sync-server/
(umask 077; openssl rand -hex 32 > ~/.local/share/flycut-sync-server/token)
```

Install `flycut-sync-server.service` as a systemd user unit, with `LISTEN` replaced by the machine's
Tailscale address, then `systemctl --user enable --now flycut-sync-server`.

The server refuses to listen on all interfaces. Bind it to a Tailscale address, or to `127.0.0.1` behind
an HTTPS reverse proxy.

## Connect Flycut

Preferences > History > Sync history through a server:

- Address: `http://<tailscale address or MagicDNS name>:8742`. Plain `http://` is accepted only when every
  address the name resolves to is loopback or on the tailnet; anything else needs `https://`.
- Token: the contents of the token file. Flycut keeps it in the login keychain.

## API

Every request needs `Authorization: Bearer <token>`.

| Request | Result |
|---|---|
| `GET /v1/logs` | `[{"machine":"...","size":N}]` |
| `GET /v1/logs/<machine>?from=N` | log bytes from offset N; `X-Log-Size` is the full size |
| `POST /v1/logs/<machine>` | appends whole JSON lines; with `X-Log-Offset` not equal to the size: 409 |
| `PUT /v1/logs/<machine>` | replaces the log (after the client compacts it) |
