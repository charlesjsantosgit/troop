"""Packed-cache inventory/isolation/cleanup checks; no Godot, GPU, or network."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PACKAGING = Path(__file__).resolve().parents[1] / "packaging"
with mock.patch.object(sys, "path", [str(PACKAGING), *sys.path]):
    SPEC = importlib.util.spec_from_file_location(
        "verify_packed_metal_cache", PACKAGING / "verify_packed_metal_cache.py")
    verifier = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(verifier)

RELATIVE = "FixtureShaderRD/" + "a" * 64 + "/" + "b" * 40 + ".metal.cache"
DATA = b"fixture cache bytes for inventory comparisons"
MANIFEST = {"files": [{"path": RELATIVE, "size": len(DATA),
                        "sha256": hashlib.sha256(DATA).hexdigest()}]}


def write_cache(root, relative=RELATIVE, data=DATA):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


class PackedInventoryTests(unittest.TestCase):
    def test_exact_inventory_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_cache(root)
            self.assertEqual(verifier.compare_extracted_cache(root, MANIFEST), 1)

    def test_missing_and_extra_group_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_cache(root, RELATIVE.replace("b" * 40, "c" * 40))
            with self.assertRaisesRegex(verifier.PackedCacheError, "missing=.*extra="):
                verifier.compare_extracted_cache(root, MANIFEST)

    def test_same_size_wrong_bytes_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_cache(root, data=b"x" * len(DATA))
            with self.assertRaisesRegex(verifier.PackedCacheError, "bytes differ"):
                verifier.compare_extracted_cache(root, MANIFEST)

    def test_wrong_size_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_cache(root, data=DATA + b"extra")
            with self.assertRaisesRegex(verifier.PackedCacheError, "bytes differ"):
                verifier.compare_extracted_cache(root, MANIFEST)

    def test_manifest_cannot_masquerade_as_an_extracted_cache_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_cache(root)
            (root / "manifest.json").write_text(json.dumps(MANIFEST))
            with self.assertRaisesRegex(verifier.CacheError, "unexpected cache path"):
                verifier.compare_extracted_cache(root, MANIFEST)

    def test_symlinked_cache_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "raw"
            target = write_cache(root)
            target.rename(target.with_suffix(".original"))
            target.symlink_to(target.with_suffix(".original"))
            with self.assertRaises(verifier.CacheError):
                verifier.compare_extracted_cache(root, MANIFEST)


class ExtractionIsolationTests(unittest.TestCase):
    def test_empty_project_absolute_script_fresh_output_and_exact_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            pack = base / "release.pck"
            pack.write_bytes(b"GDPCfixture")
            pinned = base / "pinned"
            pinned.mkdir()
            (pinned / "manifest.json").write_text(json.dumps(MANIFEST))
            scratch = base / "audit"
            scratch.mkdir()
            commands = []

            def fake_run(command, log, timeout):
                commands.append(command)
                log.write_text("fixture log")
                if command[-1] == "--version":
                    return verifier.ENGINE_VERSION + "\n"
                self.assertIn("--headless", command)
                project = Path(command[command.index("--path") + 1])
                self.assertEqual(list(project.iterdir()), [project / "project.godot"])
                self.assertNotIn("[autoload]", (project / "project.godot").read_text())
                script = Path(command[command.index("--script") + 1])
                self.assertEqual(script, (verifier.RECIPE / "extract_cache.gd").resolve())
                self.assertTrue(script.is_absolute())
                self.assertNotEqual(project, verifier.RECIPE)
                self.assertEqual(command[-2], str(pack))
                extracted = Path(command[-1])
                self.assertFalse(extracted.exists())
                write_cache(extracted)
                return "EXTRACTED_METAL_GROUPS 1\n"

            with mock.patch.object(verifier, "verify_tree", return_value=MANIFEST) as preflight, \
                    mock.patch.object(verifier, "recipe_sha256", return_value="c" * 64), \
                    mock.patch.object(verifier.tempfile, "mkdtemp", return_value=str(scratch)), \
                    mock.patch.object(verifier, "run_logged", side_effect=fake_run):
                report = verifier.verify_pack("godot", pack, pinned)
            preflight.assert_called_once_with(pinned, engine_version=verifier.ENGINE_VERSION,
                                               settings_sha256="c" * 64, target_min_os="11.0")
            self.assertEqual(report["groups"], 1)
            self.assertEqual(len(commands), 2)
            self.assertEqual(pack.read_bytes(), b"GDPCfixture")
            self.assertEqual(json.loads((pinned / "manifest.json").read_text()), MANIFEST)
            self.assertTrue((scratch / "report.json").is_file())
            self.assertTrue((scratch / "extract.log").is_file())

    def test_different_engine_never_starts_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            pack = base / "release.pck"
            pack.write_bytes(b"GDPCfixture")
            with mock.patch.object(verifier, "verify_tree", return_value=MANIFEST), \
                    mock.patch.object(verifier.tempfile, "mkdtemp", return_value=str(base)), \
                    mock.patch.object(verifier, "run_logged", return_value="4.7.2.stable") as run:
                with self.assertRaisesRegex(verifier.PackedCacheError, "requires exactly"):
                    verifier.verify_pack("godot", pack, base)
            self.assertEqual(run.call_count, 1)
            self.assertFalse((base / "empty-project").exists())


class ProcessBoundsTests(unittest.TestCase):
    def test_engine_errors_and_nonzero_exit_are_fatal(self):
        for status, output in ((0, b"ERROR: could not load pack\n"), (1, b"")):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                process = mock.Mock()
                process.wait.return_value = status
                process.poll.return_value = status

                def fake_start(_command, **options):
                    options["stdout"].write(output)
                    return process

                with mock.patch.object(verifier.subprocess, "Popen", side_effect=fake_start):
                    with self.assertRaisesRegex(verifier.PackedCacheError, "Godot failed"):
                        verifier.run_logged(["godot"], Path(directory) / "extract.log", 30)

    def test_existing_log_is_never_overwritten_or_launched(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "existing.log"
            log.write_text("retained evidence")
            with mock.patch.object(verifier.subprocess, "Popen") as launch:
                with self.assertRaises(FileExistsError):
                    verifier.run_logged(["godot"], log, 30)
            launch.assert_not_called()
            self.assertEqual(log.read_text(), "retained evidence")

    @unittest.skipUnless(os.name == "posix", "POSIX process-group fallback")
    def test_group_denial_falls_back_and_escalates_only_owned_child(self):
        process = mock.Mock(pid=12345)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("fixture", 3), -9]
        with mock.patch.object(verifier.os, "killpg", side_effect=PermissionError):
            verifier.stop_own_child(process)
        process.terminate.assert_called_once_with()
        process.kill.assert_called_once_with()
        self.assertEqual(process.wait.call_args_list,
                         [mock.call(timeout=3), mock.call(timeout=3)])

    def test_request_timeout_still_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "extract.log"
            process = mock.Mock()
            process.wait.side_effect = subprocess.TimeoutExpired("fixture", 30)
            with mock.patch.object(verifier.subprocess, "Popen", return_value=process), \
                    mock.patch.object(verifier, "stop_own_child") as cleanup:
                with self.assertRaisesRegex(verifier.PackedCacheError, "timed out after 30s"):
                    verifier.run_logged(["godot"], log, 30)
            cleanup.assert_called_once_with(process)
            self.assertTrue(log.is_file())


if __name__ == "__main__":
    unittest.main()
