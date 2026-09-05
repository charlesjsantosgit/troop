#!/usr/bin/env python3
"""Actual simultaneous ENet clients, civil authority, identity reconnect and restart."""
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
output = project / "artifacts" / "civil-network"
output.mkdir(parents=True, exist_ok=True)
run_dir = pathlib.Path(tempfile.mkdtemp(prefix="troop-civil-network-"))
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
processes = {}
logs = {}


def start(role, suffix=""):
    name = role + suffix
    logs[name] = (run_dir / f"{name}.log").open("w")
    processes[name] = subprocess.Popen([
        args.godot, "--headless", "--audio-driver", "Dummy", "--path", str(project),
        "--", "civilnetworktest", role, str(port), str(run_dir),
    ], stdout=logs[name], stderr=subprocess.STDOUT)
    return processes[name]


def wait_file(name, server, seconds=30):
    deadline = time.monotonic() + seconds
    while not (run_dir / name).exists():
        if server.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError(f"authority did not produce {name}")
        time.sleep(0.05)


def completed(process, role, seconds):
    if process.wait(timeout=seconds) != 0:
        raise RuntimeError(f"{role} failed; inspect {run_dir / (role + '.log')}")


result = {"directory": str(run_dir), "port": port, "passed": False, "roles": {}}
try:
    server = start("server")
    wait_file("ready", server)
    observer = start("observer")
    robber = start("robber")
    completed(robber, "robber", 75)
    completed(observer, "observer", 15)
    completed(start("resume"), "resume", 35)
    (run_dir / "stop").touch()
    completed(server, "server", 15)
    (run_dir / "stop").unlink()
    (run_dir / "ready").unlink()
    (run_dir / "restarting").touch()
    server = start("server", "-restart")
    wait_file("ready", server)
    completed(start("restart"), "restart", 35)
    (run_dir / "stop").touch()
    completed(server, "server-restart", 15)
    for name in processes:
        contents = (run_dir / f"{name}.log").read_text()
        role = "server" if name == "server-restart" else name
        match = re.search(rf"CIVILNETWORK_{role.upper()} (\d+)/(\d+) PASS", contents)
        if not match or match[1] != match[2] or "SCRIPT ERROR" in contents or " FAIL" in contents:
            raise RuntimeError(f"missing coverage or script error in {name}.log")
        result["roles"][name] = {"passed": int(match[1]), "checks": int(match[2])}
    result["checks"] = sum(row["checks"] for row in result["roles"].values())
    if result["checks"] < 70:
        raise RuntimeError("required civil network coverage did not complete")
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
    for name in processes:
        shutil.copy2(run_dir / f"{name}.log", output / f"{name}.log")
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
raise SystemExit(0 if result["passed"] else 1)
