import AVFoundation
import Combine
import Darwin
import Foundation

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

    init(
        preset: MetronomePreset = .standard,
        tempoSemantics: TempoSemantics = .legacyQuarterReference,
        tempoReferenceNote: TempoReferenceNote = .quarter
    ) {
        self.preset = preset.normalized
        self.tempoSemantics = tempoSemantics
        self.tempoReferenceNote = tempoReferenceNote
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
        guard normalized != preset else { return }
        preset = normalized
        if isPlaying {
            restartPlayback()
        }
    }

    func setBPM(_ bpm: Int, reschedule: Bool = true) {
        var updated = preset
        updated.bpm = bpm
        let normalized = updated.normalized
        guard normalized != preset else { return }
        preset = normalized
        if isPlaying, reschedule {
            restartPlayback()
        }
    }

    func commitTempoChange() {
        if isPlaying {
            restartPlayback()
        }
    }

    func nudgeBPM(by delta: Int) {
        setBPM(preset.bpm + delta)
    }

    func setBeats(_ beats: Int) {
        var updated = preset
        updated.beats = beats
        updated.grouping = MetronomePreset.groupings(for: beats)[0]
        apply(updated)
    }

    func setSubdivision(_ subdivision: Int) {
        var updated = preset
        updated.subdivision = subdivision
        apply(updated)
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

    /// Applies a customer-comparison tempo interpretation without changing the
    /// saved metronome preset. A timing change restarts the scheduler exactly
    /// once; changing an inactive T3 reference note does not disturb playback.
    func setTempoExperiment(
        semantics: TempoSemantics,
        referenceNote: TempoReferenceNote
    ) {
        let previousPlan = playbackPlan
        guard semantics != tempoSemantics || referenceNote != tempoReferenceNote else { return }
        objectWillChange.send()
        tempoSemantics = semantics
        tempoReferenceNote = referenceNote
        let updatedPlan = playbackPlan
        if isPlaying, !updatedPlan.hasSameSchedule(as: previousPlan) {
            restartPlayback()
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
        onTick: @escaping @Sendable (UUID, Int, Int, Int) -> Void
    ) throws -> UUID {
        try schedulingQueue.sync {
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
            let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.035)
            playbackSession = PlaybackSession(
                token: token,
                preset: preset.normalized,
                plan: plan,
                startHostTime: startHostTime,
                presentationLatency: audioEngine.outputNode.presentationLatency,
                onTick: onTick,
                nextExactFrame: 0,
                eventIndex: 0,
                cycle: 0
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
