#!/usr/bin/env python3
"""Bounded loopback-only updater timeout/cancel responsiveness regression.

Copies the production updater and fixture into a minimal temporary project, so
no game autoload, player data, graphics device, or public endpoint is involved.
Run: python3 tests/run_updater_http.py --godot /path/to/godot --project .
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


CASES = ("manifest_headers", "manifest_body", "cancel_headers", "cancel_body",
         "teardown_headers", "teardown_body")


class ProbeFailure(RuntimeError):
    pass


class StalledServer:
    def __init__(self, partial_body: bool) -> None:
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(4.0)
        self.port = self.listener.getsockname()[1]
        self.partial_body = partial_body
        self.stop = threading.Event()
        self.accepted = False
        self.error = ""
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        try:
            connection, _ = self.listener.accept()
            with connection:
                connection.settimeout(1.0)
                data = b""
                while b"\r\n\r\n" not in data and len(data) < 4096:
                    chunk = connection.recv(4096 - len(data))
                    if not chunk:
                        break
                    data += chunk
                if b"\r\n\r\n" not in data:
                    raise ProbeFailure("client did not send complete bounded headers")
                self.accepted = True
                if self.partial_body:
                    connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1024\r\n"
                                       b"Connection: close\r\n\r\n" + b"x" * 32)
                # The old threaded implementation blocks cancellation until
                # this close. It must fail the fixture's tighter frame bound,
                # while the independent supervisor still has a safe endpoint.
                self.stop.wait(2.0)
        except (OSError, ProbeFailure) as exc:
            if not self.stop.is_set():
                self.error = str(exc)

    def close(self) -> None:
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=5.0)
        if self.thread.is_alive():
            raise ProbeFailure("owned loopback server did not stop")


def stop_child(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
    except OSError:
        # Some desktop hosts deny process-group signals even for our child.
        # The direct child handle is still scoped to this run and can be used.
        try:
            process.terminate()
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except OSError:
            try:
                process.kill()
            except ProcessLookupError:
                pass
        process.wait(timeout=2.0)


def run_case(godot: str, project: Path, logs: Path, case: str) -> None:
    server = StalledServer(case.endswith("_body"))
    process = None
    log_path = logs / f"{case}.log"
    try:
        with log_path.open("wb") as output:
            options = {"start_new_session": True} if os.name == "posix" else {
                "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP,
            }
            process = subprocess.Popen(
                [godot, "--headless", "--path", str(project), "--max-fps", "60",
                 "--quit-after", "600", "--log-file", str(logs / f"{case}-engine.log"),
                 "--script", "res://tests/updaterhttptest.gd", "--", case, str(server.port)],
                cwd=project, stdin=subprocess.DEVNULL, stdout=output,
                stderr=subprocess.STDOUT, **options,
            )
            status = process.wait(timeout=8.0)
        text = log_path.read_text(encoding="utf-8", errors="replace")
        marker = f"UPDATERHTTPTEST {case} PASS "
        if status != 0 or marker not in text or "ERROR:" in text:
            raise ProbeFailure(f"{case} failed (exit {status}):\n{text}")
        if not server.accepted or server.error:
            raise ProbeFailure(f"{case} loopback server: {server.error or 'no request'}")
        print(next(line for line in text.splitlines() if line.startswith(marker)))
    finally:
        try:
            if process is not None:
                stop_child(process)
        finally:
            server.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    godot = shutil.which(args.godot)
    if godot is None:
        parser.error(f"Godot executable not found: {args.godot}")
    source = args.project.resolve()
    for relative in ("scripts/updater.gd", "tests/updaterhttptest.gd"):
        if not (source / relative).is_file():
            parser.error(f"missing source file: {source / relative}")
    scratch = Path(tempfile.mkdtemp(prefix="troop-updater-http-"))
    project = scratch / "project"
    logs = scratch / "logs"
    (project / "scripts").mkdir(parents=True)
    (project / "tests").mkdir()
    logs.mkdir()
    for relative in ("scripts/updater.gd", "tests/updaterhttptest.gd"):
        shutil.copy2(source / relative, project / relative)
    (project / "project.godot").write_text(
        'config_version=5\n\n[application]\nconfig/name="TROOP updater HTTP fixture"\n'
        'config/use_custom_user_dir=true\n'
        f'config/custom_user_dir_name="TROOP-updater-http-{uuid.uuid4().hex}"\n'
        'run/max_fps=60\n\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n',
        encoding="utf-8",
    )
    began = time.monotonic()
    try:
        for case in CASES:
            run_case(godot, project, logs, case)
    except (ProbeFailure, OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
        print(f"UPDATERHTTP-CI FAIL {exc}\nLogs: {logs}", file=sys.stderr)
        return 1
    print(f"UPDATERHTTP-CI PASS {len(CASES)}/{len(CASES)} cases "
          f"elapsed={time.monotonic() - began:.2f}s\nLogs: {logs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
