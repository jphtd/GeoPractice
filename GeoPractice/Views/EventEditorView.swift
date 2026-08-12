import SwiftData
import SwiftUI

struct PracticeEventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var existingEvents: [PracticeEvent]

    private let event: PracticeEvent?
    private let currentPreset: MetronomePreset

    @State private var name: String
    @State private var preset: MetronomePreset
    @State private var inheritanceSource: String
    @State private var persistenceError: String?

    init(event: PracticeEvent? = nil, currentPreset: MetronomePreset) {
        self.event = event
        self.currentPreset = currentPreset
        _name = State(initialValue: event?.name ?? "")
        _preset = State(initialValue: event?.preset ?? currentPreset)
        _inheritanceSource = State(initialValue: event == nil ? "current" : "keep")
        _persistenceError = State(initialValue: nil)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        HStack {
                            Text("BPM")
                            Spacer()
                            Text("\(preset.bpm)")
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(preset.bpm) },
                                set: { preset.bpm = Int($0.rounded()) }
                            ),
                            in: 30...240,
                            step: 1
                        )
                        .tint(.white)
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

                        Picker("运行方向", selection: $preset.direction) {
                            ForEach(RotationDirection.allCases) { direction in
                                Label(direction.title, systemImage: direction.symbol)
                                    .tag(direction)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
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
                    .disabled(trimmedName.isEmpty)
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
        var previousValues: (
            name: String,
            preset: MetronomePreset,
            updatedAt: Date
        )?
        if let event {
            previousValues = (
                event.name,
                event.preset,
                event.updatedAt
            )
            event.name = trimmedName
            event.apply(preset: preset)
        } else {
            let newEvent = PracticeEvent(
                name: trimmedName,
                preset: preset
            )
            modelContext.insert(newEvent)
            insertedEvent = newEvent
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            if let insertedEvent {
                modelContext.delete(insertedEvent)
            } else if let event, let previousValues {
                event.name = previousValues.name
                event.apply(preset: previousValues.preset)
                event.updatedAt = previousValues.updatedAt
            }
            persistenceError = error.localizedDescription
        }
    }
}
