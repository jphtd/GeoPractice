import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PracticeEventDragPayload: Codable, Hashable, Sendable, Transferable {
    let eventID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .geoPracticeEvent)
    }
}

private extension UTType {
    static let geoPracticeEvent = UTType(
        exportedAs: "com.kuoxiyu.geopractice.practice-event"
    )
}

enum PracticeNavigationRoute: Hashable {
    case folder(UUID)
    case event(UUID)
}

struct PracticeEventsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var events: [PracticeEvent]
    @Query(sort: [
        SortDescriptor(\PracticeFolder.sortIndex),
        SortDescriptor(\PracticeFolder.createdAt)
    ]) private var folders: [PracticeFolder]
    @Query(sort: [
        SortDescriptor(\PracticeAttempt.finishedAt, order: .reverse),
        SortDescriptor(\PracticeAttempt.createdAt, order: .reverse)
    ]) private var attempts: [PracticeAttempt]
    @Query(sort: [
        SortDescriptor(\PracticeDailyGoal.localDay, order: .reverse),
        SortDescriptor(\PracticeDailyGoal.createdAt, order: .reverse)
    ]) private var dailyGoals: [PracticeDailyGoal]

    @ObservedObject var metronome: MetronomeEngine
    let protectedEventID: UUID?
    let openMetronome: (PracticeEvent, MetronomePreset) -> Void

    @State private var showsNewEvent = false
    @State private var newEventFolderID: UUID?
    @State private var pendingDelete: PracticeEvent?
    @State private var pendingFolderDelete: PracticeFolder?
    @State private var editingFolderID: UUID?
    @State private var folderNameDraft = ""
    @State private var showsFolderEditor = false
    @State private var deleteError: String?
    @State private var dropTargetFolderID: UUID?

    private var unclassifiedEvents: [PracticeEvent] {
        events.filter { event in
            PracticeFolder.folder(containing: event.id, in: folders) == nil
        }
    }

    private var trimmedFolderName: String {
        folderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var folderNameIsAvailable: Bool {
        !trimmedFolderName.isEmpty && !folders.contains { folder in
            folder.id != editingFolderID
                && folder.name.localizedCaseInsensitiveCompare(trimmedFolderName) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()

                if events.isEmpty && folders.isEmpty {
                    ContentUnavailableView {
                        Label("还没有打卡事件", systemImage: "music.note.list")
                    } description: {
                        Text("新建一个练习项目，并继承当前节拍器预设。")
                    } actions: {
                        Button("新建事件") {
                            presentNewEvent(in: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !folders.isEmpty {
                                practiceSectionHeader("目录")

                                VStack(spacing: 0) {
                                    ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                                        HStack(spacing: 4) {
                                            NavigationLink(
                                                value: PracticeNavigationRoute.folder(folder.id)
                                            ) {
                                                PracticeFolderRow(
                                                    folder: folder,
                                                    eventCount: events.lazy.filter {
                                                        folder.contains(eventID: $0.id)
                                                    }.count,
                                                    isDropTarget: dropTargetFolderID == folder.id
                                                )
                                                .frame(maxWidth: .infinity)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)

                                            Menu {
                                                Button {
                                                    beginRenaming(folder)
                                                } label: {
                                                    Label("目录改名", systemImage: "pencil")
                                                }
                                                Button(role: .destructive) {
                                                    pendingFolderDelete = folder
                                                } label: {
                                                    Label("删除目录", systemImage: "trash")
                                                }
                                            } label: {
                                                Image(systemName: "ellipsis")
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundStyle(GeoTheme.muted)
                                                    .frame(width: 44, height: 44)
                                                    .contentShape(Rectangle())
                                            }
                                            .accessibilityLabel("更多操作，\(folder.name)")
                                            .accessibilityActions {
                                                Button("目录改名") {
                                                    beginRenaming(folder)
                                                }
                                                Button("删除目录") {
                                                    pendingFolderDelete = folder
                                                }
                                            }
                                        }
                                        .dropDestination(for: PracticeEventDragPayload.self) {
                                            payloads,
                                            _ in
                                            guard let payload = payloads.first else {
                                                return false
                                            }
                                            return classifyUnclassifiedEvent(
                                                payload.eventID,
                                                into: folder
                                            )
                                        } isTargeted: { isTargeted in
                                            withAnimation(.easeOut(duration: 0.14)) {
                                                if isTargeted {
                                                    dropTargetFolderID = folder.id
                                                } else if dropTargetFolderID == folder.id {
                                                    dropTargetFolderID = nil
                                                }
                                            }
                                        }
                                        if index < folders.count - 1 {
                                            Divider()
                                                .overlay(Color.white.opacity(0.07))
                                                .padding(.leading, 55)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }

                            if !unclassifiedEvents.isEmpty {
                                practiceSectionHeader("未分类 · \(unclassifiedEvents.count)")
                                    .padding(.top, folders.isEmpty ? 0 : 18)

                                LazyVStack(spacing: 14) {
                                    ForEach(unclassifiedEvents, id: \.id) { event in
                                        unclassifiedEventRow(event)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("练习打卡")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            presentNewEvent(in: nil)
                        } label: {
                            Label("新建练习", systemImage: "music.note")
                        }
                        Button {
                            beginCreatingFolder()
                        } label: {
                            Label("新建目录", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建练习或目录")
                }
            }
            .toolbarBackground(GeoTheme.background.opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: PracticeNavigationRoute.self) { route in
                switch route {
                case .folder(let id):
                    if let folder = folders.first(where: { $0.id == id }) {
                        PracticeFolderEventsView(
                            folder: folder,
                            metronome: metronome,
                            protectedEventID: protectedEventID,
                            openMetronome: openMetronome
                        )
                    } else {
                        ContentUnavailableView(
                            "目录不存在",
                            systemImage: "folder.badge.questionmark"
                        )
                    }
                case .event(let id):
                    if let event = events.first(where: { $0.id == id }) {
                        PracticeEventDetailView(
                            event: event,
                            attempts: attempts.filter { $0.eventID == event.id },
                            dailyGoals: dailyGoals.filter { $0.eventID == event.id },
                            metronome: metronome,
                            openMetronome: openMetronome
                        )
                    } else {
                        ContentUnavailableView(
                            "事件不存在",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                }
            }
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(isPresented: $showsNewEvent) {
            PracticeEventEditorView(
                currentPreset: metronome.preset,
                initialFolderID: newEventFolderID
            )
        }
        .alert(editingFolderID == nil ? "新建目录" : "目录改名", isPresented: $showsFolderEditor) {
            TextField("目录名称", text: $folderNameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                saveFolderEditor()
            }
            .disabled(!folderNameIsAvailable)
        } message: {
            Text("目录仅用于整理练习项目，不会改变练习记录。")
        }
        .alert("删除目录“\(pendingFolderDelete?.name ?? "")”？", isPresented: Binding(
            get: { pendingFolderDelete != nil },
            set: { if !$0 { pendingFolderDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingFolderDelete = nil
            }
            Button("删除", role: .destructive) {
                deletePendingFolder()
            }
        } message: {
            Text("目录中的练习项目会回到“未分类”，所有历史记录都会保留。")
        }
        .alert("删除“\(pendingDelete?.name ?? "")”？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
            Button("删除", role: .destructive) {
                if let event = pendingDelete {
                    delete(event)
                }
                pendingDelete = nil
            }
        } message: {
            Text("此操作会删除名称、目标、累计次数、练习时长、速度历史和保存的节拍器预设。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("好", role: .cancel) {
                deleteError = nil
            }
        } message: {
            Text(deleteError ?? "请稍后重试。")
        }
    }

    private func presentNewEvent(in folderID: UUID?) {
        newEventFolderID = folderID
        showsNewEvent = true
    }

    private func beginCreatingFolder() {
        editingFolderID = nil
        folderNameDraft = ""
        showsFolderEditor = true
    }

    private func beginRenaming(_ folder: PracticeFolder) {
        editingFolderID = folder.id
        folderNameDraft = folder.name
        showsFolderEditor = true
    }

    private func saveFolderEditor() {
        guard folderNameIsAvailable else { return }
        if let editingFolderID,
           let folder = folders.first(where: { $0.id == editingFolderID }) {
            let oldName = folder.name
            let oldUpdate = folder.updatedAt
            folder.name = trimmedFolderName
            folder.updatedAt = .now
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                folder.name = oldName
                folder.updatedAt = oldUpdate
                deleteError = error.localizedDescription
            }
        } else {
            let nextIndex = (folders.map(\.sortIndex).max() ?? -1) + 1
            let folder = PracticeFolder(
                name: trimmedFolderName,
                sortIndex: nextIndex
            )
            modelContext.insert(folder)
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                deleteError = error.localizedDescription
            }
        }
    }

    private func deletePendingFolder() {
        guard let folder = pendingFolderDelete else { return }
        modelContext.delete(folder)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            deleteError = error.localizedDescription
        }
        pendingFolderDelete = nil
    }

    private func delete(_ event: PracticeEvent) {
        do {
            PracticeFolder.move(
                eventID: event.id,
                to: nil,
                among: folders
            )
            try PracticeAttempt.deleteHistory(for: event.id, in: modelContext)
            try PracticeDailyGoal.deleteAll(for: event.id, in: modelContext)
            modelContext.delete(event)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            deleteError = error.localizedDescription
        }
    }

    private func practiceSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(GeoTheme.muted)
            .textCase(.uppercase)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func unclassifiedEventRow(_ event: PracticeEvent) -> some View {
        PracticeEventNavigationRow(
            event: event,
            protectedEventID: protectedEventID,
            onDelete: { pendingDelete = event },
            showsInlineChevron: true,
            showsInlineActions: true,
            dragPayload: folders.isEmpty
                ? nil
                : PracticeEventDragPayload(eventID: event.id),
            moveFolders: folders
        ) { folder in
            _ = classifyUnclassifiedEvent(
                event.id,
                into: folder
            )
        }
    }

    private func classifyUnclassifiedEvent(
        _ eventID: UUID,
        into destination: PracticeFolder
    ) -> Bool {
        let snapshots = folders.map { folder in
            (
                folder: folder,
                eventIDs: folder.eventIDs,
                updatedAt: folder.updatedAt
            )
        }
        let result = PracticeFolder.classifyUnclassified(
            eventID: eventID,
            toFolderID: destination.id,
            knownEventIDs: Set(events.map(\.id)),
            among: folders
        )
        guard result == .moved else {
            dropTargetFolderID = nil
            return false
        }

        do {
            try modelContext.save()
            dropTargetFolderID = nil
            return true
        } catch {
            let message = error.localizedDescription
            modelContext.rollback()
            for snapshot in snapshots {
                snapshot.folder.setEventIDs(
                    snapshot.eventIDs,
                    now: snapshot.updatedAt
                )
                snapshot.folder.updatedAt = snapshot.updatedAt
            }
            dropTargetFolderID = nil
            deleteError = message
            return false
        }
    }
}

private struct PracticeFolderEventsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var events: [PracticeEvent]
    @Query private var folders: [PracticeFolder]

    let folder: PracticeFolder
    @ObservedObject var metronome: MetronomeEngine
    let protectedEventID: UUID?
    let openMetronome: (PracticeEvent, MetronomePreset) -> Void

    @State private var showsNewEvent = false
    @State private var pendingDelete: PracticeEvent?
    @State private var deleteError: String?

    private var folderEvents: [PracticeEvent] {
        events.filter { folder.contains(eventID: $0.id) }
    }

    var body: some View {
        ZStack {
            GeoBackground()
            if folderEvents.isEmpty {
                ContentUnavailableView {
                    Label("目录还是空的", systemImage: "folder")
                } description: {
                    Text("在这里新建练习，或编辑已有练习并移动到此目录。")
                } actions: {
                    Button("新建练习") {
                        showsNewEvent = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                }
            } else {
                List {
                    Section("\(folderEvents.count) 个练习项目") {
                        ForEach(folderEvents, id: \.id) { event in
                            PracticeEventNavigationRow(
                                event: event,
                                protectedEventID: protectedEventID,
                                onDelete: { pendingDelete = event }
                            )
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsNewEvent = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("在\(folder.name)中新建练习")
            }
        }
        .sheet(isPresented: $showsNewEvent) {
            PracticeEventEditorView(
                currentPreset: metronome.preset,
                initialFolderID: folder.id
            )
        }
        .alert("删除“\(pendingDelete?.name ?? "")”？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let event = pendingDelete { delete(event) }
                pendingDelete = nil
            }
        } message: {
            Text("此操作会删除名称、目标、累计次数、练习时长、速度历史和保存的节拍器预设。")
        }
        .alert("无法删除", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "请稍后重试。")
        }
    }

    private func delete(_ event: PracticeEvent) {
        do {
            PracticeFolder.move(eventID: event.id, to: nil, among: folders)
            try PracticeAttempt.deleteHistory(for: event.id, in: modelContext)
            try PracticeDailyGoal.deleteAll(for: event.id, in: modelContext)
            modelContext.delete(event)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            deleteError = error.localizedDescription
        }
    }
}

private struct PracticeEventNavigationRow: View {
    let event: PracticeEvent
    let protectedEventID: UUID?
    let onDelete: () -> Void
    var showsInlineChevron = false
    var showsInlineActions = false
    var dragPayload: PracticeEventDragPayload?
    var moveFolders: [PracticeFolder] = []
    var onMove: ((PracticeFolder) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            eventNavigationLink

            if showsInlineActions {
                Menu {
                    Button("删除", role: .destructive, action: onDelete)
                        .disabled(event.id == protectedEventID)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(GeoTheme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作，\(event.name)")
            }
        }
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive, action: onDelete)
                .disabled(event.id == protectedEventID)
                .accessibilityHint(
                    event.id == protectedEventID
                    ? "请先在节拍器中结束当前练习"
                    : ""
                )
        }
    }

    @ViewBuilder
    private var eventNavigationLink: some View {
        if let dragPayload {
            navigationLink
                .draggable(dragPayload) {
                    PracticeEventDragPreview(name: event.name)
                }
                .accessibilityHint(
                    "长按并拖到目录可以设置分类，也可以在操作中选择要移入的目录"
                )
                .accessibilityActions {
                    ForEach(moveFolders, id: \.id) { folder in
                        Button("移到\(folder.name)") {
                            onMove?(folder)
                        }
                    }
                }
        } else {
            navigationLink
        }
    }

    private var navigationLink: some View {
        NavigationLink(value: PracticeNavigationRoute.event(event.id)) {
            HStack(spacing: 10) {
                PracticeEventRow(event: event)
                if showsInlineChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(GeoTheme.muted)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PracticeFolderRow: View {
    let folder: PracticeFolder
    let eventCount: Int
    var isDropTarget = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "folder.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(white: 0.84))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(GeoTheme.text)
                    .lineLimit(1)
                Text("\(eventCount) 个练习项目")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GeoTheme.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GeoTheme.muted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            Color.white.opacity(isDropTarget ? 0.12 : 0),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    Color.white.opacity(isDropTarget ? 0.78 : 0),
                    lineWidth: 1.25
                )
        }
        .scaleEffect(isDropTarget ? 1.012 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct PracticeEventDragPreview: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "folder.badge.plus")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(GeoTheme.text)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(
                GeoTheme.panelRaised,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            }
    }
}

private struct PracticeEventRow: View {
    let event: PracticeEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(GeoTheme.text)
                    .lineLimit(1)
                Spacer()
                Text("\(event.totalCount) 次 · \(practiceDurationString(milliseconds: event.totalDurationMilliseconds))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GeoTheme.muted)
                    .monospacedDigit()
            }
            PresetSummary(preset: event.preset)
            HStack(spacing: 8) {
                CountBadge(title: "左手", count: event.leftCount)
                CountBadge(title: "右手", count: event.rightCount)
                CountBadge(title: "合手", count: event.bothCount)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.105).opacity(0.96), Color(white: 0.05).opacity(0.98)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.075), lineWidth: 1)
                }
        }
    }
}

private struct PracticeEventDetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let event: PracticeEvent
    let attempts: [PracticeAttempt]
    let dailyGoals: [PracticeDailyGoal]
    @ObservedObject var metronome: MetronomeEngine
    let openMetronome: (PracticeEvent, MetronomePreset) -> Void

    @State private var showsEditor = false

    var body: some View {
        ZStack {
            GeoBackground()
            ScrollView {
                VStack(spacing: 18) {
                    eventHero

                    if let todayProgress {
                        PracticeGoalProgressCard(
                            title: "今日目标",
                            progress: todayProgress
                        )
                    }

                    if let planProgress {
                        PracticeGoalProgressCard(
                            title: "练习计划总目标",
                            progress: planProgress
                        )
                    }

                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 18) {
                            statisticsCard
                            VStack(spacing: 18) {
                                speedHistoryCard
                                presetCard
                            }
                        }
                    } else {
                        statisticsCard
                        speedHistoryCard
                        presetCard
                    }
                }
                .padding(16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") {
                    showsEditor = true
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            PracticeEventEditorView(event: event, currentPreset: metronome.preset)
        }
    }

    private var todayProgress: PracticeGoalProgress? {
        guard let plan = event.goalPlan else { return nil }
        let timeZone = TimeZone.autoupdatingCurrent
        let localDay = PracticeDailyGoal.localDay(
            containing: .now,
            timeZone: timeZone
        )
        guard let goal = dailyGoals.first(where: {
            $0.planID == plan.id && $0.localDay == localDay
        }) else {
            return nil
        }
        let completed = attempts
            .filter { $0.dailyGoalKey == goal.key }
            .reduce(PracticeGoalCounts()) { partial, attempt in
                partial.adding(PracticeGoalCounts(attempt: attempt))
            }
        return PracticeGoalProgress(
            targets: goal.targets,
            completed: completed
        )
    }

    private var planProgress: PracticeGoalProgress? {
        guard let plan = event.goalPlan else { return nil }
        let completed = PracticeGoalCounts(
            left: event.leftCount,
            right: event.rightCount,
            both: event.bothCount
        ).subtractingFloorAtZero(plan.baseline)
        return PracticeGoalProgress(
            targets: plan.targets,
            completed: completed
        )
    }

    private var eventHero: some View {
        GeoCard(cornerRadius: 26) {
            VStack(alignment: .leading, spacing: 16) {
                Text("PRACTICE EVENT")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.8)
                    .foregroundStyle(Color(white: 0.74))
                Text(event.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(GeoTheme.text)
                HStack {
                    Label("\(event.totalCount) 次", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Label(
                        practiceDurationString(milliseconds: event.totalDurationMilliseconds),
                        systemImage: "timer"
                    )
                    Spacer()
                    Text(event.updatedAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)
            }
        }
    }

    private var statisticsCard: some View {
        GeoCard {
            VStack(spacing: 16) {
                CardTitle(title: "累计练习", subtitle: "STATISTICS")
                ForEach(PracticeHand.controlOrder) { hand in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hand.title)
                                .font(.system(size: 14, weight: .semibold))
                            Text("练习统计")
                                .font(.system(size: 10))
                                .foregroundStyle(GeoTheme.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(event.count(for: hand)) 次")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(practiceDurationString(milliseconds: event.durationMilliseconds(for: hand)))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(GeoTheme.muted)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var speedHistoryCard: some View {
        GeoCard {
            VStack(alignment: .leading, spacing: 16) {
                CardTitle(title: "速度记录", subtitle: "TEMPO HISTORY")

                ForEach(PracticeHand.controlOrder) { hand in
                    speedSummaryRow(for: hand)
                    if hand != PracticeHand.controlOrder.last {
                        Divider()
                            .overlay(GeoTheme.line)
                    }
                }

                if attempts.isEmpty {
                    Text("完成练习并追加后，这里会保留每次的速度记录。")
                        .font(.system(size: 11))
                        .foregroundStyle(GeoTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(attempts) { attempt in
                                attemptHistoryRow(attempt)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("查看全部 \(attempts.count) 次练习记录")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func speedSummaryRow(for hand: PracticeHand) -> some View {
        let latest = latestAttempt(for: hand)

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(hand.title)
                    .font(.system(size: 14, weight: .bold))
                Spacer(minLength: 8)
                if let latest {
                    Text(latest.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GeoTheme.muted)
                        .lineLimit(1)
                } else {
                    Text("暂无记录")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GeoTheme.muted)
                }
            }

            if let latest {
                let speed = latest.speedSummary(for: hand)
                HStack(spacing: 8) {
                    speedValue(
                        title: "练习最多",
                        bpm: speed.mostPracticed?.bpm
                    )
                    speedValue(
                        title: "最大尝试",
                        bpm: speed.maximumAttempt?.bpm
                    )
                }

                if let preset = latest.mostPracticedPreset(for: hand) {
                    Button {
                        openMetronome(event, preset)
                    } label: {
                        Label("继承\(hand.title)上次设置并开始", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("继承基准音符、速度、训练音符、拍数、分组和方向")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func speedValue(title: String, bpm: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)
            Text(bpm.map(String.init) ?? "—")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 11)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func attemptHistoryRow(_ attempt: PracticeAttempt) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(attempt.finishedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, weight: .bold))
            ForEach(PracticeHand.controlOrder) { hand in
                if attempt.stats(for: hand).count > 0 {
                    let speed = attempt.speedSummary(for: hand)
                    Text("\(hand.title)　练习最多：\(speed.mostPracticed?.bpm.description ?? "—")　最大尝试：\(speed.maximumAttempt?.bpm.description ?? "—")")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(GeoTheme.muted)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            Color.white.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func latestAttempt(for hand: PracticeHand) -> PracticeAttempt? {
        attempts.first { $0.speedSummary(for: hand).mostPracticed != nil }
    }

    private var presetCard: some View {
        GeoCard {
            VStack(alignment: .leading, spacing: 16) {
                CardTitle(title: "节拍器预设", subtitle: "PRESET")
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.preset.tempoDisplay)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Label("\(event.preset.beats) 拍 · \(event.preset.grouping)", systemImage: "circle.grid.cross")
                    Label(event.preset.subdivisionTitle, systemImage: "music.note")
                    Label(event.preset.direction.title, systemImage: event.preset.direction.symbol)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GeoTheme.text)

                Button {
                    openMetronome(event, event.preset)
                } label: {
                    Label("载入并开始练习", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
