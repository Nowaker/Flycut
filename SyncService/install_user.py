"""Initialize and install a task-owned Linux user service without exposing secrets."""

import argparse
import ipaddress
import json
import os
import secrets
import subprocess
from pathlib import Path
from uuid import uuid4

from SyncService.protocol import Failure, parse_json, uuid_string


def install(root: Path, address: str, port: int) -> None:
    root = root.resolve()
    ip = ipaddress.IPv4Address(address)
    if ip not in ipaddress.IPv4Network("100.64.0.0/10") or not 1 <= port <= 65535:
        raise Failure(400, "explicit_tailnet_address_required")
    if not (root / "SyncService" / "server.py").is_file():
        raise Failure(400, "service_source_missing")
    if any(character in str(root) for character in ('"', "\\", "%", "\n")):
        raise Failure(400, "unsupported_install_path")
    os.umask(0o077)
    marker = root / "deployment.json"
    if marker.exists():
        metadata = parse_json(marker.read_bytes())
        if not isinstance(metadata, dict) or metadata.get("service") != "flycut-gpt-sync":
            raise Failure(400, "deployment_not_owned")
        collection = uuid_string(metadata["collection_id"])
        if metadata.get("bind") != address or metadata.get("port") != port:
            raise Failure(400, "deployment_address_changed")
    else:
        if {p.name for p in root.iterdir()} != {"SyncService"}:
            raise Failure(400, "deployment_directory_not_empty")
        collection = str(uuid4())
        token = secrets.token_urlsafe(32)
        with (root / ".env").open("x", encoding="utf-8") as output:
            output.write("FLYCUT_SYNC_GRANTS='" + json.dumps({token: [collection]}) + "'\n")
        (root / ".env.example").write_text("FLYCUT_SYNC_GRANTS='{\"<random-token>\":[\"<collection-uuid>\"]}'\n", encoding="utf-8")
        client = root / "client"
        client.mkdir(mode=0o700)
        with (client / ".env").open("x", encoding="utf-8") as output:
            output.write(f"FLYCUT_SYNC_URL=http://{address}:{port}\nFLYCUT_SYNC_COLLECTION={collection}\nFLYCUT_SYNC_TOKEN={token}\n")
        (client / ".env.example").write_text("FLYCUT_SYNC_URL=http://<tailnet-ip>:19787\nFLYCUT_SYNC_COLLECTION=<collection-uuid>\nFLYCUT_SYNC_TOKEN=<random-token>\n", encoding="utf-8")
        marker.write_text(json.dumps({"service": "flycut-gpt-sync", "collection_id": collection, "bind": address, "port": port}), encoding="utf-8")
    root.chmod(0o700)
    unit_directory = Path.home() / ".config" / "systemd" / "user"
    unit_directory.mkdir(parents=True, exist_ok=True)
    unit = unit_directory / "flycut-gpt-sync.service"
    description = "Description=Flycut GPT authenticated event sync"
    if unit.exists() and description not in unit.read_text(encoding="utf-8").splitlines():
        raise Failure(400, "existing_unit_not_owned")
    unit.write_text("\n".join(["[Unit]", description, "After=network.target", "", "[Service]",
        "Type=simple", f"WorkingDirectory={root}",
        f'ExecStart=/usr/bin/python3 -m SyncService.server --database "{root}/events.sqlite" --env-file "{root}/.env" --collection {collection} --bind {address} --port {port} --secured-tailnet',
        "UMask=0077", "Restart=on-failure", "RestartSec=3", "NoNewPrivileges=true",
        "", "[Install]", "WantedBy=default.target", ""]), encoding="utf-8")
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "--user", "enable", "--now", "flycut-gpt-sync.service"], check=True)
    print(f"Installed flycut-gpt-sync at http://{address}:{port}; collection {collection}")
    print(f"Client credentials file: {root}/client/.env (never print contents)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Install isolated persistent Flycut GPT user service; generates .env secrets internally.")
    parser.add_argument("--directory", type=Path, required=True, help="Task-owned directory containing only copied SyncService subtree on first install")
    parser.add_argument("--bind", required=True, help="Explicit secured tailnet IPv4 address")
    parser.add_argument("--port", type=int, default=19787)
    args = parser.parse_args()
    install(args.directory, args.bind, args.port)


if __name__ == "__main__":
    main()
