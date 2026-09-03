#!/usr/bin/env python3
"""Run TROOP's real join-entry fixture in isolated project/user-data roots."""

from __future__ import annotations

import argparse
import hashlib
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


class JoinEntryFailure(RuntimeError):
    pass


def classify_client_errors(output: str, rendered: bool) -> tuple[list[str], list[str]]:
    """Keep real errors fatal; surface one narrowly identified dummy-driver warning.

    Exact Godot 4.7's dummy renderer reports 1-3 raw DummyShader RIDs after
    successful joins and teardown. Six create/free cycles of the unchanged
    v0.4.5 VehicleExhaust also reproduce three, with no surviving materials;
    the count varies with lifecycle/frame pacing. This is an observed range,
    not an engine-wide bound. Never allow it for a rendered client, during
    entry, or with surviving ObjectDB/resources. Keep the original line visible.
    """
    errors: list[str] = []
    warnings: list[str] = []
    completed = False
    teardown = False
    known_engine = "Godot Engine v4.7.stable.official.5b4e0cb0f" in output
    for line in output.splitlines():
        if line == "JOIN_TEARDOWN ready=true":
            teardown = True
        if line.startswith("JOINENTRYTEST PASS "):
            completed = True
        if "SCRIPT ERROR:" in line or "JOINENTRYTEST FAIL " in line \
                or "ObjectDB instances leaked" in line or "resources still in use" in line:
            errors.append(line)
        elif line.startswith("ERROR:"):
            known_shutdown_warning = re.fullmatch(
                r"ERROR: [123] RID allocations of type "
                r"'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit\.", line
            )
            if not rendered and known_engine and completed and teardown and known_shutdown_warning:
                warnings.append(line)
            else:
                errors.append(line)
    return errors, warnings


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def include_join_test_fixtures(preset: str) -> str:
    """Expose fixtures without discarding shipping exclusions for export inputs."""
    def keep_other_exclusions(match: re.Match[str]) -> str:
        patterns = [pattern.strip() for pattern in match.group(1).split(",")
                    if pattern.strip() and pattern.strip() != "tests/**"]
        return 'exclude_filter="' + ",".join(patterns) + '"'

    preset, count = re.subn(r'^exclude_filter="([^"]*)"$', keep_other_exclusions,
                            preset, flags=re.MULTILINE)
    if count != 1:
        raise JoinEntryFailure("macOS preset has no unambiguous exclude_filter")
    return preset


class JoinEntryRun:
    def __init__(self, godot: str, project: Path, rendered: bool,
                 warm_restart: bool, client_timeout: float,
                 native_app: Path | None = None, bake_shaders: bool = False,
                 rendering_driver: str | None = None,
                 max_frame_gap_ms: float = 250.0) -> None:
        self.godot = godot
        self.project = project
        self.rendered = rendered
        self.client_timeout = client_timeout
        self.native_app = native_app
        self.bake_shaders = bake_shaders
        self.rendering_driver = rendering_driver
        self.max_frame_gap_ms = max_frame_gap_ms
        self.native_executable: Path | None = None
        self.run_id = uuid.uuid4().hex
        self.root = Path(tempfile.mkdtemp(
            prefix="troop-join-entry-", dir="/tmp" if native_app is not None else None
        )).resolve()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.projects: dict[str, Path] = {}
        self.user_names: dict[str, str] = {}
        self.children: dict[str, subprocess.Popen] = {}
        self.handles = []
        self.cleanup_events: list[str] = []
        self.warnings: list[str] = []
        self.client_roles = ["client-cold"]
        if warm_restart:
            self.client_roles.append("client-warm")
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserved:
            reserved.bind(("127.0.0.1", 0))
            self.port = reserved.getsockname()[1]

    def prepare_projects(self) -> None:
        for role in ("server", "client"):
            destination = self.root / f"{role}-project"
            destination.mkdir()
            shutil.copy2(self.project / "project.godot", destination / "project.godot")
            unique_name = f"TROOP-join-entry-{self.run_id}-{role}"
            self.user_names[role] = unique_name
            (destination / "override.cfg").write_text(
                "[application]\n\n"
                "config/use_custom_user_dir=true\n"
                f'config/custom_user_dir_name="{unique_name}"\n'
                # Release templates otherwise buffer diagnostic sentinels
                # until exit, hiding progress and startup-isolation checks.
                "run/flush_stdout_on_print=true\n",
                encoding="utf-8",
            )
            source_names = ["assets", "scenes", "scripts", "tests"]
            # The shipping editor plugin injects the pinned Metal cache during
            # export. Include just its code and cache inputs, not the rest of
            # packaging (baker projects, diagnostic fixtures, or build tools).
            # Older projects without this optional plugin remain supported.
            for source_name in ("addons/metal_cache_export", "packaging/metal_cache"):
                if (self.project / source_name).is_dir():
                    source_names.append(source_name)
            for source_name in source_names:
                source = self.project / source_name
                if not source.is_dir():
                    raise JoinEntryFailure(f"required source directory is missing: {source}")
                target = destination / source_name
                target.parent.mkdir(parents=True, exist_ok=True)
                if role == "client" and self.native_app is not None:
                    # The export editor may create .uid/import metadata. Its
                    # inputs must be copies, not links back into the checkout.
                    shutil.copytree(source, target)
                else:
                    target.symlink_to(source, target_is_directory=True)
            for source_name in ("icon.svg", "icon.svg.import"):
                source = self.project / source_name
                if source.exists():
                    if role == "client" and self.native_app is not None:
                        shutil.copy2(source, destination / source_name)
                    else:
                        (destination / source_name).symlink_to(source)
            source_cache = self.project / ".godot"
            destination_cache = destination / ".godot"
            destination_cache.mkdir()
            imported = source_cache / "imported"
            if not imported.is_dir():
                raise JoinEntryFailure(f"resource import cache is missing: {imported}")
            if role == "client" and self.native_app is not None:
                shutil.copytree(imported, destination_cache / "imported")
            else:
                (destination_cache / "imported").symlink_to(
                    imported, target_is_directory=True)
            for cache_name in ("global_script_class_cache.cfg", "uid_cache.bin"):
                cache_file = source_cache / cache_name
                if cache_file.is_file():
                    shutil.copy2(cache_file, destination_cache / cache_name)
            self.projects[role] = destination

    def prepare_native_client(self) -> None:
        if self.native_app is None:
            return
        source_contents = self.native_app / "Contents"
        try:
            with (source_contents / "Info.plist").open("rb") as handle:
                info = plistlib.load(handle)
        except (ValueError, plistlib.InvalidFileException) as exc:
            raise JoinEntryFailure("native app has an invalid Info.plist") from exc
        if not isinstance(info, dict):
            raise JoinEntryFailure("native app Info.plist must contain a dictionary")
        executable_name = info.get("CFBundleExecutable", "")
        if not isinstance(executable_name, str) or not executable_name \
                or Path(executable_name).name != executable_name \
                or executable_name in (".", ".."):
            raise JoinEntryFailure("native app has an invalid CFBundleExecutable")
        source_executable = source_contents / "MacOS" / executable_name
        if not source_executable.is_file() or not os.access(source_executable, os.X_OK):
            raise JoinEntryFailure(f"native executable is missing: {source_executable}")
        native_copy = self.root / "native-client.app"
        shutil.copytree(self.native_app, native_copy, symlinks=True)
        contents = native_copy / "Contents"
        executable = contents / "MacOS" / executable_name
        resource_pack = contents / "Resources" / f"{executable_name}.pck"
        for path in (executable, resource_pack):
            if not path.resolve().is_relative_to(native_copy.resolve()) or path.is_symlink():
                raise JoinEntryFailure("native app executable and pack must stay inside its copy")
        if not resource_pack.is_file():
            raise JoinEntryFailure(f"native app resource pack is missing: {resource_pack}")
        # Release templates intentionally disallow --path/--main-pack. Replace
        # only the copied app's pack, and set user:// before renderer startup.
        # Neither /Applications nor the installed game's identity/cache is used.
        native_override = executable.parent / "override.cfg"
        if native_override.is_symlink():
            raise JoinEntryFailure("native app startup override must not be a symlink")
        shutil.copy2(self.projects["client"] / "override.cfg", native_override)
        presets = (self.project / "export_presets.cfg").read_text(encoding="utf-8")
        sections = re.split(r"(?=^\[preset\.\d+(?:\.options)?\]$)", presets,
                            flags=re.MULTILINE)
        mac_preset = ""
        for index, section in enumerate(sections):
            if re.search(r'^name="macOS"$', section, flags=re.MULTILINE):
                mac_preset = section.split("]", 1)[0].removeprefix("[")
                # Keep the normal release settings; only include test fixtures
                # in this disposable pack. Never edit the real presets.
                sections[index] = include_join_test_fixtures(section)
        if not mac_preset:
            raise JoinEntryFailure("macOS export preset is missing")
        found_options = False
        for index, section in enumerate(sections):
            if section.startswith(f"[{mac_preset}.options]"):
                found_options = True
                value = "true" if self.bake_shaders else "false"
                setting = f"shader_baker/enabled={value}"
                section, count = re.subn(r"^shader_baker/enabled=.*$", setting,
                                         section, flags=re.MULTILINE)
                if count == 0:
                    section = section.rstrip() + "\n" + setting + "\n\n"
                sections[index] = section
        if not found_options:
            raise JoinEntryFailure("macOS export preset options are missing")
        (self.projects["client"] / "export_presets.cfg").write_text(
            "".join(sections), encoding="utf-8")
        exported_pack = self.root / "native-test.pck"
        export_command = [self.godot]
        # Shader baking requires a real GPU/display; a headless export silently
        # cannot exercise it. This opt-in is for a separate diagnostic pack,
        # not a change to the byte-identical cross-platform shipping pack.
        if not self.bake_shaders:
            export_command.append("--headless")
        else:
            export_command += ["--audio-driver", "Dummy", "--windowed",
                               "--resolution", "640x360"]
        export_command += ["--path", str(self.projects["client"]),
            "--export-pack", "macOS", str(exported_pack),
        ]
        # A GPU-backed editor export must not warm the native client's cache.
        # Its editor/project caches are already isolated; give its user:// a
        # different name too. The copied app has its own startup override.cfg.
        export_override = self.projects["client"] / "override.cfg"
        client_override = export_override.read_text(encoding="utf-8")
        export_override.write_text(client_override.replace(
            self.user_names["client"], f"TROOP-join-entry-{self.run_id}-export"),
            encoding="utf-8")
        try:
            self.start("native-export", export_command, self.environment())
            status = self.children["native-export"].wait(timeout=120.0)
        except subprocess.TimeoutExpired as exc:
            raise JoinEntryFailure("native test pack export timed out after 120s") from exc
        finally:
            export_override.write_text(client_override, encoding="utf-8")
        if status != 0 or not exported_pack.is_file() \
                or "ERROR:" in self.output("native-export"):
            raise JoinEntryFailure(f"native test pack export failed with exit {status}")
        with exported_pack.open("rb") as handle:
            if handle.read(4) != b"GDPC":
                raise JoinEntryFailure("native test pack export did not produce a Godot PCK")
        exported_pack.replace(resource_pack)
        self.native_executable = executable
        source_hash = sha256_file(source_executable)
        presign_hash = sha256_file(executable)
        if source_hash != presign_hash:
            raise JoinEntryFailure("copied native executable does not match the installed binary")
        # Replacing the copied PCK invalidates the copied resource seal. Repair
        # only this disposable bundle, preserving the release entitlements and
        # hardened-runtime flags. The actual installed app is never signed or
        # modified. Signing changes Mach-O signature bytes, so record both the
        # byte-identical pre-sign copy hash and the final executable hash.
        for role, command in (
            ("native-sign", ["/usr/bin/codesign", "--force", "--deep", "--sign", "-",
                             "--preserve-metadata=entitlements,flags", str(native_copy)]),
            ("native-verify", ["/usr/bin/codesign", "--verify", "--deep", "--strict",
                               str(native_copy)]),
        ):
            self.start(role, command, self.environment())
            try:
                status = self.children[role].wait(timeout=30.0)
            except subprocess.TimeoutExpired as exc:
                raise JoinEntryFailure(f"{role} timed out after 30s") from exc
            if status != 0:
                raise JoinEntryFailure(f"{role} failed with exit {status}")
        copy_hash = sha256_file(executable)
        (self.logs / "native-provenance.log").write_text(
            f"source_app={self.native_app}\n"
            f"source_version={info.get('CFBundleShortVersionString', 'unknown')}\n"
            f"source_executable_sha256={source_hash}\n"
            f"test_executable={executable}\n"
            f"test_executable_presign_sha256={presign_hash}\n"
            f"test_executable_sha256={copy_hash}\n"
            "test_signing=ad-hoc copy only; original entitlements and flags preserved\n"
            f"test_pack={resource_pack}\n"
            f"test_source={self.project}\n"
            f"test_user_dir_name={self.user_names['client']}\n"
            f"client_rendering_driver={self.rendering_driver or 'project default'}\n"
            f"shader_baker_enabled={self.bake_shaders}\n",
            encoding="utf-8")

    def environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        for name in list(environment):
            if name.startswith("TROOP_ADMIN_"):
                environment.pop(name)
        for name in ("TROOP_ADMIN_KEY", "TROOP_ADMIN_TOKEN", "TROOP_STATE_DIR",
                     "TROOP_SERVER_HOST", "TROOP_JOIN_PROFILE"):
            environment.pop(name, None)
        return environment

    def output(self, role: str) -> str:
        path = self.logs / f"{role}.log"
        return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""

    def start(self, role: str, command: list[str], environment: dict[str, str]) -> None:
        handle = (self.logs / f"{role}.log").open("wb")
        self.handles.append(handle)
        options = {"start_new_session": True} if os.name == "posix" else {
            "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP
        }
        self.children[role] = subprocess.Popen(
            command, stdin=subprocess.DEVNULL, stdout=handle,
            stderr=subprocess.STDOUT, cwd=self.projects[
                "server" if role == "server" else "client"],
            env=environment, **options,
        )

    def wait_for(self, role: str, marker: str, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            output = self.output(role)
            if role in self.client_roles:
                # A buffered read can contain startup, PASS and shutdown at
                # once. Apply the same strict client rules here and after exit
                # so polling cadence cannot turn a known warning into failure.
                errors, _warnings = classify_client_errors(output, self.rendered)
            else:
                errors = [line for line in output.splitlines()
                          if "JOINENTRYTEST FAIL " in line or "SCRIPT ERROR:" in line
                          or line.startswith("ERROR:")]
            if errors:
                raise JoinEntryFailure(f"{role} reported a fixture or script failure")
            if any(line.startswith(marker) for line in output.splitlines()):
                return
            status = self.children[role].poll()
            if status is not None:
                raise JoinEntryFailure(f"{role} exited {status} before {marker}")
            time.sleep(0.05)
        raise JoinEntryFailure(f"{role} timed out after {timeout:.0f}s waiting for {marker}")

    def require_client_pass(self, role: str) -> None:
        deadline = time.monotonic() + self.client_timeout
        self.wait_for(role, "JOINENTRY_USERDIR ", self.client_timeout)
        directories = [Path(line.removeprefix("JOINENTRY_USERDIR "))
                       for line in self.output(role).splitlines()
                       if line.startswith("JOINENTRY_USERDIR ")]
        if not directories or any(not directory.is_absolute()
                                  or directory.name != self.user_names["client"]
                                  for directory in directories):
            raise JoinEntryFailure(f"{role} did not use its isolated startup user-data directory")
        self.wait_for(role, "JOINENTRYTEST PASS ", max(0.0, deadline - time.monotonic()))
        try:
            status = self.children[role].wait(timeout=5.0)
        except subprocess.TimeoutExpired as exc:
            raise JoinEntryFailure(f"{role} did not exit after PASS") from exc
        if status != 0:
            raise JoinEntryFailure(f"{role} exited {status} after PASS")
        output = self.output(role)
        errors, warnings = classify_client_errors(output, self.rendered)
        if errors:
            raise JoinEntryFailure(f"{role} reported a fixture or script failure after PASS")
        self.warnings.extend(f"{role}: {warning}" for warning in warnings)

    def client_command(self) -> list[str]:
        command = [str(self.native_executable or self.godot)]
        if not self.rendered:
            command.append("--headless")
        if self.native_executable is None:
            command += ["--path", str(self.projects["client"])]
        if self.rendering_driver is not None:
            command += ["--rendering-driver", self.rendering_driver]
        return command + [
            "--resolution", "1600x900", "--max-fps", "60",
            "--quit-after", "9000", "--", "joinentrytest",
            "127.0.0.1", str(self.port),
            f"{self.max_frame_gap_ms:.3f}",
        ]

    def run(self) -> None:
        self.prepare_projects()
        self.prepare_native_client()
        server_environment = self.environment()
        server_environment.update({
            "TROOP_BIND_IP": "127.0.0.1",
            "TROOP_SERVER_PORT": str(self.port),
            "TROOP_WORLD_SEED": "20260805",
        })
        self.start("server", [
            self.godot, "--headless", "--path", str(self.projects["server"]),
            "--max-fps", "60", "--quit-after", "18000", "--", "server",
        ], server_environment)
        self.wait_for("server", "DEDICATED_SERVER_READY ", 30.0)
        for index, role in enumerate(self.client_roles):
            self.start(role, self.client_command(), self.environment())
            self.require_client_pass(role)
            if index + 1 < len(self.client_roles):
                # Give ENet authority time to observe the first client's clean
                # disconnect before reconnecting the same isolated identity.
                time.sleep(1.0)

    def signal_own_child(self, role: str, process: subprocess.Popen,
                         force: bool = False) -> None:
        if process.poll() is not None:
            return
        action = "KILL" if force else "TERM"
        if os.name == "posix":
            try:
                # start_new_session gives this child its own process group.
                os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
                self.cleanup_events.append(f"{role} pid={process.pid} group {action}")
                return
            except OSError as exc:
                # macOS can reject group signaling even while direct signaling
                # of the owned child is allowed. The child may also have exited
                # or changed groups since poll(). Never search for other PIDs.
                self.cleanup_events.append(
                    f"{role} pid={process.pid} group {action}: {exc}; trying owned child")
        if process.poll() is not None:
            return
        try:
            if force:
                process.kill()
            else:
                process.terminate()
            self.cleanup_events.append(f"{role} pid={process.pid} direct {action}")
        except OSError as exc:
            # Reap a concurrent exit; retain diagnostics but let the bounded
            # wait/escalation decide whether cleanup actually failed.
            self.cleanup_events.append(
                f"{role} pid={process.pid} direct {action}: {exc}; exit={process.poll()}")

    def stop_own_children(self) -> None:
        # Signal only process groups/Popen children created by this runner.
        # Never kill by executable name, project path, port, or user.
        failures = []
        try:
            for role, process in self.children.items():
                self.signal_own_child(role, process)
            for role, process in self.children.items():
                try:
                    process.wait(timeout=3.0)
                except subprocess.TimeoutExpired:
                    self.signal_own_child(role, process, force=True)
                    try:
                        process.wait(timeout=3.0)
                    except subprocess.TimeoutExpired:
                        failures.append(f"{role} pid={process.pid} remained alive after TERM/KILL")
                self.cleanup_events.append(
                    f"{role} pid={process.pid} final exit={process.poll()}")
        finally:
            for handle in self.handles:
                try:
                    handle.close()
                except OSError as exc:
                    failures.append(f"closing child log: {exc}")
            try:
                (self.logs / "cleanup.log").write_text(
                    "\n".join(self.cleanup_events) + "\n", encoding="utf-8")
            except OSError as exc:
                failures.append(f"writing cleanup log: {exc}")
        if failures:
            raise JoinEntryFailure("; ".join(failures))

    def remove_test_credentials(self) -> None:
        # User-data stays available for shader-cache and profile inspection,
        # but no generated fixture key or secret may survive the run.
        live_roles = [role for role, process in self.children.items()
                      if process.poll() is None]
        if live_roles:
            raise JoinEntryFailure(
                f"cannot remove credentials while test children are alive: {', '.join(live_roles)}")
        for role, expected_name in self.user_names.items():
            marker = "JOINENTRY_USERDIR "
            if role == "server":
                # A dedicated server does not generate an installation key and
                # does not emit JOINENTRY_USERDIR. Nothing to infer or delete.
                continue
            directories = []
            for client_role in self.client_roles:
                for line in self.output(client_role).splitlines():
                    if line.startswith(marker):
                        directories.append(Path(line.removeprefix(marker)))
            if not directories:
                # The fixture prints the path before joining or generating an
                # identity. A parser/startup failure before that point creates
                # no test credentials and already fails the sentinel gate.
                continue
            for directory in directories:
                if not directory.is_absolute() or directory.name != expected_name:
                    raise JoinEntryFailure("client reported an unexpected user-data directory")
                if directory.is_symlink():
                    raise JoinEntryFailure("client user-data directory must not be a symlink")
                for filename in ("admin_identity.key", "admin_identity_secret.txt"):
                    for suffix in ("", ".tmp", ".bak"):
                        (directory / (filename + suffix)).unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot", help="Godot 4.7 executable")
    parser.add_argument("--project", type=Path,
                        default=Path(__file__).resolve().parents[1])
    renderer = parser.add_mutually_exclusive_group()
    renderer.add_argument("--headless", dest="rendered", action="store_false",
                          help="Use the headless/dummy driver (default)")
    renderer.add_argument("--rendered", dest="rendered", action="store_true",
                          help="Use the platform renderer instead of headless/dummy")
    parser.set_defaults(rendered=False)
    parser.add_argument("--warm-restart", action="store_true",
                        help="Repeat in a fresh client process with the same cache and identity")
    parser.add_argument("--native-app", type=Path,
                        help="With --rendered, test a disposable copy of this macOS app's "
                             "release executable with the current source/test pack")
    parser.add_argument("--bake-shaders", action="store_true",
                        help="With --native-app, enable shader baking only in the disposable "
                             "Mac preset (opens a GPU-backed editor during export)")
    parser.add_argument("--rendering-driver", choices=("metal", "vulkan", "opengl3"),
                        help="With --rendered, override only the client graphics driver; "
                             "the source server and export settings are unchanged")
    parser.add_argument("--timeout", type=float, default=120.0,
                        help="Maximum seconds for each client; must be at least 90")
    parser.add_argument("--max-frame-gap-ms", type=float, default=250.0,
                        help="Maximum client frame gap; default is the strict 250 ms local gate")
    arguments = parser.parse_args()
    if not math.isfinite(arguments.timeout) or arguments.timeout < 90.0:
        parser.error("--timeout must be finite and at least 90 seconds")
    if not math.isfinite(arguments.max_frame_gap_ms) \
            or arguments.max_frame_gap_ms <= 0.0 or arguments.max_frame_gap_ms > 1000.0:
        parser.error("--max-frame-gap-ms must be finite, positive, and no more than 1000")
    executable = shutil.which(arguments.godot)
    if executable is None:
        parser.error(f"Godot executable not found: {arguments.godot}")
    project = arguments.project.resolve()
    if not (project / "tests" / "joinentrytest.gd").is_file():
        parser.error(f"joinentrytest.gd not found in {project}")
    native_app = arguments.native_app.resolve() if arguments.native_app else None
    if arguments.rendering_driver and not arguments.rendered:
        parser.error("--rendering-driver requires --rendered")
    if arguments.bake_shaders and native_app is None:
        parser.error("--bake-shaders requires --native-app")
    if native_app is not None:
        if sys.platform != "darwin" or not arguments.rendered:
            parser.error("--native-app requires macOS and --rendered")
        if not (native_app / "Contents" / "Info.plist").is_file():
            parser.error(f"macOS app bundle not found: {native_app}")
        if not (project / "export_presets.cfg").is_file():
            parser.error(f"export_presets.cfg not found in {project}")
    run = JoinEntryRun(executable, project, arguments.rendered,
                       arguments.warm_restart, arguments.timeout, native_app,
                       arguments.bake_shaders, arguments.rendering_driver,
                       arguments.max_frame_gap_ms)
    failure = ""
    try:
        run.run()
    except (JoinEntryFailure, OSError, KeyboardInterrupt) as exc:
        failure = str(exc) or "interrupted"
    finally:
        # One cleanup error must not skip other cleanup. Credential removal
        # independently refuses to race any child that could still write keys.
        for cleanup in (run.stop_own_children, run.remove_test_credentials):
            try:
                cleanup()
            except (JoinEntryFailure, OSError, subprocess.TimeoutExpired) as exc:
                detail = f"{cleanup.__name__}: {exc}"
                failure = f"{failure}; cleanup: {detail}" if failure else f"cleanup: {detail}"
    if failure:
        print(f"JOINENTRY-CI FAIL {failure}\nLogs: {run.logs}", file=sys.stderr)
        for role in run.children:
            tail = "\n".join(run.output(role).splitlines()[-12:])
            print(f"[{role}]\n{tail}", file=sys.stderr)
        return 1
    mode = "native macOS rendered" if native_app else (
        "rendered" if arguments.rendered else "headless")
    restart = " and warm restart" if arguments.warm_restart else ""
    for warning in run.warnings:
        print(f"JOINENTRY-CI WARN known headless shutdown diagnostic: {warning}")
    for role in run.client_roles:
        for line in run.output(role).splitlines():
            if line.startswith("JOINENTRYTEST PASS "):
                print(f"{role}: {line}")
    print(f"JOINENTRY-CI PASS {mode} full join entry{restart}\nLogs: {run.logs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
