import SwiftData
import SwiftUI
import UIKit

struct CoreEditorView: View {
    @EnvironmentObject private var settings: CorePracticeSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subscription: SubscriptionStore
    @Query private var savedAttempts: [PracticeAttempt]
    let route: CoreRoute
    let songs: [PracticeSong]
    let events: [PracticeEvent]
    let activeSessionID: UUID?
    let onSaved: (CorePage) -> Void
    var onRoute: (CoreRoute) -> Void = { _ in }
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
    @State private var advanced = false
    private var ladderEnabled: Bool { settings.activation(isPro: subscription.isPro).enabled }
    @State private var confirmedHands: Set<PracticeHand> = []
    @State private var initialLadderEnabled = false
    @State private var reset = CoreResetConfiguration()
    @State private var initialReset = CoreResetConfiguration()
    @State private var editTiming: CoreGoalEditTiming?
    @State private var analyzeTiming: CoreAnalyzeTiming?
    @State private var adjustedStartHands: Set<PracticeHand> = []
    @State private var startConflict: PracticeHand?
    @State private var error: String?

    private var piece: PracticeSong? {
        let id: UUID?

        switch route {
        case .createDivision(let value, _):
            id = value

        case .editDivision(let value, _):
            id = value

        default:
            id = nil
        }

        return songs.first { $0.id == id && $0.deletedAt == nil }
    }
    private var division: PracticeEvent? {
        switch route {
        case .editDivision(_, let id):
            return events.first { $0.id == id }

        default:
            return nil
        }
    }
    private var title: String {
        switch route {
        case .addPiece: "添加曲目"
        case .createDivision: "创建练习划分"
        case .editDivision: "编辑"
        default: "全部曲目"
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                if isEditable {
                    Section { CorePageHeader(title: title, back: cancel) }
                        .listRowBackground(Color.clear)
                }
                switch route {
                case .addPiece:
                    Section("曲目") {
                        TextField("曲目名称", text: $name).accessibilityIdentifier("core.piece.name")
                        Picker("划分方式", selection: $mode) {
                            ForEach(CoreDivisionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        TextField("总数（可选）", text: $total).keyboardType(.numberPad)
                    }
                case .createDivision, .editDivision:
                    Section("练习划分") {
                        Text("《\(piece?.name ?? "")》 · \(piece?.coreStructure?.label ?? "")").coreType(.caption)
                        Text(piece?.coreStructure?.mode == .sections ? "段落范围" : "小节范围")
                            .coreType(.titleSmall)

                        LabeledContent(piece?.coreStructure?.mode == .sections ? "起始段落" : "起始小节") {
                            TextField("", text: $first)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                                .accessibilityIdentifier("core.division.first")
                        }

                        LabeledContent(piece?.coreStructure?.mode == .sections ? "结束段落" : "结束小节") {
                            TextField("", text: $last)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                                .accessibilityIdentifier("core.division.last")
                        }

                    }

                    Section("适用手型") {
                        ForEach(CoreHandMode.allCases, id: \.self) { mode in
                            Button {
                                handMode = mode
                            } label: {
                                HStack {
                                    Text(mode.label).coreType(.body)
                                    Spacer()
                                    Image(systemName: handMode == mode ? "checkmark.circle.fill" : "circle")
                                }
                                .foregroundStyle(CorePalette.primary)
                                .padding(.vertical, 8)
                            }
                            .accessibilityAddTraits(handMode == mode ? .isSelected : [])
                            .accessibilityIdentifier("core.division.hand.\(mode.rawValue)")
                        }
                    }

                    if case .createDivision = route {
                        Section("目标（可选）") {
                            if setupGoal {
                                CoreButton(title: "暂不设置目标", kind: .tertiary) {
                                    setupGoal = false
                                }
                            } else {
                                Text("暂不设置目标").coreType(.body)

                                CoreButton(title: "同时设置目标", kind: .secondary) {
                                    setupGoal = true
                                }
                                .accessibilityIdentifier("core.division.enableGoal")
                            }
                        }

                        if setupGoal {
                            goalFields(for: handMode)
                        }
                    }
                    if case .editDivision = route {
                        Section("目标") { EmptyView() }
                        goalFields(for: handMode)
                    }
                default:
                    ForEach(songs.filter { $0.deletedAt == nil }) { song in
                        Button(song.name) { onSaved(.piece(song.id)); dismiss() }
                    }
                    Section("管理") {
                        NavigationLink("已归档曲目") {
                            CoreArchiveView(activeSessionID: activeSessionID, onRoute: onRoute)
                        }
                        if subscription.isPro {
                            NavigationLink("最近删除的曲目") { CoreRecentlyDeletedView() }
                        }
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
            .alert(isCreating ? "放弃创建练习划分？" : "放弃未保存的修改？", isPresented: $discardConfirmation) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃", role: .destructive) { dismiss() }
            }
            .alert("建议起始速度高于新的目标速度", isPresented: Binding(get: { startConflict != nil }, set: { if !$0 { startConflict = nil } })) {
                Button("调整") {
                    if let hand = startConflict { adjustedStartHands.insert(hand); goals[hand]?.start = "" }
                    startConflict = nil
                }
                Button("不调整", role: .cancel) { startConflict = nil }
            } message: {
                Text("调整后建议为 max(20, 目标速度 − 10)。建议不会自动保存，请继续输入并确认真实起始速度；不调整则不能保存此下周期有限速度阶梯。")
            }
            .onAppear { populate() }
            .onChange(of: error) { _, message in
                if let message { UIAccessibility.post(notification: .announcement, argument: message) }
            }
        }
    }
    private var isEditable: Bool {
        switch route {
        case .createDivision, .editDivision:
            return true
        default:
            return false
        }
    }
    private var isCreating: Bool { if case .createDivision = route { true } else { false } }
    private var hasUnsavedChanges: Bool {
        if isCreating {
            return !first.isEmpty || !last.isEmpty || handMode != .all || setupGoal || goals != initialGoals ||
                reset != initialReset
        }

        if case .editDivision = route,
           let definition = division?.coreDefinition {
            return first != String(definition.first) ||
                last != String(definition.last) ||
                handMode != definition.handMode ||
                configurationChanged || reset != initialReset || !confirmedHands.isEmpty
        }

        return false
    }
    private func cancel() {
        if hasUnsavedChanges { discardConfirmation = true } else { dismiss() }
    }
    @ViewBuilder private func goalFields(for mode: CoreHandMode) -> some View {
        ForEach(mode.hands) { hand in
            CoreGoalInputRow(hand: hand, input: Binding(get: { goals[hand] ?? CoreGoalInput() }, set: { value in
                if value.speed != goals[hand]?.speed || value.unit != goals[hand]?.unit { adjustedStartHands.remove(hand) }
                goals[hand] = value
            }),
                             showRequiredError: didAttemptSave, unitLabel: ladderEnabled && (goals[hand]?.hasLadderInput == true) && (goals[hand]?.speed.isEmpty != false) ? "速度阶梯音符单位" : "目标音符单位", ladderIsValid: ladderEnabled && (goals[hand]?.hasLadderInput == true) && (goals[hand]?.validLadder == true), onUnitChange: { unit in changeUnit(unit, for: hand) }) {
                if ladderEnabled { ladderFields(for: hand) }
            }
        }
        if ladderEnabled && mode.hands.contains(.left) && mode.hands.contains(.right) {
                    Button("复制左手速度阶梯设置到右手") {
                        guard let left = goals[.left], let start = Int(left.start), let step = Int(left.step), let reps = Int(left.reps) else {
                            error = "请先填写左手起始速度、每档 +、每档次数。"; return
                        }
                        var right = goals[.right] ?? CoreGoalInput()
                        let leftGoal = CoreHandGoal(speed: Int(left.speed).map { CoreTargetSpeed(bpm: $0, noteUnit: left.unit) },
                            ladder: CoreLadderConfiguration(startBPM: start, stepBPM: step, repsPerLevel: reps, noteUnit: left.unit))
                        do {
                            let copied = try CoreContracts.copyLeftLadderToRight(in: CoreGoal(hands: [.left: leftGoal, .right: leftGoal], ladderEnabled: true), mode: mode)
                            guard let value = copied.hands[.right], let ladder = value.ladder else { return }
                            right.start = String(ladder.startBPM); right.step = String(ladder.stepBPM); right.reps = String(ladder.repsPerLevel)
                            right.speed = value.speed.map { String($0.bpm) } ?? ""; right.unit = ladder.noteUnit
                            goals[.right] = right
                        } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("core.ladder.copyLeftRight")
        }
        Section {
            DisclosureGroup("高级设置", isExpanded: $advanced) {
                advancedFields(for: mode)
            }
        }
        if case .editDivision = route, division?.coreDefinition?.goal != nil, configurationChanged || hasLadderLock {
            Section("配置生效时间") {
                Picker("生效周期", selection: $editTiming) {
                    Text("请选择").tag(CoreGoalEditTiming?.none)
                    Text("本周期生效").tag(CoreGoalEditTiming?.some(.current))
                    Text("下周期生效").tag(CoreGoalEditTiming?.some(.next))
                }.accessibilityIdentifier("core.goal.timing")
                if editTiming == .next && targetsChanged {
                    Picker("分析标准", selection: $analyzeTiming) {
                        Text("请选择").tag(CoreAnalyzeTiming?.none)
                        Text("立即按新目标重新计算").tag(CoreAnalyzeTiming?.some(.immediately))
                        Text("跟随新目标到下周期一起切换").tag(CoreAnalyzeTiming?.some(.nextCycle))
                    }
                }
                if editTiming == .next && !targetsChanged, let analyzeTiming {
                    Text(analyzeTiming == .immediately ? "已保存分析选择：立即按新目标重新计算。" : "已保存分析选择：跟随新目标到下周期一起切换。").coreType(.caption)
                }
            }
        }
    }
    private var canConfigurePro: Bool { subscription.isPro }
    private var hasLadderLock: Bool { ladderEnabled && handMode.hands.contains { division?.coreDefinition?.ladderStates?[$0]?.startLocked == true } }
    private var configurationChanged: Bool { handMode.hands.contains { goals[$0] != initialGoals[$0] } }
    private var targetsChanged: Bool {
        handMode.hands.contains { hand in
            let input = goals[hand] ?? CoreGoalInput()
            return input.count != (initialGoals[hand]?.count ?? "") || input.speed != (initialGoals[hand]?.speed ?? "") || input.unit != (initialGoals[hand]?.unit ?? .quarter)
        }
    }
    private func changeUnit(_ unit: CoreNoteUnit, for hand: PracticeHand) {
        var input = goals[hand] ?? CoreGoalInput()
        let ratio = input.unit.quarterMultiplier / unit.quarterMultiplier
        for key in [\CoreGoalInput.start, \CoreGoalInput.step] {
            if let number = Int(input[keyPath: key]) { input[keyPath: key] = String(Int((Double(number) * ratio).rounded())) }
        }
        input.unit = unit; goals[hand] = input
        adjustedStartHands.remove(hand)
    }
    @ViewBuilder private func advancedFields(for mode: CoreHandMode) -> some View {
        Toggle("周期重置", isOn: $reset.enabled).accessibilityIdentifier("core.reset.enabled")
        if reset.enabled {
            Picker("固定周期天数", selection: $reset.days) {
                ForEach(canConfigurePro ? CoreResetConfiguration.proDays : [1], id: \.self) { Text("\($0) 天").tag($0) }
            }.accessibilityIdentifier("core.reset.days")
            if division?.coreDefinition?.goal != nil && reset.days != initialReset.days {
                Text("不立即周期重置；当天继续旧周期，下一自然日 00:00 按新周期开始并建立锚点。").coreType(.caption)
            }
        } else { Text("周期重置未启用，不按日期自动重置。").coreType(.caption) }
    }
    @ViewBuilder private func ladderFields(for hand: PracticeHand) -> some View {
        let input = goals[hand] ?? CoreGoalInput()
        Group {
            if division?.coreDefinition?.goal?.hands[hand]?.needsLadderConfirmation == true {
                Text("\(hand.title) · 速度阶梯配置待确认").coreType(.label)
                Text("配置已保存，尚未恢复阶梯执行资格。").coreType(.caption)
                if confirmedHands.contains(hand) {
                    Text("已请求确认 · 保存后生效").coreType(.caption)
                        .accessibilityIdentifier("core.ladder.\(hand.rawValue).requested")
                } else {
                    Button("确认使用当前阶梯配置") { confirmedHands.insert(hand) }
                        .frame(minHeight: 44).disabled(!input.validLadder)
                        .accessibilityLabel("\(hand.title)，确认使用当前阶梯配置")
                        .accessibilityIdentifier("core.ladder.\(hand.rawValue).confirm")
                    if !input.validLadder { Text("请先填写合法完整的阶梯参数。").coreType(.caption) }
                }
            }
            Text(input.speed.isEmpty ? "开放式速度阶梯 · 无目标速度" : "有限速度阶梯 · 目标速度使用上方练习目标 BPM")
                .coreType(.caption)
            if !input.speed.isEmpty {
                Button("改为开放式 · 清除目标速度") { goals[hand]?.speed = "" }
                    .accessibilityIdentifier("core.ladder.\(hand.rawValue).openEnded")
            }
            let state = division?.coreDefinition?.ladderStates?[hand]
            let locked = state?.startLocked == true && editTiming != .next && initialLadderEnabled && initialGoals[hand]?.participates == true
            if let state {
                Text("当前周期：\(state.cycleStart.formatted(date: .abbreviated, time: .omitted)) · 当前档 \(state.currentBPM) BPM · \(state.repsCompleted)/\(division?.coreDefinition?.goal?.hands[hand]?.ladder?.repsPerLevel ?? 0) · \(state.noteUnit.title)").coreType(.caption)
                if state.startLocked { Text("本周期起始速度已锁定；下周期起始速度可配置。实际练习 BPM 仍可自由调整。").coreType(.caption) }
                if let suggestion = state.suggestedStart(in: input.unit) {
                    let adjusted = adjustedStartHands.contains(hand)
                    let target = Int(input.speed)
                    let shown = adjusted ? max(20, (target ?? suggestion) - 10) : suggestion
                    Text("建议起始速度 · \(shown) BPM（仅建议，请确认实际起始速度）").coreType(.caption)
                    if editTiming == .next, let target, suggestion > target, !adjusted {
                        Button("处理建议起点与目标速度冲突") { startConflict = hand }
                    }
                }
            } else if let division, let stable = CoreAnalysis.stable(CoreAnalysis.planned(savedAttempts, division: division.id), hand: hand) {
                Text("建议起始速度 · \(Int((stable / input.unit.quarterMultiplier).rounded())) BPM（稳定速度换算，仅建议，请自行确认起始速度）").coreType(.caption)
            }
            if let start = Int(input.start), let target = Int(input.speed), start >= target && !locked {
                Text("\(hand.title)：有限速度阶梯需要起始速度 < 目标速度；最后一档允许短步进。").coreType(.caption).foregroundStyle(.red)
            }
            ladderNumber("起始速度（BPM）", hand: hand, key: \.start, range: 20...300).disabled(locked)
            ladderNumber("每档 +（BPM）", hand: hand, key: \.step, range: 1...20)
            ladderNumber("每档次数", hand: hand, key: \.reps, range: 1...Int.max)
            Text("音符单位 · \(input.unit.title)").coreType(.caption)
        }
    }
    private func ladderNumber(_ label: String, hand: PracticeHand, key: WritableKeyPath<CoreGoalInput, String>, range: ClosedRange<Int>) -> some View {
        let input = goals[hand] ?? CoreGoalInput()
        let value = input[keyPath: key]
        return VStack(alignment: .leading) {
            LabeledContent(label) {
                TextField("必填", text: Binding(get: { value }, set: {
                    var edited = goals[hand] ?? CoreGoalInput(); edited[keyPath: key] = $0; goals[hand] = edited
                })).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    .accessibilityIdentifier("core.ladder.\(hand.rawValue).\(key == \.start ? "start" : key == \.step ? "step" : "reps")")
            }
            if input.hasLadderInput && (didAttemptSave || !value.isEmpty) && !range.contains(Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) {
                Text(key == \.reps ? "必填正整数，不设次数上限。" : "必填整数 \(range.lowerBound)–\(range.upperBound)。")
                    .coreType(.caption).foregroundStyle(.red)
            }
        }
    }
    private func populate() {
        guard !didPopulate else { return }; didPopulate = true
        if case .editDivision = route {
            guard let definition = division?.coreDefinition else { return }

            first = String(definition.first)
            last = String(definition.last)
            handMode = definition.handMode

        }
        guard let definition = division?.coreDefinition, let goal = definition.goal else { return }
        let displayed = definition.nextCycleGoal ?? goal
        goals = displayed.hands.mapValues { value in
            let unit = value.speed?.noteUnit ?? value.ladder?.noteUnit ?? .quarter
            let ladder = value.ladder?.converted(to: unit)
            return CoreGoalInput(count: value.count.map(String.init) ?? "", speed: value.speed.map { String($0.bpm) } ?? "",
                          unit: unit,
                          participates: ladder != nil, start: ladder.map { String($0.startBPM) } ?? "",
                          step: ladder.map { String($0.stepBPM) } ?? "", reps: ladder.map { String($0.repsPerLevel) } ?? "")
        }
        initialLadderEnabled = displayed.ladderEnabled == true
        reset = displayed.reset ?? CoreResetConfiguration()
        if let pending = reset.pendingDays { reset.days = pending }
        initialReset = reset
        editTiming = division?.coreDefinition?.nextCycleGoal == nil ? nil : .next
        analyzeTiming = division?.coreDefinition?.nextCycleAnalyzeTiming
        adjustedStartHands = division?.coreDefinition?.nextCycleAdjustedStartHands ?? []
        initialGoals = goals
    }
    private func basicGoal(for mode: CoreHandMode) throws -> CoreGoal {
        var values: [PracticeHand: CoreHandGoal] = [:]
        for hand in mode.hands {
            let input = goals[hand] ?? CoreGoalInput()
            let bpm = try optionalPositive(input.speed, label: "\(hand.title)目标速度")
            var ladder: CoreLadderConfiguration?
            if ladderEnabled && input.hasLadderInput {
                guard let start = try optionalPositive(input.start, label: "\(hand.title) 起始速度"),
                      let step = try optionalPositive(input.step, label: "\(hand.title) 每档 +"),
                      let reps = try optionalPositive(input.reps, label: "\(hand.title) 每档次数") else {
                    throw CoreFlowError.invalidInput("\(hand.title)：起始速度、每档 +、每档次数均为必填。")
                }
                ladder = CoreLadderConfiguration(startBPM: start, stepBPM: step, repsPerLevel: reps, noteUnit: input.unit)
                if editTiming != .next, initialLadderEnabled, let state = division?.coreDefinition?.ladderStates?[hand],
                   state.startLocked, let bpm, bpm <= start {
                    ladder?.retainsLockedOrigin = true
                }
            } else if !ladderEnabled { ladder = division?.coreDefinition?.goal?.hands[hand]?.ladder }
            values[hand] = CoreHandGoal(count: try optionalPositive(input.count, label: "\(hand.title)目标次数"),
                speed: bpm.map { CoreTargetSpeed(bpm: $0, noteUnit: input.unit) }, ladder: ladder)
        }
        let goal = CoreGoal(hands: values, ladderEnabled: ladderEnabled || division?.coreDefinition?.goal?.ladderEnabled == true, reset: reset)
        for hand in mode.hands {
            guard let value = values[hand], CoreGoalValidation.isValid(value, ladderEnabled: ladderEnabled) else {
                throw CoreFlowError.invalidInput("\(hand.title)：请检查目标与参与的速度阶梯必填字段。")
            }
        }
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
        if editTiming == .next && ladderEnabled {
            for hand in handMode.hands {
                guard let input = goals[hand], input.hasLadderInput, let target = Int(input.speed),
                      let suggestion = division?.coreDefinition?.ladderStates?[hand]?.suggestedStart(in: input.unit) else { continue }
                if suggestion > target && !adjustedStartHands.contains(hand) { startConflict = hand; return }
            }
        }
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
                    context: modelContext, activeSessionID: activeSessionID, isPro: canConfigurePro, activation: settings.activation(isPro: subscription.isPro))
                onSaved(page)
            case .editDivision:
                guard let piece, let division,
                      let first = try optionalPositive(first, label: "起始位置"),
                      let last = try optionalPositive(last, label: "结束位置") else {
                    throw CoreFlowError.invalidInput("请填写起始和结束位置。")
                }
                let goalChanged = configurationChanged || reset != initialReset || !confirmedHands.isEmpty
                onSaved(try CoreContracts.saveDivisionAndGoal(piece: piece, division: division,
                    first: first, last: last, handMode: handMode,
                    editedGoal: goalChanged ? try basicGoal(for: handMode) : nil,
                    context: modelContext, activeSessionID: activeSessionID, isPro: canConfigurePro,
                    timing: editTiming, analyzeTiming: analyzeTiming, adjustedStartHands: adjustedStartHands, activation: settings.activation(isPro: subscription.isPro), confirmedHands: confirmedHands))
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
    var participates = true
    var hasLadderInput: Bool { !start.isEmpty || !step.isEmpty || !reps.isEmpty }
    var start = ""
    var step = ""
    var reps = ""
    var validLadder: Bool {
        guard let start = Int(start), let step = Int(step), let reps = Int(reps) else { return false }
        let target = speed.isEmpty ? nil : Int(speed).map { CoreTargetSpeed(bpm: $0, noteUnit: unit) }
        return CoreLadderConfiguration(startBPM: start, stepBPM: step, repsPerLevel: reps, noteUnit: unit).isValid(target: target)
    }
}
private struct CoreGoalInputRow<LadderContent: View>: View {
    let hand: PracticeHand
    @Binding var input: CoreGoalInput
    var showRequiredError = false
    var unitLabel = "目标音符单位"
    var ladderIsValid = false
    var onUnitChange: (CoreNoteUnit) -> Void = { _ in }
    @ViewBuilder var ladderContent: () -> LadderContent
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
            Picker(unitLabel, selection: Binding(get: { input.unit }, set: onUnitChange)) {
                ForEach(CoreNoteUnit.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if showRequiredError && input.count.isEmpty && input.speed.isEmpty && !ladderIsValid {
                Text("请填写目标次数、练习目标速度或完整开放式速度阶梯。").coreType(.caption).foregroundStyle(.red)
            }
            ladderContent()
        }
    }
}

struct CoreSessionView: View {
    @Query private var songs: [PracticeSong]
    @Query private var events: [PracticeEvent]
    @Query private var attempts: [PracticeAttempt]
    @ObservedObject var runtime: CoreSessionRuntime
    @ObservedObject var engine: MetronomeEngine
    var isGeoBeat: Bool
    let openGeoBeat: () -> Void
    let finish: () -> Void
    var onRoute: (CoreRoute) -> Void = { _ in }
    var detach: () -> Void = {}
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contextRevealed = false
    @State private var revealRequest = UUID()
    private var showDetails: Bool { !runtime.isFocusEnabled || contextRevealed }
    private var sessionCanvas: Color { CorePalette.canvas }
    @State private var continueAfterTargets = false
    @State private var playbackError: String?
    private func allTargetCountsReached(in context: CoreSessionContext) -> Bool {
        context.handMode.hands.allSatisfy { hand in
            guard let targetCount = context.goal.hands[hand]?.count else {
                return false
            }

            let savedCount = CoreAnalysis.count(
                CoreAnalysis.planned(attempts, division: context.divisionID),
                hand: hand,
                cycleStart: context.cycleStart
            )

            let currentSessionCount =
                runtime.session.completionSamples(for: hand).count

            return savedCount + currentSessionCount >= targetCount
        }
    }
    var body: some View {
        Group {
            if runtime.isFocusEnabled, let context = runtime.context {
                focusLayout(context)
            } else {
                ordinaryLayout
            }
        }
        .background(sessionCanvas)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: revealRequest) {
            guard contextRevealed else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !UIAccessibility.isVoiceOverRunning else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) { contextRevealed = false }
        }
        .onChange(of: voiceOverEnabled) { _, _ in
            if contextRevealed { revealRequest = UUID() }
        }
    }

    private var ordinaryLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: runtime.context == nil ? 20 : 12) {
                if runtime.context == nil { Text("GeoBeat").font(.largeTitle.bold()) }
                if let context = runtime.context {
                    if showDetails {
                        HStack(alignment: .center, spacing: 8) {
                            sessionActions(context).font(.headline.bold()).frame(minHeight: 44)
                            Spacer(minLength: 8)
                            provisionalBack
                                .opacity(runtime.hasStartedPlayback ? 0 : 1)
                                .allowsHitTesting(!runtime.hasStartedPlayback)
                                .accessibilityHidden(runtime.hasStartedPlayback)
                        }.frame(height: 44)
                        HStack(alignment: .bottom, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(context.pieceName).coreType(.body)
                                    .accessibilityIdentifier("core.focus.context")
                                Text(context.divisionName).coreType(.body)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                let seconds = PracticeHand.allCases.reduce(Int64(0)) { $0 + runtime.session.stats(for: $1, at: timeline.date).durationMilliseconds } / 1000
                                Text("有效时间 \(seconds / 60):\(String(format: "%02lld", seconds % 60))")
                                    .monospacedDigit().coreType(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .accessibilityIdentifier("core.session.duration")
                            }
                        }
                    }
                    handControl(context).frame(maxWidth: .infinity, alignment: .leading)
                    if showDetails, let goal = context.goal.hands[runtime.currentHand] {
                        let actualCount =
                            CoreAnalysis.count(
                                CoreAnalysis.planned(attempts, division: context.divisionID),
                                hand: runtime.currentHand,
                                cycleStart: context.cycleStart
                            )
                            + runtime.session.completionSamples(
                                for: runtime.currentHand
                            ).count

                        VStack(alignment: .leading, spacing: 4) {
                            Text("练习次数")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let targetCount = goal.count {
                                Text("\(actualCount)/\(targetCount)")
                                    .font(.system(size: 32, weight: .black, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(.easeOut(duration: 0.20), value: actualCount)
                            } else {
                                Text("\(actualCount)")
                                    .font(.system(size: 32, weight: .black, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(.easeOut(duration: 0.20), value: actualCount)
                            }
                        }
                        .accessibilityIdentifier("core.session.count")
                        if let target = goal.speed { Text("目标：\(target.noteUnit.title) = \(target.bpm) BPM").foregroundStyle(.secondary) }
                    }
                } else {
                    Text("独立 GeoBeat · 未关联计划练习").font(.headline)
                }
                if showDetails, let context = runtime.context, context.goal.ladderEnabled == true,
                   let config = context.goal.hands[runtime.currentHand]?.ladder,
                   let state = runtime.execution?.ladderStates?[runtime.currentHand] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前档 \(state.currentBPM) BPM（\(state.noteUnit.title)） · \(state.repsCompleted) / \(config.repsPerLevel)")
                            .accessibilityIdentifier("core.session.ladder")
                        if let target = context.goal.hands[runtime.currentHand]?.speed {
                            Text("阶梯目标 \(target.bpm) BPM · \(state.startLocked ? "起始速度已锁定" : "起始速度未锁定")")
                                .accessibilityIdentifier("core.session.startLock")
                            if state.currentBPM > target.bpm {
                                Text("当前档高于新目标，停止自动升速；已有进度不回退。")
                            } else if state.currentBPM == target.bpm {
                                Text("已达到目标速度")
                            }
                        } else {
                            Text("\(state.currentBPM == 300 ? "执行上限 300 BPM" : "开放式阶梯 · 无目标速度") · \(state.startLocked ? "起始速度已锁定" : "起始速度未锁定")")
                                .accessibilityIdentifier("core.session.startLock")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if showDetails, let context = runtime.context, context.goal.ladderEnabled != true,
                   let stable = CoreAnalysis.stable(CoreAnalysis.planned(attempts, division: context.divisionID), hand: runtime.currentHand) {
                    let suggested = stable / engine.preset.referenceNote.durationInQuarterNotes
                    Text("建议起始速度：\(suggested.formatted(.number.precision(.fractionLength(0...1)))) BPM（\(engine.preset.referenceNote.title)）。可自行修改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if runtime.context != nil {
                    beatControl.frame(maxWidth: .infinity, alignment: .center)
                } else if isGeoBeat {
                    beatControl
                }
                if runtime.context == nil {
                    CoreTempoControls(engine: engine, showsBeats: true, independentGeoBeat: true)
                }
                if let message = playbackError ?? engine.errorMessage { Text(message).foregroundStyle(.red) }
                if runtime.isFocusEnabled {
                    Color.clear.frame(height: 56).contentShape(Rectangle())
                        .onTapGesture { revealContext() }
                        .accessibilityLabel("显示练习信息")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { revealContext() }
                        .accessibilityIdentifier("core.focus.reveal")
                }
            }.padding().frame(maxWidth: 720).frame(maxWidth: .infinity)
                .background {
                    if runtime.isFocusEnabled {
                        sessionCanvas.contentShape(Rectangle()).onTapGesture { revealContext() }
                    }
                }
        }
        .background(sessionCanvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let context = runtime.context {
                let showsTargetActions = runtime.hasStartedPlayback && allTargetCountsReached(in: context) && !continueAfterTargets
                VStack(spacing: 8) {
                    CoreTempoControls(engine: engine, showsBeats: true)
                    if showsTargetActions {
                        HStack(spacing: 12) {
                            CoreButton(title: "继续练习") {
                                continueAfterTargets = true
                            }

                            CoreButton(title: "结束练习", action: finish)
                        }
                    } else {
                        CoreButton(title: runtime.hasStartedPlayback ? "完成一次 · \(runtime.currentHand.title)" : "开始播放后可记录") {
                            runtime.record(preset: engine.effectivePlaybackPreset)
                            engine.apply(runtime.preset)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        .disabled(!runtime.session.isRunning || !engine.isPlaying)
                        .accessibilityIdentifier("core.session.record")
                    }
                    Button("结束练习", action: finish)
                        .foregroundStyle(CorePalette.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .opacity(runtime.hasStartedPlayback && !showsTargetActions ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: runtime.hasStartedPlayback)
                        .allowsHitTesting(runtime.hasStartedPlayback && !showsTargetActions)
                        .accessibilityHidden(!runtime.hasStartedPlayback || showsTargetActions)
                        .accessibilityIdentifier("core.session.finish")
                }
                .padding(.horizontal).padding(.vertical, 8)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
                .background(sessionCanvas)
            }
        }
        .padding(.bottom, 56)

    }
    private func sessionActions(_ context: CoreSessionContext) -> some View {
                    Menu("练习操作") {
                        Button("独立使用 GeoBeat", action: detach)
                            .accessibilityIdentifier("core.session.detach")
                        Menu("切换曲目") {
                            ForEach(songs.filter { $0.deletedAt == nil && !$0.isArchived && $0.id != context.pieceID }) { piece in
                                Menu(piece.name) {
                                    ForEach(events.filter { $0.songID == piece.id && $0.coreDefinition?.hasValidGoal == true }) { division in
                                        Button(division.name) { onRoute(.startPractice(piece: piece.id, division: division.id)) }
                                    }
                                }
                            }
                        }
                        Menu("切换练习划分") {
                            ForEach(events.filter { $0.songID == context.pieceID && $0.id != context.divisionID && $0.coreDefinition?.hasValidGoal == true }) { division in
                                Button(division.name) { onRoute(.startPractice(piece: context.pieceID, division: division.id)) }
                            }
                        }
                        Button("归档当前曲目") { onRoute(.archivePiece(context.pieceID)) }
                        Button("删除当前曲目", role: .destructive) { onRoute(.deletePiece(context.pieceID)) }
                        Button("编辑划分范围 / 适用手型") { onRoute(.editDivision(piece: context.pieceID, division: context.divisionID)) }
                    }.accessibilityIdentifier("core.session.actions")
    }

    private var beatControl: some View {
                    PrototypePulseStage(
                        preset: engine.preset,
                        pulse: engine.lastPulse,
                        isPlaying: engine.isPlaying
                    )
                    .frame(height: runtime.context == nil || runtime.isFocusEnabled ? 240 : 180)
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlayback() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { togglePlayback() }
                    .accessibilityIdentifier("core.session.beat")
                    .accessibilityLabel(engine.isPlaying ? "节拍器正在运行" : "节拍器已暂停")
                    .accessibilityHint("轻点切换运行状态")
    }

    @ViewBuilder private func handControl(_ context: CoreSessionContext) -> some View {
                    if context.handMode.allowsHandSwitching {
                        Picker("当前手型", selection: Binding(get: { runtime.currentHand }, set: {
                            runtime.switchHand($0)
                            engine.apply(runtime.preset)
                        })) {
                            ForEach(context.handMode.hands) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("core.session.handSwitcher")
                        .accessibilityRepresentation {
                            HStack {
                                ForEach(context.handMode.hands) { hand in
                                    Button(hand.title) {
                                        runtime.switchHand(hand)
                                        engine.apply(runtime.preset)
                                    }
                                        .accessibilityAddTraits(runtime.currentHand == hand ? .isSelected : [])
                                        .accessibilityIdentifier("core.session.hand.\(hand.rawValue)")
                                }
                            }
                        }
                    } else {
                        Text("当前手型 · \(runtime.currentHand.title)").coreType(.body)
                            .accessibilityIdentifier("core.session.currentHand")
                    }

    }

    private func focusLayout(_ context: CoreSessionContext) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 6) {
                        HStack(alignment: .center, spacing: 8) {
                            provisionalBack
                                .opacity(runtime.hasStartedPlayback ? 0 : 1)
                                .allowsHitTesting(!runtime.hasStartedPlayback)
                                .accessibilityHidden(runtime.hasStartedPlayback)
                            Text(context.pieceName).font(.headline)
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                                .fixedSize(horizontal: false, vertical: true)
                            provisionalBack.hidden().accessibilityHidden(true)
                        }
                        let actual = CoreAnalysis.count(CoreAnalysis.planned(attempts, division: context.divisionID), hand: runtime.currentHand, cycleStart: context.cycleStart)
                            + runtime.session.completionSamples(for: runtime.currentHand).count
                        let target = context.goal.hands[runtime.currentHand]?.count
                        Text(target.map { "\(actual) / \($0)" } ?? "\(actual)")
                            .monospacedDigit().font(.title2)
                            .accessibilityLabel("\(runtime.currentHand.title)，已练习 \(actual) 次" + (target.map { "，目标 \($0) 次" } ?? ""))
                            .accessibilityIdentifier("core.focus.count")
                    }.frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                    beatControl
                    Spacer(minLength: 0)
                    if contextRevealed {
                        VStack(spacing: 4) {
                            Text(context.divisionName)
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text("有效时间 \(runtime.practiceDurationMilliseconds(at: timeline.date) / 1000) 秒")
                            }
                            sessionActions(context)
                            if let target = context.goal.hands[runtime.currentHand]?.speed {
                                Text("目标：\(target.noteUnit.title) = \(target.bpm) BPM")
                            }
                            if let state = runtime.execution?.ladderStates?[runtime.currentHand],
                               let ladder = context.goal.hands[runtime.currentHand]?.ladder {
                                Text("当前档 \(state.currentBPM) BPM · \(state.repsCompleted) / \(ladder.repsPerLevel)")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("core.focus.context")
                    }
                    if let message = playbackError ?? engine.errorMessage { Text(message).foregroundStyle(.red) }
                }
                .padding(.horizontal).padding(.vertical, 12)
                .frame(maxWidth: 720)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
                .background {
                    sessionCanvas.contentShape(Rectangle()).onTapGesture { revealContext() }
                        .accessibilityLabel("显示练习信息").accessibilityAddTraits(.isButton)
                        .accessibilityAction { revealContext() }.accessibilityIdentifier("core.focus.reveal")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let showsTargetActions = runtime.hasStartedPlayback && allTargetCountsReached(in: context) && !continueAfterTargets
            VStack(spacing: 12) {
                handControl(context).frame(minHeight: 44)
                CoreTempoControls(engine: engine)
                if showsTargetActions {
                    HStack {
                        CoreButton(title: "继续练习") { continueAfterTargets = true }
                        CoreButton(title: "结束练习", action: finish)
                    }
                } else {
                    CoreButton(title: runtime.hasStartedPlayback ? "完成一次" : "开始播放后可记录") {
                        runtime.record(preset: engine.effectivePlaybackPreset)
                        engine.apply(runtime.preset)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }.disabled(!runtime.session.isRunning || !engine.isPlaying)
                        .accessibilityIdentifier("core.session.record")
                }
                Button("结束练习", action: finish)
                    .frame(minHeight: 44)
                    .opacity(runtime.hasStartedPlayback && !showsTargetActions ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: runtime.hasStartedPlayback)
                    .allowsHitTesting(runtime.hasStartedPlayback && !showsTargetActions)
                    .accessibilityHidden(!runtime.hasStartedPlayback || showsTargetActions)
                    .accessibilityIdentifier("core.session.finish")
            }.padding(.horizontal).padding(.bottom, 12)
                .frame(maxWidth: 720).frame(maxWidth: .infinity).background(sessionCanvas)
        }
    }

    private var provisionalBack: some View {
        Button("返回", action: finish)
            .buttonStyle(.plain).foregroundStyle(CorePalette.accent)
            .frame(minWidth: 44, minHeight: 44)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("core.session.back")
    }

    private func revealContext() {
        guard runtime.isFocusEnabled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) { contextRevealed = true }
        revealRequest = UUID()
    }
    private func togglePlayback() {
        if engine.isPlaying {
            engine.pause()
            runtime.synchronizePlayback(isPlaying: false)
        } else {
            do {
                try runtime.startPlayback {
                    engine.start()
                    return engine.isPlaying
                }
                playbackError = nil
            } catch { playbackError = error.localizedDescription }
        }
    }
}

private struct CoreTempoControls: View {
    @ObservedObject var engine: MetronomeEngine
    var showsBeats = false
    var independentGeoBeat = false
    @State private var dragStartBPM: Int?
    @State private var dragStartBeats: Int?
    @State private var enteredBPM = ""
    @State private var inputError: String?
    @FocusState private var bpmFocused: Bool
    var body: some View {
        Group {
        if independentGeoBeat {
            VStack(alignment: .leading, spacing: 16) {
                Stepper("实际速度：\(engine.preset.bpm) BPM", value: Binding(get: { engine.preset.bpm }, set: { engine.setBPM($0) }), in: 20...300)
                    .accessibilityIdentifier("core.tempo.bpm")
                HStack {
                    TextField("输入 BPM（20–300）", text: $enteredBPM).keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($bpmFocused)
                        .accessibilityIdentifier("core.tempo.input")
                    Button("应用") {
                        guard let value = TempoScrubModel.validatedBPMInput(enteredBPM) else {
                            inputError = "实际速度须为 20–300 的整数。"; return
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
        } else {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if dragStartBPM != nil && engine.preset.bpm > 20 {
                    Text("\(engine.preset.bpm - 1)").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(engine.preset.bpm) BPM").font(.title.monospacedDigit())
                if dragStartBPM != nil && engine.preset.bpm < 300 {
                    Text("\(engine.preset.bpm + 1)").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                    let start = dragStartBPM ?? engine.preset.bpm
                    dragStartBPM = start
                    engine.setBPM(min(300, max(20, start - Int(value.translation.height / 4))))
                }.onEnded { _ in dragStartBPM = nil })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("实际速度")
                .accessibilityValue("\(engine.preset.bpm) BPM")
                .accessibilityHint("上下滑动调整速度")
                .accessibilityAdjustableAction { direction in
                    engine.setBPM(min(300, max(20, engine.preset.bpm + (direction == .increment ? 1 : -1))))
                }
                .accessibilityIdentifier("core.tempo.bpm")
            HStack(spacing: 12) {
                Picker("实际音符单位", selection: Binding(get: { engine.preset.referenceNote }, set: {
                    var value = engine.preset; value.referenceNote = $0; engine.apply(value)
                })) {
                    ForEach(TempoReferenceNote.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("core.tempo.noteUnit")
                if showsBeats {
                    HStack(spacing: 12) {
                        if dragStartBeats != nil && engine.preset.beats > 1 {
                            Text("\(engine.preset.beats - 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("每小节 \(engine.preset.beats) 拍")
                        if dragStartBeats != nil && engine.preset.beats < 9 {
                            Text("\(engine.preset.beats + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                            let start = dragStartBeats ?? engine.preset.beats
                            dragStartBeats = start
                            engine.setBeats(min(9, max(1, start - Int(value.translation.height / 16))))
                        }.onEnded { _ in dragStartBeats = nil })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("每小节拍数")
                        .accessibilityValue("\(engine.preset.beats) 拍")
                        .accessibilityHint("上下滑动调整每小节拍数")
                        .accessibilityAdjustableAction { direction in
                            engine.setBeats(min(9, max(1, engine.preset.beats + (direction == .increment ? 1 : -1))))
                        }
                        .accessibilityIdentifier("core.tempo.beats")
                }
            }
        }
        }
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
            if case .piece(let id) = scope, let piece = songs.first(where: { $0.id == id }) {
                let result = CoreTargetCompletion.piece(piece, events: events, attempts: attempts)
                Section("当前目标状态") {
                    Text("整曲目标完成度：\(CoreTargetCompletion.percentage(result.combined))")
                        .accessibilityIdentifier("analyze.target.piece")
                    Text("\(result.divisionCount) 个练习划分 / \(result.achievedCount) 个已达到当前目标 / \(result.inProgressCount) 个进行中 / \(result.unavailableCount) 个暂无法计算")
                        .font(.caption)
                }
            }
            ForEach(filteredEvents) { event in
                if let definition = event.coreDefinition {
                    Section("《\(songs.first { $0.id == event.songID }?.name ?? "曲目")》 · \(event.name)") {
                        CoreDivisionAnalysis(definition: definition, attempts: CoreAnalysis.planned(attempts, division: event.id), isCurrent: songs.contains { $0.id == event.songID && !$0.isArchived && $0.deletedAt == nil })
                        if let latest = CoreAnalysis.planned(attempts, division: event.id).first {
                            NavigationLink("查看最近一次练习结果") { CoreSavedSessionView(attempt: latest) }
                        }
                    }
                }
            }
            if filteredEvents.isEmpty { Text("暂无练习数据") }
        }.navigationTitle("分析").navigationBarTitleDisplayMode(.inline)
    }
    private var filteredEvents: [PracticeEvent] {
        events.filter { event in
            guard songs.contains(where: { $0.id == event.songID && $0.deletedAt == nil }) else { return false }
            switch scope {
            case .overall: return event.coreDefinition != nil
            case .piece(let piece): return event.songID == piece
            case .division(let piece, let division): return event.songID == piece && event.id == division
            }
        }.sorted { $0.createdAt < $1.createdAt }
    }
}

struct CoreDivisionAnalysis: View {
    @State private var previewPro = false
    @EnvironmentObject private var subscription: SubscriptionStore
    let definition: CoreDivisionDefinition
    let attempts: [PracticeAttempt]
    var comparison: [PracticeHand: Double] = [:]
    var isCurrent = true
    var body: some View {
        let completion = CoreTargetCompletion.division(definition: definition, attempts: attempts, isCurrent: isCurrent)
        Text("当前目标完成度仅表示已达到当前配置的目标，不代表演奏质量。")
            .font(.caption).foregroundStyle(.secondary)
        if !isCurrent { Text("此曲目不参与当前目标完成度计算。") }
        if attempts.isEmpty { Text("暂无已保存的计划练习") }
        ForEach(definition.handMode.hands) { hand in
            VStack(alignment: .leading, spacing: 8) {
                Text(hand.title).font(.headline)
                let stable = CoreAnalysis.stable(attempts, hand: hand)
                Text("稳定速度：\(stable.map(format) ?? "暂无数据")（四分音符等值）")
                if let previous = comparison[hand], let stable {
                    Text("保存前 \(format(previous)) → 保存后 \(format(stable))").font(.caption)
                }
                if let goal = completion.goal, let target = goal.hands[hand], let result = completion.hands[hand] {
                    let count = result.actualCount ?? 0
                    Text("当前目标完成度：\(CoreTargetCompletion.percentage(result.combined))")
                        .accessibilityIdentifier("analyze.target.hand.\(hand.rawValue)")
                    if let targetCount = target.count {
                        Text("当前目标周期次数：\(count) / \(targetCount)")
                        Text("次数完成度：\(CoreTargetCompletion.percentage(result.count))")
                    }
                    if let speed = target.speed {
                        Text("当前目标：\(speed.noteUnit.title) = \(speed.bpm) BPM")
                        Text("速度完成度：\(CoreTargetCompletion.percentage(result.speed))")
                    }
                    if target.count == nil && target.speed == nil, let ladder = target.ladder {
                        Text("开放式速度阶梯没有有限终点，不显示完成度百分比。")
                        if let state = definition.ladderStates?[hand] {
                            Text("当前档：\(state.currentBPM) BPM · \(state.repsCompleted) / \(ladder.repsPerLevel) 次")
                        }
                    }
                    if subscription.isPro || previewPro {
                        Text("目标差距").font(.subheadline.bold())
                        if let targetCount = target.count { Text("次数差距：\(max(0, targetCount - count)) 次") }
                        if let speed = target.speed {
                            if let stable { Text("速度差距：\(format(max(0, Double(speed.bpm) - stable / speed.noteUnit.quarterMultiplier))) BPM（\(speed.noteUnit.title)）") }
                            else { Text("速度差距：暂无数据") }
                        }
                    }
                }
            }.padding(.vertical, 8)
        }
        Text("划分当前目标完成度：\(CoreTargetCompletion.percentage(completion.combined))")
            .accessibilityIdentifier("analyze.target.division")
        if let mastery = CoreAnalysis.divisionMastery(attempts, definition: definition) {
            Text(mastery <= 0.8 ? "这个划分需要关注。" : "当前划分未触发基础弱项提醒。")
        } else { Text("弱项诊断：数据不足").foregroundStyle(.secondary) }
        if !subscription.isPro {
            Text("详细目标差距为 Pro 分析。Free 可查看当前稳定速度、次数进度及当前目标完成度。").font(.caption).foregroundStyle(.secondary)
#if DEBUG
            Toggle("测试预览 Pro 目标差距", isOn: $previewPro)
            if previewPro { Text("仅此 Debug 界面的验收预览；不代表购买或解锁 Pro。").font(.caption).foregroundStyle(.secondary) }
#endif
        }
        Text("已保存练习：\(attempts.count)").font(.caption)
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
                    Text("《\(destination.context.pieceName)》 · \(destination.context.divisionName)")
                    Text("练习所属周期：\(destination.context.cycleLabel)").font(.callout)
                    Text("跨午夜也归属于开始时的每日周期。当前周期进度在下方另行显示。").font(.caption).foregroundStyle(.secondary)
                    Text(saved == nil ? "请核对本次数据，再确认保存。" : "练习已保存，已更新对应划分的分析。")
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
                    if samples.isEmpty { Text("没有完成记录；退出不会保存空练习。") }
                }
                if let saved, let definition = events.first(where: { $0.id == saved.eventID })?.coreDefinition {
                    Section("本次所属周期累计") {
                        ForEach(destination.context.handMode.hands) { hand in
                            let count = CoreAnalysis.count(CoreAnalysis.planned(attempts, division: saved.eventID), hand: hand, cycleStart: destination.context.cycleStart)
                            Text("\(hand.title)：\(count) 次（\(destination.context.cycleLabel)）")
                        }
                    }
                    Section("保存结果 / 分析") {
                        CoreDivisionAnalysis(definition: definition, attempts: CoreAnalysis.planned(attempts, division: saved.eventID), comparison: before)
                    }
                    Button("返回曲目") { returnToDivision() }.accessibilityIdentifier("core.result.return")
                } else {
                    if !samples.isEmpty {
                        Button("确认保存", action: save).accessibilityIdentifier("core.result.save")
                    } else {
                        Button("结束并返回（不保存空练习）") {
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
        onReturn(.piece(destination.context.pieceID)); dismiss()
    }
}

/// Read-only access to the last saved raw result, including after app restart.
private struct CoreSavedSessionView: View {
    let attempt: PracticeAttempt
    var body: some View {
        List {
            Section {
                Text("计划练习 · 已确认保存")
                if let context = attempt.coreContext {
                    Text("《\(context.pieceName)》 · \(context.divisionName)")
                    Text("练习所属周期：\(context.cycleLabel)")
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
        }.navigationTitle("已保存练习").navigationBarTitleDisplayMode(.inline)
    }
}

struct CoreCycleStartView: View {
    let definition: CoreDivisionDefinition
    let hands: [PracticeHand]
    let confirm: ([PracticeHand: Int]) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inputs: [PracticeHand: String] = [:]
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text("确认起始速度").font(.headline)
                ForEach(hands) { hand in
                    Section(hand.title) {
                        if let config = definition.goal?.hands[hand]?.ladder,
                           let suggestion = definition.ladderStates?[hand]?.suggestedStart(in: config.noteUnit) {
                            Text("建议 \(suggestion) BPM；请自行确认真实起始速度。")
                        }
                        LabeledContent("起始速度（BPM）") {
                            TextField("必填", text: Binding(get: { inputs[hand] ?? "" }, set: { inputs[hand] = $0 }))
                                .keyboardType(.numberPad).accessibilityIdentifier("core.cycle.\(hand.rawValue).start")
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("确认并开始") {
                    do {
                        var values: [PracticeHand: Int] = [:]
                        for hand in hands {
                            guard let bpm = TempoScrubModel.validatedBPMInput(inputs[hand] ?? "") else {
                                throw CoreFlowError.invalidInput("请为每个手型填写 20–300 的整数起始 BPM。")
                            }
                            values[hand] = bpm
                        }
                        try confirm(values)
                    } catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("core.cycle.confirm")
            }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct CoreExitDecisionView: View {
    let saveOnly: Bool
    let error: String?
    let choose: (CoreExitChoice) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(saveOnly ? "保存并结束后编辑" : "结束练习？").font(.title2.bold())
            if saveOnly { Text("编辑划分范围或适用手型前，必须先保存并结束当前练习。") }
            Button("保存并结束") { choose(.save) }.accessibilityIdentifier("core.exit.save")
            if !saveOnly {
                Button("不保存并结束", role: .destructive) { choose(.discard) }.accessibilityIdentifier("core.exit.discard")
            }
            Button("取消", role: .cancel) { choose(.cancel) }.accessibilityIdentifier("core.exit.cancel")
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("core.exit.error") }
        }.padding(24).presentationDetents([.medium])
    }
}

struct CoreRecentlyDeletedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var subscription: SubscriptionStore
    @Query private var songs: [PracticeSong]

    @State private var error: String?

    private var deletedPieces: [PracticeSong] {
        songs
            .filter { $0.deletedAt != nil }
            .sorted {
                ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast)
            }
    }

    var body: some View {
        Form {
            if subscription.isPro {
                if deletedPieces.isEmpty {
                    Section {
                        Text("没有最近删除的曲目。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(deletedPieces) { piece in
                        Section {
                            Text(piece.name)

                            Text("Recently Deleted")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("7 天保留期内可以恢复；保留期结束后将永久删除。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let expiration = piece.deletionExpiresAt {
                                Text("永久删除时间：\(expiration.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                            }

                            Button("恢复") {
                                restore(piece)
                            }
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("最近删除的曲目")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !subscription.isPro { dismiss() } }
        .onChange(of: subscription.isPro) { _, isPro in if !isPro { dismiss() } }
    }

    private func restore(_ piece: PracticeSong) {
        do {
            try CoreContracts.restoreRecentlyDeletedPiece(
                piece: piece,
                context: modelContext,
                isPro: subscription.isPro
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
// Shared lightweight actions; no Piece Settings destination.
struct CorePieceActions: View {
    let piece: PracticeSong
    let onRoute: (CoreRoute) -> Void
    var body: some View {
        Button(piece.isArchived ? "取消归档" : "归档") {
            onRoute(piece.isArchived ? .unarchivePiece(piece.id) : .archivePiece(piece.id))
        }
        Button("删除", role: .destructive) { onRoute(.deletePiece(piece.id)) }
    }
}

struct CoreArchiveView: View {
    @Query(sort: [SortDescriptor(\PracticeSong.sortIndex), SortDescriptor(\PracticeSong.createdAt)]) private var songs: [PracticeSong]
    @Query private var events: [PracticeEvent]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var subscription: SubscriptionStore
    let activeSessionID: UUID?
    let onRoute: (CoreRoute) -> Void
    @State private var confirmation: CoreRoute?
    @State private var error: String?
    @State private var undoID: UUID?
    @State private var undoPresentationID = UUID()
    private var archivedPieces: [PracticeSong] { songs.filter { $0.isArchived && $0.deletedAt == nil } }
    var body: some View {
        Form {
            if archivedPieces.isEmpty {
                ContentUnavailableView("暂无归档曲目", systemImage: "archivebox")
            } else {
                Section {
                    ForEach(archivedPieces) { piece in
                        Menu { CorePieceActions(piece: piece, onRoute: act) } label: {
                            Text(piece.name).frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("core.archive.actions.\(piece.id)")
                    }
                }
                Section {
                    Button("删除全部已归档曲目", role: .destructive) { act(.deleteAllArchivedPieces) }
                }
            }
        }
        .navigationTitle("已归档曲目").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let confirmation {
                CoreExitHandoffView(route: confirmation, songs: songs, events: events,
                    activeSessionID: activeSessionID, onCompleted: {
                        if case .deletePiece(let id) = confirmation, subscription.isPro {
                            undoPresentationID = UUID(); undoID = id
                        }
                        self.confirmation = nil
                    }, onCancel: { self.confirmation = nil })
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let undoID {
                CoreQuickUndoView(restore: {
                    guard let piece = songs.first(where: { $0.id == undoID }) else { return false }
                    do {
                        try CoreContracts.restoreRecentlyDeletedPiece(piece: piece, context: modelContext, isPro: subscription.isPro)
                        return true
                    } catch { self.error = error.localizedDescription; return false }
                }, finish: { id in
                    if id == undoPresentationID { self.undoID = nil }
                }, presentationID: undoPresentationID).id(undoPresentationID)
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func act(_ route: CoreRoute) {
        if activeSessionID != nil { onRoute(route); return }
        if case .unarchivePiece(let id) = route, let piece = songs.first(where: { $0.id == id }) {
            do { try CoreContracts.unarchivePiece(piece: piece, context: modelContext) }
            catch { self.error = error.localizedDescription }
        } else { confirmation = route }
    }
}

// A05 completes the Session before presenting this confirmation.
struct CoreExitHandoffView: View {
    let route: CoreRoute
    let songs: [PracticeSong]
    let events: [PracticeEvent]
    var activeSessionID: UUID? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var subscription: SubscriptionStore

    @State private var error: String?

    var onCompleted: () -> Void = {}
    var onCancel: () -> Void = {}
    private func confirmDelete(_ piece: PracticeSong) {
        do {
            switch subscription.effectiveAccessState {
            case .checking:
                error = "正在确认订阅状态，请稍后再试。"

            case .entitled:
                try CoreContracts.movePieceToRecentlyDeleted(
                    piece: piece,
                    context: modelContext,
                    activeSessionID: activeSessionID,
                    isPro: subscription.isPro
                )
                onCompleted()

            case .notEntitled:
                try CoreContracts.permanentlyDeletePiece(
                    piece: piece,
                    context: modelContext,
                    activeSessionID: activeSessionID
                )
                onCompleted()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
    private func confirmArchive(_ piece: PracticeSong) {
        do {
            try CoreContracts.archivePiece(piece: piece, context: modelContext, activeSessionID: activeSessionID)
            onCompleted(); dismiss()
        } catch { self.error = error.localizedDescription}
    }
    private func confirmBulkDelete() {
        guard subscription.effectiveAccessState != .checking else { return }
        do {
            try CoreContracts.deleteAllArchivedPieces(context: modelContext,
                activeSessionID: activeSessionID, isPro: subscription.isPro)
            onCompleted(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private var pieceID: UUID? {
        switch route {
        case .archivePiece(let id), .deletePiece(let id), .editDivision(let id, _): id
        default: nil
        }
    }
    private var title: String {
        switch route {
        case .archivePiece: "归档曲目？"
        case .deleteAllArchivedPieces: subscription.isPro ? "删除全部已归档曲目？" : "永久删除全部已归档曲目？"
        case .deletePiece: "删除曲目？"
        case .editDivision: "编辑练习划分"
        default: ""
        }
    }
    private var identifier: String {
        switch route {
        case .archivePiece: "core.continuation.archive"
        case .deleteAllArchivedPieces: "core.archive.deleteAllConfirmation"
        case .deletePiece: "core.continuation.deleteConfirmation"
        case .editDivision: "core.continuation.divisionEdit"
        default: "core.continuation"
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.headline).accessibilityIdentifier(identifier)
                    Text(songs.first { $0.id == pieceID }?.name ?? "")
                }
                if case .archivePiece = route,
                   let piece = songs.first(where: { $0.id == pieceID && $0.deletedAt == nil }) {
                    Section { Text("这首曲目将离开当前练习，已有练习历史继续保留。归档不会删除曲目，也不会进入最近删除。") }
                    Section {
                        Button("归档曲目") { confirmArchive(piece) }
                        Button("取消", role: .cancel) { onCancel() }                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
                if case .deleteAllArchivedPieces = route {
                    Section {
                        switch subscription.effectiveAccessState {
                        case .checking: Text("正在确认订阅状态…")
                        case .entitled: Text("所有已归档曲目将进入最近删除的曲目，保留 7 天；期间可以恢复为已归档状态，到期后永久删除。")
                        case .notEntitled: Text("所有已归档曲目将被永久删除。此操作无法撤销。")
                        }
                    }
                    Section {
                        Button(subscription.isPro ? "删除全部" : "全部永久删除", role: .destructive) { confirmBulkDelete() }
                            .disabled(subscription.effectiveAccessState == .checking)
                        Button("取消", role: .cancel) { onCancel() }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
                if case .deletePiece = route,
                   let piece = songs.first(where: { $0.id == pieceID }) {

                    Section {
                        switch subscription.effectiveAccessState {
                        case .checking:
                            Text("正在确认订阅状态…")
                                .foregroundStyle(.secondary)

                        case .entitled:
                            Text("这首曲目将进入最近删除的曲目，并保留 7 天。保留期内可以恢复；到期后将永久删除。")
                                .foregroundStyle(.secondary)

                        case .notEntitled:
                            Text("这首曲目将被永久删除。此操作无法撤销。")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Button(
                            subscription.isPro ? "删除曲目" : "永久删除",
                            role: .destructive
                        ) {
                            confirmDelete(piece)
                        }
                        .disabled(subscription.effectiveAccessState == .checking)

                        Button("取消", role: .cancel) {
                            dismiss()
                        }
                    }

                    if let error {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                        }
                    }
                }
                if case .editDivision(_, let id) = route,
                   let division = events.first(where: { $0.id == id }), let definition = division.coreDefinition {
                    Section {
                        Text(division.name)
                        Text("适用手型 · \(definition.handMode.label)")
                    }
                }
            }.navigationTitle(title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { onCancel() } } }
        }
    }
}


struct CoreGlobalSettingsView: View {
    @EnvironmentObject private var settings: CorePracticeSettings
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    let activeSession: Bool
    var body: some View {
        NavigationStack {
            Form {
                #if DEBUG
                Section("开发测试") {
                    Toggle("启用测试 Pro", isOn: Binding(
                        get: { subscription.debugProEnabled },
                        set: { subscription.setDebugProEnabled($0) }
                    ))
                    .accessibilityIdentifier("core.settings.debugPro")
                }
                #endif
                Section("Pro 功能") {
                    if subscription.isPro {
                        Toggle("专注模式", isOn: Binding(get: { settings.focusEnabled }, set: {
                            settings.setFocusEnabled($0, isPro: subscription.isPro)
                        })).accessibilityIdentifier("core.settings.focus")
                        Toggle("速度阶梯", isOn: Binding(get: { settings.ladderEnabled }, set: {
                            settings.setLadderEnabled($0, isPro: subscription.isPro)
                        })).accessibilityIdentifier("core.settings.globalLadder")
                        if activeSession { Text("下一次练习生效").font(.caption) }
                    }
                    NavigationLink("Rovia Pro 权益") { PrototypeProView() }
                }
            }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } } }
        }
    }
}
