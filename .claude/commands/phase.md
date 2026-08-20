---
description: Start a phase — load its plan file and lock the boundary
argument-hint: [plan-slug or date]
---
Run `python3 Tools/usage-guard.py --report` first and show me the two numbers. At ≥80% on either
window, stop here: invoke the `usage-monitor` skill instead — it writes the resume doc and schedules
the auto-resume agent, which `--report` does not — and ask whether to start the phase anyway.

Read the matching plan under `docs/superpowers/plans/` (glob `*$ARGUMENTS*.md`). If more than one
matches, list them and ask which. If none matches, list the directory and stop.

Confirm back to me: the goal, the allowed areas, and the "do not modify" list. Then enter plan mode.
Do not edit anything until I approve.

Run the same check again before moving from one phase to the next — a plan that runs dry mid-phase
is the failure this gate exists to prevent.
