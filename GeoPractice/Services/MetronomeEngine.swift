import AVFoundation
import Combine
import Darwin
import Foundation

struct BeatPlaybackPulse: Equatable, Sendable {
    let beat: Int
    let subdivision: Int
    let cycle: Int
    let sequence: UInt64
    let kind: BeatPulseKind
    let eventInterval: TimeInterval
    let presentedAt: Date
}

@MainActor
final class MetronomeEngine: ObservableObject {
    @Published private(set) var preset: MetronomePreset
    private(set) var tempoSemantics: TempoSemantics
    private(set) var tempoReferenceNote: TempoReferenceNote
    @Published private(set) var isPlaying = false
    @Published private(set) var currentBeat = 0
    @Published private(set) var currentSubdivision = 0
    @Published private(set) var currentCycle = 0
    @Published private(set) var lastPulse: BeatPlaybackPulse?
    @Published var errorMessage: String?

    private var scheduler = BeatAudioScheduler()
    private var playbackToken = UUID()
    private var lastAcceptedPulseSequence: UInt64?
    private var cancellables: Set<AnyCancellable> = []
    private var groupingPreferences: [Int: String] = [:]

    init(
        preset: MetronomePreset = .standard,
        tempoSemantics: TempoSemantics = .independentReference,
        tempoReferenceNote: TempoReferenceNote? = nil
    ) {
        let normalized = preset.normalized
        self.preset = normalized
        self.tempoSemantics = tempoSemantics
        self.tempoReferenceNote = tempoReferenceNote ?? normalized.referenceNote
        groupingPreferences[normalized.beats] = normalized.grouping
        observeAudioSystem()
    }

    var playbackPlan: MetronomePlaybackPlan {
        preset.playbackPlan(
            semantics: tempoSemantics,
            referenceNote: tempoReferenceNote
        )
    }

    func apply(_ newPreset: MetronomePreset) {
        let normalized = newPreset.normalized
        let nextReference = tempoSemantics == .independentReference
            ? normalized.referenceNote
            : tempoReferenceNote
        groupingPreferences[normalized.beats] = normalized.grouping
        guard normalized != preset || nextReference != tempoReferenceNote else { return }
        let previousPreset = preset
        let previousPlan = playbackPlan
        preset = normalized
        tempoReferenceNote = nextReference
        if isPlaying {
            updatePlayback(
                from: previousPlan,
                previousPreset: previousPreset
            )
        }
    }

    func setBPM(_ bpm: Int, reschedule: Bool = true) {
        var updated = preset
        updated.bpm = bpm
        let normalized = updated.normalized
        guard normalized != preset else { return }
        preset = normalized
        if isPlaying, reschedule {
            reviseScheduledPlayback()
        }
    }

    func commitTempoChange() {
        if isPlaying {
            reviseScheduledPlayback()
        }
    }

    func nudgeBPM(by delta: Int) {
        setBPM(preset.bpm + delta)
    }

    func setBeats(_ beats: Int) {
        var updated = preset
        let normalizedBeats = min(max(beats, 3), 9)
        let validGroupings = MetronomePreset.groupings(for: normalizedBeats)
        updated.beats = normalizedBeats
        updated.grouping = groupingPreferences[normalizedBeats]
            .flatMap { validGroupings.contains($0) ? $0 : nil }
            ?? validGroupings[0]
        apply(updated)
    }

    func setSubdivision(_ subdivision: Int) {
        var updated = preset
        updated.subdivision = subdivision
        apply(updated)
    }

    /// Updates the written note that receives the BPM value. This is a formal
    /// preset change (rather than a debug-only interpretation), so it follows
    /// event inheritance and practice-session draft persistence.
    func setTempoReferenceNote(_ referenceNote: TempoReferenceNote) {
        var updated = preset
        updated.referenceNote = referenceNote
        let normalized = updated.normalized
        guard tempoSemantics != .independentReference
                || tempoReferenceNote != referenceNote
                || normalized != preset else { return }

        let previousPlan = playbackPlan
        let previousPreset = preset
        objectWillChange.send()
        tempoSemantics = .independentReference
        tempoReferenceNote = referenceNote
        preset = normalized
        if isPlaying {
            updatePlayback(
                from: previousPlan,
                previousPreset: previousPreset
            )
        }
    }

    func setDirection(_ direction: RotationDirection) {
        var updated = preset
        updated.direction = direction
        let normalized = updated.normalized
        guard normalized != preset else { return }
        preset = normalized
    }

    func setGrouping(_ grouping: String) {
        var updated = preset
        updated.grouping = grouping
        apply(updated)
    }

    /// Applies a temporary debug interpretation without changing the saved
    /// metronome preset. A timing change replaces the scheduler anchor exactly
    /// once without resetting the cursor; an inactive T3 reference note does
    /// not disturb playback.
    func setTempoExperiment(
        semantics: TempoSemantics,
        referenceNote: TempoReferenceNote
    ) {
        let previousPlan = playbackPlan
        guard semantics != tempoSemantics || referenceNote != tempoReferenceNote else { return }
        objectWillChange.send()
        tempoSemantics = semantics
        tempoReferenceNote = referenceNote
        if isPlaying {
            updatePlayback(
                from: previousPlan,
                previousPreset: preset
            )
        }
    }

    func toggle() {
        isPlaying ? stop() : start()
    }

    func start() {
        guard !isPlaying else { return }
        do {
            try configureAudioSession()
            isPlaying = true
            try beginScheduledPlayback()
            errorMessage = nil
        } catch {
            isPlaying = false
            scheduler.stop()
            errorMessage = "无法启动声音：\(error.localizedDescription)"
        }
    }

    func stop() {
        playbackToken = UUID()
        lastAcceptedPulseSequence = nil
        scheduler.stop()
        isPlaying = false
        currentBeat = 0
        currentSubdivision = 0
        currentCycle = 0
        lastPulse = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restartPlayback() {
        playbackToken = UUID()
        lastAcceptedPulseSequence = nil
        scheduler.stop()
        currentBeat = 0
        currentSubdivision = 0
        currentCycle = 0
        lastPulse = nil
        do {
            try configureAudioSession()
            try beginScheduledPlayback()
        } catch {
            scheduler.stop()
            isPlaying = false
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            errorMessage = "无法更新节拍：\(error.localizedDescription)"
        }
    }

    /// Applies timing-only and accent-only changes without returning to the
    /// first beat. A topology change still requires a fresh measure because
    /// the old beat/subdivision cursor cannot be mapped unambiguously.
    private func updatePlayback(
        from previousPlan: MetronomePlaybackPlan,
        previousPreset: MetronomePreset
    ) {
        let updatedPlan = playbackPlan
        let hasSameTopology = updatedPlan.eventsPerMeasure == previousPlan.eventsPerMeasure
            && updatedPlan.pulsesPerBeat == previousPlan.pulsesPerBeat

        guard hasSameTopology else {
            restartPlayback()
            return
        }

        let timingChanged = updatedPlan.eventInterval != previousPlan.eventInterval
        let accentsChanged = preset.strongBeatIndices != previousPreset.strongBeatIndices
            || preset.secondaryAccentIndices != previousPreset.secondaryAccentIndices
        if timingChanged || accentsChanged {
            reviseScheduledPlayback()
        }
    }

    /// Keeps the running audio graph and musical cursor intact. Already queued
    /// clicks finish unchanged; the latest settings take effect at the first
    /// event that has not yet entered the audio queue.
    private func reviseScheduledPlayback() {
        guard scheduler.reviseFutureSchedule(
            preset: preset,
            plan: playbackPlan
        ) else {
            // This is a recovery path for an inconsistent engine state, not the
            // normal tempo-change path.
            restartPlayback()
            return
        }
        errorMessage = nil
    }

    private func beginScheduledPlayback() throws {
        lastAcceptedPulseSequence = nil
        playbackToken = try scheduler.start(
            preset: preset,
            plan: playbackPlan
        ) { [weak self] token, pulse in
            guard let self, self.isPlaying, self.playbackToken == token else { return }
            if let lastSequence = self.lastAcceptedPulseSequence,
               pulse.sequence <= lastSequence {
                return
            }
            self.lastAcceptedPulseSequence = pulse.sequence
            self.currentBeat = pulse.beat
            self.currentSubdivision = pulse.subdivision
            self.currentCycle = pulse.cycle
            self.lastPulse = pulse
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    private func observeAudioSystem() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard
                        let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                        AVAudioSession.InterruptionType(rawValue: rawValue) == .began
                    else { return }
                    self?.stop()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard
                        let self,
                        self.isPlaying,
                        let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                        let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue),
                        [
                            .newDeviceAvailable,
                            .oldDeviceUnavailable,
                            .override,
                            .wakeFromSleep,
                            .noSuitableRouteForCategory,
                            .routeConfigurationChange
                        ].contains(reason)
                    else { return }
                    self.restartPlayback()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.playbackToken = UUID()
                    self.lastAcceptedPulseSequence = nil
                    self.scheduler.stop()
                    self.scheduler = BeatAudioScheduler()
                    self.isPlaying = false
                    self.currentBeat = 0
                    self.currentSubdivision = 0
                    self.currentCycle = 0
                    self.lastPulse = nil
                    self.errorMessage = "音频服务已重置，请重新点击播放。"
                }
            }
            .store(in: &cancellables)
    }
}

private final class BeatAudioScheduler: @unchecked Sendable {
    private enum ClickKind: CaseIterable {
        case downbeat
        case groupAccent
        case beat
        case subdivision
    }

    private struct PlaybackSession {
        let token: UUID
        var preset: MetronomePreset
        var plan: MetronomePlaybackPlan
        let startHostTime: UInt64
        let presentationLatency: TimeInterval
        let onTick: @MainActor @Sendable (UUID, BeatPlaybackPulse) -> Void
        var frontier: BeatScheduleFrontier
    }

    private struct PendingRevision {
        let preset: MetronomePreset
        let plan: MetronomePlaybackPlan
    }

    private let audioEngine = AVAudioEngine()
    private let schedulingQueue = DispatchQueue(label: "com.kuoxiyu.GeoPractice.audio-scheduler", qos: .userInteractive)
    private let sampleRate = 44_100.0
    private let lookAheadSeconds = 0.22
    private var playerNodes: [ClickKind: AVAudioPlayerNode] = [:]
    private var clickBuffers: [ClickKind: AVAudioPCMBuffer] = [:]
    private var schedulingTimer: DispatchSourceTimer?
    private var playbackSession: PlaybackSession?
    private var pendingRevision: PendingRevision?

    init() {
        prepareAudioGraph()
    }

    func start(
        preset: MetronomePreset,
        plan: MetronomePlaybackPlan,
        onTick: @escaping @MainActor @Sendable (UUID, BeatPlaybackPulse) -> Void
    ) throws -> UUID {
        return try schedulingQueue.sync {
            stopLocked()
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }

            for playerNode in playerNodes.values {
                playerNode.stop()
                playerNode.reset()
            }

            let token = UUID()
            let presentationLatency = audioEngine.outputNode.presentationLatency
            let startHostTime = mach_absolute_time()
                + AVAudioTime.hostTime(forSeconds: 0.035)
            playbackSession = PlaybackSession(
                token: token,
                preset: preset.normalized,
                plan: plan,
                startHostTime: startHostTime,
                presentationLatency: presentationLatency,
                onTick: onTick,
                frontier: BeatScheduleFrontier()
            )

            scheduleAheadLocked()
            let startTime = AVAudioTime(hostTime: startHostTime)
            for playerNode in playerNodes.values {
                playerNode.play(at: startTime)
            }

            let timer = DispatchSource.makeTimerSource(queue: schedulingQueue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                self?.scheduleAheadLocked()
            }
            schedulingTimer = timer
            timer.resume()
            return token
        }
    }

    func stop() {
        schedulingQueue.sync {
            stopLocked()
        }
    }

    /// Coalesces rapid UI commits on the scheduler queue. No queued audio is
    /// revoked, so the graph never pauses and the musical address cannot jump.
    func reviseFutureSchedule(
        preset: MetronomePreset,
        plan: MetronomePlaybackPlan
    ) -> Bool {
        schedulingQueue.sync {
            guard let session = playbackSession,
                  session.plan.eventsPerMeasure == plan.eventsPerMeasure,
                  session.plan.pulsesPerBeat == plan.pulsesPerBeat
            else { return false }
            pendingRevision = PendingRevision(
                preset: preset.normalized,
                plan: plan
            )
            return true
        }
    }

    private func stopLocked() {
        schedulingTimer?.setEventHandler {}
        schedulingTimer?.cancel()
        schedulingTimer = nil
        playbackSession = nil
        pendingRevision = nil
        for playerNode in playerNodes.values {
            playerNode.stop()
            playerNode.reset()
        }
        if audioEngine.isRunning {
            audioEngine.pause()
        }
    }

    private func scheduleAheadLocked() {
        applyPendingRevisionLocked()
        guard var session = playbackSession else { return }
        let nowHostTime = mach_absolute_time()
        let elapsedSeconds: Double
        if nowHostTime >= session.startHostTime {
            elapsedSeconds = AVAudioTime.seconds(forHostTime: nowHostTime - session.startHostTime)
        } else {
            elapsedSeconds = -AVAudioTime.seconds(forHostTime: session.startHostTime - nowHostTime)
        }
        if elapsedSeconds >= 0 {
            session.frontier.ensureNextEventIsNoEarlier(
                than: (elapsedSeconds + 0.012) * sampleRate
            )
        }
        let horizonFrame = max(0, elapsedSeconds + lookAheadSeconds) * sampleRate
        while session.frontier.nextExactFrame <= horizonFrame {
            let event = session.frontier.takeNext(
                plan: session.plan,
                sampleRate: sampleRate
            )
            let scheduledFrame = AVAudioFramePosition(event.exactFrame.rounded())
            let beat = event.beat
            let subdivision = event.subdivision
            let kind = clickKind(beat: beat, subdivision: subdivision, preset: session.preset)
            let pulseKind = BeatPulseVisualModel.kind(
                beat: beat,
                subdivision: subdivision,
                strongBeatIndices: session.preset.strongBeatIndices,
                secondaryAccentIndices: session.preset.secondaryAccentIndices
            )

            if let buffer = clickBuffers[kind], let playerNode = playerNodes[kind] {
                let audioTime = AVAudioTime(sampleTime: scheduledFrame, atRate: sampleRate)
                playerNode.scheduleBuffer(buffer, at: audioTime)
            }

            scheduleVisualTick(
                token: session.token,
                beat: beat,
                subdivision: subdivision,
                cycle: event.cycle,
                sequence: event.sequence,
                kind: pulseKind,
                eventInterval: event.eventInterval,
                eventFrame: event.exactFrame,
                startHostTime: session.startHostTime,
                presentationLatency: session.presentationLatency,
                callback: session.onTick
            )
        }
        playbackSession = session
    }

    private func applyPendingRevisionLocked() {
        guard let revision = pendingRevision,
              var session = playbackSession
        else { return }
        pendingRevision = nil

        if revision.plan.eventInterval != session.plan.eventInterval {
            let nowHostTime = mach_absolute_time()
            let elapsed: TimeInterval
            if nowHostTime >= session.startHostTime {
                elapsed = AVAudioTime.seconds(
                    forHostTime: nowHostTime - session.startHostTime
                )
            } else {
                elapsed = 0
            }
            let minimumNextFrame = (elapsed + 0.012) * sampleRate
            session.frontier.reviseFutureInterval(
                to: revision.plan.eventInterval,
                sampleRate: sampleRate,
                minimumNextExactFrame: minimumNextFrame
            )
        }
        session.preset = revision.preset
        session.plan = revision.plan
        playbackSession = session
    }

    private func scheduleVisualTick(
        token: UUID,
        beat: Int,
        subdivision: Int,
        cycle: Int,
        sequence: UInt64,
        kind: BeatPulseKind,
        eventInterval: TimeInterval,
        eventFrame: Double,
        startHostTime: UInt64,
        presentationLatency: TimeInterval,
        callback: @escaping @MainActor @Sendable (UUID, BeatPlaybackPulse) -> Void
    ) {
        let eventOffset = AVAudioTime.hostTime(forSeconds: eventFrame / sampleRate)
        let eventHostTime = startHostTime + eventOffset
        let nowHostTime = mach_absolute_time()
        let renderDelay = eventHostTime > nowHostTime
            ? AVAudioTime.seconds(forHostTime: eventHostTime - nowHostTime)
            : 0
        let delay = renderDelay + presentationLatency
        // Freeze the intended audible presentation time. If the main queue is
        // briefly busy, the visual envelope arrives already aged instead of
        // flashing late and drifting away from the click the user heard.
        let intendedPresentationDate = Date.now.addingTimeInterval(delay)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                callback(
                    token,
                    BeatPlaybackPulse(
                        beat: beat,
                        subdivision: subdivision,
                        cycle: cycle,
                        sequence: sequence,
                        kind: kind,
                        eventInterval: eventInterval,
                        presentedAt: intendedPresentationDate
                    )
                )
            }
        }
    }

    private func clickKind(beat: Int, subdivision: Int, preset: MetronomePreset) -> ClickKind {
        if subdivision > 0 {
            return .subdivision
        }
        if preset.strongBeatIndices.contains(beat) {
            return .downbeat
        }
        if preset.secondaryAccentIndices.contains(beat) {
            return .groupAccent
        }
        return .beat
    }

    private func prepareAudioGraph() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for kind in ClickKind.allCases {
            let playerNode = AVAudioPlayerNode()
            playerNodes[kind] = playerNode
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        }

        clickBuffers[.downbeat] = makeClick(frequency: 1_100, gain: 0.16, duration: 0.065, format: format)
        clickBuffers[.groupAccent] = makeClick(frequency: 850, gain: 0.16, duration: 0.065, format: format)
        clickBuffers[.beat] = makeClick(frequency: 620, gain: 0.085, duration: 0.065, format: format)
        clickBuffers[.subdivision] = makeClick(frequency: 420, gain: 0.032, duration: 0.040, format: format)
    }

    private func makeClick(
        frequency: Double,
        gain: Double,
        duration: Double,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        let terminalGain = 0.001
        let exponentialRate = log(terminalGain / gain) / duration

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            let attack = min(1, time / 0.0015)
            let envelope = gain * exp(exponentialRate * time) * attack
            samples[frame] = Float(sin(2 * .pi * frequency * time) * envelope)
        }
        return buffer
    }
}
