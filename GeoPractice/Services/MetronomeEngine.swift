import AVFoundation
import Combine
import Darwin
import Foundation

/// The four audible roles of a metronome event. Keeping this mapping outside
/// AVFoundation makes the sound hierarchy deterministic and directly testable.
enum MetronomeClickKind: String, CaseIterable, Hashable, Sendable {
    case downbeat
    case groupAccent
    case beat
    case subdivision

    init(pulseKind: BeatPulseKind) {
        switch pulseKind {
        case .strong:
            self = .downbeat
        case .secondary:
            self = .groupAccent
        case .weak:
            self = .beat
        case .subdivision:
            self = .subdivision
        }
    }
}

/// A short procedural click tuned for phone speakers. `targetPeak` is a hard
/// digital ceiling for a single rendered click, not a system-volume override.
struct MetronomeClickProfile: Equatable, Sendable {
    static let maximumPeak = 0.60
    static let maximumDuration: TimeInterval = 0.018

    let frequency: Double
    let targetPeak: Double
    let duration: TimeInterval
    let attackDuration: TimeInterval
    let decayTimeConstant: TimeInterval
    let harmonicMix: Double
    let transientMix: Double

    static func profile(for kind: MetronomeClickKind) -> Self {
        switch kind {
        case .downbeat:
            Self(
                frequency: 1_800,
                targetPeak: 0.54,
                duration: 0.018,
                attackDuration: 0.00035,
                decayTimeConstant: 0.0058,
                harmonicMix: 0.34,
                transientMix: 0.24
            )
        case .groupAccent:
            Self(
                frequency: 1_450,
                targetPeak: 0.44,
                duration: 0.017,
                attackDuration: 0.00038,
                decayTimeConstant: 0.0052,
                harmonicMix: 0.30,
                transientMix: 0.20
            )
        case .beat:
            Self(
                frequency: 1_050,
                targetPeak: 0.34,
                duration: 0.016,
                attackDuration: 0.00042,
                decayTimeConstant: 0.0048,
                harmonicMix: 0.27,
                transientMix: 0.17
            )
        case .subdivision:
            Self(
                frequency: 780,
                targetPeak: 0.22,
                duration: 0.0135,
                attackDuration: 0.00045,
                decayTimeConstant: 0.0039,
                harmonicMix: 0.22,
                transientMix: 0.12
            )
        }
    }
}

/// Offline renderer shared by the audio graph and unit tests. The waveform is
/// deliberately deterministic: two calls with the same kind and sample rate
/// return bit-for-bit identical samples.
enum MetronomeClickWaveform {
    static func samples(
        for kind: MetronomeClickKind,
        sampleRate: Double
    ) -> [Float] {
        samples(
            profile: MetronomeClickProfile.profile(for: kind),
            sampleRate: sampleRate
        )
    }

    static func samples(
        profile: MetronomeClickProfile,
        sampleRate: Double
    ) -> [Float] {
        guard sampleRate.isFinite, sampleRate >= 8_000 else { return [] }

        let duration = min(
            MetronomeClickProfile.maximumDuration,
            max(2 / sampleRate, finiteOrZero(profile.duration))
        )
        let frameCount = max(2, Int(floor(sampleRate * duration)))
        let targetPeak = min(
            MetronomeClickProfile.maximumPeak,
            max(0, finiteOrZero(profile.targetPeak))
        )
        guard targetPeak > 0 else { return Array(repeating: 0, count: frameCount) }

        let nyquistSafeFrequency = sampleRate * 0.44
        let frequency = min(
            nyquistSafeFrequency / 2,
            max(40, finiteOrZero(profile.frequency))
        )
        let attackDuration = max(1 / sampleRate, finiteOrZero(profile.attackDuration))
        let decayTimeConstant = max(1 / sampleRate, finiteOrZero(profile.decayTimeConstant))
        let harmonicMix = min(0.5, max(0, finiteOrZero(profile.harmonicMix)))
        let transientMix = min(0.35, max(0, finiteOrZero(profile.transientMix)))
        let releaseDuration = min(0.0012, duration * 0.18)
        let transientFrequencyA = min(3_200, nyquistSafeFrequency)
        let transientFrequencyB = min(5_100, nyquistSafeFrequency * 0.92)

        var rawSamples = [Double](repeating: 0, count: frameCount)
        var rawPeak = 0.0

        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            let remaining = max(0, duration - time)
            let attackProgress = min(1, time / attackDuration)
            let attack = attackProgress * attackProgress * (3 - 2 * attackProgress)
            let releaseProgress = min(1, remaining / releaseDuration)
            let release = releaseProgress * releaseProgress * (3 - 2 * releaseProgress)
            let tonalDecay = exp(-time / decayTimeConstant)
            let transientDecay = exp(-time / 0.00115)

            let fundamental = sin(2 * .pi * frequency * time)
            let harmonic = sin(2 * .pi * frequency * 2 * time + 0.17)
            let transient = 0.62 * sin(2 * .pi * transientFrequencyA * time)
                + 0.38 * sin(2 * .pi * transientFrequencyB * time + 0.31)
            let sample = attack * release * (
                (fundamental + harmonicMix * harmonic) * tonalDecay
                    + transientMix * transient * transientDecay
            )

            rawSamples[frame] = sample
            rawPeak = max(rawPeak, abs(sample))
        }

        guard rawPeak > .ulpOfOne else {
            return Array(repeating: 0, count: frameCount)
        }

        let normalization = targetPeak / rawPeak
        var result = rawSamples.map { sample -> Float in
            let normalized = sample * normalization
            let limited = min(
                MetronomeClickProfile.maximumPeak,
                max(-MetronomeClickProfile.maximumPeak, normalized)
            )
            return Float(limited)
        }

        // Exact zero endpoints avoid a discontinuity when AVAudioPlayerNode
        // begins or releases a buffer, including at the fastest supported rate.
        result[0] = 0
        result[result.count - 1] = 0
        return result
    }

    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

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
    private var playerNodes: [MetronomeClickKind: AVAudioPlayerNode] = [:]
    private var clickBuffers: [MetronomeClickKind: AVAudioPCMBuffer] = [:]
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
            let pulseKind = BeatPulseVisualModel.kind(
                beat: beat,
                subdivision: subdivision,
                strongBeatIndices: session.preset.strongBeatIndices,
                secondaryAccentIndices: session.preset.secondaryAccentIndices
            )
            let clickKind = MetronomeClickKind(pulseKind: pulseKind)

            if let buffer = clickBuffers[clickKind],
               let playerNode = playerNodes[clickKind] {
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

    private func prepareAudioGraph() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for kind in MetronomeClickKind.allCases {
            let playerNode = AVAudioPlayerNode()
            playerNodes[kind] = playerNode
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            clickBuffers[kind] = makeClick(kind: kind, format: format)
        }
    }

    private func makeClick(
        kind: MetronomeClickKind,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let waveform = MetronomeClickWaveform.samples(
            for: kind,
            sampleRate: format.sampleRate
        )
        let frameCount = AVAudioFrameCount(waveform.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for (frame, sample) in waveform.enumerated() {
            samples[frame] = sample
        }
        return buffer
    }
}
