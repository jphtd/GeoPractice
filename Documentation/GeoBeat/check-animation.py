"""Run the production Swift geometry against the approved p5.js contours.
Usage: python3 Documentation/GeoBeat/check-animation.py (macOS with Xcode).
No packages required; generated build files stay in a temporary directory.
"""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
view = (repo / 'GeoPractice/Views/ProductPrototype/PrototypeRootMetronomeViews.swift').read_text()
engine = (repo / 'GeoPractice/Services/MetronomeEngine.swift').read_text()
lifecycle = (repo / 'GeoPractice/Models/BeatVisualLifecycle.swift').read_text()
model = view[view.index('enum GeoBeatAnimation {'):view.index('private struct PrototypePulseStage:')]
pulse = engine[engine.index('struct BeatPlaybackPulse:'):engine.index('/// The first musical address')]
kind = lifecycle[lifecycle.index('enum BeatPulseKind:'):lifecycle.index('struct BeatPulseAddress:')]
checks = r'''
let js = JSContext()!
js.exceptionHandler = { _, error in fatalError(error!.toString()) }
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let start = source.range(of: "const contourCache")!.lowerBound
let end = source.range(of: "function windowResized")!.lowerBound
js.evaluateScript(String(source[start..<end]))
for n in 1...9 {
    let expected = js.evaluateScript("JSON.stringify(contour(\(n)))")!.toString()!
    let points = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as! [[String: Double]]
    assert(points.count == GeoBeatAnimation.contours[n - 1].count)
    for (a, b) in zip(points, GeoBeatAnimation.contours[n - 1]) {
        assert(abs(a["x"]! - b.x) < 1e-12 && abs(a["y"]! - b.y) < 1e-12)
    }
    for bpm in [40, 80, 100, 130, 160, 180, 240] {
        for phase in stride(from: 0.0, through: Double(n), by: 0.125) {
            let date = Date(timeIntervalSinceReferenceDate: 42)
            let p = GeoBeatAnimation.outline(beats: n, bpm: bpm, beat: phase,
                idle: false, date: date, reduceMotion: false)
            assert(p.count == 180 && p.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            let reduced = GeoBeatAnimation.outline(beats: n, bpm: bpm, beat: phase,
                idle: false, date: date, reduceMotion: true)
            assert(reduced == GeoBeatAnimation.contours[n - 1])
        }
    }
}
let date = Date(timeIntervalSinceReferenceDate: 100)
let pulse = BeatPlaybackPulse(beat: 2, subdivision: 1, cycle: 3, sequence: 5,
    kind: .subdivision, eventInterval: 0.25, presentedAt: date)
assert(GeoBeatAnimation.beat(pulse: pulse, pulsesPerBeat: 2, at: date.addingTimeInterval(0.125)) == 2.75)
assert(GeoBeatAnimation.beat(pulse: pulse, pulsesPerBeat: 2, at: date.addingTimeInterval(1)) == 3)
assert(GeoBeatAnimation.beat(pulse: nil, pulsesPerBeat: 2, at: date) == 0)
print("PASS: all 9 contours match p5.js point-for-point; motion/reduced-motion and scheduler checks passed")
'''
# The recording context cannot recreate the stage or act as a clock input.
assert '.id(practiceSession.session.sessionID)' not in view
stage = view[view.index('private struct PrototypePulseStage:'):view.index('private struct PrototypeParameterMenu')]
assert 'practiceSession' not in stage and 'launch' not in stage
with tempfile.TemporaryDirectory(prefix='geobeat-check-') as folder:
    swift = Path(folder) / 'check.swift'
    swift.write_text('import Foundation\nimport JavaScriptCore\n' + kind + pulse + model + checks)
    subprocess.run(['swift', '-module-cache-path', folder + '/cache', str(swift), str(Path(__file__).with_name('sketch.js'))], check=True)
