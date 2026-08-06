#!/usr/bin/env python3
"""Create TROOP's signed, single-file GitHub Releases update envelope."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any


VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\Z")
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
KEY_ID = "troop-update-rsa-2026-01"
ALGORITHM = "rsa-pkcs1v15-sha256"


def file_asset(path: Path, repository: str, version: str) -> dict[str, Any]:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "name": path.name,
        "url": (
            f"https://github.com/{repository}/releases/download/"
            f"v{version}/{path.name}"
        ),
        "sha256": digest.hexdigest(),
        "size": path.stat().st_size,
    }


def load_private_key(args: argparse.Namespace, temp_dir: Path) -> Path:
    if args.private_key:
        key_path = args.private_key.resolve()
        if not key_path.is_file():
            raise SystemExit(f"Private key does not exist: {key_path}")
        return key_path
    if not args.private_key_env:
        raise SystemExit("Supply --private-key or --private-key-env")
    encoded = os.environ.get(args.private_key_env, "")
    if not encoded:
        raise SystemExit(f"Environment variable {args.private_key_env} is empty")
    try:
        key_bytes = base64.b64decode(encoded, validate=True)
    except ValueError as exc:
        raise SystemExit("The private-key environment value is not strict base64") from exc
    key_path = temp_dir / "update-private.pem"
    key_path.write_bytes(key_bytes)
    key_path.chmod(0o600)
    return key_path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--dist", type=Path, default=root / "dist")
    parser.add_argument("--metadata", type=Path, default=Path(__file__).with_name("release_metadata.json"))
    parser.add_argument("--public-key", type=Path, default=Path(__file__).with_name("update_public_key.pem"))
    private = parser.add_mutually_exclusive_group(required=True)
    private.add_argument("--private-key", type=Path)
    private.add_argument("--private-key-env")
    args = parser.parse_args()

    if not VERSION_RE.fullmatch(args.version):
        parser.error("--version must be numeric")
    if not REPOSITORY_RE.fullmatch(args.repository):
        parser.error("--repository must be OWNER/REPO")
    dist = args.dist.resolve()
    metadata = json.loads(args.metadata.read_text(encoding="utf-8"))

    names = {
        "content": f"TROOP-{args.version}-content.pck",
        "windows": f"TROOP-{args.version}-Windows-x86_64-Setup.exe",
        "macos": f"TROOP-{args.version}-macOS-universal.dmg",
    }
    paths = {kind: dist / name for kind, name in names.items()}
    missing = [str(path) for path in paths.values() if not path.is_file()]
    if missing:
        raise SystemExit("Missing release assets:\n" + "\n".join(missing))

    payload = {
        "app_id": "com.charlessantos.troop",
        "assets": {
            kind: file_asset(path, args.repository, args.version)
            for kind, path in paths.items()
        },
        "channel": "stable",
        "godot_compatibility": str(metadata["godot_compatibility"]),
        "minimum_bootstrap": int(metadata["minimum_bootstrap"]),
        "network_protocol": int(metadata["network_protocol"]),
        "notes": str(metadata.get("notes", "")),
        "release_url": f"https://github.com/{args.repository}/releases/tag/v{args.version}",
        "repository": args.repository,
        "requires_installer": bool(metadata["requires_installer"]),
        "schema": 1,
        "tag": f"v{args.version}",
        "version": args.version,
    }
    payload_bytes = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")

    with tempfile.TemporaryDirectory(prefix="troop-update-sign-") as temp_name:
        temp = Path(temp_name)
        private_key = load_private_key(args, temp)
        payload_path = temp / "payload.json"
        signature_path = temp / "payload.sig"
        payload_path.write_bytes(payload_bytes)
        subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-sign", str(private_key),
                "-out", str(signature_path), str(payload_path),
            ],
            check=True,
        )
        subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(args.public_key.resolve()),
                "-signature", str(signature_path), str(payload_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        signature = signature_path.read_bytes()

    envelope = {
        "algorithm": ALGORITHM,
        "key_id": KEY_ID,
        "payload": base64.b64encode(payload_bytes).decode("ascii"),
        "signature": base64.b64encode(signature).decode("ascii"),
    }
    output = dist / "TROOP-update.json"
    temporary_output = dist / ".TROOP-update.json.tmp"
    temporary_output.write_text(
        json.dumps(envelope, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary_output, output)
    print(f"Wrote signed update envelope: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
