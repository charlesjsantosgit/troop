#!/usr/bin/env python3
"""Measure a supplied macOS TROOP app's first menu; never export or modify it.

Run alone on the GPU, for example:
  python3 tests/run_native_first_menu.py --app /Applications/TROOP.app --warm-restart

Each invocation creates a disposable app and fresh user:// directory. Optional
warm restart reuses only that invocation's cache. Logs and copies are retained
for inspection. A cold failure is never replaced by a passing warm result.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


PREFIX = "NATIVEFIRSTMENU "


class FirstMenuFailure(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bundle_fingerprint(app: Path) -> dict[str, str]:
    """Reject links before copying/signing: no copy path may point at the source."""
    fingerprint = {}
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            raise FirstMenuFailure(f"app bundle contains a symlink: {path}")
        if path.is_file():
            fingerprint[str(path.relative_to(app))] = sha256_file(path)
        elif not path.is_dir():
            raise FirstMenuFailure(f"unsupported bundle entry: {path}")
    return fingerprint


def inspect_app(app: Path) -> tuple[dict, str]:
    if not app.is_absolute() or app.suffix != ".app" or not app.is_dir():
        raise FirstMenuFailure("--app must identify an existing .app bundle")
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        raise FirstMenuFailure("app has no valid Info.plist") from exc
    name = info.get("CFBundleExecutable") if isinstance(info, dict) else None
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_. -]+", name) \
            or name in (".", ".."):
        raise FirstMenuFailure("invalid CFBundleExecutable")
    executable = app / "Contents/MacOS" / name
    pack = app / "Contents/Resources" / f"{name}.pck"
    for path in (executable, pack):
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(app):
            raise FirstMenuFailure(f"native executable/PCK must be inside the app: {path}")
    if not os.access(executable, os.X_OK):
        raise FirstMenuFailure("bundle executable is not executable")
    return info, name


def sandbox_profile(source_app: Path, real_user_data: Path) -> str:
    for path in (source_app, real_user_data):
        if not path.is_absolute() or path == Path("/"):
            raise FirstMenuFailure("sandbox protection requires specific absolute paths")
    return ("(version 1)\n(allow default)\n"
            f"(deny file-read* file-write* (subpath {json.dumps(str(real_user_data))}))\n"
            f"(deny file-write* (subpath {json.dumps(str(source_app))}))\n"
            '(deny file-write* (subpath "/Applications/TROOP.app"))\n')


def parse_events(output: str) -> list[dict]:
    events = []
    for line in output.splitlines():
        if not line.startswith(PREFIX):
            continue
        try:
            event = json.loads(line[len(PREFIX):])
        except (ValueError, TypeError) as exc:
            raise FirstMenuFailure("invalid observer JSON") from exc
        if not isinstance(event, dict) or not isinstance(event.get("event"), str):
            raise FirstMenuFailure("invalid observer event")
        events.append(event)
    return events


def finite_metric(event: dict, name: str) -> float:
    value = event.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float)) \
            or not math.isfinite(value) or value < 0:
        raise FirstMenuFailure(f"invalid metric: {name}")
    return float(value)


def evaluate_output(output: str, status: int, user_dir: Path,
                    first_menu_limit_ms: float, gap_limit_ms: float,
                    heartbeat_seconds: float, menu_wall_ms: float | None) -> dict:
    events = parse_events(output)
    errors = [line for line in output.splitlines()
              if "SCRIPT ERROR:" in line or line.startswith("ERROR:")
              or ("ObjectDB instances" in line and "leaked" in line)
              or "resources still in use" in line]
    errors += [str(event.get("message", "observer failure")) for event in events
               if event["event"] == "FAIL"]
    if status != 0:
        errors.append(f"process exited {status}")
    by_name = {}
    for name in ("INIT", "READY", "FIRST_PROCESS_FRAME", "FIRST_DRAW", "MENU_VISIBLE", "DONE"):
        matches = [event for event in events if event["event"] == name]
        if len(matches) != 1:
            raise FirstMenuFailure(f"expected one {name} event, got {len(matches)}")
        by_name[name] = matches[0]
    ready = by_name["READY"]
    done = by_name["DONE"]
    if ready.get("user_dir") != str(user_dir) or ready.get("native") is not True \
            or ready.get("rendered") is not True:
        errors.append("startup isolation/native renderer was not confirmed")
    if done.get("menu_visible") is not True or done.get("menu_stayed_visible") is not True \
            or done.get("original_content") is not True:
        errors.append("normal menu/original supplied content is not ready")
    first_menu_ms = finite_metric(done, "first_menu_ms")
    max_gap_ms = finite_metric(done, "max_gap_ms")
    heartbeat_ms = finite_metric(done, "heartbeat_ms")
    if finite_metric(done, "draw_frames") < 2 or heartbeat_ms < heartbeat_seconds * 1000:
        errors.append("insufficient post-menu heartbeat coverage")
    init_ms = finite_metric(by_name["INIT"], "ticks_ms")
    ready_ms = finite_metric(ready, "ticks_ms")
    process_ms = finite_metric(by_name["FIRST_PROCESS_FRAME"], "ticks_ms")
    draw_ms = finite_metric(by_name["FIRST_DRAW"], "ticks_ms")
    if not init_ms <= ready_ms <= process_ms <= draw_ms <= first_menu_ms:
        errors.append("startup timestamps are out of order")
    if abs(first_menu_ms - finite_metric(by_name["MENU_VISIBLE"], "ticks_ms")) > 0.01:
        errors.append("first-menu summary disagrees with menu-visible event")
    # Never allow an observer to drop the startup-to-first-frame interval.
    if max_gap_ms + 0.01 < max(process_ms - ready_ms, draw_ms - ready_ms):
        errors.append("max gap omitted ready-to-first-frame work")
    if any(finite_metric(event, "ms") > max_gap_ms + 0.01
           for event in events if event["event"] == "GAP"):
        errors.append("max gap omitted a logged frame gap")
    if menu_wall_ms is None or not math.isfinite(menu_wall_ms) or menu_wall_ms < 0:
        errors.append("host wall-clock menu observation is missing")
        measured_first_menu_ms = first_menu_ms
    else:
        # This conservative wall-clock value includes process startup, plus up
        # to one 50ms polling interval; report the engine's exact clock as well.
        measured_first_menu_ms = max(first_menu_ms, menu_wall_ms)
    if measured_first_menu_ms > first_menu_limit_ms:
        errors.append(f"first menu {measured_first_menu_ms:.3f}ms exceeds {first_menu_limit_ms:.3f}ms")
    if max_gap_ms > gap_limit_ms:
        errors.append(f"max gap {max_gap_ms:.3f}ms exceeds {gap_limit_ms:.3f}ms")
    return {"passed": not errors, "errors": errors, "engine_first_menu_ms": first_menu_ms,
            "observed_first_menu_wall_ms": menu_wall_ms, "max_gap_ms": max_gap_ms,
            "heartbeat_ms": heartbeat_ms, "first_menu_limit_ms": first_menu_limit_ms,
            "max_gap_limit_ms": gap_limit_ms, "events": events}


def validate_limits(args: argparse.Namespace) -> None:
    for name in ("first_menu_limit_ms", "max_frame_gap_ms"):
        value = getattr(args, name)
        if not math.isfinite(value) or not 0 < value <= 60000:
            raise FirstMenuFailure(f"{name} must be finite and in (0, 60000]")
    if not math.isfinite(args.heartbeat_seconds) or not 5 <= args.heartbeat_seconds <= 10:
        raise FirstMenuFailure("--heartbeat-seconds must be between 5 and 10")
    if not math.isfinite(args.timeout) or not args.heartbeat_seconds + 10 <= args.timeout <= 300:
        raise FirstMenuFailure("--timeout must cover heartbeat plus 10 seconds and be at most 300")


class NativeFirstMenuRun:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.source_app = args.app.resolve()
        self.root = Path(tempfile.mkdtemp(prefix="troop-native-first-menu-", dir="/tmp")).resolve()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.copy_app = self.root / "FirstMenu.app"
        user_support = (Path.home() / "Library/Application Support").resolve()
        self.real_user_data = user_support / "Godot/app_userdata"
        self.user_name = "TROOP-first-menu-" + uuid.uuid4().hex
        self.user_dir = user_support / self.user_name
        self.profile = self.root / "protect-original.sb"
        self.processes: list[subprocess.Popen] = []
        self.cleanup_events: list[str] = []
        self.results: dict[str, dict] = {}
        self.original: dict[str, str] | None = None

    def command(self, name: str, command: list[str], timeout: float = 30) -> int:
        with (self.logs / f"{name}.log").open("wb") as handle:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=handle,
                                       stderr=subprocess.STDOUT, cwd=self.root, start_new_session=True)
            self.processes.append(process)
            try:
                return process.wait(timeout=timeout)
            finally:
                self.stop_process(process)

    def stop_process(self, process: subprocess.Popen) -> None:
        if process.poll() is not None:
            return
        for force in (False, True):
            try:
                os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
            except ProcessLookupError:
                pass
            except PermissionError:
                process.kill() if force else process.terminate()
            self.cleanup_events.append(f"owned pid={process.pid} {'KILL' if force else 'TERM'}")
            try:
                process.wait(timeout=3)
                return
            except subprocess.TimeoutExpired:
                continue
        raise FirstMenuFailure(f"owned process {process.pid} survived bounded cleanup")

    def prepare(self) -> None:
        info, executable_name = inspect_app(self.source_app)
        self.original = bundle_fingerprint(self.source_app)
        if self.copy_app.exists() or self.user_dir.exists() or self.user_dir.is_symlink():
            raise FirstMenuFailure("refusing to reuse an app copy or user directory")
        shutil.copytree(self.source_app, self.copy_app)
        if bundle_fingerprint(self.copy_app) != self.original:
            raise FirstMenuFailure("app copy differs before instrumentation")
        self.user_dir.mkdir()
        observer = self.root / "observer.gd"
        shutil.copy2(Path(__file__).with_name("native_first_menu_observer.gd"), observer)
        self.executable = self.copy_app / "Contents/MacOS" / executable_name
        override = self.executable.parent / "override.cfg"
        override.write_text(
            '[application]\nconfig/use_custom_user_dir=true\n'
            f'config/custom_user_dir_name={json.dumps(self.user_name)}\n'
            'run/flush_stdout_on_print=true\n\n'
            '[autoload]\nNativeFirstMenuObserver='
            + json.dumps("*" + str(observer)) + "\n", encoding="utf-8")
        self.profile.write_text(sandbox_profile(self.source_app, self.real_user_data), encoding="utf-8")
        for name, command in (
            ("sign-copy", ["/usr/bin/codesign", "--force", "--deep", "--sign", "-",
                           "--preserve-metadata=entitlements,flags", str(self.copy_app)]),
            ("verify-copy", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.copy_app)]),
        ):
            if self.command(name, command) != 0:
                raise FirstMenuFailure(f"{name} failed; inspect {self.logs / (name + '.log')}")
        pack_relative = f"Contents/Resources/{executable_name}.pck"
        if sha256_file(self.copy_app / pack_relative) != self.original[pack_relative]:
            raise FirstMenuFailure("supplied PCK changed during copy instrumentation")
        provenance = {"source_app": str(self.source_app), "source_version": info.get("CFBundleShortVersionString"),
                      "source_files": self.original, "copy_app": str(self.copy_app),
                      "test_executable_sha256": sha256_file(self.executable),
                      "copy_only_changes": "startup observer/isolation override; ad-hoc signing",
                      "user_dir": str(self.user_dir), "warm_reuses_only_this_user_dir": self.args.warm_restart,
                      "audio_driver": self.args.audio_driver or "platform default (normal installed audio)",
                      "first_menu_clock": "max(engine ticks, launch-to-marker wall clock; <=50ms poll granularity)"}
        (self.logs / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

    def client_command(self) -> list[str]:
        command = ["/usr/bin/sandbox-exec", "-f", str(self.profile), str(self.executable),
                   "--verbose", "--windowed", "--resolution", "1600x900"]
        if self.args.audio_driver is not None:
            command += ["--audio-driver", self.args.audio_driver]
        return command

    def run_phase(self, phase: str) -> None:
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("TROOP_", "GODOT_", "DYLD_"))}
        environment.update({"TROOP_FIRST_MENU_USER_DIR": str(self.user_dir),
                            "TROOP_FIRST_MENU_HEARTBEAT_SECONDS": str(self.args.heartbeat_seconds),
                            "TROOP_FIRST_MENU_PHASE": phase})
        command = self.client_command()
        log_path = self.logs / f"{phase}.log"
        started = time.monotonic()
        menu_wall_ms = None
        failure = None
        with log_path.open("wb") as handle:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=handle,
                                       stderr=subprocess.STDOUT, cwd=self.root, env=environment,
                                       start_new_session=True)
            self.processes.append(process)
            try:
                while process.poll() is None:
                    output = log_path.read_text(encoding="utf-8", errors="replace")
                    # Lines may be in flight. Parse only complete records here.
                    complete = output[:output.rfind("\n") + 1]
                    if menu_wall_ms is None and any(event["event"] == "MENU_VISIBLE"
                                                    for event in parse_events(complete)):
                        menu_wall_ms = (time.monotonic() - started) * 1000
                    if time.monotonic() - started > self.args.timeout:
                        raise FirstMenuFailure(f"{phase} timed out after {self.args.timeout:g}s")
                    time.sleep(0.05)
                status = process.wait(timeout=1)
            except (OSError, subprocess.SubprocessError, FirstMenuFailure) as exc:
                failure = str(exc)
            finally:
                self.stop_process(process)
                status = process.returncode
        output = log_path.read_text(encoding="utf-8", errors="replace")
        print(output, end="", flush=True)
        try:
            result = evaluate_output(output, status, self.user_dir, self.args.first_menu_limit_ms,
                                     self.args.max_frame_gap_ms, self.args.heartbeat_seconds, menu_wall_ms)
        except FirstMenuFailure as exc:
            result = {"passed": False, "errors": [str(exc)], "observed_first_menu_wall_ms": menu_wall_ms}
        if failure is not None:
            result["passed"] = False
            result["errors"].append(failure)
        result["warm_after_incomplete_cold"] = phase == "warm" and not any(
            event.get("event") == "DONE" for event in self.results.get("cold", {}).get("events", []))
        result["wall_seconds"] = time.monotonic() - started
        result["exit_code"] = status
        self.results[phase] = result
        print(f"NATIVEFIRSTMENU_RESULT {phase} " + json.dumps(result, sort_keys=True), flush=True)

    def finish(self) -> None:
        failures = []
        for process in self.processes:
            try:
                self.stop_process(process)
            except (OSError, FirstMenuFailure) as exc:
                failures.append(str(exc))
        if self.original is not None:
            try:
                if bundle_fingerprint(self.source_app) != self.original:
                    failures.append("original app fingerprint changed")
            except (OSError, FirstMenuFailure) as exc:
                failures.append(str(exc))
        (self.logs / "results.json").write_text(json.dumps(self.results, indent=2) + "\n", encoding="utf-8")
        (self.logs / "cleanup.log").write_text("\n".join(self.cleanup_events + failures) + "\n", encoding="utf-8")
        if failures:
            raise FirstMenuFailure("; ".join(failures))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Explicit existing native .app; never exported or modified")
    parser.add_argument("--warm-restart", action="store_true", help="Also report a fresh process using this run's new cache")
    parser.add_argument("--audio-driver", choices=("CoreAudio", "Dummy"),
                        help="Diagnostic override only; default preserves normal installed audio")
    parser.add_argument("--first-menu-limit-ms", type=float, default=5000.0)
    parser.add_argument("--max-frame-gap-ms", type=float, default=500.0)
    parser.add_argument("--heartbeat-seconds", type=float, default=8.0, help="Post-menu observation, 5–10 seconds")
    parser.add_argument("--timeout", type=float, default=90.0, help="Bound each native process, including shutdown")
    args = parser.parse_args()
    try:
        validate_limits(args)
        if sys.platform != "darwin":
            raise FirstMenuFailure("native first-menu verification requires macOS")
        runner = NativeFirstMenuRun(args)
    except (OSError, FirstMenuFailure) as exc:
        parser.error(str(exc))
    print(f"NATIVEFIRSTMENU_ARTIFACTS {runner.root}", flush=True)
    failure = None
    try:
        runner.prepare()
        for phase in (["cold", "warm"] if args.warm_restart else ["cold"]):
            runner.run_phase(phase)
    except (OSError, subprocess.SubprocessError, FirstMenuFailure) as exc:
        failure = str(exc)
    finally:
        try:
            runner.finish()
        except (OSError, FirstMenuFailure) as exc:
            failure = f"{failure}; {exc}" if failure else str(exc)
    passed = failure is None and bool(runner.results) and all(result["passed"] for result in runner.results.values())
    print("NATIVEFIRSTMENUTEST " + ("PASS" if passed else "FAIL")
          + (f" {failure}" if failure else "") + f" artifacts={runner.root}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
