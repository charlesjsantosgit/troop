"""Cache generator safety tests: mocked processes only, never launch a GPU."""

from contextlib import ExitStack, redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PACKAGING = Path(__file__).resolve().parents[1] / "packaging"
with mock.patch.object(sys, "path", [str(PACKAGING), *sys.path]):
    SPEC = importlib.util.spec_from_file_location("bake_metal_cache", PACKAGING / "bake_metal_cache.py")
    bake = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(bake)


class ProcessCleanupTests(unittest.TestCase):
    def process(self):
        process = mock.Mock(pid=123456)
        process.wait.return_value = 0
        return process

    def test_group_gets_term_and_kill_even_when_leader_exits(self):
        process = self.process()
        with mock.patch.object(bake.os, "killpg") as killpg:
            bake.stop_owned_group(process)
        self.assertEqual(killpg.call_args_list,
                         [mock.call(process.pid, signal.SIGTERM), mock.call(process.pid, signal.SIGKILL)])
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=3), mock.call(timeout=3)])

    def test_missing_group_is_safe(self):
        with mock.patch.object(bake.os, "killpg", side_effect=ProcessLookupError):
            bake.stop_owned_group(self.process())

    def test_permission_and_other_oserror_fall_back_to_direct_child(self):
        for error in (PermissionError, OSError):
            with self.subTest(error=error):
                process = self.process()
                with mock.patch.object(bake.os, "killpg", side_effect=error):
                    bake.stop_owned_group(process)
                process.terminate.assert_called_once_with()
                process.kill.assert_called_once_with()

    def test_direct_child_lookup_race_is_safe(self):
        process = self.process()
        process.terminate.side_effect = ProcessLookupError
        process.kill.side_effect = ProcessLookupError
        with mock.patch.object(bake.os, "killpg", side_effect=PermissionError):
            bake.stop_owned_group(process)

    def test_term_timeout_still_kills(self):
        process = self.process()
        process.wait.side_effect = [subprocess.TimeoutExpired("owned", 3), 0]
        with mock.patch.object(bake.os, "killpg") as killpg:
            bake.stop_owned_group(process)
        self.assertEqual(killpg.call_args_list[-1], mock.call(process.pid, signal.SIGKILL))

    def test_kill_timeout_remains_failure(self):
        process = self.process()
        process.wait.side_effect = subprocess.TimeoutExpired("owned", 3)
        with mock.patch.object(bake.os, "killpg"), self.assertRaises(subprocess.TimeoutExpired):
            bake.stop_owned_group(process)

    def test_run_logged_timeout_cleans_even_if_leader_has_exited(self):
        process = self.process()
        process.poll.return_value = 0
        process.wait.side_effect = subprocess.TimeoutExpired("owned", 2)
        with tempfile.TemporaryDirectory() as temp, \
                mock.patch.object(bake.subprocess, "Popen", return_value=process) as popen, \
                mock.patch.object(bake, "stop_owned_group") as cleanup, \
                self.assertRaises(subprocess.TimeoutExpired):
            bake.run_logged(["not-executed"], Path(temp) / "log.txt", timeout=2)
        cleanup.assert_called_once_with(process)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_run_logged_exit_and_error_output(self):
        for status, output, fails in ((0, "done", False), (1, "done", True),
                                      (0, "ERROR: shader failure", True),
                                      (0, "WARNING: skipped optional shader", False)):
            with self.subTest(status=status, output=output), tempfile.TemporaryDirectory() as temp:
                process = self.process()
                process.wait.return_value = status

                def popen(*args, **kwargs):
                    kwargs["stdout"].write(output.encode())
                    return process

                with mock.patch.object(bake.subprocess, "Popen", side_effect=popen), \
                        mock.patch.object(bake, "stop_owned_group") as cleanup:
                    if fails:
                        with self.assertRaises(RuntimeError):
                            bake.run_logged(["not-executed"], Path(temp) / "log.txt")
                    else:
                        bake.run_logged(["not-executed"], Path(temp) / "log.txt")
                cleanup.assert_called_once_with(process)


class RecipeAndIsolationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="troop-baker-unit-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.recipe = self.root / "recipe"
        self.recipe.mkdir()
        for name, content in (("project.godot", "project"), ("export_presets.cfg", "presets"),
                              ("main.tscn", "scene"), ("extract_cache.gd", "extractor")):
            (self.recipe / name).write_text(content)
        self.recipe_patch = mock.patch.object(bake, "RECIPE", self.recipe)
        self.recipe_patch.start()
        self.addCleanup(self.recipe_patch.stop)

    def test_recipe_hash_is_framed_and_deterministic(self):
        expected = hashlib.sha256()
        for name in ("project.godot", "export_presets.cfg", "main.tscn"):
            expected.update(name.encode() + b"\0" + (self.recipe / name).read_bytes() + b"\0")
        self.assertEqual(bake.recipe_sha256(), expected.hexdigest())
        before = bake.recipe_sha256()
        (self.recipe / "main.tscn").write_text("changed")
        self.assertNotEqual(bake.recipe_sha256(), before)

    def test_verify_does_not_spawn_or_require_macos(self):
        with mock.patch.object(bake.sys, "argv", ["bake", "--verify", "artifact"]), \
                mock.patch.object(bake.sys, "platform", "linux"), \
                mock.patch.object(bake, "verify_tree", return_value={"files": [1]}) as verify, \
                mock.patch.object(bake.subprocess, "Popen") as popen, \
                mock.patch.object(bake.subprocess, "check_output") as check_output, \
                mock.patch.object(bake.tempfile, "mkdtemp") as mkdtemp, redirect_stdout(io.StringIO()):
            self.assertEqual(bake.main(), 0)
        verify.assert_called_once_with(Path("artifact"), engine_version=bake.ENGINE_VERSION,
                                       settings_sha256=bake.recipe_sha256(), target_min_os="11.0")
        popen.assert_not_called()
        check_output.assert_not_called()
        mkdtemp.assert_not_called()

    def test_existing_output_and_nonmac_bake_are_rejected_before_spawn(self):
        for platform, output in (("darwin", self.root), ("linux", self.root / "new")):
            with self.subTest(platform=platform), \
                    mock.patch.object(bake.sys, "argv", ["bake", "--output", str(output)]), \
                    mock.patch.object(bake.sys, "platform", platform), \
                    mock.patch.object(bake.subprocess, "check_output") as check, \
                    redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                bake.main()
            check.assert_not_called()

    def test_wrong_engine_rejected_before_toolchain_or_scratch(self):
        with mock.patch.object(bake.sys, "argv", ["bake", "--output", str(self.root / "new")]), \
                mock.patch.object(bake.sys, "platform", "darwin"), \
                mock.patch.object(bake.shutil, "which", return_value="/mock/godot"), \
                mock.patch.object(bake.subprocess, "check_output", return_value="wrong") as check, \
                mock.patch.object(bake.tempfile, "mkdtemp") as mkdtemp, \
                redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            bake.main()
        self.assertEqual(check.call_count, 1)
        mkdtemp.assert_not_called()

    def test_mock_bake_preserves_recipe_and_separates_extractor(self):
        original = {p.name: p.read_bytes() for p in self.recipe.iterdir()}
        scratch = self.root / "owned-run"
        scratch.mkdir()
        output = self.root / "artifact"
        calls = []

        def run(command, log, timeout=300):
            calls.append((command, log, timeout))
            if len(calls) == 1:
                Path(command[-1]).write_bytes(b"owned pack fixture")

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(bake.sys, "argv", ["bake", "--output", str(output)]))
            stack.enter_context(mock.patch.object(bake.sys, "platform", "darwin"))
            stack.enter_context(mock.patch.object(bake.shutil, "which", return_value="/mock/godot"))
            stack.enter_context(mock.patch.object(bake.subprocess, "check_output",
                                                  side_effect=[bake.ENGINE_VERSION, "Metal compiler"]))
            stack.enter_context(mock.patch.object(bake.tempfile, "mkdtemp", return_value=str(scratch)))
            stack.enter_context(mock.patch.object(bake, "run_logged", side_effect=run))
            extract = stack.enter_context(mock.patch.object(bake, "extract_tree",
                                            return_value={"files": [1], "omitted": []}))
            verify = stack.enter_context(mock.patch.object(bake, "verify_tree"))
            stack.enter_context(redirect_stdout(io.StringIO()))
            self.assertEqual(bake.main(), 0)
        self.assertEqual(original, {p.name: p.read_bytes() for p in self.recipe.iterdir()})
        self.assertEqual(len(calls), 2)
        self.assertNotIn("--headless", calls[0][0])
        self.assertIn("--headless", calls[1][0])
        for command, log, _ in calls:
            self.assertTrue(log.is_relative_to(scratch))
            self.assertTrue(Path(command[command.index("--log-file") + 1]).is_relative_to(scratch))
        project = Path(calls[0][0][calls[0][0].index("--path") + 1])
        extractor = Path(calls[1][0][calls[1][0].index("--path") + 1])
        self.assertNotEqual(project, extractor)
        self.assertFalse((extractor / ".godot").exists())
        self.assertNotEqual((project / "override.cfg").read_text(), (extractor / "override.cfg").read_text())
        self.assertIn("owned-run-baker", (project / "override.cfg").read_text())
        extract.assert_called_once_with(scratch / "exported-cache", output,
            engine_version=bake.ENGINE_VERSION, settings_sha256=bake.recipe_sha256(),
            target_min_os="11.0", omit_invalid=True)
        verify.assert_called_once()
        provenance = json.loads((scratch / "provenance.json").read_text())
        self.assertEqual(provenance["pack_sha256"], hashlib.sha256(b"owned pack fixture").hexdigest())


if __name__ == "__main__":
    unittest.main()
