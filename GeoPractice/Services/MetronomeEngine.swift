import AVFoundation
import Combine
import Darwin
import Foundation

/// Pure continuation math for an interval-only transport update. Keeping this
/// independent from AVAudioEngine makes P0-3 cursor behavior deterministic at
/// subdivision and measure boundaries.
struct BeatPlaybackContinuation: Equatable, Sendable {
    let initialEventIndex: Int
    let initialCycle: Int
    let firstEventPresentationDelay: TimeInterval?

    static func next(
        currentBeat: Int,
        currentSubdivision: Int,
        currentCycle: Int,
        previousPlan: MetronomePlaybackPlan,
        nextPlan: MetronomePlaybackPlan,
        elapsedSinceLastPulse: TimeInterval?
    ) -> BeatPlaybackContinuation {
        guard let elapsedSinceLastPulse else {
            return BeatPlaybackContinuation(
                initialEventIndex: 0,
                initialCycle: 0,
                firstEventPresentationDelay: nil
            )
        }

        let eventCount = max(1, previousPlan.eventsPerMeasure)
        let rawCurrentIndex = currentBeat * previousPlan.pulsesPerBeat
            + currentSubdivision
        let currentIndex = min(eventCount - 1, max(0, rawCurrentIndex))
        let nextIndex = currentIndex + 1
        let wrapsMeasure = nextIndex >= eventCount
        let delay = max(
            0,
            nextPlan.eventInterval - max(0, elapsedSinceLastPulse)
        )

        return BeatPlaybackContinuation(
            initialEventIndex: wrapsMeasure ? 0 : nextIndex,
            initialCycle: max(0, currentCycle) + (wrapsMeasure ? 1 : 0),
            firstEventPresentationDelay: delay
        )
    }
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
    @Published private(set) var lastPulseDate = Date.distantPast
    @Published var errorMessage: String?

    private var scheduler = BeatAudioScheduler()
    private var playbackToken = UUID()
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
        let previousPlan = playbackPlan
        preset = normalized
        if isPlaying, reschedule {
            continuePlayback(from: previousPlan)
        }
    }

    func commitTempoChange() {
        if isPlaying {
            continuePlayback(from: playbackPlan)
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
        scheduler.stop()
        isPlaying = false
        currentBeat = 0
        currentSubdivision = 0
        currentCycle = 0
        lastPulseDate = .distantPast
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restartPlayback() {
        playbackToken = UUID()
        scheduler.stop()
        currentBeat = 0
        currentSubdivision = 0
        currentCycle = 0
        lastPulseDate = .distantPast
        do {
            try beginScheduledPlayback()
        } catch {
            isPlaying = false
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
            continuePlayback(from: previousPlan)
        }
    }

    /// Cancels all look-ahead audio and visual callbacks, then makes the next
    /// logical event the first event of a new scheduler anchor. The published
    /// beat, subdivision, cycle, and last pulse remain intact while the new
    /// interval is applied relative to the most recently heard pulse.
    private func continuePlayback(from previousPlan: MetronomePlaybackPlan) {
        let hasPresentedPulse = lastPulseDate != .distantPast
        let elapsed = hasPresentedPulse
            ? max(0, Date.now.timeIntervalSince(lastPulseDate))
            : nil
        let continuation = BeatPlaybackContinuation.next(
            currentBeat: currentBeat,
            currentSubdivision: currentSubdivision,
            currentCycle: currentCycle,
            previousPlan: previousPlan,
            nextPlan: playbackPlan,
            elapsedSinceLastPulse: elapsed
        )

        playbackToken = UUID()
        do {
            playbackToken = try scheduler.start(
                preset: preset,
                plan: playbackPlan,
                initialEventIndex: continuation.initialEventIndex,
                initialCycle: continuation.initialCycle,
                firstEventPresentationDelay: continuation.firstEventPresentationDelay
            ) { [weak self] token, beat, subdivision, cycle in
                Task { @MainActor [weak self] in
                    guard let self, self.isPlaying, self.playbackToken == token else { return }
                    self.currentBeat = beat
                    self.currentSubdivision = subdivision
                    self.currentCycle = cycle
                    self.lastPulseDate = .now
                }
            }
            errorMessage = nil
        } catch {
            isPlaying = false
            scheduler.stop()
            errorMessage = "无法更新节拍：\(error.localizedDescription)"
        }
    }

    private func beginScheduledPlayback() throws {
        playbackToken = try scheduler.start(
            preset: preset,
            plan: playbackPlan
        ) { [weak self] token, beat, subdivision, cycle in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, self.playbackToken == token else { return }
                self.currentBeat = beat
                self.currentSubdivision = subdivision
                self.currentCycle = cycle
                self.lastPulseDate = .now
            }
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
                    self.scheduler.stop()
                    self.scheduler = BeatAudioScheduler()
                    self.isPlaying = false
                    self.currentBeat = 0
                    self.currentSubdivision = 0
                    self.currentCycle = 0
                    self.lastPulseDate = .distantPast
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
        let preset: MetronomePreset
        let plan: MetronomePlaybackPlan
        let startHostTime: UInt64
        let presentationLatency: TimeInterval
        let onTick: @Sendable (UUID, Int, Int, Int) -> Void
        var nextExactFrame: Double
        var eventIndex: Int
        var cycle: Int
    }

    private let audioEngine = AVAudioEngine()
    private let schedulingQueue = DispatchQueue(label: "com.kuoxiyu.GeoPractice.audio-scheduler", qos: .userInteractive)
    private let sampleRate = 44_100.0
    private let lookAheadSeconds = 0.22
    private var playerNodes: [ClickKind: AVAudioPlayerNode] = [:]
    private var clickBuffers: [ClickKind: AVAudioPCMBuffer] = [:]
    private var schedulingTimer: DispatchSourceTimer?
    private var playbackSession: PlaybackSession?

    init() {
        prepareAudioGraph()
    }

    func start(
        preset: MetronomePreset,
        plan: MetronomePlaybackPlan,
        initialEventIndex: Int = 0,
        initialCycle: Int = 0,
        firstEventPresentationDelay: TimeInterval? = nil,
        onTick: @escaping @Sendable (UUID, Int, Int, Int) -> Void
    ) throws -> UUID {
        // Capture the requested audible deadline before tearing down the old
        // graph. This keeps queue-reset time from being added to the first
        // continued interval on a busy device.
        let requestedPresentationHostTime = firstEventPresentationDelay.map {
            mach_absolute_time()
                + AVAudioTime.hostTime(forSeconds: max(0, $0))
        }

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
            let renderLead: TimeInterval
            if let requestedPresentationHostTime {
                // Player-node scheduling is expressed at render time, while
                // the deadline is expressed at the user's audible/visual
                // presentation time. Subtract graph-reset time and output
                // latency, while retaining a small safe render lead.
                let nowHostTime = mach_absolute_time()
                let remainingPresentationDelay: TimeInterval
                if requestedPresentationHostTime > nowHostTime {
                    remainingPresentationDelay = AVAudioTime.seconds(
                        forHostTime: requestedPresentationHostTime - nowHostTime
                    )
                } else {
                    remainingPresentationDelay = 0
                }
                renderLead = max(
                    0.012,
                    remainingPresentationDelay - presentationLatency
                )
            } else {
                renderLead = 0.035
            }
            let startHostTime = mach_absolute_time()
                + AVAudioTime.hostTime(forSeconds: renderLead)
            let safeEventIndex = min(
                max(0, initialEventIndex),
                max(0, plan.eventsPerMeasure - 1)
            )
            playbackSession = PlaybackSession(
                token: token,
                preset: preset.normalized,
                plan: plan,
                startHostTime: startHostTime,
                presentationLatency: presentationLatency,
                onTick: onTick,
                nextExactFrame: 0,
                eventIndex: safeEventIndex,
                cycle: max(0, initialCycle)
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

    private func stopLocked() {
        schedulingTimer?.setEventHandler {}
        schedulingTimer?.cancel()
        schedulingTimer = nil
        playbackSession = nil
        for playerNode in playerNodes.values {
            playerNode.stop()
            playerNode.reset()
        }
        if audioEngine.isRunning {
            audioEngine.pause()
        }
    }

    private func scheduleAheadLocked() {
        guard var session = playbackSession else { return }
        let nowHostTime = mach_absolute_time()
        let elapsedSeconds: Double
        if nowHostTime >= session.startHostTime {
            elapsedSeconds = AVAudioTime.seconds(forHostTime: nowHostTime - session.startHostTime)
        } else {
            elapsedSeconds = -AVAudioTime.seconds(forHostTime: session.startHostTime - nowHostTime)
        }
        let horizonFrame = max(0, elapsedSeconds + lookAheadSeconds) * sampleRate
        let exactInterval = sampleRate * session.plan.eventInterval
        let eventCount = session.plan.eventsPerMeasure

        while session.nextExactFrame <= horizonFrame {
            let scheduledFrame = AVAudioFramePosition(session.nextExactFrame.rounded())
            let beat = session.eventIndex / session.plan.pulsesPerBeat
            let subdivision = session.eventIndex % session.plan.pulsesPerBeat
            let kind = clickKind(beat: beat, subdivision: subdivision, preset: session.preset)

            if let buffer = clickBuffers[kind], let playerNode = playerNodes[kind] {
                let audioTime = AVAudioTime(sampleTime: scheduledFrame, atRate: sampleRate)
                playerNode.scheduleBuffer(buffer, at: audioTime)
            }

            scheduleVisualTick(
                token: session.token,
                beat: beat,
                subdivision: subdivision,
                cycle: session.cycle,
                eventFrame: session.nextExactFrame,
                startHostTime: session.startHostTime,
                presentationLatency: session.presentationLatency,
                callback: session.onTick
            )

            session.nextExactFrame += exactInterval
            session.eventIndex += 1
            if session.eventIndex == eventCount {
                session.eventIndex = 0
                session.cycle += 1
            }
        }
        playbackSession = session
    }

    private func scheduleVisualTick(
        token: UUID,
        beat: Int,
        subdivision: Int,
        cycle: Int,
        eventFrame: Double,
        startHostTime: UInt64,
        presentationLatency: TimeInterval,
        callback: @escaping @Sendable (UUID, Int, Int, Int) -> Void
    ) {
        let eventOffset = AVAudioTime.hostTime(forSeconds: eventFrame / sampleRate)
        let eventHostTime = startHostTime + eventOffset
        let nowHostTime = mach_absolute_time()
        let renderDelay = eventHostTime > nowHostTime
            ? AVAudioTime.seconds(forHostTime: eventHostTime - nowHostTime)
            : 0
        let delay = renderDelay + presentationLatency

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            callback(token, beat, subdivision, cycle)
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
