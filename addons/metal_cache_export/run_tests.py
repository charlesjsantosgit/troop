#!/usr/bin/env python3
"""Bounded headless plugin tests in a fresh, autoload-free temporary project.

No game startup, real game user directory, cache baking, GPU, or export template
is involved. Temporary inputs and complete logs are retained for inspection.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    root = Path(tempfile.mkdtemp(prefix="troop-metal-export-test-")).resolve()
    project = root / "project"
    plugin = project / "addons" / "metal_cache_export"
    plugin.mkdir(parents=True)
    for name in ("export_plugin.gd", "test_export_plugin.gd"):
        shutil.copy2(source / name, plugin / name)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Metal export unit test"\n'
    )
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("TROOP_", "GODOT_", "DYLD_"))}
    environment["TROOP_METAL_EXPORT_TEST_ROOT"] = str(root / "fixtures")
    command = [args.godot, "--headless", "--path", str(project),
               "--script", "res://addons/metal_cache_export/test_export_plugin.gd"]
    print(f"METALCACHEEXPORTTEST logs/fixtures: {root}", flush=True)
    with (root / "test.log").open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        try:
            return_code = process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)
            return_code = 1
    output = (root / "test.log").read_text()
    print(output, end="")
    if return_code or " PASS\n" not in output or "SCRIPT ERROR:" in output or "ERROR:" in output:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
