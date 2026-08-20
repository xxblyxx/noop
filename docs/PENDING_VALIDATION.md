# Pending validation — claims shipped but not yet confirmed on real data

Some changes here cannot be validated when they land. The strap produces the confirming data hours
or nights later, and some of it only when the wearer's body, the phone's connection state, or the
firmware happens to do the thing the code is watching for. That gap is where a fix quietly becomes
folklore: it was reasoned about carefully, the tests pass, nobody ever saw it work.

**This file is the list of those debts.** `Tools/pending-validation.py` reads it from a
`SessionStart` hook (see `.claude/settings.json`) and surfaces the entries whose `check-after` date
has arrived, so a new session opens by ASKING whether you want to check — regardless of what that
session was actually about.

## Scope — keep this narrow

Only **claims awaiting evidence**: something shipped, whose correctness rests on data that did not
exist yet. Not a TODO list, not a wishlist, not refactors. The moment "would be nice to clean up X"
lands here, the session-start reminder becomes wallpaper and stops working for the entries that
matter. Ordinary follow-ups belong in the tracker.

## How to use it

**Adding.** Any change whose correctness rests on unobserved data gets an entry before the work is
called done. Fill in every field — an entry that cannot be acted on in six months is noise:

| field | what it must answer |
|---|---|
| `id` | short kebab-case slug, unique |
| `shipped` | commit + issue + date, so the code is findable |
| `claim` | what we asserted is true and have not seen |
| `needs` | the DATA EVENT that must occur before checking is even possible |
| `blocked-because` | why it hasn't happened yet — the honest reason, not a placeholder |
| `check` | the exact command to run |
| `passes-if` | what would count as confirmation, decided NOW rather than after seeing the result |
| `check-after` | earliest date a check could be informative |

`check-after` is the whole anti-nag mechanism. Set it to when the data could *plausibly* exist, not
to tomorrow.

⚠️ A missing or malformed `check-after` is treated as **ripe**, deliberately — a typo must make noise
rather than bury an item forever.

**Checking.** Run the `check` command. If it passes, move the entry to `## Settled` with one line
saying what was actually observed. If the data still isn't there, bump `check-after` and, if the
reason changed, update `blocked-because`. Bumping is honest; deleting an unvalidated entry is not.

**Settling.** Entries move to `## Settled` rather than being deleted. It costs one line and it is the
difference between "we checked and it held" and "someone got tired of seeing it."

---

## Open

### Duplicate R-R ingest: the historical-wins rule has never run against a real night
- id: rr-historical-authority
- shipped: branch `fix/rr-duplicate-ingest` 2026-08-19 (#1451) — `WhoopStore.insertHistorical` +
  Kotlin `WhoopRepository.insertHistorical`. A batch decoded from the strap's banked history now
  CLEARS each wall-second it carries beats for before writing its own, so the live stream's copy of
  those same heartbeats no longer survives beside it.
- claim: (a) on a night with the phone connected throughout, stored R-R lands at ~1.0x the strap's
  own `Σ rr_count` instead of the measured 1.65x, and no second carries beats from two batches;
  (b) nothing legitimate is lost — seconds the strap banked no beats for keep their live rows, and
  overall beat coverage does not fall below what the strap itself claims.
- needs: one overnight offload on the fixed build, with the phone connected for the whole night
  (that is the condition that produced the duplication — a disconnected stretch banks once and would
  pass trivially).
- blocked-because: 🔴 NOT YET RUN. The evidence behind the fix is a 6 h 17 m DAYTIME window
  (2026-08-19 20:57→03:14 UTC, `v18AuxSample` n=22,058): stored 14,193 rows vs the strap's claim of
  8,608, 2.105 s of beat-time per wall second where two batches wrote vs 1.079 s where one did, and
  zero duplicated seconds across the 23:58:38→02:16:38 BLE disconnect. No night has been measured at
  all, before or after.
- check: pull the store and re-run the Phase 0 analysis over the new night —
  `xcrun devicectl device copy from --device 00008150-000E434E3AD8401C --domain-type
  appDataContainer --domain-identifier com.bly.noop --source "Library/Application
  Support/OpenWhoop/whoop.sqlite" …` (plus `-wal`/`-shm`), decode `v18AuxSample` with the repo's own
  `V18AuxCodec`, then compare `Σ rr_count` against stored `rrInterval` rows for the night and count
  seconds holding two rows with the same `ord`.
- passes-if: stored ÷ claimed sits at 1.0–1.1 across the night (it was 1.65 before, ~2.0 per
  connected half-hour), AND duplicated-`ord` seconds are either 0 or a handful — under 0.5 % of
  reporting seconds, clustered at offload boundaries rather than spread through every connected
  half-hour. That residual is EXPECTED and is pinned by `testALiveInsertNeverClearsAnything`: a live
  flush landing after the historical batch for the same second still leaves both rows, and the
  Collector buffers ~30 readings before flushing. A steady ~2.0 means the clear is not firing at all;
  a ratio well BELOW 1.0 means it deletes more than it replaces and is the worse failure — check that
  seconds the strap claimed 0 beats for still hold their live rows.
- check-after: 2026-08-20

## Settled

_(nothing yet)_
