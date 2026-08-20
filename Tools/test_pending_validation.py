#!/usr/bin/env python3
"""Tests for the pending-validation ledger reader.

The two behaviours worth pinning are the ones that decide whether a debt is ever seen again: a
`## Settled` entry must never be re-surfaced, and a missing or malformed `check-after` must be
treated as RIPE rather than skipped. The second is the fail-loud rule from the script's docstring —
a typo in a date that silently buried an item forever would defeat the whole mechanism.

Run: python3 -m unittest Tools.test_pending_validation -v   (from the repo root)
     or: cd Tools && python3 -m unittest test_pending_validation -v
"""
import importlib.util
import pathlib
import unittest
from datetime import date

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("pv", ROOT / "Tools/pending-validation.py")
pv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pv)

DOC = """# header prose that must not be parsed as an entry

## Open

### First thing
- id: alpha
- shipped: abc123 2026-08-19
- needs: a night with the phone connected
  for its whole duration
- check: run the thing
- check-after: 2026-08-21

### Second thing
- id: beta
- check-after: not-a-date

## Settled

### Old thing
- id: gamma
- check-after: 2020-01-01
"""


class ParseTests(unittest.TestCase):

    def test_only_open_entries_are_parsed(self):
        ids = [i["id"] for i in pv.parse(DOC)]
        self.assertEqual(["alpha", "beta"], ids, "a Settled entry must never come back")

    def test_wrapped_prose_fields_are_joined(self):
        alpha = pv.parse(DOC)[0]
        self.assertEqual("a night with the phone connected for its whole duration", alpha["needs"])

    def test_no_open_section_parses_to_nothing(self):
        self.assertEqual([], pv.parse("# just a doc\n\nno headings here\n"))


class RipenessTests(unittest.TestCase):

    def test_future_date_is_not_ripe(self):
        ripe, note = pv.ripeness({"check-after": "2026-08-21"}, date(2026, 8, 19))
        self.assertFalse(ripe)
        self.assertIn("not until", note)

    def test_due_today_is_ripe(self):
        ripe, _ = pv.ripeness({"check-after": "2026-08-21"}, date(2026, 8, 21))
        self.assertTrue(ripe)

    def test_overdue_reports_how_late(self):
        ripe, note = pv.ripeness({"check-after": "2026-08-21"}, date(2026, 8, 24))
        self.assertTrue(ripe)
        self.assertIn("3d ago", note)

    def test_missing_date_is_ripe_not_skipped(self):
        ripe, note = pv.ripeness({}, date(2026, 8, 19))
        self.assertTrue(ripe, "a dateless entry must make noise, never disappear")
        self.assertIn("no check-after", note)

    def test_unparseable_date_is_ripe_not_skipped(self):
        ripe, note = pv.ripeness({"check-after": "not-a-date"}, date(2026, 8, 19))
        self.assertTrue(ripe, "a typo must fail loud")
        self.assertIn("unparseable", note)


class ShippedLedgerTests(unittest.TestCase):
    """The real file must stay parseable — a malformed entry would silently drop a live debt."""

    def test_every_open_entry_has_the_load_bearing_fields(self):
        doc = ROOT / "docs" / "PENDING_VALIDATION.md"
        if not doc.exists():
            self.skipTest("no ledger yet")
        for item in pv.parse(doc.read_text()):
            for field in ("id", "shipped", "claim", "needs", "check", "passes-if", "check-after"):
                self.assertIn(field, item, f"{item.get('id', item['title'])} is missing {field}")


if __name__ == "__main__":
    unittest.main()
