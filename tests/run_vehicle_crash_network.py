#!/usr/bin/env python3
"""Real ENet vehicle damage, fatal release, outsider rejection and late-join test."""
import argparse
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", shutil.which("godot") or "godot"))
parser.add_argument("--project", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
args = parser.parse_args()
project = args.project.resolve()
output = project / "artifacts" / "city-traffic"
output.mkdir(parents=True, exist_ok=True)
run_dir = pathlib.Path(tempfile.mkdtemp(prefix="troop-vehicle-crash-"))
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
processes = {}
logs = {}


def start(role):
    logs[role] = (run_dir / f"{role}.log").open("w")
    processes[role] = subprocess.Popen([
        args.godot, "--headless", "--audio-driver", "Dummy", "--path", str(project),
        "--script", "res://tests/vehiclecrashnetworktest.gd", "--", role, str(port), str(run_dir)
    ], stdout=logs[role], stderr=subprocess.STDOUT)


def wait_for_file(name, seconds=25):
    deadline = time.monotonic() + seconds
    while not (run_dir / name).exists():
        if processes["server"].poll() is not None or time.monotonic() > deadline:
            raise RuntimeError(f"server did not produce {name}")
        time.sleep(0.05)


result = {"directory": str(run_dir), "port": port, "passed": False, "roles": {}}
try:
    start("server")
    wait_for_file("ready")
    start("observer")
    start("driver")
    for role in ("driver", "observer"):
        if processes[role].wait(timeout=65) != 0:
            raise RuntimeError(f"{role} failed")
    wait_for_file("server-wrecks")
    start("late")
    if processes["late"].wait(timeout=35) != 0:
        raise RuntimeError("late-join verification failed")
    (run_dir / "stop").touch()
    if processes["server"].wait(timeout=15) != 0:
        raise RuntimeError("authority shutdown verification failed")
    for role in processes:
        contents = (run_dir / f"{role}.log").read_text()
        match = re.search(rf"VEHICLECRASHNETTEST {role} (\d+)/(\d+) PASS", contents)
        if not match or match[1] != match[2] or "SCRIPT ERROR" in contents or " FAIL" in contents:
            raise RuntimeError(f"unexpected failure in {role}.log")
        result["roles"][role] = {"passed": int(match[1]), "checks": int(match[2])}
    result["checks"] = sum(row["checks"] for row in result["roles"].values())
    if result["checks"] < 46:
        raise RuntimeError("required crash replication coverage did not complete")
    result["passed"] = True
except Exception as error:
    result["error"] = str(error)
finally:
    for process in processes.values():
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    for log in logs.values():
        log.close()
    for role in processes:
        shutil.copy2(run_dir / f"{role}.log", output / f"crash-network-{role}.log")
    (output / "crash-network-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
raise SystemExit(0 if result["passed"] else 1)
