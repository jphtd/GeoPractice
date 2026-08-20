import SwiftData
import SwiftUI

struct PracticeEventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var existingEvents: [PracticeEvent]
    @Query(sort: [
        SortDescriptor(\PracticeFolder.sortIndex),
        SortDescriptor(\PracticeFolder.createdAt)
    ]) private var folders: [PracticeFolder]

    private let event: PracticeEvent?
    private let currentPreset: MetronomePreset
    private let requestedInitialFolderID: UUID?

    @AppStorage(PracticePreferenceKeys.tempoScrubDirection)
    private var tempoScrubDirectionRaw = TempoScrubDirection.horizontal.rawValue
    @State private var name: String
    @State private var preset: MetronomePreset
    @State private var inheritanceSource: String
    @State private var persistenceError: String?
    @State private var isTempoScrubbing = false
    @State private var folderID: UUID?
    @State private var didResolveExistingFolder = false
    @State private var goalEnabled: Bool
    @State private var goalTargets: PracticeGoalCounts

    init(
        event: PracticeEvent? = nil,
        currentPreset: MetronomePreset,
        initialFolderID: UUID? = nil
    ) {
        self.event = event
        self.currentPreset = currentPreset
        self.requestedInitialFolderID = initialFolderID
        _name = State(initialValue: event?.name ?? "")
        _preset = State(initialValue: event?.preset ?? currentPreset)
        _inheritanceSource = State(initialValue: event == nil ? "current" : "keep")
        _persistenceError = State(initialValue: nil)
        _folderID = State(initialValue: initialFolderID)
        _goalEnabled = State(initialValue: event?.hasGoalPlan ?? false)
        _goalTargets = State(
            initialValue: event?.goalPlan?.targets
                ?? PracticeGoalCounts(left: 10, right: 10, both: 10)
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tempoScrubDirection: TempoScrubDirection {
        TempoScrubDirection(rawValue: tempoScrubDirectionRaw) ?? .horizontal
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()
                Form {
                    Section("事件") {
                        TextField("例如：肖邦练习曲右手", text: $name)
                            .textInputAutocapitalization(.never)
                        Text("练习次数和时长将在节拍器练习中记录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Picker("目录", selection: $folderID) {
                            Text("未分类")
                                .tag(Optional<UUID>.none)
                            ForEach(folders, id: \.id) { folder in
                                Text(folder.name)
                                    .tag(Optional(folder.id))
                            }
                        }
                    }

                    Section("练习目标") {
                        Toggle("开启目标", isOn: $goalEnabled)
                            .tint(.white)

                        if goalEnabled {
                            PracticeGoalTargetsEditor(
                                targets: $goalTargets,
                                title: "计划总目标"
                            )
                            .listRowInsets(EdgeInsets(
                                top: 8,
                                leading: 0,
                                bottom: 8,
                                trailing: 0
                            ))

                            Text("计划从开启时开始累计；以后修改目标不会重算已完成次数。每天首次从此项目开始练习时，可以确认或修改当天目标。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("继承节拍器预设") {
                        Picker("预设来源", selection: $inheritanceSource) {
                            if event != nil {
                                Text("保持事件当前预设")
                                    .tag("keep")
                            }
                            Text("当前节拍器 · \(currentPreset.bpm) BPM")
                                .tag("current")
                            ForEach(MetronomePreset.builtIns, id: \.bpm) { item in
                                Text("\(item.name) · \(item.bpm) BPM")
                                    .tag("builtin-\(item.bpm)")
                            }
                            ForEach(existingEvents.filter { $0.id != event?.id }, id: \.id) { item in
                                Text("事件：\(item.name)")
                                    .tag("event-\(item.id.uuidString)")
                            }
                        }
                        .onChange(of: inheritanceSource) { _, source in
                            inheritPreset(from: source)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text(preset.tempoDisplay)
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            PresetSummary(preset: preset)
                        }
                        .padding(.vertical, 4)
                    }

                    Section("速度") {
                        TempoScrubber(
                            bpm: preset.bpm,
                            direction: tempoScrubDirection,
                            onScrubbingChanged: { isTempoScrubbing = $0 },
                            onCommit: { bpm in
                                preset.bpm = bpm
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                    }

                    Section("节拍结构") {
                        Picker("每小节拍数", selection: Binding(
                            get: { preset.beats },
                            set: { newValue in
                                preset.beats = newValue
                                preset.grouping = MetronomePreset.groupings(for: newValue)[0]
                            }
                        )) {
                            ForEach(3...9, id: \.self) { value in
                                Text("\(value) 拍").tag(value)
                            }
                        }

                        let groupings = MetronomePreset.groupings(for: preset.beats)
                        if groupings.count > 1 {
                            Picker("重音分组", selection: $preset.grouping) {
                                ForEach(groupings, id: \.self) { value in
                                    Text(value).tag(value)
                                }
                            }
                        }

                        Picker("细分", selection: $preset.subdivision) {
                            Text("二分音符").tag(0)
                            Text("四分音符").tag(1)
                            Text("八分音符").tag(2)
                            Text("十六分音符").tag(4)
                        }

                        Picker("闪烁顺序", selection: $preset.direction) {
                            ForEach(RotationDirection.allCases) { direction in
                                Label(direction.title, systemImage: direction.symbol)
                                    .tag(direction)
                            }
                        }
                    }
                }
                .scrollDisabled(isTempoScrubbing)
                .scrollContentBackground(.hidden)
                .onAppear {
                    resolveInitialFolderIfNeeded()
                }
                .onChange(of: folders.map(\.id)) { _, availableFolderIDs in
                    resolveInitialFolderIfNeeded()
                    if let folderID, !availableFolderIDs.contains(folderID) {
                        self.folderID = nil
                    }
                }
            }
            .navigationTitle(event == nil ? "新建打卡" : "编辑打卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .fontWeight(.bold)
                    .disabled(trimmedName.isEmpty || (goalEnabled && goalTargets.total == 0))
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("无法保存", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("好", role: .cancel) {
                persistenceError = nil
            }
        } message: {
            Text(persistenceError ?? "请稍后重试。")
        }
    }

    private func resolveInitialFolderIfNeeded() {
        guard !didResolveExistingFolder else { return }
        defer { didResolveExistingFolder = true }

        if let event {
            folderID = PracticeFolder.folder(
                containing: event.id,
                in: folders
            )?.id
        } else if let requestedInitialFolderID,
                  folders.contains(where: { $0.id == requestedInitialFolderID }) {
            folderID = requestedInitialFolderID
        }
    }

    private func inheritPreset(from source: String) {
        if source == "keep" {
            if let event {
                preset = event.preset
            }
            return
        }
        if source == "current" {
            preset = currentPreset
            return
        }

        if source.hasPrefix("builtin-"),
           let bpm = Int(source.replacingOccurrences(of: "builtin-", with: "")) {
            var builtIn = MetronomePreset.standard
            builtIn.bpm = bpm
            preset = builtIn
            return
        }

        if source.hasPrefix("event-"),
           let id = UUID(uuidString: source.replacingOccurrences(of: "event-", with: "")),
           let sourceEvent = existingEvents.first(where: { $0.id == id }) {
            preset = sourceEvent.preset
        }
    }

    private func save() {
        var insertedEvent: PracticeEvent?
        let folderSnapshots = folders.map {
            (folder: $0, eventIDs: $0.eventIDs, updatedAt: $0.updatedAt)
        }
        var previousValues: (
            name: String,
            preset: MetronomePreset,
            goalPlan: PracticeGoalPlan?,
            updatedAt: Date
        )?
        let savedEvent: PracticeEvent
        if let event {
            previousValues = (
                event.name,
                event.preset,
                event.goalPlan,
                event.updatedAt
            )
            event.name = trimmedName
            event.apply(preset: preset)
            if goalEnabled {
                event.updateGoalPlanTargets(goalTargets)
            } else {
                event.disableGoalPlan()
            }
            savedEvent = event
        } else {
            let newEvent = PracticeEvent(
                name: trimmedName,
                preset: preset
            )
            modelContext.insert(newEvent)
            if goalEnabled {
                newEvent.enableGoalPlan(targets: goalTargets)
            }
            insertedEvent = newEvent
            savedEvent = newEvent
        }

        let destination = folders.first { $0.id == folderID }
        PracticeFolder.move(
            eventID: savedEvent.id,
            to: destination,
            among: folders
        )

        do {
            try modelContext.save()
            dismiss()
        } catch {
            for snapshot in folderSnapshots {
                snapshot.folder.setEventIDs(
                    snapshot.eventIDs,
                    now: snapshot.updatedAt
                )
            }
            if let insertedEvent {
                modelContext.delete(insertedEvent)
            } else if let event, let previousValues {
                event.name = previousValues.name
                event.apply(preset: previousValues.preset)
                event.setGoalPlan(previousValues.goalPlan)
                event.updatedAt = previousValues.updatedAt
            }
            persistenceError = error.localizedDescription
        }
    }
}
