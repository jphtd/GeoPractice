# Node 3 — Speed Ladder Session Execution

Date: 2026-10-03 (Asia/Shanghai)
Branch: `practice-core-v1-rebuild-20261002`
Starting checkpoint: `9861c5863bcdefaca99b80d6abd4b04cbd0b3092`
Commit title: `feat: restore speed ladder session execution`

Development result: PASS for Node 3 execution, with BPM-02 explicitly unresolved as authorized. Physical iPhone Smoke was unavailable. This report does not constitute Orchestrator independent remote acceptance.

## Implementation and scope

- Each Record preserves actual BPM and note unit. Only a quarter-note-equivalent match with the current hand's current rung increments rung reps. Other records increment actual repetitions without advancing, backtracking, or backfilling Ladder.
- Reps per Level controls advancement. Finite Ladder uses a final short step and holds Target; reaching Target or Target Count never automatically ends Session or switches hand. Lowered current targets preserve a higher existing rung and stop further advancement.
- Open-ended Ladder has no target speed. Its final automatic step is capped at 300; 300 is an execution ceiling, not completion.
- Per-hand Ladder states remain independent. Actual BPM does not change on hand switching or rung advancement. Active UI distinguishes actual tempo, current rung/reps, finite target, and cycle Start lock. The existing segmented hand control has accessible individual actions; its visual layout is unchanged.
- Session drafts carry execution state. Confirmed Session save persists records and execution state together through the existing save transaction. Historical records remain unchanged.
- Cycle resolution happens at Session start. A Session crossing a reset boundary stays in its original cycle. Pending next-cycle Goal configuration is promoted only at the next cycle. Cadence edits take effect at the scheduled next midnight rather than immediately.
- When a new cycle has no previously confirmed pending Start, a native confirmation form requires explicit per-hand Start values. Suggested Start is displayed as a suggestion, with empty input fields. First valid rung Record locks Start; Actual BPM stays freely adjustable.
- Re-enabling Ladder uses the new user-confirmed origin without backfilling Off records. Current note-unit migration retains progress when equivalent and resets only rounded, changed current-rung progress.
- Shared BPM validation/normalization now supports 20–300. The click-profile maximum duration was reduced from 18 ms to 16 ms because the new fastest supported event interval is 1/60 s; the existing full-suite audio safety check exposed the conflict. Accent hierarchy remains intact. No animation changes were made.
- No new End Practice, Save/Discard/Cancel, Archive/Delete, Recently Deleted, theme, or animation implementation. Existing save screens were used only to verify persistence.

## FROZEN authority used

Targeted clauses only; no full Rovia rescan:

- Product v1.1: LAD-06–12 and TEM-05–07 for record matching, continuity, target holding, and note-unit equivalence.
- Product Amendment 02: per-applicable-hand execution isolation, with superseded rules replaced by later amendments.
- Product Amendment 03: A03-LAD-01–17, A03-EDIT-01–07, A03-CYCLE-01–10, A03-NOTE-01–05.
- Product Amendment 04: 20–300 BPM execution range and the open-ended final step to 300.
- Product Amendment 08 / Navigation Amendment 05 / UI Applicable Hand Authority Sync Amendment 01: the four official hand modes and inherited applicable hands.
- Navigation Amendment 03 §7.4: hand switching cannot change Actual BPM.
- UI 05 Active Practice Session §§13–14: Actual BPM separated from secondary current rung/reps; finite target only when present.
- UI 07 Goal Edit: existing state and configuration-edit context.

The supplied UI amendment was read from Downloads; reference documents were not modified.

## BPM-02 — Actual BPM Initialization Spec Gap

Observed source chain:

`MetronomePreset.standard.bpm = 112`
→ `PracticeEvent.init(preset: .standard)` stores the preset
→ `CoreSessionRuntime.begin` reads `division.preset`
→ `PracticeCoreRootView.startPractice` applies `runtime.preset` to the engine.

Thus a newly created planned Division can open its first Session at 112 even though the user has not chosen an Actual BPM for that Session. This is inherited implementation behavior, not an established Ladder or Product initialization rule.

The examined FROZEN clauses distinguish Actual BPM from Ladder Start, Current rung, and Practice Target, and explicitly prohibit automatic Actual BPM changes on hand switching. They do not define which value must initialize the first Actual BPM of a new Session. Suggested Start clauses define Ladder suggestions, not Actual BPM initialization.

Treatment: report BPM-02; preserve the existing Actual BPM initialization path pending formal Authority. Do not change `.standard = 112`, and do not bind Actual BPM to Start/rung/Target. This gap is isolated from the implemented progression rules and is non-blocking for this Node under the explicit Node 3 instruction. Product Authority must define the initialization source before a later fix.

## Verification

| Check | Result |
|---|---|
| Final Debug Build | PASS — `/tmp/rovia-node3-build-final2.log` |
| Last-correction targeted regression | 40 tests / 0 failures — `/tmp/rovia-node3-targeted-verified.xcresult` |
| Full suite | 319 tests / 0 failures — `/tmp/rovia-node3-full-final.xcresult` |
| Simulator | PASS — iPhone 18 Pro, iOS 27; actual UI interactions described below |
| Physical device | NOT RUN — `RAPHA iPhone` / iPhone 17 Pro reported `unavailable`, including final device check |
| Diff whitespace check | PASS |

Verification chronology: the full suite passed before the final initial-hand-sheet dismissal sequencing correction. The final correction then passed Build, the 40-test targeted suite, and the new-cycle UI Smoke. Per the user's continuation instruction, the already passed full suite and unrelated UI Smoke were retained rather than rerun. No implementation changes were made after the last targeted pass.

The 10 added runtime tests cover controlled progression and persistence, mismatch/equivalence/isolation/recovery, finite short step and open-ended ceiling, single-hand and Off execution, 241–300 recording, current/next-cycle separation across midnight, required new-cycle confirmation, cadence timing, current target lowering/Start lock, re-enable behavior, and note-unit migration. Existing Basic Goal and historical-data tests remain green.

## Simulator evidence

Controlled fixture: Target Count 5, Start 40, Step 2, Target 44, Reps per Level 1. Actual BPM was entered explicitly through the UI.

| Action | Observed result |
|---|---|
| Left Record at 40 | Current rung 42, reps 0/1; Actual stays 40; Start locks |
| Repeat old Actual 40 at rung 42 | Record/count increases; rung remains 42, reps 0/1 |
| Left Record at 42 | Current rung 44, reps 0/1 |
| Left Record at 44 | Remains 44, reps 1/1; controlled run shows Left 3/5 and Session running |
| Switch Left → Right → Together | Each hand begins with its own rung 40/0; Actual BPM unchanged |
| Record independently, switch back Left | Restores Left rung 42 and count 1/5 before continuing to 44 |
| Save via existing flow and reopen | Raw records show Left 40/42/44, Right 40, Together 40; Left reopens rung 44, reps 1/1, cumulative 3/5, Start locked |
| Finite Start 100 / Step 3 / Target 108 | 100 → 103 → 106 → 108; recording 108 remains 108 |
| Open-ended Start 298 / Step 3 | 298 → 300, subsequent records remain 300; UI says execution limit and displays no target speed |
| Input 241 / 300 / 301 | 241 and 300 accepted; 301 blocked with range message |
| New-cycle fixture, previous valid 44 | Suggested 34 appears with empty Start fields; empty confirmation blocked |
| Explicit new-cycle Starts 30 | Starts at rung 30/0; Actual still independent at inherited 112 until user changes it |
| New-cycle Actual 30 Record | Rung 32/0, cycle count 1/5, Start locked; Actual remains 30 |

Debug fixtures: `ladder-execution`, `ladder-short`, `ladder-open`, `ladder-cycle`. They are in-memory and do not seed a user's persistent store.

## Changed files and reason

1. `GeoPractice/Models/MetronomePreset.swift` — shared 300 BPM limit.
2. `GeoPractice/Services/MetronomeEngine.swift` — click duration safety at the newly supported maximum event rate.
3. `GeoPractice/Views/PracticeCore/PracticeCoreDomain.swift` — saved cycle identity and re-enable origin handling.
4. `GeoPractice/Views/PracticeCore/PracticeCoreSession.swift` — runtime progression, cycle/configuration resolution, draft/save persistence.
5. `GeoPractice/Views/PracticeCore/PracticeCoreFlowViews.swift` — distinct actual/rung UI, 20–300 input, accessible hand actions, new-cycle confirmation.
6. `GeoPractice/Views/PracticeCore/PracticeCoreViews.swift` — new-cycle start routing and orderly initial-hand sheet dismissal.
7. `GeoPractice/Views/PracticeCore/PracticeCoreIntegration.swift` — isolated Debug fixtures.
8. `GeoPracticeTests/PracticeCoreTests.swift` — Node 3 runtime/regression tests.
9. `GeoPracticeTests/MetronomePresetTests.swift` — updated range and maximum-rate safety assertions.
10. `Documentation/Node3Verification.md` — this evidence and scope report.

New Spec Gap: BPM-02 only. No additional blocking Spec Conflict identified. Stop after Node 3; Node 4 is not entered.
