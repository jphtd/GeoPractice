import Combine
import Foundation
import SwiftUI

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
        if let data = defaults.data(forKey: Self.draftKey),
           let draft = try? JSONDecoder().decode(PracticeSessionDraft.self, from: data) {
            restored = draft.session
            restoredPreset = draft.preset?.normalized
            switch restored.phase {
            case .running:
                restored.pause(at: draft.savedAt)
            case .idle, .paused, .finished:
                break
            }
        }
        _session = Published(initialValue: restored)
        sessionPreset = restoredPreset
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

    func adjustCount(for hand: PracticeHand, by delta: Int) {
        var next = session
        next.adjustCount(for: hand, by: delta)
        commit(next, at: .now)
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
            ) { event in
                let request = PendingPracticeLaunch(
                    eventID: event.id,
                    eventName: event.name,
                    preset: event.preset
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
                finishPractice: {
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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                metronome.stop()
                practiceSession.pause()
            } else if selectedTab == .metronome {
                practiceSession.startIfNeeded(preset: metronome.preset)
            }
        }
        .onAppear {
            if let restoredPreset = practiceSession.sessionPreset {
                metronome.apply(restoredPreset)
            }
        }
        .onReceive(checkpointTimer) { date in
            guard scenePhase == .active,
                  selectedTab == .metronome,
                  practiceSession.session.isRunning
            else { return }
            practiceSession.persistSnapshot(at: date)
        }
    }

    private func launchPractice(_ request: PendingPracticeLaunch) {
        metronome.apply(request.preset)
        practiceSession.begin(sourceEventID: request.eventID, preset: request.preset)
        selectedTab = .metronome
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
        .modelContainer(for: PracticeEvent.self, inMemory: true)
}
