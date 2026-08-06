#!/usr/bin/env python3
"""Validate a release tag and inject its public service endpoints into TROOP."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\Z")
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
HOST_RE = re.compile(
    r"(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\Z"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--server-host", required=True)
    parser.add_argument(
        "--project", type=Path, default=Path(__file__).resolve().parents[1] / "project.godot"
    )
    parser.add_argument(
        "--metadata", type=Path, default=Path(__file__).with_name("release_metadata.json")
    )
    parser.add_argument(
        "--net-script",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "scripts" / "net.gd",
    )
    args = parser.parse_args()

    if not VERSION_RE.fullmatch(args.version):
        parser.error("--version must be a numeric TROOP version")
    if not REPOSITORY_RE.fullmatch(args.repository):
        parser.error("--repository must be an OWNER/REPO slug")
    if not HOST_RE.fullmatch(args.server_host):
        parser.error("--server-host must be a hostname or IPv4 address without a port")

    project_path = args.project.resolve()
    text = project_path.read_text(encoding="utf-8")
    version_match = re.search(r'^config/version="([^"]+)"$', text, re.MULTILINE)
    if not version_match:
        parser.error("project.godot has no application config/version")
    if version_match.group(1) != args.version:
        parser.error(
            f"tag version {args.version} does not match project.godot "
            f"version {version_match.group(1)}"
        )
    protocol_match = re.search(
        r'^config/network_protocol=([0-9]+)$', text, re.MULTILINE
    )
    metadata = json.loads(args.metadata.read_text(encoding="utf-8"))
    if not protocol_match:
        parser.error("project.godot has no application config/network_protocol")
    if int(protocol_match.group(1)) != int(metadata["network_protocol"]):
        parser.error(
            "project.godot network protocol does not match release_metadata.json"
        )
    net_text = args.net_script.read_text(encoding="utf-8")
    net_protocol_match = re.search(
        r"^const PROTOCOL_VERSION := ([0-9]+)$", net_text, re.MULTILINE
    )
    if not net_protocol_match:
        parser.error("scripts/net.gd has no numeric PROTOCOL_VERSION constant")
    if int(net_protocol_match.group(1)) != int(metadata["network_protocol"]):
        parser.error("Net.PROTOCOL_VERSION does not match release_metadata.json")
    updated, count = re.subn(
        r'^config/update_repository="[^"]*"$',
        f'config/update_repository="{args.repository}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        parser.error("project.godot has no application config/update_repository")
    updated, count = re.subn(
        r'^public_server_host="[^"]*"$',
        f'public_server_host="{args.server_host}"',
        updated,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        parser.error("project.godot has no network/public_server_host")
    project_path.write_text(updated, encoding="utf-8")
    print(
        f"Prepared TROOP {args.version} for {args.repository} "
        f"and {args.server_host}:30623"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
