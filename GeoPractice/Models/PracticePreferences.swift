import Foundation

enum TempoScrubDirection: String, CaseIterable, Codable, Identifiable, Sendable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontal:
            "左右滑动"
        case .vertical:
            "上下滑动"
        }
    }

    var detail: String {
        switch self {
        case .horizontal:
            "向右加速，向左减速"
        case .vertical:
            "向上加速，向下减速"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .horizontal:
            "向右拖动提高速度，向左拖动降低速度"
        case .vertical:
            "向上拖动提高速度，向下拖动降低速度"
        }
    }

    /// Returns a signed distance with positive values always meaning a tempo
    /// increase. UIKit's vertical translation grows downwards, so the vertical
    /// option deliberately reverses that axis.
    func primaryTranslation(horizontal: Double, vertical: Double) -> Double {
        switch self {
        case .horizontal:
            horizontal
        case .vertical:
            -vertical
        }
    }
}

enum PracticePreferenceKeys {
    static let tempoScrubDirection = "practice.tempoScrubDirection.v1"
    static let continueAudioInBackground = "practice.continueAudioInBackground.v1"
    static let keepScreenAwake = "practice.keepScreenAwake.v1"
}

/// Pure policy for lifecycle behavior. Keeping this independent from SwiftUI,
/// UIApplication and the audio engine makes lock-screen decisions deterministic
/// and directly testable.
struct PracticeRuntimePolicy: Equatable, Sendable {
    enum SceneState: Equatable, Sendable {
        case active
        case inactive
        case background
    }

    enum BackgroundAction: Equatable, Sendable {
        case continueRunning
        case stopAndPause
    }

    let continueAudioInBackground: Bool
    let keepScreenAwake: Bool

    init(
        continueAudioInBackground: Bool = true,
        keepScreenAwake: Bool = false
    ) {
        self.continueAudioInBackground = continueAudioInBackground
        self.keepScreenAwake = keepScreenAwake
    }

    func backgroundAction(
        isMetronomeSelected: Bool,
        isMetronomePlaying: Bool
    ) -> BackgroundAction {
        continueAudioInBackground && isMetronomeSelected && isMetronomePlaying
            ? .continueRunning
            : .stopAndPause
    }

    func shouldDisableIdleTimer(
        sceneState: SceneState,
        isMetronomeSelected: Bool,
        isMetronomePlaying: Bool
    ) -> Bool {
        sceneState == .active
            && keepScreenAwake
            && isMetronomeSelected
            && isMetronomePlaying
    }

    func shouldPersistCheckpoint(
        sceneState: SceneState,
        isMetronomeSelected: Bool,
        isMetronomePlaying: Bool,
        isPracticeRunning: Bool
    ) -> Bool {
        guard isMetronomeSelected, isPracticeRunning else { return false }

        switch sceneState {
        case .active:
            return true
        case .inactive:
            return false
        case .background:
            return backgroundAction(
                isMetronomeSelected: isMetronomeSelected,
                isMetronomePlaying: isMetronomePlaying
            ) == .continueRunning
        }
    }

    func shouldPauseWhenEnteringInactive(
        isMetronomeSelected: Bool,
        isMetronomePlaying: Bool,
        isPracticeRunning: Bool
    ) -> Bool {
        isMetronomeSelected
            && !isMetronomePlaying
            && isPracticeRunning
    }

    func shouldPauseAfterOffscreenPlaybackStops(
        sceneState: SceneState,
        isMetronomeSelected: Bool,
        wasPlaying: Bool,
        isPlaying: Bool,
        isPracticeRunning: Bool
    ) -> Bool {
        sceneState != .active
            && isMetronomeSelected
            && wasPlaying
            && !isPlaying
            && isPracticeRunning
    }
}
