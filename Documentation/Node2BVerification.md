# Node 2B — Speed Ladder Goal Configuration

Verified 2026-10-03. Base checkpoint: `c5cf4258e4a2e37d671cc07549d8ded11ce3de3e`.
Branch: `practice-core-v1-rebuild-20261002`.

## Scope and authority

Configuration, editing, validation and persistence only. Session rung advancement,
cycle application and pending Analyze standard application remain for Node 3.
Actual BPM initialization, the standard 112 preset, Session speed controls,
End Practice, deletion and animation were not changed.

Only relevant clauses were read from:

- Product v1.1 FROZEN: LAD-02A–E (unit context), START-01/02, history preservation.
- Product A02: LAD-01–09 (master, participation, independent hands, config-only copy).
- Product A03: LAD-01–17, EDIT-01–08, CYCLE-01–10, NOTE-01–05.
- Product A04: §01 BPM range and §02 next-cycle start conflict.
- Product A08: applicable four modes, Only Together, historical facts.
- Navigation v1.1 Current and Amendments 02/03/05: Goal route ownership,
  per-hand contexts and configuration semantics; A05 covers the former three-mode list.
- 07 Goal Edit UI Spec v1.0 FROZEN: §§07–50 relevant Goal/Ladder/Reset/edit clauses.
- UI Practice Core Amendment 01 — Applicable Hand Authority Sync — FROZEN: §§04/07.
  Supplied file: `/Users/rapha/Downloads/Rovia UI Practice Core Amendment 01 — Applicable Hand Authority Sync — FROZEN.docx`.

Later amendments override old strict divisibility, Reps 1–10, Reset Off default,
two-day/monthly cadence and three-mode authority. Synced sources were not modified.

## Saved behavior

- Pro master switch; default participation on enabling; participation is confined to Division hands.
- Independent Start/Step/Reps and finite or open-ended configuration for each hand.
- Finite Target uses the existing Practice Target BPM/unit, avoiding a second target authority.
- Start/Target 20–300, Step integer 1–20, Reps positive with no Product upper bound.
- Finite level calculation includes its exact Target and permits a final short step.
- A complete open-ended participating Ladder provides per-hand Goal validity.
- Off retains saved Ladder configuration and facts, and excludes Ladder from validity.
- Copy Left → Right copies configuration/unit context only; ordinary save guards still apply.
- Explicit saved Ladder facts drive Cycle Start Lock; ordinary records are not guessed to be Ladder facts.
- Current and next-cycle configuration are stored separately, with independent Analyze timing.
- Suggested-start adjustment decisions persist; suggestion never automatically becomes actual Start.
- Reset defaults On/1 day. Pro fixed days: 1/3/5/7/14/30/60/90. Cadence edits persist next-midnight timing.
- Note-unit conversion rounds configuration values; raw historical records and state facts remain intact.
- Current lower-target edits can preserve an already locked origin under A03-EDIT-03;
  newly established finite Ladders still require Start < Target.
- Existing inactive-hand Goal data and legacy Goal Target Date evidence remain preserved.

## Verification

- Debug Build: PASS, iPhone 18 Pro / iOS 27.0 simulator.
- Targeted PracticeCoreTests: 30 passed, 0 failures, 0 skipped.
- Full suite: 309 passed, 0 failures, 0 skipped.
- Final whitespace/diff validation: PASS.
- Simulator interaction Smoke: PASS for all ten requested categories:
  1. Only Left: open-ended 40/2/11 saved and reopened.
  2. Only Right: finite Start 40, Step 3, Reps 2, Target 80 saved.
  3. Only Together: only Together fields, with no Left/Right or Copy control.
  4. Three hands: independent Start 40/50/60, Step 2/3/4, Reps 1/2/3 saved.
  5. Finite: Target field retains its fixed Basic Goal meaning.
  6. Final short step: 100/3/2 → Target 108 configuration saved; no live advancement claimed.
  7. Open-ended: no Target required, Start/Step/Reps required.
  8. Start 19, Step 21, Reps 0 and Target 301 individually blocked on Save; corrected input saved.
  9. Ladder Off saved while Basic Goal remained valid.
  10. Existing history fixture: editing Step preserved current 103 BPM, 1/2 state,
      locked origin and one saved historical Session. Tests also assert raw record/context equality.
- Additional final UI check: locked Start directly offers next-cycle editing; Suggested 93 > new Target 80
  enters Adjust / Do not adjust decision. Adjust leaves Start empty. Explicit Start 71 and Analyze
  next-cycle choice saved/reopened without repeat decision; current Target remains 108 and history remains 103.

Smoke used isolated Debug in-memory fixtures. Pro preview is available only in those fixtures;
it does not grant an entitlement or mutate persistent user data. `ladder-history` explicitly seeds
QA state and one record; it does not implement production Record → rung advancement.

Final logs/results are in `/tmp/rovia-node2b-build-releasecheck.log`,
`/tmp/rovia-node2b-targeted-releasecheck.xcresult`, `/tmp/rovia-node2b-full-releasecheck.xcresult`.
Temporary evidence may be removed by macOS. This report retains the verification scope.

New blocking Spec Gap / Conflict: NONE. Final visual/animation acceptance is outside this Node.
Stop after Node 2B; do not enter Node 3.
