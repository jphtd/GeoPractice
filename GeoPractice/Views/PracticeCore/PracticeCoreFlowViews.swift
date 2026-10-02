import SwiftData
import SwiftUI

/// Temporary native screens for the E2E path; not FROZEN visual acceptance.
struct CoreTestLabel: View {
    var body: some View {
        Text("端到端测试版 · 临时界面").font(.caption).foregroundStyle(.secondary)
    }
}

struct CoreEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let route: CoreRoute
    let songs: [PracticeSong]
    let events: [PracticeEvent]
    let activeSessionID: UUID?
    let onSaved: (CorePage) -> Void
    @State private var name = ""
    @State private var mode = CoreDivisionMode.measures
    @State private var total = ""
    @State private var first = ""
    @State private var last = ""
    @State private var handMode = CoreHandMode.all
    @State private var goals: [PracticeHand: CoreGoalInput] = [:]
    @State private var setupGoal = false
    @State private var discardConfirmation = false
    @State private var didAttemptSave = false
    @State private var didPopulate = false
    @State private var initialGoals: [PracticeHand: CoreGoalInput] = [:]
    @State private var error: String?

    private var piece: PracticeSong? {
        let id: UUID?
        switch route {
        case .createDivision(let value, _), .pieceSettings(let value): id = value
        case .editGoal(let value, _): id = value
        default: id = nil
        }
        return songs.first { $0.id == id }
    }
    private var division: PracticeEvent? {
        if case .editGoal(_, let id) = route { return events.first { $0.id == id } }
        return nil
    }
    private var title: String {
        switch route {
        case .addPiece: "添加曲目"
        case .createDivision: "创建练习划分"
        case .editGoal: division?.coreDefinition?.hasValidGoal == true ? "编辑 Goal" : "设置 Goal"
        case .pieceSettings: "曲目设置"
        default: "全部曲目"
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                if isEditable {
                    Section { CorePageHeader(title: title, back: cancel) }
                        .listRowBackground(Color.clear)
                } else { Section { CoreTestLabel() } }
                switch route {
                case .addPiece:
                    Section("曲目") {
                        TextField("曲目名称", text: $name).accessibilityIdentifier("core.piece.name")
                        Picker("划分方式", selection: $mode) {
                            ForEach(CoreDivisionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        TextField("总数（可选）", text: $total).keyboardType(.numberPad)
                    }
                case .createDivision:
                    Section("《\(piece?.name ?? "")》 · \(piece?.coreStructure?.label ?? "")") {
                        Text(piece?.coreStructure?.mode == .sections ? "段落范围" : "小节范围").coreType(.titleSmall)
                        LabeledContent(piece?.coreStructure?.mode == .sections ? "起始段落" : "起始小节") {
                            TextField("", text: $first).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                                .accessibilityIdentifier("core.division.first")
                        }
                        LabeledContent(piece?.coreStructure?.mode == .sections ? "结束段落" : "结束小节") {
                            TextField("", text: $last).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                                .accessibilityIdentifier("core.division.last")
                        }
                        Text("范围不能与现有划分重叠，可以保留未划分区域。").coreType(.caption)
                    }
                    Section("适用手型") {
                        ForEach(CoreHandMode.allCases, id: \.self) { mode in
                            Button { handMode = mode } label: {
                                HStack {
                                    Text(mode.label).coreType(.body)
                                    Spacer()
                                    Image(systemName: handMode == mode ? "checkmark.circle.fill" : "circle")
                                }.foregroundStyle(CorePalette.primary).padding(.vertical, 8)
                            }.accessibilityAddTraits(handMode == mode ? .isSelected : [])
                                .accessibilityIdentifier("core.division.hand.\(mode.rawValue)")
                        }
                    }
                    Section("Goal（可选）") {
                        if setupGoal {
                            CoreButton(title: "暂不设置 Goal", kind: .tertiary) { setupGoal = false }
                        } else {
                            Text("暂不设置 Goal").coreType(.body)
                            CoreButton(title: "同时设置 Goal", kind: .secondary) { setupGoal = true }
                                .accessibilityIdentifier("core.division.enableGoal")
                        }
                    }
                    if setupGoal { goalFields(for: handMode) }
                case .editGoal:
                    if let mode = division?.coreDefinition?.handMode {
                        Section {
                            Text("《\(piece?.name ?? "")》 · \(division?.name ?? "")").coreType(.body)
                            Text("适用手型 · \(mode.label)").coreType(.caption)
                        }
                        goalFields(for: mode)
                    }
                case .pieceSettings:
                    if let piece, let structure = piece.coreStructure {
                        Section("《\(piece.name)》") {
                            Text(structure.label)
                            NavigationLink("创建练习划分") {
                                CoreEditorView(route: .createDivision(piece: piece.id, mode: structure.mode),
                                    songs: songs, events: events, activeSessionID: activeSessionID, onSaved: onSaved)
                            }
                            Text("本测试版本保留曲目结构，不提供结构重划或历史迁移。").font(.caption)
                        }
                    }
                default:
                    ForEach(songs) { song in
                        Button(song.name) { onSaved(.piece(song.id)); dismiss() }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if route == .addPiece || isEditable {
                    Section {
                        CoreButton(title: isCreating ? "保存练习划分" : "保存", action: save).accessibilityIdentifier("core.editor.save")
                        if isEditable { CoreButton(title: "取消", kind: .tertiary, action: cancel) }
                    }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isEditable { ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) } }
            }
            .toolbar(isEditable ? .hidden : .visible, for: .navigationBar)
            .interactiveDismissDisabled(hasUnsavedChanges)
            .alert(isCreating ? "放弃创建练习划分？" : "放弃未保存的 Goal 修改？", isPresented: $discardConfirmation) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃", role: .destructive) { dismiss() }
            }
            .onAppear { populate() }
        }
    }
    private var isEditable: Bool {
        switch route { case .createDivision, .editGoal: true; default: false }
    }
    private var isCreating: Bool { if case .createDivision = route { true } else { false } }
    private var hasUnsavedChanges: Bool {
        if isCreating { return !first.isEmpty || !last.isEmpty || handMode != .all || setupGoal || goals != initialGoals }
        if case .editGoal = route { return goals != initialGoals }
        return false
    }
    private func cancel() {
        if hasUnsavedChanges { discardConfirmation = true } else { dismiss() }
    }
    @ViewBuilder private func goalFields(for mode: CoreHandMode) -> some View {
        ForEach(mode.hands) { hand in
            CoreGoalInputRow(hand: hand, input: Binding(get: { goals[hand] ?? CoreGoalInput() }, set: { goals[hand] = $0 }),
                             showRequiredError: didAttemptSave)
        }
        Section {
            Text("每个适用手型至少填写目标次数或练习目标速度之一。速度使用所选音符单位，独立于实际节拍器速度。")
                .coreType(.caption).foregroundStyle(CorePalette.secondary)
        }
    }
    private func populate() {
        guard !didPopulate else { return }; didPopulate = true
        guard let goal = division?.coreDefinition?.goal else { return }
        goals = goal.hands.mapValues { CoreGoalInput(count: $0.count.map(String.init) ?? "",
            speed: $0.speed.map { String($0.bpm) } ?? "", unit: $0.speed?.noteUnit ?? .quarter) }
        initialGoals = goals
    }
    private func basicGoal(for mode: CoreHandMode) throws -> CoreGoal {
        var values: [PracticeHand: CoreHandGoal] = [:]
        for hand in mode.hands {
            let input = goals[hand] ?? CoreGoalInput()
            let bpm = try optionalPositive(input.speed, label: "\(hand.title)目标速度")
            values[hand] = CoreHandGoal(count: try optionalPositive(input.count, label: "\(hand.title)目标次数"),
                speed: bpm.map { CoreTargetSpeed(bpm: $0, noteUnit: input.unit) })
        }
        let goal = CoreGoal(hands: values)
        guard goal.isValid(for: mode) else { throw CoreIntegrationError.invalidGoal }
        return goal
    }
    private func optionalPositive(_ text: String, label: String) throws -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard let number = Int(value), number > 0 else { throw CoreFlowError.invalidInput("\(label)须为正整数。") }
        return number
    }
    private func save() {
        didAttemptSave = true
        do {
            guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
            switch route {
            case .addPiece:
                let structure = CorePieceStructure(mode: mode, total: try optionalPositive(total, label: "总数"))
                let song = try CoreContracts.savePiece(name: name, structure: structure, context: modelContext, activeSessionID: activeSessionID)
                onSaved(.piece(song.id))
            case .createDivision:
                guard let piece, let first = try optionalPositive(first, label: "起始位置"),
                      let last = try optionalPositive(last, label: "结束位置") else {
                    throw CoreFlowError.invalidInput("请填写起始和结束位置。")
                }
                let page = try CoreContracts.saveCreatedDivision(piece: piece,
                    definition: CoreDivisionDefinition(first: first, last: last, handMode: handMode,
                        goal: setupGoal ? try basicGoal(for: handMode) : nil),
                    context: modelContext, activeSessionID: activeSessionID)
                onSaved(page)
            case .editGoal:
                guard let division, let definition = division.coreDefinition, let piece else { throw CoreIntegrationError.missingMetadata }
                let goal = try basicGoal(for: definition.handMode)
                onSaved(try CoreContracts.saveGoal(piece: piece.id, division: division, goal: goal,
                    context: modelContext, activeSessionID: activeSessionID))
            default: return
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct CoreGoalInput: Equatable {
    var count = ""
    var speed = ""
    var unit = CoreNoteUnit.quarter
}
private struct CoreGoalInputRow: View {
    let hand: PracticeHand
    @Binding var input: CoreGoalInput
    var showRequiredError = false
    var body: some View {
        Section(hand.title) {
            LabeledContent("目标次数") {
                TextField("可选", text: $input.count).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    .accessibilityIdentifier("core.goal.\(hand.rawValue).count")
            }
            if !input.count.isEmpty && (Int(input.count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) < 1 {
                Text("目标次数须为正整数。").coreType(.caption).foregroundStyle(.red)
            }
            LabeledContent("练习目标 BPM") {
                TextField("可选", text: $input.speed).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    .accessibilityIdentifier("core.goal.\(hand.rawValue).speed")
            }
            if !input.speed.isEmpty && !(20...300).contains(Int(input.speed.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) {
                Text("练习目标 BPM 须为 20–300 的整数。").coreType(.caption).foregroundStyle(.red)
            }
            Picker("目标音符单位", selection: $input.unit) {
                ForEach(CoreNoteUnit.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if showRequiredError && input.count.isEmpty && input.speed.isEmpty {
                Text("请填写目标次数或练习目标速度。").coreType(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct CoreSessionView: View {
    @Query private var attempts: [PracticeAttempt]
    @ObservedObject var runtime: CoreSessionRuntime
    @ObservedObject var engine: MetronomeEngine
    var isGeoBeat: Bool
    let openGeoBeat: () -> Void
    let finish: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(isGeoBeat ? "GeoBeat" : "当前计划练习").font(.largeTitle.bold())
                CoreTestLabel()
                if let context = runtime.context {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("正在记录到当前 Session").font(.headline)
                        Text("《\(context.pieceName)》 · \(context.divisionName)")
                        Text("状态：\(runtime.session.isRunning ? "练习中" : "已暂停") · 本次 \(runtime.count) 次")
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let seconds = PracticeHand.allCases.reduce(Int64(0)) { $0 + runtime.session.stats(for: $1, at: timeline.date).durationMilliseconds } / 1000
                            Text("有效计时 \(seconds / 60):\(String(format: "%02lld", seconds % 60))").monospacedDigit()
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    if context.handMode.allowsHandSwitching {
                        Picker("当前手型", selection: Binding(get: { runtime.session.currentHand }, set: { runtime.switchHand($0) })) {
                            ForEach(context.handMode.hands) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("core.session.handSwitcher")
                    } else {
                        Text("当前手型 · \(runtime.session.currentHand.title)").coreType(.body)
                            .accessibilityIdentifier("core.session.currentHand")
                    }
                    if let goal = context.goal.hands[runtime.session.currentHand] {
                        Text("本手型本次完成 \(runtime.session.completionSamples(for: runtime.session.currentHand).count) 次"
                             + (goal.count.map { " · 每日目标 \($0) 次" } ?? ""))
                        if let target = goal.speed { Text("目标：\(target.noteUnit.title) = \(target.bpm) BPM").foregroundStyle(.secondary) }
                    }
                } else {
                    Text("独立 GeoBeat · 未关联计划 Session").font(.headline)
                    Text("当前使用节拍器不会改变任何划分的 Goal 或 Stable BPM。").font(.callout).foregroundStyle(.secondary)
                }
                if isGeoBeat {
                    PrototypePulseStage(preset: engine.preset, pulse: engine.lastPulse, isPlaying: engine.isPlaying).frame(height: 240)
                }
                CoreTempoControls(engine: engine)
                if let context = runtime.context,
                   let stable = CoreAnalysis.stable(CoreAnalysis.planned(attempts, division: context.divisionID), hand: runtime.session.currentHand) {
                    let suggested = stable / engine.preset.referenceNote.durationInQuarterNotes
                    Text("建议起始速度：\(suggested.formatted(.number.precision(.fractionLength(0...1)))) BPM（\(engine.preset.referenceNote.title)）。可自行修改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = engine.errorMessage { Text(message).foregroundStyle(.red) }
                if isGeoBeat {
                    CoreButton(title: engine.isPlaying ? "暂停练习 / 节拍器" : "播放 / 继续练习", kind: runtime.context == nil ? .primary : .secondary) {
                        if engine.isPlaying { engine.pause(); runtime.pause() }
                        else { engine.start(); if engine.isPlaying { runtime.resume() } }
                    }.accessibilityIdentifier("core.geobeat.play")
                    if runtime.context != nil {
                        CoreButton(title: "完成一次 · \(runtime.session.currentHand.title)") { runtime.record(preset: engine.effectivePlaybackPreset) }
                            .disabled(!runtime.session.isRunning).accessibilityIdentifier("core.session.record")
                        Text("每完整练习一次后点一次。每条记录保留当时的手型、BPM 和音符单位；节拍声本身不会自动计为一次完成。").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    CoreButton(title: "进入 GeoBeat 练习", action: openGeoBeat).accessibilityIdentifier("core.session.openGeoBeat")
                    CoreButton(title: runtime.session.isRunning ? "暂停计时" : "继续计时", kind: .secondary) {
                        if runtime.session.isRunning { runtime.pause(); engine.pause() } else { runtime.resume() }
                    }
                }
                if runtime.context != nil {
                    CoreButton(title: "结束练习", kind: .secondary, action: finish).accessibilityIdentifier("core.session.finish")
                }
            }.padding().frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(CorePalette.canvas)
    }
}

private struct CoreTempoControls: View {
    @ObservedObject var engine: MetronomeEngine
    @State private var enteredBPM = ""
    @State private var inputError: String?
    @FocusState private var bpmFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Stepper("实际速度：\(engine.preset.bpm) BPM", value: Binding(get: { engine.preset.bpm }, set: { engine.setBPM($0) }), in: 20...240)
                .accessibilityIdentifier("core.tempo.bpm")
            HStack {
                TextField("输入 BPM（20–240）", text: $enteredBPM).keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($bpmFocused)
                    .accessibilityIdentifier("core.tempo.input")
                Button("应用") {
                    guard let value = TempoScrubModel.validatedBPMInput(enteredBPM) else {
                        inputError = "实际速度须为 20–240 的整数。"; return
                    }
                    engine.setBPM(value); enteredBPM = ""; inputError = nil; bpmFocused = false
                }.accessibilityIdentifier("core.tempo.apply")
            }
            if let inputError { Text(inputError).font(.caption).foregroundStyle(.red) }
            Picker("实际音符单位", selection: Binding(get: { engine.preset.referenceNote }, set: {
                var value = engine.preset; value.referenceNote = $0; engine.apply(value)
            })) {
                ForEach(TempoReferenceNote.allCases) { Text($0.title).tag($0) }
            }
            Stepper("每小节 \(engine.preset.beats) 拍", value: Binding(get: { engine.preset.beats }, set: { engine.setBeats($0) }), in: 1...9)
        }
    }
}

struct CoreAnalyzeView: View {
    @Query private var events: [PracticeEvent]
    @Query private var songs: [PracticeSong]
    @Query private var attempts: [PracticeAttempt]
    let scope: CoreAnalyzeContext
    var body: some View {
        List {
            Section { CoreTestLabel(); Text("只使用已确认保存的计划练习。速度按手型分别计算，未练过的手型显示暂无数据。") }
            ForEach(filteredEvents) { event in
                if let definition = event.coreDefinition {
                    Section("《\(songs.first { $0.id == event.songID }?.name ?? "曲目")》 · \(event.name)") {
                        CoreDivisionAnalysis(definition: definition, attempts: CoreAnalysis.planned(attempts, division: event.id))
                        if let latest = CoreAnalysis.planned(attempts, division: event.id).first {
                            NavigationLink("查看最近一次 Session 结果") { CoreSavedSessionView(attempt: latest) }
                        }
                    }
                }
            }
            if filteredEvents.isEmpty { Text("还没有练习划分。添加曲目并完成一次计划练习后查看结果。") }
        }.navigationTitle("Analyze").navigationBarTitleDisplayMode(.inline)
    }
    private var filteredEvents: [PracticeEvent] {
        events.filter { event in
            switch scope {
            case .overall: return event.coreDefinition != nil
            case .piece(let piece): return event.songID == piece
            case .division(let piece, let division): return event.songID == piece && event.id == division
            }
        }.sorted { $0.createdAt < $1.createdAt }
    }
}

struct CoreDivisionAnalysis: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    @State private var previewPro = false
    let definition: CoreDivisionDefinition
    let attempts: [PracticeAttempt]
    var comparison: [PracticeHand: Double] = [:]
    var body: some View {
        if attempts.isEmpty { Text("暂无已保存的计划练习") }
        ForEach(definition.handMode.hands) { hand in
            VStack(alignment: .leading, spacing: 8) {
                Text(hand.title).font(.headline)
                let stable = CoreAnalysis.stable(attempts, hand: hand)
                Text("Stable BPM：\(stable.map(format) ?? "暂无数据")（四分音符等值）")
                if let previous = comparison[hand], let stable {
                    Text("保存前 \(format(previous)) → 保存后 \(format(stable))").font(.caption)
                }
                if let goal = definition.goal, let target = goal.hands[hand] {
                    let count = CoreAnalysis.count(attempts, hand: hand, cycleStart: Calendar.current.startOfDay(for: .now))
                    if let targetCount = target.count { Text("本周期次数：\(count) / \(targetCount)") }
                    if count == 0, let latest = attempts.first(where: { $0.completions.contains { $0.hand == hand } }),
                       (goal.updatedAt ?? .distantPast) <= latest.finishedAt {
                        Text("本周期尚无此手型的已保存记录；熟练度沿用上一份有效值。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let speed = target.speed {
                        Text("当前目标：\(speed.noteUnit.title) = \(speed.bpm) BPM")
                        if let stable { Text("速度完成度：\(format(100 * stable / speed.quarterEquivalent))%") }
                    }
                    if let mastery = CoreAnalysis.mastery(attempts, hand: hand, goal: goal) {
                        Text("手型 Mastery：\(format(mastery * 100))%")
                    } else if target.speed == nil {
                        Text("当前只有次数目标，暂时无法计算熟练度；设置练习目标速度后可计算熟练度与弱项。").font(.caption)
                    }
                    if subscription.isPro || previewPro {
                        Text("Goal Gap").font(.subheadline.bold())
                        if let targetCount = target.count { Text("次数差距：\(max(0, targetCount - count)) 次") }
                        if let speed = target.speed {
                            if let stable { Text("速度差距：\(format(max(0, Double(speed.bpm) - stable / speed.noteUnit.quarterMultiplier))) BPM（\(speed.noteUnit.title)）") }
                            else { Text("速度差距：暂无数据") }
                        }
                    }
                }
            }.padding(.vertical, 8)
        }
        if let mastery = CoreAnalysis.divisionMastery(attempts, definition: definition) {
            Text("划分 Mastery：\(format(mastery * 100))%")
            Text(mastery <= 0.8 ? "基础弱项提醒：距当前目标熟练度仍有至少 20% 差距。" : "当前划分未触发基础弱项提醒。")
        } else { Text("划分 Mastery：尚未建立").foregroundStyle(.secondary) }
        if !subscription.isPro {
            Text("详细 Goal Gap 为 Pro 分析。Free 可查看当前 Stable BPM、次数进度及基础熟练度。").font(.caption).foregroundStyle(.secondary)
#if DEBUG
            Toggle("测试预览 Pro Goal Gap", isOn: $previewPro)
            if previewPro { Text("仅此 Debug 界面的验收预览；不代表购买或解锁 Pro。").font(.caption).foregroundStyle(.secondary) }
#endif
        }
        Text("已保存 Session：\(attempts.count)").font(.caption)
    }
    private func format(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
}

struct CoreResultDestination: Identifiable {
    let id = UUID()
    let context: CoreSessionContext
}
struct CoreResultView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var events: [PracticeEvent]
    @Query private var attempts: [PracticeAttempt]
    @ObservedObject var runtime: CoreSessionRuntime
    let destination: CoreResultDestination
    let onReturn: (CorePage) -> Void
    @State private var saved: PracticeAttempt?
    @State private var error: String?
    @State private var before: [PracticeHand: Double] = [:]
    var body: some View {
        NavigationStack {
            List {
                Section {
                    CoreTestLabel()
                    Text("《\(destination.context.pieceName)》 · \(destination.context.divisionName)")
                    Text("Session 所属周期：\(destination.context.cycleLabel)").font(.callout)
                    Text("跨午夜也归属于开始时的每日周期。当前周期进度在下方另行显示。").font(.caption).foregroundStyle(.secondary)
                    Text(saved == nil ? "请核对本次数据，再确认保存。" : "Session 已保存，已更新对应划分的分析。")
                }
                let samples = saved?.completions ?? runtime.session.reviewSummary?.completions ?? []
                Section("本次有效时长") {
                    ForEach(destination.context.handMode.hands) { hand in
                        let milliseconds = saved?.stats(for: hand).durationMilliseconds ?? runtime.session.stats(for: hand, at: .now).durationMilliseconds
                        Text("\(hand.title)：\(milliseconds / 1000) 秒")
                    }
                }
                Section("本次原始记录 · \(samples.count) 次") {
                    ForEach(samples) { sample in
                        Text("\(sample.hand.title) · \(sample.preset.referenceNote.title) = \(sample.preset.bpm) BPM · \(sample.completedAt.formatted(date: .abbreviated, time: .standard))")
                    }
                    if samples.isEmpty { Text("没有完成记录；退出不会保存空 Session。") }
                }
                if let saved, let definition = events.first(where: { $0.id == saved.eventID })?.coreDefinition {
                    Section("本次所属周期累计") {
                        ForEach(destination.context.handMode.hands) { hand in
                            let count = CoreAnalysis.count(CoreAnalysis.planned(attempts, division: saved.eventID), hand: hand, cycleStart: destination.context.cycleStart)
                            Text("\(hand.title)：\(count) 次（\(destination.context.cycleLabel)）")
                        }
                    }
                    Section("保存结果 / Analyze") {
                        CoreDivisionAnalysis(definition: definition, attempts: CoreAnalysis.planned(attempts, division: saved.eventID), comparison: before)
                    }
                    Button("返回练习划分") { returnToDivision() }.accessibilityIdentifier("core.result.return")
                } else {
                    if !samples.isEmpty {
                        Button("确认保存", action: save).accessibilityIdentifier("core.result.save")
                    } else {
                        Button("结束并返回（不保存空 Session）") {
                            do { try runtime.discardEmpty(); returnToDivision() } catch { self.error = error.localizedDescription }
                        }
                    }
                    Button("继续本次练习") { runtime.continuePractice(); dismiss() }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(saved == nil ? "确认练习结果" : "已保存的练习结果").navigationBarTitleDisplayMode(.inline)
        }.interactiveDismissDisabled()
    }
    private func save() {
        do {
            guard let event = events.first(where: { $0.id == destination.context.divisionID }) else { throw CoreIntegrationError.wrongDestination }
            let history = CoreAnalysis.planned(attempts, division: event.id)
            for hand in destination.context.handMode.hands { before[hand] = CoreAnalysis.stable(history, hand: hand) }
            saved = try runtime.save(division: event, in: modelContext)
        } catch { self.error = error.localizedDescription }
    }
    private func returnToDivision() {
        onReturn(.division(piece: destination.context.pieceID, division: destination.context.divisionID)); dismiss()
    }
}

/// Read-only access to the last saved raw result, including after app restart.
private struct CoreSavedSessionView: View {
    let attempt: PracticeAttempt
    var body: some View {
        List {
            Section {
                CoreTestLabel()
                Text("计划练习 · 已确认保存")
                if let context = attempt.coreContext {
                    Text("《\(context.pieceName)》 · \(context.divisionName)")
                    Text("Session 所属周期：\(context.cycleLabel)")
                }
                Text("结束时间：\(attempt.finishedAt.formatted(date: .abbreviated, time: .standard))")
            }
            Section("本次结果") {
                ForEach(attempt.coreContext?.handMode.hands ?? PracticeHand.allCases) { hand in
                    let stats = attempt.stats(for: hand)
                    Text("\(hand.title)：\(stats.count) 次 · \(stats.durationMilliseconds / 1000) 秒")
                }
            }
            Section("原始记录") {
                ForEach(attempt.completions) { sample in
                    Text("\(sample.hand.title) · \(sample.preset.referenceNote.title) = \(sample.preset.bpm) BPM · \(sample.completedAt.formatted(date: .abbreviated, time: .standard))")
                }
            }
        }.navigationTitle("已保存 Session").navigationBarTitleDisplayMode(.inline)
    }
}
