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

Install `flycut-sync-server.service` as a systemd user unit, with `HOST` replaced by the machine's
Tailscale name (it listens on every address the name resolves to), then `systemctl --user enable --now flycut-sync-server`.

The server refuses to listen on all interfaces. Bind it to a Tailscale address, or to `127.0.0.1` behind
an HTTPS reverse proxy. `-listen` takes a comma-separated list, e.g. `127.0.0.1:8742,desktop.example.ts.net:8742`
while clients move from the direct address to the proxy.

Behind Caddy, restricted to the tailnet:

```
flycut.example.ts.net {
	@tailnet remote_ip 127.0.0.0/8 ::1 100.64.0.0/10 fd7a:115c:a1e0::/48
	handle @tailnet {
		request_body {
			max_size 64MB
		}
		reverse_proxy 127.0.0.1:8742
	}
	handle {
		respond "Tailscale required" 403
	}
}
```

## Connect Flycut

Preferences > History > Sync history through a server:

- Address: `https://<proxy name>`, or `http://<the server's Tailscale name>:8742` without a proxy. Plain
  `http://` is accepted only when every address the name resolves to is loopback or on the tailnet.
- Token: the contents of the token file. Flycut stores it in the login keychain itself; enter it here
  rather than adding the item with `security`, which macOS 15 makes Flycut ask the keychain password for.

## API

Every request needs `Authorization: Bearer <token>`.

| Request | Result |
|---|---|
| `GET /v1/logs` | `[{"machine":"...","size":N}]` |
| `GET /v1/logs/<machine>?from=N` | log bytes from offset N; `X-Log-Size` is the full size |
| `POST /v1/logs/<machine>` | appends whole JSON lines; with `X-Log-Offset` not equal to the size: 409 |
| `PUT /v1/logs/<machine>` | replaces the log (after the client compacts it) |
