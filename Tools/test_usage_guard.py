#!/usr/bin/env python3
"""Tests for the plan-usage guard.

Three behaviours decide whether the guard is worth trusting, and all three are pinned here: the
warning must fire at the threshold and name the window that was actually crossed; the throttle must
stay quiet for one interval and then speak again, because a nag every prompt is a nag nobody reads;
and a failure to obtain the number must be reported rather than swallowed (the fail-loud rule from
the script's docstring, shared with `pending-validation.py`).

⚠️ No test here may touch the network, the keychain, or the real `~/.claude` files. Two mechanisms
are needed, not one: every test gets a private `CACHE` so `refresh()` short-circuits, *and*
`_access_token` is patched to raise so the deliberate cache-miss cases cannot fall through to a live
credential read. Patching only the cache would still be offline on CI — where `_access_token()`
raises "not on macOS" — while quietly hitting `api.anthropic.com` on a developer's Mac.

Run: python3 -m unittest Tools.test_usage_guard -v   (from the repo root)
     or: cd Tools && python3 -m unittest test_usage_guard -v
"""
import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("ug", ROOT / "Tools/usage-guard.py")
ug = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ug)

RESET_5H = 1787000000
RESET_7D = 1787200000


def _cache_blob(pct5h, pct7d, age_sec=0):
    """A cache in the shape Claude Code's own /usage writes — fractions, not percentages."""
    updated = datetime.now(timezone.utc) - timedelta(seconds=age_sec)
    return {
        "version": 2,
        "updatedAt": updated.isoformat().replace("+00:00", "Z"),
        "usageData": {
            "utilization5h": pct5h / 100.0,
            "utilization7d": pct7d / 100.0,
            "reset5hAt": RESET_5H,
            "reset7dAt": RESET_7D,
            "limitStatus": "allowed",
        },
    }


def _no_token():
    raise RuntimeError("patched: tests never read credentials")


class GuardCase(unittest.TestCase):
    """Base case: private cache + throttle files, and a token reader that always refuses."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = pathlib.Path(self._tmp.name)
        self._orig = (ug.CACHE, ug.STATE, ug._access_token)
        ug.CACHE = tmp / "cache.json"
        ug.STATE = tmp / "throttle.json"
        ug._access_token = _no_token
        self.addCleanup(self._restore)

    def _restore(self):
        ug.CACHE, ug.STATE, ug._access_token = self._orig
        self._tmp.cleanup()

    def write_cache(self, pct5h, pct7d, age_sec=0):
        ug.CACHE.write_text(json.dumps(_cache_blob(pct5h, pct7d, age_sec)))

    def run_main(self, *argv):
        out = io.StringIO()
        orig_argv = sys.argv
        sys.argv = ["usage-guard.py", *argv]
        try:
            with contextlib.redirect_stdout(out):
                rc = ug.main()
        finally:
            sys.argv = orig_argv
        return rc, out.getvalue()


class RefreshTests(GuardCase):
    def test_fresh_cache_is_used_without_a_network_call(self):
        self.write_cache(43, 11, age_sec=60)
        usage, age, err = ug.refresh()
        # _access_token raises, so err staying None is proof the network path was never entered.
        self.assertIsNone(err)
        self.assertLess(age, ug.REFRESH_MAX_AGE)
        self.assertAlmostEqual(usage["utilization5h"], 0.43)

    def test_missing_cache_and_no_credentials_reports_the_error(self):
        usage, age, err = ug.refresh()
        self.assertIsNone(usage)
        self.assertIsNone(age)
        self.assertIn("RuntimeError", err)

    def test_stale_cache_survives_a_failed_refresh(self):
        self.write_cache(43, 11, age_sec=45 * 60)
        usage, age, err = ug.refresh()
        self.assertIsNotNone(usage)          # stale numbers beat no numbers
        self.assertGreater(age, ug.STALE_AFTER)
        self.assertIn("RuntimeError", err)


class WarningBlockTests(GuardCase):
    def test_names_the_five_hour_window_when_that_is_the_one_crossed(self):
        usage = _cache_blob(85, 10)["usageData"]
        block = ug._warning_block(85, 10, usage)
        self.assertIn("5h window", block)
        self.assertIn(ug._local(RESET_5H), block)

    def test_names_the_weekly_window_when_that_is_the_one_crossed(self):
        usage = _cache_blob(10, 85)["usageData"]
        block = ug._warning_block(10, 85, usage)
        self.assertIn("weekly window", block)
        self.assertIn(ug._local(RESET_7D), block)

    def test_local_returns_a_placeholder_rather_than_raising(self):
        self.assertEqual(ug._local("nonsense"), "?")
        self.assertEqual(ug._local(None), "?")


class ThrottleTests(GuardCase):
    def test_one_warning_per_interval_then_speaks_again(self):
        self.assertTrue(ug._should_warn_again(85.0))
        self.assertFalse(ug._should_warn_again(85.0))
        state = json.loads(ug.STATE.read_text())
        state["lastWarnAt"] -= ug.REWARN_AFTER + 60
        ug.STATE.write_text(json.dumps(state))
        self.assertTrue(ug._should_warn_again(85.0))


class StateFileTests(unittest.TestCase):
    def test_throttle_file_is_project_scoped_but_the_cache_is_shared(self):
        # A shared throttle file would let a warning fired in a sibling fork silence this one for
        # 30 minutes; the cache, by contrast, is shared with Claude Code's /usage on purpose.
        self.assertEqual(ug.STATE.name, "noop-usage-guard.json")
        self.assertEqual(ug.CACHE.name, "vscode-claude-status-cache.json")


class PromptModeTests(GuardCase):
    def test_silent_below_the_threshold(self):
        self.write_cache(43, 11)
        rc, out = self.run_main("--mode", "prompt")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")

    def test_warns_once_at_or_over_the_threshold(self):
        self.write_cache(85, 11)
        rc, out = self.run_main("--mode", "prompt")
        self.assertEqual(rc, 0)
        payload = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(payload["hookEventName"], "UserPromptSubmit")
        self.assertIn("AT OR OVER 80%", payload["additionalContext"])
        self.assertIn("5h window", payload["additionalContext"])
        self.assertTrue(ug.STATE.exists())

        _, again = self.run_main("--mode", "prompt")   # throttled
        self.assertEqual(again, "")


class SessionModeTests(GuardCase):
    def test_emits_one_json_line_with_both_windows(self):
        self.write_cache(43, 11)
        rc, out = self.run_main("--mode", "session")
        self.assertEqual(rc, 0)
        self.assertEqual(len(out.strip().splitlines()), 1)
        payload = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(payload["hookEventName"], "SessionStart")
        self.assertIn("43.0%", payload["additionalContext"])
        self.assertIn("11.0%", payload["additionalContext"])

    def test_reports_a_lookup_failure_rather_than_going_quiet(self):
        rc, out = self.run_main("--mode", "session")
        self.assertEqual(rc, 0)
        payload = json.loads(out)["hookSpecificOutput"]
        self.assertIn("FAILED", payload["additionalContext"])


class ReportModeTests(GuardCase):
    def test_plain_text_for_running_by_hand(self):
        self.write_cache(43, 11)
        rc, out = self.run_main("--report")
        self.assertEqual(rc, 0)
        self.assertIn("5h window:", out)
        self.assertNotIn("hookSpecificOutput", out)


if __name__ == "__main__":
    unittest.main()
