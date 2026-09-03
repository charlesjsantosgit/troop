#!/usr/bin/env python3
"""Run TROOP's bounded real-ENet dedicated release gate on localhost only."""

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
import time
import uuid


class RelayFailure(RuntimeError):
    pass


class RelayRun:
    def __init__(self, godot: str, project: Path) -> None:
        self.godot = godot
        self.project = project
        self.logs = Path(tempfile.mkdtemp(prefix="troop-dedicated-relay-"))
        self.run_id = uuid.uuid4().hex
        self.children: dict[str, subprocess.Popen] = {}
        self.handles = []
        self.deadline = time.monotonic() + 75.0
        # Resolve a free loopback UDP port before starting Godot. If another
        # process wins the brief close/start race, READY fails instead of
        # connecting to or terminating a pre-existing server.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]

    def output(self, role: str) -> str:
        path = self.logs / f"{role}.log"
        return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""

    def start(self, role: str) -> None:
        environment = os.environ.copy()
        for name in ("TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR"):
            environment.pop(name, None)
        environment["TROOP_RELAY_TEST_RUN"] = self.run_id
        handle = (self.logs / f"{role}.log").open("wb")
        self.handles.append(handle)
        options = {"start_new_session": True} if os.name == "posix" else {
            "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP
        }
        self.children[role] = subprocess.Popen(
            [self.godot, "--headless", "--path", str(self.project),
             "--max-fps", "60", "--quit-after", "4200", "--script",
             "res://tests/dedicatedrelaytest.gd", "--", role, str(self.port)],
            stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT,
            cwd=self.project, env=environment, **options,
        )

    def wait_for(self, role: str, marker: str, timeout: float) -> None:
        deadline = min(self.deadline, time.monotonic() + timeout)
        while time.monotonic() < deadline:
            output = self.output(role)
            if marker in output:
                return
            if " FAIL " in output or "SCRIPT ERROR:" in output:
                raise RelayFailure(f"{role} reported an error")
            status = self.children[role].poll()
            if status is not None:
                raise RelayFailure(f"{role} exited {status} before {marker}")
            time.sleep(0.05)
        raise RelayFailure(f"{role} timed out waiting for {marker}")

    def require_pass(self, role: str, timeout: float = 20.0) -> None:
        marker = f"DEDICATEDRELAY-{role.upper()} PASS "
        self.wait_for(role, marker, timeout)
        remaining = max(0.01, min(5.0, self.deadline - time.monotonic()))
        try:
            status = self.children[role].wait(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            raise RelayFailure(f"{role} did not exit after PASS") from exc
        if status != 0 or "ERROR:" in self.output(role):
            raise RelayFailure(f"{role} exited {status} or logged an engine error")

    def cleanup(self) -> None:
        # Signal only live child process groups created by this runner. Never
        # find/kill processes by executable name, port, or user identity.
        for process in self.children.values():
            if process.poll() is None:
                try:
                    if os.name == "posix":
                        os.killpg(process.pid, signal.SIGTERM)
                    else:
                        process.terminate()
                except ProcessLookupError:
                    pass
        for process in self.children.values():
            if process.poll() is None:
                try:
                    process.wait(timeout=3.0)
                except subprocess.TimeoutExpired:
                    try:
                        if os.name == "posix":
                            os.killpg(process.pid, signal.SIGKILL)
                        else:
                            process.kill()
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=3.0)
        for handle in self.handles:
            handle.close()
        # Godot removes test identities on normal exit. Also cover interrupted
        # children, using only the exact unique per-run directory they reported
        # and six explicitly named files. Logs and unrelated files are retained.
        for role in self.children:
            expected_name = f"TROOP-dedicated-relay-{self.port}-{role}-{self.run_id}"
            for line in self.output(role).splitlines():
                if not line.startswith("DEDICATEDRELAY-USERDIR "):
                    continue
                directory = Path(line.removeprefix("DEDICATEDRELAY-USERDIR "))
                if not directory.is_absolute() or directory.name != expected_name:
                    raise RelayFailure("fixture reported an unexpected identity directory")
                if directory.is_symlink():
                    raise RelayFailure("fixture identity directory must not be a symlink")
                for filename in ("admin_identity.key", "admin_identity_secret.txt"):
                    for suffix in ("", ".tmp", ".bak"):
                        (directory / (filename + suffix)).unlink(missing_ok=True)

    def run(self) -> None:
        self.start("server")
        self.wait_for("server", "DEDICATEDRELAY-SERVER READY ", 15.0)
        for role in ("reject-version", "reject-protocol"):
            self.start(role)
            self.require_pass(role)
        self.start("receiver")
        self.wait_for("receiver", "DEDICATEDRELAY-RECEIVER READY ", 20.0)
        self.start("sender")
        for role in ("sender", "receiver", "server"):
            self.require_pass(role)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot", help="Godot 4.7 executable")
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    executable = shutil.which(arguments.godot)
    if executable is None:
        parser.error(f"Godot executable not found: {arguments.godot}")
    project = arguments.project.resolve()
    if not (project / "tests" / "dedicatedrelaytest.gd").is_file():
        parser.error(f"dedicatedrelaytest.gd not found in {project}")
    run = RelayRun(executable, project)
    failure = ""
    try:
        run.run()
    except (RelayFailure, OSError, KeyboardInterrupt) as exc:
        failure = str(exc) or "interrupted"
    finally:
        try:
            run.cleanup()
        except (RelayFailure, OSError, subprocess.TimeoutExpired) as exc:
            failure = f"{failure}; cleanup: {exc}" if failure else f"cleanup: {exc}"
    if failure:
        print(f"DEDICATEDRELAY-CI FAIL {failure}\nLogs: {run.logs}", file=sys.stderr)
        for role in run.children:
            tail = "\n".join(run.output(role).splitlines()[-8:])
            print(f"[{role}]\n{tail}", file=sys.stderr)
        return 1
    print(f"DEDICATEDRELAY-CI PASS two clients; version/protocol rejection; "
          f"movement/combat/chat/voice/claims/disconnect\nLogs: {run.logs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
