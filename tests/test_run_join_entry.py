"""The dummy-renderer exception must not hide runtime or native-client errors."""

import unittest

from run_join_entry import classify_client_errors


HEADER = "Godot Engine v4.7.stable.official.5b4e0cb0f - https://godotengine.org\n"
PASS = "JOIN_TEARDOWN ready=true\nJOINENTRYTEST PASS entered=true ready=true\n"
RID = "ERROR: 2 RID allocations of type 'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit."


class ClientDiagnosticsTest(unittest.TestCase):
    def test_clean_run(self):
        self.assertEqual(classify_client_errors(HEADER + PASS, False), ([], []))

    def test_known_headless_shutdown_stays_visible(self):
        self.assertEqual(classify_client_errors(HEADER + PASS + RID, False), ([], [RID]))

    def test_native_renderer_never_ignores_rid_errors(self):
        self.assertEqual(classify_client_errors(HEADER + PASS + RID, True), ([RID], []))

    def test_early_error_is_fatal(self):
        self.assertEqual(classify_client_errors(HEADER + RID + "\n" + PASS, False), ([RID], []))

    def test_teardown_required(self):
        errors, warnings = classify_client_errors(HEADER + "JOINENTRYTEST PASS ready=true\n" + RID, False)
        self.assertEqual((errors, warnings), ([RID], []))

    def test_only_observed_engine_and_rid_count(self):
        for output in [HEADER.replace("4.7.stable", "4.7.2.stable") + PASS + RID,
                       HEADER + PASS + RID.replace("2 RID", "3 RID"),
                       HEADER + PASS + RID.replace("DummyShaderE", "DummyMaterialE")]:
            with self.subTest(output=output):
                errors, warnings = classify_client_errors(output, False)
                self.assertTrue(errors)
                self.assertFalse(warnings)

    def test_other_runtime_failures_remain_fatal(self):
        for error in ["ERROR: bad renderer resource", "SCRIPT ERROR: bad call",
                      "JOINENTRYTEST FAIL entered=false",
                      "WARNING: ObjectDB instances leaked at exit.",
                      "ERROR: 1 resources still in use at exit."]:
            with self.subTest(error=error):
                errors, _ = classify_client_errors(HEADER + PASS + error + "\n" + RID, False)
                self.assertIn(error, errors)


if __name__ == "__main__":
    unittest.main()
