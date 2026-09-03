#!/usr/bin/env python3
"""Regenerate portable engine shaders on a Mac with Metal GPU + Apple toolchain.

This is a developer build step, not something players run. Outputs and logs go
to new directories only. The extractor runs in a separate empty project so
host/editor shader caches cannot leak into the exported cache inventory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

from metal_shader_cache import ENGINE_VERSION, extract_tree, verify_tree


RECIPE = Path(__file__).resolve().parent / "metal_baker"


def recipe_sha256() -> str:
    digest = hashlib.sha256()
    for name in ("project.godot", "export_presets.cfg", "main.tscn"):
        digest.update(name.encode() + b"\0" + (RECIPE / name).read_bytes() + b"\0")
    return digest.hexdigest()


def run_logged(command: list[str], log: Path, timeout: int = 300) -> None:
    with log.open("wb") as handle:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=handle,
                                   stderr=subprocess.STDOUT, cwd=log.parent, start_new_session=True)
        try:
            result = process.wait(timeout=timeout)
        finally:
            # A failed/timed-out leader can exit before poll(), while its Metal
            # compiler children are still running. The session belongs to this
            # invocation even after the leader exits, so always clean it.
            stop_owned_group(process)
    output = log.read_text(errors="replace")
    if result != 0 or "ERROR:" in output:
        raise RuntimeError(f"build failed; inspect {log}")


def stop_owned_group(process: subprocess.Popen) -> None:
    # Godot's baker spawns compiler children. Always send both signals to the
    # owned session; the leader may exit before a compiler has acknowledged TERM.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        except OSError:
            try:
                process.kill() if sig == signal.SIGKILL else process.terminate()
            except ProcessLookupError:
                pass  # Direct-child exit raced the group-signal fallback.
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            if sig == signal.SIGKILL:
                raise


def isolate_runtime(project: Path, user_name: str) -> None:
    # Runtime-only settings in the disposable copy; never change the pinned
    # shader recipe. Unique user directories avoid cross-run logs/preferences.
    (project / "override.cfg").write_text(
        '[application]\nconfig/use_custom_user_dir=true\n'
        f'config/custom_user_dir_name={json.dumps(user_name)}\n', encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify", type=Path, help="Verify checked-in inputs; no GPU or writes")
    args = parser.parse_args()
    settings_hash = recipe_sha256()
    if args.verify is not None:
        manifest = verify_tree(args.verify, engine_version=ENGINE_VERSION,
                               settings_sha256=settings_hash, target_min_os="11.0")
        print(f"METAL_CACHE_VERIFIED {len(manifest['files'])} groups")
        return 0
    if sys.platform != "darwin" or args.output is None:
        parser.error("baking requires macOS and --output pointing to a NEW directory")
    if args.output.exists() or args.output.is_symlink():
        parser.error("refusing to overwrite an existing output")
    godot = shutil.which(args.godot)
    if godot is None:
        parser.error("Godot executable not found")
    version = subprocess.check_output([godot, "--version"], text=True, timeout=15).strip()
    if version != ENGINE_VERSION:
        parser.error(f"requires exactly {ENGINE_VERSION}, got {version}")
    compiler = subprocess.check_output(["xcrun", "-sdk", "macosx", "metal", "--version"],
                                       text=True, timeout=30).strip()
    scratch = Path(tempfile.mkdtemp(prefix="troop-metal-bake-", dir="/tmp")).resolve()
    print(f"METAL_BAKE_LOGS {scratch}", flush=True)
    project = scratch / "project"
    shutil.copytree(RECIPE, project, ignore=shutil.ignore_patterns(".godot", "*.uid"))
    isolate_runtime(project, f"{scratch.name}-baker")
    pack = scratch / "baked.pck"
    run_logged([godot, "--path", str(project), "--rendering-driver", "metal",
                "--log-file", str(scratch / "bake-engine.log"),
                "--export-pack", "macOS", str(pack)], scratch / "bake.log")
    # A mounted PCK and the filesystem are merged by Godot. Never extract from
    # the baker project, whose .godot contains host-specific runtime shaders.
    extractor = scratch / "extractor"
    extractor.mkdir()
    (extractor / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="TROOP cache extraction"\n')
    isolate_runtime(extractor, f"{scratch.name}-extractor")
    extracted = scratch / "exported-cache"
    run_logged([godot, "--headless", "--path", str(extractor), "--script",
                str(project / "extract_cache.gd"), "--log-file", str(scratch / "extract-engine.log"),
                "--", str(pack), str(extracted)],
               scratch / "extract.log", timeout=30)
    manifest = extract_tree(extracted, args.output.resolve(), engine_version=version,
                            settings_sha256=settings_hash, target_min_os="11.0", omit_invalid=True)
    verify_tree(args.output, engine_version=version, settings_sha256=settings_hash,
                target_min_os="11.0")
    (scratch / "provenance.json").write_text(json.dumps({
        "engine_version": version, "compiler": compiler, "settings_sha256": settings_hash,
        "pack_sha256": hashlib.sha256(pack.read_bytes()).hexdigest(),
        "output": str(args.output.resolve()), "groups": len(manifest["files"]),
        "omitted": manifest["omitted"],
    }, indent=2) + "\n")
    print(f"METAL_CACHE_BUILT {len(manifest['files'])} groups; {len(manifest['omitted'])} omitted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
