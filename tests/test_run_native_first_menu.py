"""Pure-Python native menu safety/metric gates; never launch Godot or sign an app."""

import argparse
import json
import math
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest

from run_native_first_menu import (
    FirstMenuFailure, NativeFirstMenuRun, bundle_fingerprint, evaluate_output, inspect_app,
    parse_events, sandbox_profile, validate_limits,
)


USER_DIR = Path("/tmp/unique-first-menu-data")


def event(name, **fields):
    return "NATIVEFIRSTMENU " + json.dumps({"event": name, **fields}) + "\n"


def clean_output(first_menu=2963.0, ready=2800.0, gap=163.0, **done_overrides):
    done = dict(first_menu_ms=first_menu, max_gap_ms=gap, heartbeat_ms=8001.0,
                draw_frames=480, menu_visible=True, menu_stayed_visible=True,
                original_content=True)
    done.update(done_overrides)
    return (event("INIT", ticks_ms=100.0)
            + event("READY", ticks_ms=ready, native=True, rendered=True, user_dir=str(USER_DIR))
            + event("FIRST_PROCESS_FRAME", ticks_ms=first_menu - 10)
            + event("FIRST_DRAW", ticks_ms=first_menu)
            + event("MENU_VISIBLE", ticks_ms=first_menu)
            + event("DONE", **done))


def evaluate(output, **overrides):
    options = dict(status=0, user_dir=USER_DIR, first_menu_limit_ms=5000,
                   gap_limit_ms=500, heartbeat_seconds=8, menu_wall_ms=3000)
    options.update(overrides)
    return evaluate_output(output, **options)


class FirstMenuMetricsTest(unittest.TestCase):
    def test_clean_warm_like_metrics(self):
        result = evaluate(clean_output())
        self.assertTrue(result["passed"])
        self.assertEqual(result["engine_first_menu_ms"], 2963)
        self.assertEqual(result["observed_first_menu_wall_ms"], 3000)

    def test_29430ms_cold_freeze_is_not_hidden(self):
        result = evaluate(clean_output(first_menu=29430, ready=100, gap=29330), menu_wall_ms=29500)
        self.assertFalse(result["passed"])
        self.assertTrue(any("first menu" in error for error in result["errors"]))
        self.assertTrue(any("max gap" in error for error in result["errors"]))

    def test_ready_to_first_draw_is_required(self):
        result = evaluate(clean_output(first_menu=4500, ready=100, gap=40), menu_wall_ms=4550)
        self.assertIn("max gap omitted ready-to-first-frame work", result["errors"])

    def test_host_clock_includes_pre_observer_startup(self):
        result = evaluate(clean_output(), menu_wall_ms=6000)
        self.assertFalse(result["passed"])

    def test_exact_limit_is_accepted(self):
        result = evaluate(clean_output(first_menu=5000, ready=4500, gap=500), menu_wall_ms=5000)
        self.assertTrue(result["passed"])

    def test_configurable_limits_are_explicit(self):
        result = evaluate(clean_output(first_menu=6000, ready=5000, gap=1000),
                          menu_wall_ms=6100, first_menu_limit_ms=6500, gap_limit_ms=1100)
        self.assertTrue(result["passed"])
        self.assertEqual(result["first_menu_limit_ms"], 6500)

    def test_missing_or_duplicate_events_fail(self):
        for output in ("", clean_output().replace('"FIRST_DRAW"', '"OTHER"'),
                       clean_output() + event("DONE")):
            with self.subTest(output=output), self.assertRaises(FirstMenuFailure):
                evaluate(output)

    def test_bad_numeric_metrics_fail(self):
        for value in (math.nan, math.inf, -1, True, "500"):
            with self.subTest(value=value), self.assertRaises(FirstMenuFailure):
                evaluate(clean_output(max_gap_ms=value))

    def test_wrong_user_data_or_headless_fails(self):
        for output in (clean_output().replace(str(USER_DIR), "/real/saves"),
                       clean_output().replace('"native": true', '"native": false'),
                       clean_output().replace('"rendered": true', '"rendered": false')):
            with self.subTest(output=output):
                self.assertFalse(evaluate(output)["passed"])

    def test_incomplete_menu_or_heartbeat_fails(self):
        for override in ({"menu_visible": False}, {"menu_stayed_visible": False},
                         {"original_content": False}, {"heartbeat_ms": 4999}, {"draw_frames": 1}):
            with self.subTest(override=override):
                self.assertFalse(evaluate(clean_output(**override))["passed"])

    def test_errors_and_nonzero_exit_are_not_filtered(self):
        for error in ("ERROR: shader failure", "SCRIPT ERROR: invalid method",
                      "WARNING: ObjectDB instances leaked at exit.",
                      "ERROR: 3 RID allocations of type 'DummyShader' were leaked at exit."):
            with self.subTest(error=error):
                self.assertFalse(evaluate(clean_output() + error)["passed"])
        self.assertFalse(evaluate(clean_output(), status=1)["passed"])

    def test_update_restart_is_failure(self):
        self.assertFalse(evaluate(clean_output() + event("FAIL", message="update staged"))["passed"])

    def test_logged_spike_cannot_disappear_from_summary(self):
        self.assertFalse(evaluate(clean_output() + event("GAP", ms=3000))["passed"])

    def test_missing_wall_observation_is_failure(self):
        self.assertFalse(evaluate(clean_output(), menu_wall_ms=None)["passed"])

    def test_parser_ignores_regular_logs_but_rejects_malformed_markers(self):
        self.assertEqual(parse_events("Godot startup\n" + event("INIT", ticks_ms=12)),
                         [{"event": "INIT", "ticks_ms": 12}])
        for output in ("NATIVEFIRSTMENU {", "NATIVEFIRSTMENU []", "NATIVEFIRSTMENU {}"):
            with self.subTest(output=output), self.assertRaises(FirstMenuFailure):
                parse_events(output)


class FirstMenuSafetyTest(unittest.TestCase):
    def test_audio_default_preserves_normal_installed_behavior(self):
        runner = SimpleNamespace(profile=Path("/tmp/owned.sb"),
                                 executable=Path("/tmp/owned.app/Contents/MacOS/TROOP"),
                                 args=SimpleNamespace(audio_driver=None))
        self.assertNotIn("--audio-driver", NativeFirstMenuRun.client_command(runner))

    def test_dummy_audio_requires_explicit_diagnostic_override(self):
        runner = SimpleNamespace(profile=Path("/tmp/owned.sb"),
                                 executable=Path("/tmp/owned.app/Contents/MacOS/TROOP"),
                                 args=SimpleNamespace(audio_driver="Dummy"))
        self.assertEqual(NativeFirstMenuRun.client_command(runner)[-2:],
                         ["--audio-driver", "Dummy"])

    def test_sandbox_protects_supplied_and_installed_apps_and_real_data(self):
        profile = sandbox_profile(Path('/tmp/a "quoted".app'), Path("/Users/test/Library/Application Support/Godot/app_userdata"))
        self.assertIn('(deny file-write* (subpath "/Applications/TROOP.app"))', profile)
        self.assertIn('(deny file-read* file-write*', profile)
        self.assertIn(r'a \"quoted\".app', profile)

    def test_sandbox_rejects_broad_or_relative_targets(self):
        for path in (Path("/"), Path("relative.app")):
            with self.subTest(path=path), self.assertRaises(FirstMenuFailure):
                sandbox_profile(path, Path("/specific/data"))

    def test_invalid_limits_fail(self):
        defaults = dict(first_menu_limit_ms=5000, max_frame_gap_ms=500,
                        heartbeat_seconds=8, timeout=90)
        for override in ({"first_menu_limit_ms": math.nan}, {"max_frame_gap_ms": 0},
                         {"heartbeat_seconds": 4}, {"heartbeat_seconds": 11},
                         {"timeout": 10}, {"timeout": math.inf}, {"timeout": 301}):
            with self.subTest(override=override), self.assertRaises(FirstMenuFailure):
                validate_limits(argparse.Namespace(**(defaults | override)))
        validate_limits(argparse.Namespace(**defaults))

    def make_app(self, root, executable_name="TROOP"):
        app = root / "Fixture.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": executable_name}))
        executable = app / "Contents/MacOS/TROOP"
        executable.write_bytes(b"not launched")
        executable.chmod(0o755)
        (app / "Contents/Resources/TROOP.pck").write_bytes(b"GDPCfixture")
        return app

    def test_inspection_and_fingerprinting_do_not_modify_source(self):
        with tempfile.TemporaryDirectory() as folder:
            app = self.make_app(Path(folder).resolve())
            before = bundle_fingerprint(app)
            self.assertEqual(inspect_app(app)[1], "TROOP")
            self.assertEqual(bundle_fingerprint(app), before)

    def test_executable_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app = self.make_app(Path(folder).resolve(), "../../original")
            with self.assertRaises(FirstMenuFailure):
                inspect_app(app)

    def test_symlink_would_not_be_followed_during_copy_or_signing(self):
        with tempfile.TemporaryDirectory() as folder:
            app = self.make_app(Path(folder).resolve())
            (app / "Contents/link").symlink_to(app / "Contents/Info.plist")
            with self.assertRaises(FirstMenuFailure):
                bundle_fingerprint(app)


if __name__ == "__main__":
    unittest.main()
