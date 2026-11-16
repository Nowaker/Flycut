# flycut-sync-server

Keeps each machine's Flycut history log so Macs (and the Linux bridge) can sync without a shared folder.
It stores one append-only `<machine>.jsonl` per machine, plus the pasteboard data those logs refer to, and does
no merging; clients do that.

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

## Pasteboard data

A copy holds more than text: Slack puts its own block format and HTML next to the text, a screenshot is a
PNG with no text at all. Flycut keeps every representation the copying app provided (but not the ones macOS
would only make on request by converting another, nor promised or not-to-be-saved ones), up to 64 MB per copy,
largest dropped first, text always kept. A put event then lists them in `"items"`, each `{"t": pasteboard type,
"b": sha256, "n": bytes}`; the data itself is uploaded first, as `blobs/<machine>/<sha256>`. A clipping without
text is labelled with what it is, e.g. `[image: PNG, 1920×1080, 1.2 MB]` or `[image: GIF, 480×270, 1.1 MB, 20 frames]`.
Pasting it puts every representation back.

Replacing a log removes that machine's blobs the new log no longer refers to (once they are ten minutes old).

## Credentials

Clipping contents that look like credentials (`FlycutEngine/credential-rules.json`, gitleaks-style rules
plus a check for lone random-looking words) are sealed by the clients before they reach the server: such a
put carries `"enc": "v1:..."` instead of `"contents"`, AES-256-CTR with HMAC-SHA256, keys derived from the
token (format in `FlycutEngine/FlycutSyncCrypto.h`). Their pasteboard data is sealed too (`"s": true` on the
representation; the blob holds nonce, ciphertext and tag). Reading the logs or blobs shows ciphertext for them;
every client with the token reads them as usual. Flycut shows them in red.

To read one on the server host:

```sh
flycut-sync-server reveal -data ~/.local/share/flycut-sync-server/logs -token-file ~/.local/share/flycut-sync-server/token
flycut-sync-server reveal -data ... -token-file ... -id <clipping id>
flycut-sync-server reveal -data ... -token-file ... -id <clipping id> -save ~/revealed
```

The first lists sealed clippings (time, id, machine, app, length); the second prints one; the third also writes
its pasteboard data (HTML, an image) into the directory, one file per representation.

## Web history

`https://<server>/web/` lists every machine's history, merged the way Flycut merges it, with search, a
machine filter, favorites, image previews and each clipping's formats to download. Duplicates are not
hidden there: every copy is its own clipping.

Credentials stay masked: the list and the detail never carry their text and search doesn't look inside
it. **Reveal** fetches one clipping's text (`POST /web/api/reveal`, logged with the clipping id and the
requester's address); **Hide** takes it out of the page again, and **Copy without showing** puts it on
the clipboard without displaying it.

Signing in:

- **Open History in Browser**, in Flycut's menu or Preferences > History, asks the server for a one-time
  link with the token and opens it. The link works once, within two minutes.
- **Browser Login…** in Preferences > History sets an optional login and password (the login may be
  empty), stored as PBKDF2-SHA256 in `web-login.json` beside the logs. Without one, the one-time link is
  the only way in; with one, the link still works. Ten wrong passwords in 15 minutes lock the form for a while.

A session lasts 12 hours. Its cookie is signed with a key derived from the token, so a new token signs
everyone out.

## API

Every `/v1` request needs `Authorization: Bearer <token>`; `/web/` signs in as described above.

| Request | Result |
|---|---|
| `GET /v1/logs` | `[{"machine":"...","size":N}]` |
| `GET /v1/logs/<machine>?from=N` | log bytes from offset N; `X-Log-Size` is the full size |
| `POST /v1/logs/<machine>` | appends whole JSON lines; with `X-Log-Offset` not equal to the size: 409 |
| `PUT /v1/logs/<machine>` | replaces the log (after the client compacts it) |
| `GET /v1/blobs/<machine>` | `["<sha256>", ...]`, the machine's stored blobs |
| `GET`/`HEAD /v1/blobs/<machine>/<sha256>` | the blob; 404 if not stored |
| `PUT /v1/blobs/<machine>/<sha256>` | stores it; 400 unless the body's SHA-256 is the name (up to 256 MB) |
| `GET /v1/archive/search?q=<words>&list=0\|1&limit=50&offset=0` | `{"matched": N, "clippings": [<put event as stored>, ...]}`: live clippings of every machine, newest rank first, duplicates kept; all words must match contents, app or machine (case-insensitive; sealed text is never searched); `limit` up to 200 |
| `POST /v1/web/admission` | `{"path": "/web/admit?code=..."}`, a one-time sign-in link for the web history |
| `GET /v1/web/login` | `{"login": "...", "password": true}` |
| `PUT`/`DELETE /v1/web/login` | sets (`{"login", "password"}`) or removes the web history password |
