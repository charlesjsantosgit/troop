"""The dummy-renderer exception must not hide runtime or native-client errors."""

import unittest
from pathlib import Path
import tempfile
from types import SimpleNamespace

from run_join_entry import (JoinEntryFailure, JoinEntryRun, classify_client_errors,
                           include_join_test_fixtures)


HEADER = "Godot Engine v4.7.stable.official.5b4e0cb0f - https://godotengine.org\n"
PASS = "JOIN_TEARDOWN ready=true\nJOINENTRYTEST PASS entered=true ready=true\n"
RID = "ERROR: 2 RID allocations of type 'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit."


class ClientDiagnosticsTest(unittest.TestCase):
    def test_clean_run(self):
        self.assertEqual(classify_client_errors(HEADER + PASS, False), ([], []))

    def test_known_headless_shutdown_stays_visible(self):
        for count in (1, 2, 3):
            warning = RID.replace("2 RID", f"{count} RID")
            with self.subTest(count=count):
                self.assertEqual(classify_client_errors(HEADER + PASS + warning, False),
                                 ([], [warning]))

    def test_native_renderer_never_ignores_rid_errors(self):
        for count in (1, 2, 3):
            warning = RID.replace("2 RID", f"{count} RID")
            with self.subTest(count=count):
                self.assertEqual(classify_client_errors(HEADER + PASS + warning, True),
                                 ([warning], []))

    def test_early_error_is_fatal(self):
        self.assertEqual(classify_client_errors(HEADER + RID + "\n" + PASS, False), ([RID], []))

    def test_teardown_required(self):
        errors, warnings = classify_client_errors(HEADER + "JOINENTRYTEST PASS ready=true\n" + RID, False)
        self.assertEqual((errors, warnings), ([RID], []))

    def test_only_observed_engine_and_rid_count(self):
        for output in [HEADER.replace("4.7.stable", "4.7.2.stable") + PASS + RID,
                       HEADER + PASS + RID.replace("2 RID", "0 RID"),
                       HEADER + PASS + RID.replace("2 RID", "4 RID"),
                       HEADER + PASS + RID.replace("2 RID", "13 RID"),
                       HEADER + PASS + RID.replace("DummyShaderE", "DummyMaterialE")]:
            with self.subTest(output=output):
                errors, warnings = classify_client_errors(output, False)
                self.assertTrue(errors)
                self.assertFalse(warnings)

    def test_three_rids_before_teardown_remain_fatal(self):
        warning = RID.replace("2 RID", "3 RID")
        output = HEADER + "JOINENTRYTEST PASS ready=true\n" + warning + "\nJOIN_TEARDOWN ready=true\n"
        self.assertEqual(classify_client_errors(output, False), ([warning], []))

    def test_other_runtime_failures_remain_fatal(self):
        for error in ["ERROR: bad renderer resource", "SCRIPT ERROR: bad call",
                      "JOINENTRYTEST FAIL entered=false",
                      "WARNING: ObjectDB instances leaked at exit.",
                      "ERROR: 1 resources still in use at exit."]:
            with self.subTest(error=error):
                errors, _ = classify_client_errors(HEADER + PASS + error + "\n" + RID, False)
                self.assertIn(error, errors)


class BufferedClientDiagnosticsTest(unittest.TestCase):
    @staticmethod
    def runner(output, rendered=False):
        return SimpleNamespace(
            output=lambda _role: output,
            client_roles=["client-cold", "client-warm"],
            rendered=rendered,
            children={},
        )

    def test_coalesced_startup_pass_and_known_shutdown(self):
        output = HEADER + "JOINENTRY_USERDIR /tmp/isolated\n" + PASS + RID.replace("2 RID", "3 RID")
        for marker in ("JOINENTRY_USERDIR ", "JOINENTRYTEST PASS "):
            with self.subTest(marker=marker):
                JoinEntryRun.wait_for(self.runner(output), "client-cold", marker, 1)

    def test_coalesced_real_errors_still_fail(self):
        for diagnostic in (RID.replace("2 RID", "4 RID"), "ERROR: bad renderer resource",
                           "SCRIPT ERROR: bad call", "WARNING: ObjectDB instances leaked at exit."):
            with self.subTest(diagnostic=diagnostic):
                with self.assertRaises(JoinEntryFailure):
                    JoinEntryRun.wait_for(self.runner(HEADER + PASS + diagnostic),
                                         "client-cold", "JOINENTRYTEST PASS ", 1)

    def test_coalesced_rendered_warning_still_fails(self):
        with self.assertRaises(JoinEntryFailure):
            JoinEntryRun.wait_for(self.runner(HEADER + PASS + RID, rendered=True),
                                 "client-cold", "JOINENTRYTEST PASS ", 1)

    def test_server_never_uses_client_shutdown_exception(self):
        output = HEADER + PASS + "DEDICATED_SERVER_READY version=0.4.9\n" + RID
        with self.assertRaises(JoinEntryFailure):
            JoinEntryRun.wait_for(self.runner(output), "server", "DEDICATED_SERVER_READY ", 1)


class ClientCommandTest(unittest.TestCase):
    def test_configured_frame_gap_is_forwarded_to_fixture(self):
        runner = SimpleNamespace(
            native_executable=None,
            godot="godot",
            rendered=False,
            projects={"client": "/tmp/troop-client"},
            rendering_driver=None,
            port=30623,
            max_frame_gap_ms=400.0,
        )
        command = JoinEntryRun.client_command(runner)
        self.assertEqual(command[-4:],
                         ["joinentrytest", "127.0.0.1", "30623", "400.000"])


class NativeExportInputsTest(unittest.TestCase):
    def test_fixture_export_preserves_packaging_and_other_exclusions(self):
        preset = ('[preset.1]\nname="macOS"\n'
                  'exclude_filter="artifacts/**,tests/**,build/**,dist/**,'
                  'packaging/**,addons/**,private-data/**"\n')
        self.assertEqual(include_join_test_fixtures(preset),
                         preset.replace(",tests/**", ""))

    def test_fixture_export_requires_one_exclusion_setting(self):
        for preset in ('[preset.1]\nname="macOS"\n',
                       'exclude_filter="tests/**"\nexclude_filter="build/**"\n'):
            with self.subTest(preset=preset), self.assertRaises(JoinEntryFailure):
                include_join_test_fixtures(preset)

    def prepare_inputs(self, directory, *, native, cache_inputs=True):
        source = Path(directory) / "source"
        source.mkdir()
        (source / "project.godot").write_text('[application]\nconfig/name="TROOP"\n')
        for name in ("assets", "scenes", "scripts", "tests", ".godot/imported"):
            (source / name).mkdir(parents=True)
        if cache_inputs:
            for name, content in (
                ("addons/metal_cache_export/plugin.cfg", "cache plugin"),
                ("packaging/metal_cache/manifest.json", '{"cache":"pinned"}'),
                ("packaging/metal_cache/files/example.cache", "cache bytes"),
                ("packaging/metal_baker/test.gd", "must not copy"),
            ):
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
        root = Path(directory) / "run"
        root.mkdir()
        runner = SimpleNamespace(project=source, root=root, run_id="fixture",
                                 user_names={}, projects={},
                                 native_app=Path("fixture.app") if native else None)
        JoinEntryRun.prepare_projects(runner)
        return runner

    def test_native_export_gets_independent_plugin_and_cache_copies_only(self):
        with tempfile.TemporaryDirectory(prefix="troop-export-inputs-") as directory:
            runner = self.prepare_inputs(directory, native=True)
            client = runner.projects["client"]
            for name in ("addons/metal_cache_export", "packaging/metal_cache"):
                self.assertTrue((client / name).is_dir())
                self.assertFalse((client / name).is_symlink())
                self.assertTrue((runner.projects["server"] / name).is_symlink())
            cache = client / "packaging/metal_cache/files/example.cache"
            self.assertEqual(cache.read_text(), "cache bytes")
            cache.write_text("disposable change")
            self.assertEqual((runner.project / "packaging/metal_cache/files/example.cache")
                             .read_text(), "cache bytes")
            self.assertFalse((client / "packaging/metal_baker").exists())

    def test_source_run_links_export_inputs_without_copying_baker_projects(self):
        with tempfile.TemporaryDirectory(prefix="troop-export-inputs-") as directory:
            runner = self.prepare_inputs(directory, native=False)
            for role in ("server", "client"):
                project = runner.projects[role]
                for name in ("addons/metal_cache_export", "packaging/metal_cache"):
                    self.assertTrue((project / name).is_symlink())
                self.assertFalse((project / "packaging/metal_baker").exists())

    def test_older_projects_without_plugin_inputs_still_prepare(self):
        with tempfile.TemporaryDirectory(prefix="troop-export-inputs-") as directory:
            runner = self.prepare_inputs(directory, native=True, cache_inputs=False)
            self.assertTrue((runner.projects["client"] / "scripts").is_dir())
            self.assertFalse((runner.projects["client"] / "packaging").exists())


if __name__ == "__main__":
    unittest.main()
