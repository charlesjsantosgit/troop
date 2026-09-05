#!/usr/bin/env python3
"""Actual ENet buyer/visitor/restart test, with isolated saves and identities."""
import argparse
import json
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", shutil.which("godot") or "godot"))
parser.add_argument("--project", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
args = parser.parse_args()
ROOT = args.project.resolve()
OUTPUT = ROOT / "artifacts" / "crownreach"
OUTPUT.mkdir(parents=True, exist_ok=True)
run_dir = pathlib.Path(tempfile.mkdtemp(prefix="troop-city-network-"))
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
processes = []
logs = []

def start(role, suffix=""):
    log = (run_dir / f"{role}{suffix}.log").open("w")
    logs.append(log)
    process = subprocess.Popen([
        args.godot, "--headless", "--audio-driver", "Dummy", "--path", str(ROOT),
        "--script", "res://tests/citynetworktest.gd", "--", role, str(port), str(run_dir)
    ], stdout=log, stderr=subprocess.STDOUT)
    processes.append(process)
    return process

def ready(server):
    deadline = time.monotonic() + 25
    while not (run_dir / "ready").exists():
        if server.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError("server did not become ready")
        time.sleep(0.1)

result = {"directory": str(run_dir), "port": port, "passed": False}
try:
    server = start("server")
    ready(server)
    for role in ("buyer", "visitor"):
        if start(role).wait(timeout=85) != 0:
            raise RuntimeError(f"{role} failed")
    (run_dir / "stop").touch()
    if server.wait(timeout=15) != 0:
        raise RuntimeError("server checkpoint failed")
    (run_dir / "stop").unlink()
    (run_dir / "ready").unlink()
    server = start("server", "-restart")
    ready(server)
    if start("resume").wait(timeout=45) != 0:
        raise RuntimeError("restart verification failed")
    (run_dir / "stop").touch()
    if server.wait(timeout=15) != 0:
        raise RuntimeError("restart shutdown failed")
    for path in run_dir.glob("*.log"):
        contents = path.read_text()
        if "SCRIPT ERROR" in contents or "CITYNETWORK_" not in contents or " FAIL" in contents:
            raise RuntimeError(f"unexpected error in {path.name}")
    result["passed"] = True
except Exception as error:
    result["error"] = str(error)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
    for log in logs:
        log.close()
    (OUTPUT / "network-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
raise SystemExit(0 if result["passed"] else 1)
