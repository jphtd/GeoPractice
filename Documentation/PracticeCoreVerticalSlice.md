# Practice Core Vertical Slice v1.0 — Development delivery

> Historical checkpoint of the original three-screen delivery. The user subsequently authorized temporary target screens for a real end-to-end test. The old “stopped / disconnected” destination statuses below are superseded for that path by [Practice Core E2E delivery](PracticeCoreE2E.md), dated 2026-09-28. This historical record does not describe the current runtime integration.

Date: 2026-09-27. Status: implemented within the three-screen boundary; ready for independent QA/Orchestrator review. This document does not grant FROZEN acceptance to external target screens.

## Baseline and scope

SSOT: Rovia Product v1.1 FROZEN; Navigation v1.1 FROZEN + Amendment 01; Animation System v1.1 FROZEN; UI Foundation v1.0 FROZEN; screens 01/02/03 v1.0 FROZEN. Sources are the iCloud Rovia Current directories. No SSOT or synced sources were modified.

The existing GeoPractice SwiftUI / SwiftData repository is retained. App entry now uses PracticeCoreRootView. Existing uncommitted metronome changes were preserved. No dependency was added.

## Accepted implementation boundary

| Screen | Implemented states and contracts |
|---|---|
| Practice Home | Normal: current Piece ActionCards and tertiary All Pieces, no Primary; Empty: Add Piece; Recovery: title only, neutral StateCard and sole Continue CTA, no ordinary browsing |
| Piece Detail | Normal: identity, structure metadata, Analyze row, Division ActionCards; No Division: exact frozen explanation and Create CTA in EmptyState |
| Practice Division Detail | No Valid Goal: neutral StateCard, Set Goal Primary, Free Practice Secondary; Valid Goal: editable Goal ActionCard, Start Planned Practice Primary, Free Practice Secondary; Analyze in both |
| Shared | Four PageHeader patterns; fixed Practice / GeoBeat / Analyze bottom navigation; single semantic accent; Light/Dark; 16/24/32 responsive margins; ordinary detail width <=720; multiline text; 44pt interaction targets; ordinary vertical scrolling |

Frozen basis: 01 §§1–16; 02 §§19–28,30–34; 03 §§4,18–42; Foundation typography/color/component rules; Animation D1/E1 press feedback (100ms, scale .99, no spring). Reduce Motion removes press scale, retaining opacity feedback. No stagger, breathing, celebration or new motion token was added. Navigation uses the platform NavigationStack.

Accessibility: standard Dynamic Type grows content and headers without one-line title truncation. Persistent bottom navigation uses native-style bounded label growth through XXXL and Large Content Viewer for larger accessibility sizes, retaining full labels and selected semantics. This prevents unrecognizable split words at AX5 without adding a new navigation arrangement. Device VoiceOver gestures and Reduce Motion playback still require manual QA; implementation inspection is not a substitute for that check.

## Route contracts

CoreNavigation owns the actual NavigationStack path and the typed pending target request.

- Home -> Piece -> Division, with stable UUIDs and nested back behavior.
- Both Add Piece controls emit the same addPiece contract.
- Create emits Piece ID + current mode. CoreContracts.saveCreatedDivision validates structural bounds and non-overlap, persists no Goal and no Session, returns the new detail identity. CoreNavigation.createdDivisionSaved checks the matching request and updates the stack.
- Goal edit emits Piece + Division IDs. On a matching successful valid save, CoreNavigation.goalSaved returns to the same detail without adding duplicate pages. Goal validity is computed from explicit data for each applicable hand; date is optional. Non-applicable hands do not block validity.
- Planned start validates Goal and unique-active-session preconditions; requesting the target alone does not create a Session.
- Free Practice and the global GeoBeat tab have distinct contracts. The tab carries an existing Active Session ID, preserving the default-linked-context rule.
- Analyze keeps overall / Piece / Division context.
- Continue carries the original Session ID. Recovery reads the durable draft without rewriting it, creating a new Session, or starting a timer.

All external requests currently stop with a native boundary notice. They do not execute legacy side effects or masquerade as completed target flows. Creation and Goal return contracts are tested through their integration API; their forms are not implemented in this slice.

## Spec Gap register

| ID | Status / owner | Concrete dependency and consequence |
|---|---|---|
| SG-01 | Open, out-of-scope UI dependency | Create Division form has no frozen internal UI. Entry, inherited mode, persistence guard and successful return exist; no form was invented. |
| SG-02 | Open, out-of-scope UI dependency | Goal Editor has no frozen internal UI. Old count-only editor cannot represent v1.1 per-hand target speed/unit and cycle semantics. Entry and validated return exist, editor remains disconnected. |
| SG-03 | Open, out-of-scope target dependency | Add Piece, All Pieces, Piece Settings, Active Session, GeoBeat, Analyze require accepted destination integration. Specific conflicts are listed below. |
| SG-04 | Open, Product/migration decision | Legacy Piece/Event rows lack confirmed mode, range and applicable hands. New optional metadata stays nil; no inference from names, old targets or ordering. Selecting an unmapped object stops at the compatibility boundary. Existing rows/history are not deleted or relabeled. |
| SG-05 | Open, legacy session compatibility | Corrupt/orphan/empty/finished drafts need an accepted migration/result handling policy. They remain stored and receive an explicit boundary explanation. They are not silently converted into valid planned Sessions. |
| UI-GAP-01/02 | Upstream non-blocking | Canonical platform/viewport and final brand assets remain unresolved upstream; this implementation uses the existing iOS/iPadOS platform and frozen candidate palette. |

UI-GAP-03 and NAV-UI-GAP-01 remain CLOSED. No new product rule is proposed.

## Engineering compatibility register

| ID | Result and remaining limit |
|---|---|
| EG-01 | Added explicit Piece structure and Division/hand/Goal read models, eight target note units and normalized speed. These support the three screens and route guards. Full Goal Cycle, recalculation, Ladder and editor runtime are outside this slice; no claim of full v1.1 engine migration. |
| EG-02 | New root avoids old auto-launch/recovery/discard-and-switch behavior. Existing draft identity is read without mutation. Continue/start contracts stop before the incompatible Active Session destination; actual resumption and recording runtime are not accepted here. |
| EG-03 | New root uses direct SwiftData queries and does not invoke old bootstrap, end-date auto-archive, destructive section editing or cloud restore at startup. New optional metadata is included in existing backup serialization; reopen and backup round-trip tests pass. Historical on-device schema migration and mixed-version cloud conflict behavior remain unverified; automatic cloud sync is not started by this shell. |

## Target screens — Not FROZEN / Not QA Accepted

| Target | Integration decision / specific conflict |
|---|---|
| Add Piece | Stopped: legacy editor supplies old structural/date defaults, not confirmed v1.1 Piece mode/range facts. |
| All Pieces | Stopped: no separate accepted target; existing library UI mixes direct-start and legacy management behavior. |
| Piece Settings | Stopped: legacy structure removal can delete history and legacy date settings can auto-archive; incompatible with frozen history preservation/explicit archive semantics. |
| Create Practice Division | Stopped at entry; no standalone frozen form. Contract and persistence/return hook implemented. |
| Goal Editor | Stopped: old count model does not cover explicit applicable hands and target note unit+BPM. |
| Active Practice Session / Result | Stopped: old goal-less launch, discard-and-switch and auto-return-to-metronome do not meet frozen lifecycle. Continue/Start do not invoke them. |
| GeoBeat | Stopped: old runtime does not provide accepted linked/independent Record Source and detach/reconnect guarantees. Audio engine and visuals were not redesigned. |
| Analyze | Stopped: old statistics is not the frozen current Stable BPM/Mastery/Weakness model or its Free/Pro boundary. No statistics value is relabeled as these metrics. |

Free and Pro share the exact three-screen hierarchy. No crown, lock, upgrade card or hidden Analyze entry is added. Destination permission enforcement remains a dependency.

## Files

New:
- GeoPractice/Views/PracticeCore/PracticeCoreDomain.swift — explicit models, rules, navigation and return contracts.
- GeoPractice/Views/PracticeCore/PracticeCoreComponents.swift — shared Foundation components.
- GeoPractice/Views/PracticeCore/PracticeCoreViews.swift — the three screens and state composition.
- GeoPractice/Views/PracticeCore/PracticeCoreIntegration.swift — target boundaries, read-only recovery and Debug fixtures.
- GeoPracticeTests/PracticeCoreTests.swift — nine targeted tests.
- Documentation/PracticeCoreVerticalSlice.md and Documentation/PracticeCoreQA/ — delivery record and simulator evidence.

Modified:
- GeoPractice/GeoPracticeApp.swift — new entry; isolated in-memory Debug fixtures; normal launch remains persistent.
- GeoPractice/Models/PracticeSong.swift — optional explicit structure metadata; optional metadata in backup Song/Event round trips.
- GeoPractice/Models/PracticeEvent.swift — optional explicit Division metadata.
- GeoPractice.xcodeproj/project.pbxproj — source/test registrations.

Not changed by this slice: pre-existing local edits in MetronomePreset.swift, MetronomeEngine.swift, PrototypeRootMetronomeViews.swift, MetronomePresetTests.swift and Documentation/GeoBeat.

## Verification and reproduction

- Xcode 27 / iOS 27 simulator: Debug build succeeds.
- Full existing suite + new tests: 272 passed, 0 failed.
- After final bottom-navigation accessibility adjustment: 9 PracticeCore tests passed, 0 failed; final Release simulator build succeeded (arm64 and x86_64).
- Test coverage: per-hand Goal validity and optional date; all eight units; recovery priority and stable Session identity; range/non-overlap; no auto-created Goal/Session; no legacy inference; persisted reopen; backup round trip; matching creation/editor callbacks and stable navigation stack.
- Visual evidence inspected: seven core states in PracticeCoreQA; dark and AX5 long-title variants; iPad 13-inch single-column detail. Screenshots are synthetic Debug fixtures, not user's live data.
- Existing build warning: RootView.swift uses ModelContext without importing SwiftData directly; unchanged in this slice. AppIntents metadata extraction reports no dependency. Neither blocks build/test.
- Not claimed: production target-flow completion, legacy user-data migration approval, physical-device QA, minimum-iOS-17 runtime QA, end-to-end automated UI gestures, VoiceOver gesture audit, or upstream QA acceptance.

Open GeoPractice.xcodeproj, choose GeoPractice scheme. Normal launch uses local persisted data; an unmapped legacy library will stop at SG-04 instead of inventing structure.

To review all three screens independently of migration, add a Debug launch argument:

```
-practice-core-fixture normal
```

Available fixture values: normal, empty, recovery, piece, no-division, no-goal, valid-goal, long. All fixture content uses an isolated in-memory ModelContainer. Release builds cannot activate these fixtures. There is no production demo picker or hidden mutation of the user's library.

Example checks from repository root:

```sh
xcodebuild -project GeoPractice.xcodeproj -scheme GeoPractice -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project GeoPractice.xcodeproj -scheme GeoPractice -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## Verified SSOT fingerprints (SHA-256)

- `Rovia_Product_v1.1_FROZEN.docx`: `04fe23cf47575229588f001c597f690e1db9d20736794450303853108a32353e`
- `Rovia-Navigation-v1.1-Amendment-01-FROZEN.md`: `049b03f0680e42a090dc2d38cf2e1f47837242edfbbbbd2812d441c6a7792bba`
- `Rovia-Navigation-v1.1-FROZEN.md`: `c2744bc61c0ca3ebc17a8073b71b836407a48a1e34d4454a6178ed75ebac4e83`
- `01 Practice Home UI Spec v1.0 FROZEN.md`: `63c3c43485e04c67c3b28f20daf4739760542511b686da90192fbccd120f3df1`
- `02 Piece Detail UI Spec v1.0 FROZEN.md`: `162edb072635348a9ff5adcf6949281f4ee5a683c9ee5262cd6969f0e0c2eb75`
- `03 Practice Division Detail UI Spec v1.0 FROZEN.md`: `8883ed4159f56a621fb56188944b990569cdbead7d3244dc8fc016b1f172f4e4`
- `Rovia UI Foundation v1.0 FROZEN.txt`: `066f83ee272908b30afaeec11083238633f45b2942a093dfb00b4e7cf7935719`
- `Rovia_Animation_System_v1.1_FROZEN.txt`: `78d5023ff9cc77880d5ed4690863e5b20e340bd9d99246dc6dbfca4b0142def8`

## Final checks

Final targeted result: 9/9 passed after accessibility adjustment. Earlier full regression: 272/272 passed. Debug and Release builds succeeded; git diff --check passed. Ten simulator screenshots were inspected. No commits, upstream edits, publishing or migration of user data were performed.

Logs from this run: /tmp/rovia-core-final-test.log (full regression), /tmp/rovia-core-accessibility-test.log (final 9 tests), /tmp/rovia-core-release-final.log (final Release build). Temporary logs may be removed by macOS; the reproducible commands above and retained screenshots are the durable handoff.

## 2026-09-27 Debug fixture initialization fix

User's Xcode run exposed automatic CloudKit initialization in the Debug in-memory container. Simulator logs explicitly reported unsupported unique constraints and required attributes. The fixture configuration now sets cloudKitDatabase: .none, matching the local-only production configuration. No user store was removed or reset. A locally signed Debug build succeeded and the normal fixture was launched and visually verified after the change. Prior unsigned build verification had not covered this configuration difference.
