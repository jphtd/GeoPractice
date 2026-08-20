import SwiftUI

struct PracticeGoalTargetsEditor: View {
    @Binding var targets: PracticeGoalCounts
    var title: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(GeoTheme.muted)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(PracticeHand.controlOrder) { hand in
                        targetField(for: hand)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(minWidth: 430)

                VStack(spacing: 8) {
                    ForEach(PracticeHand.controlOrder) { hand in
                        targetField(for: hand)
                    }
                }
            }

            HStack {
                Text("总目标")
                Spacer()
                Text("\(targets.total) 次")
                    .fontWeight(.bold)
                    .monospacedDigit()
            }
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(GeoTheme.muted)
        }
        .padding(12)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func targetField(for hand: PracticeHand) -> some View {
        HStack(spacing: 6) {
            Text(hand.title)
                .font(.system(.subheadline, weight: .semibold))
                .frame(minWidth: 34, alignment: .leading)

            Button {
                update(hand, by: -1)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(targets.value(for: hand) == 0)
            .accessibilityLabel("减少\(hand.title)目标一次")

            TextField("0", text: textBinding(for: hand))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(.body, design: .rounded, weight: .bold))
                .monospacedDigit()
                .frame(minWidth: 42, minHeight: 44)
                .background(
                    Color.black.opacity(0.24),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityLabel("\(hand.title)目标次数")

            Button {
                update(hand, by: 1)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("增加\(hand.title)目标一次")
        }
        .frame(minHeight: 44)
    }

    private func textBinding(for hand: PracticeHand) -> Binding<String> {
        Binding(
            get: { String(targets.value(for: hand)) },
            set: { text in
                let digits = text.filter(\.isNumber)
                set(value: min(maximumTarget, Int(digits) ?? 0), for: hand)
            }
        )
    }

    private func update(_ hand: PracticeHand, by delta: Int) {
        let current = targets.value(for: hand)
        let next: Int
        if delta > 0 {
            next = min(maximumTarget, current == Int.max ? current : current + 1)
        } else {
            next = max(0, current - 1)
        }
        set(value: next, for: hand)
    }

    private func set(value: Int, for hand: PracticeHand) {
        let value = min(maximumTarget, max(0, value))
        targets = PracticeGoalCounts(
            left: hand == .left ? value : targets.left,
            right: hand == .right ? value : targets.right,
            both: hand == .both ? value : targets.both
        )
    }

    private var maximumTarget: Int { 99_999 }
}

struct DailyGoalSetupView: View {
    @Environment(\.dismiss) private var dismiss

    let eventName: String
    let date: Date
    let initialTargets: PracticeGoalCounts
    let onConfirm: (PracticeGoalCounts) -> Bool

    @State private var targets: PracticeGoalCounts

    init(
        eventName: String,
        date: Date,
        initialTargets: PracticeGoalCounts,
        onConfirm: @escaping (PracticeGoalCounts) -> Bool
    ) {
        self.eventName = eventName
        self.date = date
        self.initialTargets = initialTargets
        self.onConfirm = onConfirm
        _targets = State(initialValue: initialTargets)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(eventName)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                            Text(date.formatted(date: .long, time: .omitted))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(GeoTheme.muted)
                            Text("这是今天首次进入该计划。确认后，同一天后续练习会继续累计这组目标。")
                                .font(.footnote)
                                .foregroundStyle(GeoTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        PracticeGoalTargetsEditor(
                            targets: $targets,
                            title: "今日目标"
                        )
                    }
                    .frame(maxWidth: 560)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("设置今日目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并开始") {
                        if onConfirm(targets) {
                            dismiss()
                        }
                    }
                    .fontWeight(.bold)
                    .disabled(targets.total == 0)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct PracticeGoalProgressCard: View {
    let title: String
    let progress: PracticeGoalProgress

    var body: some View {
        GeoCard {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(title: title, subtitle: "PRACTICE GOAL")
                ForEach(PracticeHand.controlOrder) { hand in
                    let target = progress.targets.value(for: hand)
                    if target > 0 {
                        let completed = progress.completed.value(for: hand)
                        VStack(spacing: 6) {
                            HStack {
                                Text(hand.title)
                                Spacer()
                                Text("\(completed)/\(target)")
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                            ProgressView(
                                value: min(1, Double(completed) / Double(target))
                            )
                            .tint(.white)
                        }
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(hand.title)已完成 \(completed) 次，目标 \(target) 次，剩余 \(progress.remaining.value(for: hand)) 次")
                    }
                }

                Divider().overlay(GeoTheme.line)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(progress.isComplete ? "目标已完成" : "目标进行中")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                        Text("剩余 \(progress.remaining.total) 次")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GeoTheme.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(progress.creditedCompletedTotal)/\(progress.targets.total)")
                            .font(.system(.body, design: .rounded, weight: .bold))
                            .monospacedDigit()
                        Text(progress.completionRate.formatted(
                            .percent.precision(.fractionLength(1))
                        ))
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(GeoTheme.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
