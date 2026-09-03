#!/usr/bin/env python3
"""Verify an exported PCK contains exactly the pinned, byte-identical Metal cache.

The extractor mounts the pack only after Godot has started headlessly in a NEW
empty project. A mounted pack merges with res://, so neither the game project
nor the baker project may be used as the extraction project. Logs and extracted
bytes remain in a unique temporary directory; no input is changed or overwritten.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

from bake_metal_cache import RECIPE, recipe_sha256
from metal_shader_cache import CacheError, ENGINE_VERSION, cache_files, verify_tree


class PackedCacheError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def stop_own_child(process: subprocess.Popen) -> None:
    """Bounded cleanup of this handle/group only, including macOS group denial."""
    for force in (False, True):
        if process.poll() is not None:
            return
        signaled = False
        if os.name == "posix":
            try:
                os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
                signaled = True
            except OSError:
                pass
        if not signaled and process.poll() is None:
            try:
                process.kill() if force else process.terminate()
            except OSError:
                pass  # A concurrent exit is reaped by wait; otherwise escalate.
        try:
            process.wait(timeout=3)
            return
        except subprocess.TimeoutExpired:
            continue
    raise PackedCacheError(f"owned Godot process {process.pid} did not exit after TERM/KILL")


def run_logged(command: list[str], log: Path, timeout: int) -> str:
    options = {"start_new_session": True} if os.name == "posix" else {
        "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP
    }
    with log.open("xb") as handle:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=handle,
                                   stderr=subprocess.STDOUT, cwd=log.parent, **options)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            raise PackedCacheError(f"Godot timed out after {timeout}s; inspect {log}") from exc
        finally:
            stop_own_child(process)
    output = log.read_text(encoding="utf-8", errors="replace")
    if status != 0 or "ERROR:" in output:
        raise PackedCacheError(f"Godot failed with exit {status}; inspect {log}")
    return output


def compare_extracted_cache(root: Path, manifest: dict) -> int:
    """Compare a raw extracted tree (no files/ prefix) with validated records."""
    actual = {path.relative_to(root).as_posix(): path for path in cache_files(root)}
    expected = {record["path"]: record for record in manifest["files"]}
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    if missing or extra:
        raise PackedCacheError(f"packed cache inventory differs: missing={missing}, extra={extra}")
    for relative, path in actual.items():
        record = expected[relative]
        if path.stat().st_size != record["size"] or sha256_file(path) != record["sha256"]:
            raise PackedCacheError(f"packed cache bytes differ from pinned manifest: {relative}")
    return len(actual)


def verify_pack(godot: str, pack: Path, cache: Path) -> dict:
    pack = pack.resolve(strict=True)
    cache = cache.resolve(strict=True)
    if not pack.is_file():
        raise PackedCacheError("PCK input must be a file")
    with pack.open("rb") as handle:
        if handle.read(4) != b"GDPC":
            raise PackedCacheError("input is not a Godot PCK")
    manifest = verify_tree(cache, engine_version=ENGINE_VERSION,
                           settings_sha256=recipe_sha256(), target_min_os="11.0")
    scratch = Path(tempfile.mkdtemp(prefix="troop-packed-metal-cache-")).resolve()
    print(f"METAL_PACKED_CACHE_LOGS {scratch}", flush=True)
    version = run_logged([godot, "--version"], scratch / "version.log", 15).strip()
    if version != ENGINE_VERSION:
        raise PackedCacheError(f"requires exactly {ENGINE_VERSION}, got {version}")
    project = scratch / "empty-project"
    project.mkdir()
    (project / "project.godot").write_text(
        'config_version=5\n\n[application]\n'
        'config/name="TROOP packed cache verification"\n'
        'config/use_custom_user_dir=true\n'
        f'config/custom_user_dir_name="{scratch.name}"\n'
        '\n[debug]\nfile_logging/enable_file_logging=false\n', encoding="utf-8")
    extracted = scratch / "extracted-cache"
    output = run_logged(
        [godot, "--headless", "--path", str(project), "--script",
         str((RECIPE / "extract_cache.gd").resolve()), "--", str(pack), str(extracted)],
        scratch / "extract.log", 30)
    counts = re.findall(r"^EXTRACTED_METAL_GROUPS ([0-9]+)$", output, re.MULTILINE)
    if len(counts) != 1 or int(counts[0]) != len(manifest["files"]):
        raise PackedCacheError("extractor did not report the exact pinned group count")
    count = compare_extracted_cache(extracted, manifest)
    report = {"pack": str(pack), "pack_sha256": sha256_file(pack),
              "cache": str(cache), "manifest_sha256": sha256_file(cache / "manifest.json"),
              "engine_version": version, "groups": count, "logs": str(scratch)}
    (scratch / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--cache", type=Path,
                        default=Path(__file__).resolve().parent / "metal_cache")
    parser.add_argument("--pack", type=Path, required=True)
    args = parser.parse_args()
    godot = shutil.which(args.godot)
    if godot is None:
        parser.error("Godot executable not found")
    try:
        report = verify_pack(godot, args.pack, args.cache)
    except (PackedCacheError, CacheError, OSError, ValueError, KeyboardInterrupt) as exc:
        print(f"METAL_PACKED_CACHE FAIL: {exc or 'interrupted'}", file=sys.stderr)
        return 1
    print(f"METAL_PACKED_CACHE_VERIFIED {report['groups']} groups pack={report['pack']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
