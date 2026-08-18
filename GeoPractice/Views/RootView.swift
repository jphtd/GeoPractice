import Combine
import Foundation
import SwiftUI
import UIKit

enum RootTab: Hashable {
    case practice
    case metronome
}

private struct PendingPracticeLaunch {
    let eventID: UUID
    let eventName: String
    let preset: MetronomePreset
}

private struct PracticeSessionDraft: Codable {
    let session: PracticeSession
    let savedAt: Date
    let preset: MetronomePreset?
}

@MainActor
final class PracticeSessionController: ObservableObject {
    private static let draftKey = "practiceSessionDraft.v1"

    @Published private(set) var session: PracticeSession
    private(set) var sessionPreset: MetronomePreset?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var restored = PracticeSession()
        var restoredPreset: MetronomePreset?
        var restoredSavedAt: Date?
        if let data = defaults.data(forKey: Self.draftKey),
           let draft = try? JSONDecoder().decode(PracticeSessionDraft.self, from: data) {
            restored = draft.session
            restoredPreset = draft.preset?.normalized
            restoredSavedAt = draft.savedAt
            switch restored.phase {
            case .running:
                restored.pause(at: draft.savedAt)
            case .idle, .paused, .finished:
                break
            }
        }
        _session = Published(initialValue: restored)
        sessionPreset = restoredPreset
        if let restoredSavedAt {
            // Re-encode immediately so legacy drafts that had no sessionID
            // keep the decoder-generated ID across every later relaunch.
            persist(restored, at: restoredSavedAt)
        }
    }

    func begin(
        sourceEventID: UUID? = nil,
        preset: MetronomePreset,
        at date: Date = .now
    ) {
        var next = PracticeSession()
        next.begin(sourceEventID: sourceEventID, at: date)
        sessionPreset = preset.normalized
        commit(next, at: date)
    }

    func startIfNeeded(preset: MetronomePreset, at date: Date = .now) {
        switch session.phase {
        case .idle:
            begin(preset: preset, at: date)
        case .paused:
            if sessionPreset == nil {
                sessionPreset = preset.normalized
            }
            resume(at: date)
        case .running, .finished:
            break
        }
    }

    func resume(at date: Date = .now) {
        var next = session
        next.resume(at: date)
        commit(next, at: date)
    }

    func pause(at date: Date = .now) {
        var next = session
        next.pause(at: date)
        commit(next, at: date)
    }

    func switchHand(to hand: PracticeHand, at date: Date = .now) {
        var next = session
        next.switchHand(to: hand, at: date)
        commit(next, at: date)
    }

    func recordCompletion(
        for hand: PracticeHand,
        preset: MetronomePreset,
        at date: Date = .now
    ) {
        var next = session
        next.recordCompletion(for: hand, preset: preset, at: date)
        commit(next, at: date)
    }

    /// Compatibility for restoring and exercising legacy count-only drafts.
    /// User-facing `+1` controls always call `recordCompletion` instead.
    func adjustCount(for hand: PracticeHand, by delta: Int) {
        var next = session
        next.adjustCount(for: hand, by: delta)
        commit(next, at: .now)
    }

    @discardableResult
    func undoLastCompletion(
        for hand: PracticeHand,
        at date: Date = .now
    ) -> PracticeCompletionSample? {
        var next = session
        let removed = next.undoLastCompletion(for: hand)
        guard removed != nil else { return nil }
        commit(next, at: date)
        return removed
    }

    /// User-facing undo that also supports pre-history drafts whose counts do
    /// not have corresponding completion samples.
    @discardableResult
    func undoLatestCompletionOrLegacyCount(
        for hand: PracticeHand,
        at date: Date = .now
    ) -> Bool {
        var next = session
        if next.undoLastCompletion(for: hand) == nil {
            guard next.stats(for: hand, at: date).count > 0 else { return false }
            next.adjustCount(for: hand, by: -1)
        }
        commit(next, at: date)
        return true
    }

    func finish(at date: Date = .now) -> PracticeSessionSummary? {
        var next = session
        let summary = next.finish(at: date)
        commit(next, at: date)
        return summary
    }

    func continueAfterReview(at date: Date = .now) {
        var next = session
        next.continueAfterReview(at: date)
        commit(next, at: date)
    }

    func reset() {
        session = PracticeSession()
        sessionPreset = nil
        defaults.removeObject(forKey: Self.draftKey)
    }

    func updatePreset(_ preset: MetronomePreset, at date: Date = .now) {
        guard session.phase != .idle else { return }
        sessionPreset = preset.normalized
        persist(session, at: date)
    }

    func persistSnapshot(at date: Date = .now) {
        persist(session, at: date)
    }

    private func commit(_ next: PracticeSession, at date: Date) {
        session = next
        persist(next, at: date)
    }

    private func persist(_ session: PracticeSession, at date: Date) {
        guard session.phase != .idle else {
            defaults.removeObject(forKey: Self.draftKey)
            return
        }
        let draft = PracticeSessionDraft(
            session: session,
            savedAt: date,
            preset: sessionPreset
        )
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: Self.draftKey)
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PracticePreferenceKeys.continueAudioInBackground)
    private var continueAudioInBackground = true
    @AppStorage(PracticePreferenceKeys.keepScreenAwake)
    private var keepScreenAwake = false
    @StateObject private var metronome = MetronomeEngine()
    @StateObject private var practiceSession = PracticeSessionController()
    @State private var selectedTab: RootTab = .practice
    @State private var pendingPracticeLaunch: PendingPracticeLaunch?
    private let checkpointTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $selectedTab) {
            PracticeEventsView(
                metronome: metronome,
                protectedEventID: protectedPracticeEventID
            ) { event, preset in
                let request = PendingPracticeLaunch(
                    eventID: event.id,
                    eventName: event.name,
                    preset: preset
                )
                if practiceSession.session.phase == .running
                    || practiceSession.session.phase == .paused
                    || practiceSession.session.phase == .finished {
                    pendingPracticeLaunch = request
                } else {
                    launchPractice(request)
                }
            }
            .tag(RootTab.practice)
            .tabItem {
                Label("打卡", systemImage: "checkmark.circle")
            }

            MetronomeView(
                engine: metronome,
                practiceSession: practiceSession,
                leaveMetronome: {
                    selectedTab = .practice
                }
            )
                .tag(RootTab.metronome)
                .tabItem {
                    Label("节拍器", systemImage: "metronome")
                }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "当前练习尚未处理完",
            isPresented: Binding(
                get: { pendingPracticeLaunch != nil },
                set: { if !$0 { pendingPracticeLaunch = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("返回当前练习") {
                pendingPracticeLaunch = nil
                selectedTab = .metronome
            }
            if let request = pendingPracticeLaunch {
                Button("放弃本次并开始“\(request.eventName)”", role: .destructive) {
                    pendingPracticeLaunch = nil
                    launchPractice(request)
                }
            }
            Button("取消", role: .cancel) {
                pendingPracticeLaunch = nil
            }
        } message: {
            Text("当前会话的次数和时长尚未保存。你可以返回节拍器完成或确认汇总，也可以明确放弃后开始新的练习。")
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .metronome {
                if let restoredPreset = practiceSession.sessionPreset {
                    metronome.apply(restoredPreset)
                }
                practiceSession.startIfNeeded(preset: metronome.preset)
            } else {
                metronome.stop()
                practiceSession.pause()
            }
            synchronizeIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase, at: .now)
        }
        .onChange(of: metronome.isPlaying) { wasPlaying, isPlaying in
            handlePlaybackChange(
                wasPlaying: wasPlaying,
                isPlaying: isPlaying,
                at: .now
            )
        }
        .onChange(of: keepScreenAwake) { _, _ in
            synchronizeIdleTimer()
        }
        .onChange(of: continueAudioInBackground) { _, _ in
            guard scenePhase == .background else { return }
            handleBackgroundTransition(at: .now)
        }
        .onAppear {
            if let restoredPreset = practiceSession.sessionPreset {
                metronome.apply(restoredPreset)
            }
            synchronizeIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(checkpointTimer) { date in
            guard runtimePolicy.shouldPersistCheckpoint(
                sceneState: runtimeSceneState(for: scenePhase),
                isMetronomeSelected: selectedTab == .metronome,
                isMetronomePlaying: metronome.isPlaying,
                isPracticeRunning: practiceSession.session.isRunning
            ) else { return }
            practiceSession.persistSnapshot(at: date)
        }
    }

    private func launchPractice(_ request: PendingPracticeLaunch) {
        metronome.apply(request.preset)
        practiceSession.begin(sourceEventID: request.eventID, preset: request.preset)
        selectedTab = .metronome
    }

    private var runtimePolicy: PracticeRuntimePolicy {
        PracticeRuntimePolicy(
            continueAudioInBackground: continueAudioInBackground,
            keepScreenAwake: keepScreenAwake
        )
    }

    private func handleScenePhaseChange(_ phase: ScenePhase, at date: Date) {
        switch phase {
        case .inactive:
            // Locking an iPhone passes through inactive before background. Save
            // immediately, but do not tear down audio during that transition.
            // If an interruption stopped audio just before the phase update,
            // pause timing here so the two states cannot drift apart.
            if runtimePolicy.shouldPauseWhenEnteringInactive(
                isMetronomeSelected: selectedTab == .metronome,
                isMetronomePlaying: metronome.isPlaying,
                isPracticeRunning: practiceSession.session.isRunning
            ) {
                practiceSession.pause(at: date)
            }
            practiceSession.persistSnapshot(at: date)
        case .background:
            handleBackgroundTransition(at: date)
        case .active:
            if selectedTab == .metronome {
                practiceSession.startIfNeeded(preset: metronome.preset, at: date)
            }
        @unknown default:
            practiceSession.persistSnapshot(at: date)
        }
        synchronizeIdleTimer(for: phase)
    }

    private func handleBackgroundTransition(at date: Date) {
        switch runtimePolicy.backgroundAction(
            isMetronomeSelected: selectedTab == .metronome,
            isMetronomePlaying: metronome.isPlaying
        ) {
        case .continueRunning:
            practiceSession.startIfNeeded(preset: metronome.preset, at: date)
            practiceSession.persistSnapshot(at: date)
        case .stopAndPause:
            metronome.stop()
            practiceSession.pause(at: date)
            practiceSession.persistSnapshot(at: date)
        }
        synchronizeIdleTimer(for: .background)
    }

    private func handlePlaybackChange(
        wasPlaying: Bool,
        isPlaying: Bool,
        at date: Date
    ) {
        if runtimePolicy.shouldPauseAfterOffscreenPlaybackStops(
            sceneState: runtimeSceneState(for: scenePhase),
            isMetronomeSelected: selectedTab == .metronome,
            wasPlaying: wasPlaying,
            isPlaying: isPlaying,
            isPracticeRunning: practiceSession.session.isRunning
        ) {
            // Audio interruptions and media-service resets can stop the engine
            // while no UI is visible. Keep the recorded practice duration in
            // step with the audio truth instead of silently counting onward.
            practiceSession.pause(at: date)
            practiceSession.persistSnapshot(at: date)
        }
        synchronizeIdleTimer()
    }

    private func synchronizeIdleTimer(for phase: ScenePhase? = nil) {
        let effectivePhase = phase ?? scenePhase
        let shouldDisable = runtimePolicy.shouldDisableIdleTimer(
            sceneState: runtimeSceneState(for: effectivePhase),
            isMetronomeSelected: selectedTab == .metronome,
            isMetronomePlaying: metronome.isPlaying
        )
        if UIApplication.shared.isIdleTimerDisabled != shouldDisable {
            UIApplication.shared.isIdleTimerDisabled = shouldDisable
        }
    }

    private func runtimeSceneState(
        for phase: ScenePhase
    ) -> PracticeRuntimePolicy.SceneState {
        switch phase {
        case .active:
            .active
        case .inactive:
            .inactive
        case .background:
            .background
        @unknown default:
            .inactive
        }
    }

    private var protectedPracticeEventID: UUID? {
        switch practiceSession.session.phase {
        case .running, .paused, .finished:
            practiceSession.session.sourceEventID
        case .idle:
            nil
        }
    }
}

#Preview {
    RootView()
        .modelContainer(
            for: [PracticeEvent.self, PracticeAttempt.self],
            inMemory: true
        )
}
