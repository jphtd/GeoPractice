# GeoBeat approved animation integration

Repository: https://github.com/jphtd/GeoPractice — branch `v4-design`.
Base: `9acb82d61c21acde489c73395340b9cfba109c98`.

## Source and scope

The approved source is `sketch.js`, copied unchanged from the animation-preview
folder belonging to “GeoBeat ·节拍器 动画与特效”, whose completed approval says
this p5.js preview is the final animation baseline. `DESIGN-NOTES.md` is also
preserved verbatim; its relative design-reference links refer to that original
workspace, not files supplied by this repository.

Replaced only the shipping `PrototypePulseStage` renderer. The legacy
`MetronomeView` renderer remains for its existing callers/tests. SwiftUI uses
the original 180-point contours, rounding, easing, 420 ms morph, speed-dependent
bounce, idle breathing, and current-beat dots. The existing scheduler supplies
beat/subdivision timestamps instead of a second visual timer. Existing BPM
controls provide the tempo readout; the preview's demo controls are not copied.
The compact stage scales the artwork to fit its existing layout.

Enabled the approved 1/2-beat modes in the shipping GeoBeat selector and the
shared preset/engine normalization. Existing 3–9-beat settings retain their
values. No dependencies, persistence schema changes, data migration, audio
scheduler changes, subscription changes, or animation redesign.

## Frozen contracts

The stage takes only preset, audio pulse, and transport state. It has no
Recording Context or Session input. Removed the Session-ID view identity
that could destroy its timeline. Tab selection no longer pauses the shared
metronome or practice session. Explicit pause, stop, and background policy
remain in their existing owners. Actual stop returns to idle; pause captures
the displayed beat; context updates cannot invoke either action in the stage.
Reduce Motion removes breathing, rotation, translation, and morph while
retaining the current beat indication.

The base branch does NOT yet implement the full Frozen navigation contract:
there is no independent Recording Context release/reconnect flow alongside
an existing Active Session; independent practice cannot yet be associated
with a section at save time. Practice/Analyze navigation and labels also still
reflect the existing product prototype. This animation-only commit does not
claim to implement or certify those missing product flows. They require a
separate product integration. End-to-end release/reconnect testing is therefore
not possible on this baseline, although the renderer is independent of them.

## Verification

- App Debug build for arm64 iOS Simulator: passed (Xcode 27).
- Entire existing test target, build-for-testing: passed; test execution has
  NOT occurred because this sandbox cannot connect to CoreSimulator.
- `python3 Documentation/GeoBeat/check-animation.py`: passed. Runs extracted
  production Swift geometry, compares all nine 180-point contours against
  the original JavaScript via JavaScriptCore, checks motion across seven
  tempos, reduced motion, subdivision timing and absence of Session identity.
- Simulator launch, audible playback, visual pause/resume and rapid meter
  changes remain unverified on a device. No claim of full runtime acceptance.

Local build command (the frontend option avoids nested compiler-plugin
sandbox failures; it does not change the project build settings):

```sh
xcodebuild -project GeoPractice.xcodeproj -scheme GeoPractice \
  -sdk iphonesimulator -configuration Debug -derivedDataPath /tmp/geobeat-build \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build-for-testing
```
