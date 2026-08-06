#!/usr/bin/env python3
"""Offline verification for a signed TROOP update envelope and its assets."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--envelope", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--dist", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()

    envelope = json.loads(args.envelope.read_text(encoding="utf-8"))
    if envelope.get("algorithm") != "rsa-pkcs1v15-sha256":
        raise SystemExit("Unexpected signature algorithm")
    if envelope.get("key_id") != "troop-update-rsa-2026-01":
        raise SystemExit("Unexpected signing key")
    payload_bytes = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    with tempfile.TemporaryDirectory(prefix="troop-update-verify-") as temp_name:
        temp = Path(temp_name)
        payload_path = temp / "payload.json"
        signature_path = temp / "payload.sig"
        payload_path.write_bytes(payload_bytes)
        signature_path.write_bytes(signature)
        subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(args.public_key.resolve()),
                "-signature", str(signature_path), str(payload_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    payload = json.loads(payload_bytes)
    if payload["repository"] != args.repository:
        raise SystemExit("Manifest repository mismatch")
    if payload["tag"] != "v" + payload["version"]:
        raise SystemExit("Manifest tag/version mismatch")
    for kind, asset in payload["assets"].items():
        path = args.dist / asset["name"]
        if not path.is_file():
            raise SystemExit(f"Missing {kind} asset: {path}")
        if path.stat().st_size != asset["size"]:
            raise SystemExit(f"Size mismatch for {path.name}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != asset["sha256"]:
            raise SystemExit(f"SHA-256 mismatch for {path.name}")
    print(f"Verified signed TROOP {payload['version']} update and all assets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
