"""Fail closed when a Swift test host exits before its assigned inventory ends."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("batches", Path(__file__).parents[2] / "scripts/test-batches.py")
batches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batches)


def event(kind, identity=None):
    payload = {"kind": kind}
    if identity:
        payload["testID"] = identity
    return {"kind": "event", "payload": payload, "version": 0}


def test(identity):
    return {"kind": "test", "payload": {"kind": "function", "id": identity}, "version": 0}


class BatchAuditTests(unittest.TestCase):
    def test_complete_and_explicit_skip_are_accounted_separately(self):
        result = batches.audit({"a", "b"}, [test("a"), test("b"), event("runStarted"),
            event("testEnded", "a"), event("testSkipped", "b"), event("runEnded")], 0)
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["completed"], ["a"])
        self.assertEqual(result["skipped"], ["b"])

    def test_zero_exit_without_run_end_is_failure(self):
        result = batches.audit({"a"}, [test("a"), event("runStarted"), event("testEnded", "a")], 0)
        self.assertTrue(result["errors"])

    def test_missing_test_is_not_hidden_by_run_end(self):
        result = batches.audit({"a"}, [test("a"), event("runStarted"), event("runEnded")], 0)
        self.assertEqual(result["missing"], ["a"])
        self.assertTrue(result["errors"])

    def test_foreign_inventory_is_rejected(self):
        result = batches.audit({"a"}, [test("other"), event("runStarted"),
            event("testEnded", "a"), event("runEnded")], 0)
        self.assertTrue(result["errors"])

    def test_failure_status_is_preserved_even_with_complete_events(self):
        for status in [1, -9, 137]:
            result = batches.audit({"a"}, [test("a"), event("runStarted"),
                event("testEnded", "a"), event("runEnded")], status)
            self.assertTrue(result["errors"])

    def test_filtered_discovery_is_rejected_before_launch(self):
        import contextlib
        import io
        import sys
        from unittest.mock import patch
        args = ["test-batches", "--host", "unused", "--bundle", "unused",
                "--output", "unused", "--", "--filter", "wanted"]
        with patch.object(sys, "argv", args), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                batches.main()
        self.assertEqual(raised.exception.code, 2)

    def test_recorded_error_cannot_be_hidden_by_zero_exit(self):
        issue = event("issueRecorded", "a")
        issue["payload"]["issue"] = {"isKnown": False, "_severity": "error"}
        result = batches.audit({"a"}, [test("a"), event("runStarted"), issue,
            event("testEnded", "a"), event("runEnded")], 0)
        self.assertTrue(result["errors"])

    def test_selector_matches_name_but_not_another_function(self):
        import re
        selector = batches.selector("Module.Suite/function(value:)/source.swift:3:2")
        self.assertTrue(re.fullmatch(selector, "Module.Suite/function(value:)"))
        self.assertFalse(re.fullmatch(selector, "Module.Suite/function(other:)"))


if __name__ == "__main__":
    unittest.main()
