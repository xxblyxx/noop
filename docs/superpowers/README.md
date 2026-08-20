# superpowers — design specs, phase plans, and handoffs

Where multi-session work is written down before it is built, so a phase can be picked up cold.

| Directory | Holds | Naming |
|---|---|---|
| `specs/` | Design documents — the shape of a feature, the trade-offs, what was rejected | `YYYY-MM-DD-<slug>-design.md` |
| `plans/` | Phase plans — a bounded unit of work with an explicit boundary and acceptance criteria | `YYYY-MM-DD-<slug>.md` |
| `handoff/` | Cross-session state — written when context fills or a phase pauses | `YYYY-MM-DD-<slug>-handoff.md` |

A large piece of work usually gets one spec and several plans; a plan may be split across sessions,
in which case each pause writes a handoff.

## The loop

1. `/phase <slug>` — load the plan, confirm the boundary, enter plan mode.
2. Approve the plan; implement.
3. `@qa-runner`, then `@code-reviewer`.
4. `/wrapup`, then `/handoff <slug>` if stopping mid-phase.
5. `/clear` before the next phase — never carry one phase's context into the next.

Start from [`TEMPLATE-plan.md`](TEMPLATE-plan.md) and [`TEMPLATE-handoff.md`](TEMPLATE-handoff.md).

## Why the boundary section matters

A plan's **Allowed areas** and **Do not modify** lists are what keep a session from widening into a
refactor nobody asked for. If a dependency genuinely forces work outside the boundary, that is a
signal to stop and write a new plan — not to quietly extend the current one.
