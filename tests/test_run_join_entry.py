"""The dummy-renderer exception must not hide runtime or native-client errors."""

import unittest
from types import SimpleNamespace

from run_join_entry import JoinEntryFailure, JoinEntryRun, classify_client_errors


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
        output = HEADER + PASS + "DEDICATED_SERVER_READY version=0.4.7\n" + RID
        with self.assertRaises(JoinEntryFailure):
            JoinEntryRun.wait_for(self.runner(output), "server", "DEDICATED_SERVER_READY ", 1)


if __name__ == "__main__":
    unittest.main()
