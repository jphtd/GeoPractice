import Combine
import SwiftData
import SwiftUI

struct PracticeCoreRootView: View {
    @Query(sort: [SortDescriptor(\PracticeSong.sortIndex), SortDescriptor(\PracticeSong.createdAt)]) private var songs: [PracticeSong]
    @Query private var events: [PracticeEvent]
    @StateObject private var settings: CorePracticeSettings
    @StateObject private var navigation = CoreNavigation()
    @StateObject private var practiceStore = PracticeLibraryStore()
    @ObservedObject private var cloudSync = ICloudSyncService.shared
    @State private var practiceStoreError: String?
    @State private var boundaryMessage: String?
    @State private var editingComposerID: UUID?
    @State private var composerDraft = ""
    @State private var recovery: CoreRecovery?
    @State private var pendingLegacySession = false
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var runtime: CoreSessionRuntime
    @StateObject private var engine = MetronomeEngine()
    @State private var selectedTab = "Practice"
    @State private var independentGeoBeat = false
    @StateObject private var independentRuntime = CoreSessionRuntime(defaults: UserDefaults(suiteName: "CoreIndependent.\(UUID())")!, restore: false)
    @State private var savedFocusSummary: (piece: UUID, practice: Int64, focus: Int64)?
    @State private var sheetRoute: CoreRoute?
    @State private var queuedRoute: CoreRoute?
    @State private var recentlyDeletedUndoID: UUID?
    @State private var undoPresentationID = UUID()
    @State private var deleteFromArchive = false
    @State private var initialHandRoute: CoreRoute?
    @State private var selectedInitialHand: (piece: UUID, division: UUID, hand: PracticeHand)?
    @State private var cycleStartRequest: (piece: UUID, division: UUID, hand: PracticeHand?, definition: CoreDivisionDefinition, hands: [PracticeHand])?
    @State private var analyzeScope: CoreAnalyzeContext?
    @Environment(\.modelContext) private var modelContext
    @State private var exitDestination: CoreExitDestination?
    @State private var exitError: String?
    @State private var loaded = false
    private let checkpoint = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    let fixture: CoreFixture?

    init(fixture: CoreFixture? = nil) {
        self.fixture = fixture
        let defaults = fixture == nil ? UserDefaults.standard : UserDefaults(suiteName: "CoreFixture.\(UUID())")!
        _runtime = StateObject(wrappedValue: CoreSessionRuntime(defaults: defaults, restore: fixture == nil))
        _settings = StateObject(wrappedValue: CorePracticeSettings(defaults: defaults))
    }

    private var currentPieces: [PracticeSong] {
        songs.filter { !$0.isArchived && $0.deletedAt == nil }
    }
    private var isIndependentGeoBeat: Bool {
        independentGeoBeat || runtime.context == nil
    }
    private var focusSurfaceVisible: Bool {
        (selectedTab == "Practice" && runtime.isFocusEnabled && !runtime.needsRecovery) ||
            (selectedTab == "GeoBeat" && (isIndependentGeoBeat
                ? settings.focusActivation(isPro: subscription.isPro)
                : runtime.isFocusEnabled && !runtime.needsRecovery))
    }
    var body: some View {
        Group {
            if selectedTab == "GeoBeat" {
                NavigationStack {
                    CoreSessionView(
                        runtime: isIndependentGeoBeat ? independentRuntime : runtime,
                        engine: engine,
                        isGeoBeat: true,
                        isIndependentGeoBeat: isIndependentGeoBeat,
                        independentFocusPresentation: isIndependentGeoBeat && settings.focusActivation(isPro: subscription.isPro),
                        openGeoBeat: {},
                        finish: finishSession,
                        onRoute: request, detach: detachGeoBeat,
                        saveIndependent: saveIndependent,
                        leaveIndependent: reconnectPractice
                    )
                }
            } else if selectedTab == "Analyze" {
                NavigationStack { CoreAnalyzeView(scope: .overall) }
            } else {
                practiceStack
            }
        }
        .environmentObject(settings)
        .tint(CorePalette.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !focusSurfaceVisible {
            VStack(spacing: 8) {
                if sheetRoute == nil { quickUndo }
                CoreBottomNavigation(
                    activeSessionID: runtime.activeID ?? recovery?.sessionID,
                    selectedTab: selectedTab,
                    onPractice: { reconnectPractice() },
                    onRoute: request
                )
            }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if fixture != nil && !focusSurfaceVisible { Text("Debug 场景 · 数据不持久保存。真实流程测试请关闭启动参数。")
                .font(.caption).padding(8).frame(maxWidth: .infinity).background(.yellow.opacity(0.15))
                .allowsHitTesting(false) }
        }
        .sheet(isPresented: Binding(get: { sheetRoute != nil }, set: { if !$0 { sheetRoute = nil; navigation.cancel() } }), onDismiss: {
            if let route = queuedRoute { queuedRoute = nil; request(route) }
        }) {
            if let sheetRoute {
                switch sheetRoute {
                case .settings:
                    CoreGlobalSettingsView(
                        practiceStore: practiceStore,
                        storeError: practiceStoreError,
                        activeSessionID: protectedSyncEventID
                    )
                        .environmentObject(settings)

                case .archivedPieces:
                    NavigationStack {
                        CoreArchiveView(activeSessionID: runtime.activeID ?? recovery?.sessionID, onRoute: request)
                            .toolbar { ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { self.sheetRoute = nil; navigation.cancel() }
                            } }
                    }
                    .safeAreaInset(edge: .bottom) { quickUndo }
                case .archivePiece, .deletePiece, .deleteAllArchivedPieces:
                    CoreExitHandoffView(
                        route: sheetRoute,
                        songs: songs,
                        events: events,
                        activeSessionID: runtime.activeID ?? recovery?.sessionID,
                        onCompleted: {
                            if case .deletePiece(let id) = sheetRoute, subscription.isPro {
                                undoPresentationID = UUID()
                                recentlyDeletedUndoID = id
                            }
                            if case .deletePiece = sheetRoute, deleteFromArchive {
                                self.sheetRoute = .archivedPieces
                            } else {
                                self.sheetRoute = nil
                            }
                            navigation.path = []
                            navigation.cancel()
                            selectedTab = "Practice"
                        },
                        onCancel: {
                            switch sheetRoute {
                            case .archivePiece, .deletePiece:
                                self.sheetRoute = nil

                            case .deleteAllArchivedPieces:
                                self.sheetRoute = .archivedPieces

                            default:
                                self.sheetRoute = nil
                            }
                        }                    )
                default:
                    CoreEditorView(route: sheetRoute, songs: songs, events: events,
                        activeSessionID: runtime.activeID ?? recovery?.sessionID, onSaved: returnFromEditor,
                                   onRoute: request)
                        .environmentObject(settings)
                }
            }
        }
        .sheet(isPresented: Binding(get: { analyzeScope != nil }, set: { if !$0 { analyzeScope = nil } })) {
            if let analyzeScope {
                NavigationStack {
                    CoreAnalyzeView(scope: analyzeScope)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { self.analyzeScope = nil } } }
                }
            }
        }
        .sheet(isPresented: Binding(get: { initialHandRoute != nil }, set: { if !$0 { initialHandRoute = nil; navigation.cancel() } }), onDismiss: {
            guard let choice = selectedInitialHand else { return }
            selectedInitialHand = nil
            do { try startPractice(piece: choice.piece, division: choice.division, initialHand: choice.hand) }
            catch { boundaryMessage = error.localizedDescription }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择练习手型").coreType(.titleMedium).accessibilityAddTraits(.isHeader)
                Text("选择本次练习首先记录的手型。").coreType(.body).foregroundStyle(CorePalette.secondary)
                ForEach(CoreHandMode.all.hands) { hand in
                    CoreButton(title: hand.title, kind: .secondary) {
                        guard case .startPractice(let piece, let division) = initialHandRoute else { return }
                        selectedInitialHand = (piece, division, hand)
                        initialHandRoute = nil
                    }.accessibilityIdentifier("core.initialHand.\(hand.rawValue)")
                }
                CoreButton(title: "取消", kind: .tertiary) { initialHandRoute = nil; navigation.cancel() }
            }.padding(24).frame(maxWidth: 720).presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .accessibilityIdentifier("core.initialHand.sheet")
        }
        .sheet(isPresented: Binding(get: { runtime.exitRequest != nil }, set: { _ in }), onDismiss: continueAfterExit) {
            CoreExitDecisionView(saveOnly: runtime.exitRequest?.saveOnly == true, error: exitError, choose: resolveExit)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { cycleStartRequest != nil }, set: { if !$0 { cycleStartRequest = nil } })) {
            if let request = cycleStartRequest {
                CoreCycleStartView(definition: request.definition, hands: request.hands) { starts in
                    try startPractice(piece: request.piece, division: request.division, initialHand: request.hand, confirmedStarts: starts)
                    cycleStartRequest = nil
                }
            }
        }
        .alert("操作提示", isPresented: Binding(get: { boundaryMessage != nil }, set: { if !$0 { boundaryMessage = nil } })) {
            if canDeferLegacyRecovery { Button("暂不恢复", action: deferLegacyRecovery) }
            Button("返回", role: .cancel) { boundaryMessage = nil; navigation.cancel() }
        } message: { Text(boundaryMessage ?? "") }
        .onAppear {
            configurePracticeStore()
            expireDeletedPieces()
            loadInitialContext()
        }
        .onReceive(checkpoint) { _ in runtime.persist(); expireDeletedPieces() }
        .onChange(of: engine.preset) { _, value in
            if !independentGeoBeat { runtime.updatePreset(value) }
        }
        .onChange(of: engine.isPlaying) { _, current in
            // Commit uses the completed startup result, never a transient
            // isPlaying publication while the audio engine is still starting.
            if !current { runtime.pause(); independentRuntime.pause() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { engine.pause(); runtime.pause(); independentRuntime.pause() }
            else { expireDeletedPieces() }
            guard fixture == nil else { return }
            if phase == .active {
                cloudSync.syncWhenAppBecomesActive()
            } else {
                cloudSync.syncBeforeBackgrounding()
            }
        }
        .onChange(of: protectedSyncEventID) { _, eventID in
            practiceStore.protectedEventID = eventID
            if fixture == nil { cloudSync.retryNow() }
        }
    }

    private var protectedSyncEventID: UUID? {
        CoreSyncProtection.activeEventID(
            planned: runtime,
            independent: independentRuntime,
            recoveryID: recovery?.sessionID
        )
    }

    private func configurePracticeStore() {
        do {
            try practiceStore.configure(modelContext: modelContext)
            practiceStore.protectedEventID = protectedSyncEventID
            practiceStoreError = nil
            if fixture == nil { cloudSync.start(store: practiceStore) }
        } catch {
            practiceStoreError = error.localizedDescription
        }
    }

    private func expireDeletedPieces() {
        guard songs.contains(where: { $0.deletionExpiresAt.map { $0 <= Date.now } == true }) else { return }
        do { try CoreContracts.expireDeletedPieces(in: modelContext) }
        catch { boundaryMessage = error.localizedDescription }
    }

    private var practiceStack: some View {
        NavigationStack(path: $navigation.path) {
            Group {
                if runtime.context != nil && !runtime.needsRecovery {
                    CoreSessionView(runtime: runtime, engine: engine, isGeoBeat: false,
                        openGeoBeat: { selectedTab = "GeoBeat" }, finish: finishSession, onRoute: request, detach: detachGeoBeat)
                } else { CoreScreen { home } }
            }
            .navigationDestination(for: CorePage.self) { page in
                switch page {
                case .piece(let id):
                    if let piece = songs.first(where: { $0.id == id && $0.deletedAt == nil }), let structure = piece.coreStructure {
                        pieceDetail(piece, structure: structure)
                    }
                case .division(let pieceID, let divisionID):
                    if let piece = songs.first(where: { $0.id == pieceID && $0.deletedAt == nil }),
                       let structure = piece.coreStructure,
                       let division = events.first(where: { $0.id == divisionID && $0.songID == pieceID }) {
                        CoreScreen {
                            CorePageHeader(title: "练习划分", back: back)
                            Text(piece.name).coreType(.titleMedium)
                            divisionCard(piece, division: division, structure: structure)
                        }
                    }
                case .recentlyDeleted:
                    if subscription.isPro { CoreRecentlyDeletedView() }
                }
            }
        }
    }

    @ViewBuilder private var home: some View {
        let state = CoreHomeState.resolve(pieceCount: currentPieces.count, recovery: currentRecovery)
        HStack(spacing: 8) {
            CorePageHeader(title: "Practice", trailing: currentRecovery == nil ? "plus" : nil, trailingLabel: "添加曲目") { request(.addPiece) }
            CoreIconButton(symbol: "gearshape", label: "设置") { request(.settings) }
        }
        Group {
            switch state {
            case .normal:
                VStack(alignment: .leading, spacing: 12) {
                    section("当前曲目")
                    ForEach(currentPieces) { piece in
                        CoreActionCard(title: piece.name) { openPiece(piece) }
                    }
                    CoreButton(title: "查看全部曲目", kind: .tertiary) { request(.allPieces) }.padding(.top, 12)
                }.accessibilityIdentifier("practice.normal")
            case .empty:
                CoreEmptyState(title: "还没有曲目", copy: "", button: "添加曲目") {
                    request(.addPiece)
                }.padding(.top, 24).accessibilityIdentifier("practice.empty")
                if !songs.isEmpty {
                    CoreButton(title: "查看全部曲目", kind: .tertiary) { request(.allPieces) }
                }
            case .recovery(let session):
                VStack(alignment: .leading, spacing: 16) {
                    Text("练习已暂停").coreType(.caption).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(CorePalette.subtle, in: Capsule())
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.pieceName).coreType(.titleSmall)
                        Text(session.divisionName).coreType(.body).foregroundStyle(CorePalette.secondary)
                    }
                    CoreButton(title: "继续练习") { request(.resumeSession(session.sessionID)) }
                    if canDeferLegacyRecovery {
                        CoreButton(title: "暂不恢复", kind: .secondary, action: deferLegacyRecovery)
                            .accessibilityIdentifier("practice.deferRecovery")
                    }
                }.coreCard().accessibilityIdentifier("practice.recovery")
            }
        }.padding(.top, 24)
    }

    private func pieceDetail(_ piece: PracticeSong, structure: CorePieceStructure) -> some View {
        let divisions = events.filter { $0.songID == piece.id }.sorted {
            ($0.coreDefinition?.first ?? Int.max) < ($1.coreDefinition?.first ?? Int.max)
        }
        return CoreScreen {
            HStack(spacing: 0) {
                CorePageHeader(title: "曲目详情", back: back)
                Menu {
                    Button("编辑作曲家") {
                        composerDraft = piece.composerText ?? ""
                        editingComposerID = piece.id
                    }
                    CorePieceActions(piece: piece, onRoute: request)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("曲目操作").accessibilityIdentifier("core.piece.actions")
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(piece.name).coreType(.titleLarge).accessibilityAddTraits(.isHeader)
                    Text(piece.composerText.flatMap {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                    } ?? "未填写作曲家")
                        .coreType(.caption).foregroundStyle(CorePalette.secondary)
                    Text(structure.label).coreType(.body).foregroundStyle(CorePalette.secondary)
                }
                if let saved = savedFocusSummary, saved.piece == piece.id {
                    Text("本次练习 \(saved.practice / 1000) 秒 · 专注 \(saved.focus / 1000) 秒")
                        .coreType(.caption).foregroundStyle(CorePalette.secondary)
                        .accessibilityIdentifier("core.focus.savedSummary")
                }
                CoreNavigationRow { request(.analyze(.piece(piece.id))) }.padding(.top, 24)
                VStack(alignment: .leading, spacing: 12) {
                    section("练习划分")
                    if divisions.isEmpty {
                        CoreEmptyState(title: "还没有练习划分", copy: "", button: "创建练习划分") {
                            request(.createDivision(piece: piece.id, mode: structure.mode))
                        }.accessibilityIdentifier("piece.noDivision")
                    } else {
                        ForEach(divisions) { division in
                            divisionCard(piece, division: division, structure: structure)
                        }
                        CoreButton(title: "创建练习划分", kind: .secondary) {
                            request(.createDivision(piece: piece.id, mode: structure.mode))
                        }
                    }
                }.padding(.top, 32)
            }.padding(.top, 20)
        }.alert("作曲家", isPresented: Binding(get: { editingComposerID == piece.id },
                                            set: { if !$0 { editingComposerID = nil } })) {
            TextField("作曲家（可选）", text: $composerDraft)
            Button("保存") {
                do { try CoreContracts.updateComposer(piece: piece, text: composerDraft, context: modelContext) }
                catch { boundaryMessage = error.localizedDescription }
                editingComposerID = nil
            }
            Button("取消", role: .cancel) { editingComposerID = nil }
        } message: {
            Text("保留输入原文；只有唯一匹配的目录名称或别名才会关联规范身份。")
        }
    }

    @ViewBuilder private func divisionCard(_ piece: PracticeSong, division: PracticeEvent,
                                          structure: CorePieceStructure) -> some View {
        if let definition = division.coreDefinition, definition.fits(structure) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if navigation.path.last == .division(piece: piece.id, division: division.id) {
                        Text(definition.label(mode: structure.mode)).coreType(.titleSmall).accessibilityAddTraits(.isHeader)
                    } else {
                        Button { navigation.path.append(.division(piece: piece.id, division: division.id)) } label: {
                            Text(definition.label(mode: structure.mode)).coreType(.titleSmall)
                        }.accessibilityIdentifier("division.detail.\(division.id)")
                    }
                    Spacer()
                    Menu {
                        Button("编辑") { request(.editDivision(piece: piece.id, division: division.id)) }
                        Button("自由练习") { request(.freePractice) }
                        Button("划分分析") { request(.analyze(.division(piece: piece.id, division: division.id))) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("\(definition.label(mode: structure.mode))，更多操作")
                        .accessibilityIdentifier("division.actions.\(division.id)")
                }
                Text("适用手型 · \(definition.handMode.label)").coreType(.caption).foregroundStyle(CorePalette.secondary)
                if definition.hasValidGoal, let goal = definition.goal {
                    ForEach(definition.handMode.hands) { hand in
                        Text(compactGoal(goal, hand: hand)).coreType(.body).foregroundStyle(CorePalette.secondary)
                    }
                    CoreButton(title: "开始练习") { request(.startPractice(piece: piece.id, division: division.id)) }
                        .accessibilityIdentifier("division.start.\(division.id)")
                } else {
                    Text("未设置目标").coreType(.body).foregroundStyle(CorePalette.secondary)
                    CoreButton(title: "设置目标") { request(.editDivision(piece: piece.id, division: division.id)) }
                        .accessibilityIdentifier("division.setGoal.\(division.id)")
                }
            }.coreCard()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(division.name).coreType(.titleSmall)
                Text(CoreIntegrationError.missingMetadata.localizedDescription).coreType(.caption)
            }.coreCard()
        }
    }
    private func compactGoal(_ goal: CoreGoal, hand: PracticeHand) -> String {
        guard let value = goal.hands[hand] else { return hand.title }
        var facts = [hand.title]
        if let count = value.count { facts.append("\(count) 次") }
        if let speed = value.speed { facts.append("\(speed.noteUnit.title) = \(speed.bpm) BPM") }
        if goal.ladderEnabled == true, value.ladder != nil {
            facts.append(value.speed == nil ? "开放式速度阶梯" : "速度阶梯")
        }
        return facts.joined(separator: " · ")
    }

    private func section(_ title: String) -> some View {
        Text(title).coreType(.titleSmall).accessibilityAddTraits(.isHeader)
    }
    private func back() { if !navigation.path.isEmpty { navigation.path.removeLast() } }
    private func openPiece(_ piece: PracticeSong) {
        guard piece.coreStructure?.isValid == true else {
            boundaryMessage = CoreIntegrationError.missingMetadata.localizedDescription
            return
        }
        navigation.path.append(.piece(piece.id))
    }
    private var canDeferLegacyRecovery: Bool {
        runtime.activeID == nil && (recovery != nil || pendingLegacySession)
    }
    private func deferLegacyRecovery() {
        guard canDeferLegacyRecovery else { return }
        // Synthetic fixtures must never acknowledge a real device's draft.
        if fixture == nil { CoreDependencies.deferLegacyRecovery() }
        recovery = nil
        pendingLegacySession = false
        boundaryMessage = nil
        navigation.cancel()
        navigation.path = []
        selectedTab = "Practice"
    }
    private var currentRecovery: CoreRecovery? {
        if runtime.needsRecovery, let context = runtime.context {
            return CoreRecovery(sessionID: runtime.session.sessionID, divisionID: context.divisionID,
                pieceName: context.pieceName, divisionName: context.divisionName)
        }
        return recovery
    }
    private func returnFromEditor(_ page: CorePage) {
        sheetRoute = nil
        selectedTab = "Practice"
        navigation.editorSaved(page)
        recovery = nil
    }
    private func detachGeoBeat() {
        engine.pause(); runtime.pause()
        independentGeoBeat = true; selectedTab = "GeoBeat"
    }
    private func reconnectPractice() {
        if isIndependentGeoBeat { engine.pause(); engine.apply(runtime.preset) }
        independentRuntime.pause()
        independentGeoBeat = false; selectedTab = "Practice"
    }
    private func saveIndependent(piece: PracticeSong, division: PracticeEvent) {
        do {
            _ = try independentRuntime.saveIndependent(
                piece: piece, division: division, in: modelContext
            )
            engine.stop()
        } catch { boundaryMessage = error.localizedDescription }
    }
    private func finishSession() {
        exitError = nil
        do {
            if !runtime.hasStartedPlayback {
                let piece = try runtime.cancelBeforePlayback()
                engine.stop()
                selectedTab = "Practice"; navigation.returnedBeforePlayback(piece: piece)
            } else { try runtime.requestExit(.ordinary) }
        }
        catch { boundaryMessage = error.localizedDescription }
    }
    private func resolveExit(_ choice: CoreExitChoice) {
        guard let id = runtime.context?.divisionID, let pieceID = runtime.context?.pieceID,
              let division = events.first(where: { $0.id == id }) else { return }
        do {
            let date = Date.now
            let summary = runtime.isFocusEnabled && runtime.count > 0 && choice == .save
                ? (piece: pieceID, practice: runtime.practiceDurationMilliseconds(at: date), focus: runtime.focusDurationMilliseconds(at: date)) : nil
            exitDestination = try runtime.resolveExit(choice, division: division, in: modelContext, at: date)
            if choice != .cancel { savedFocusSummary = summary; independentGeoBeat = false }
            exitError = nil
            if choice != .cancel { engine.stop() }
            else { navigation.cancel() }
        } catch { exitError = error.localizedDescription }
    }
    private func continueAfterExit() {
        guard let destination = exitDestination else { return }
        exitDestination = nil
        switch destination {
        case .piece(let id):
            selectedTab = "Practice"; navigation.path = [.piece(id)]; navigation.cancel()
        case .route(let route):
            selectedTab = "Practice"
            request(route)
        }
    }
    private func request(_ route: CoreRoute) {
        if selectedTab == "GeoBeat", isIndependentGeoBeat {
            switch route {
            case .geoBeat: break
            default:
                engine.pause()
                independentRuntime.pause()
            }
        }
        // Dismiss the presenting sheet before a guard or another destination can appear.
        if sheetRoute != nil {
            queuedRoute = route
            sheetRoute = nil
            return
        }
        if case .deletePiece(let id) = route {
            deleteFromArchive = songs.first(where: { $0.id == id })?.isArchived == true
        }

        navigation.request(route)
        do {
            if let context = runtime.context {
                let guarded: Bool
                switch route {
                case .startPractice(let piece, let division):
                    guard let target = events.first(where: { $0.id == division && $0.songID == piece }),
                          target.coreDefinition?.hasValidGoal == true else { throw CoreIntegrationError.invalidGoal }
                    guarded = runtime.activeID == nil || division != context.divisionID || piece != context.pieceID
                case .archivePiece(let piece), .deletePiece(let piece): guarded = piece == context.pieceID
                case .deleteAllArchivedPieces:
                    guarded = songs.contains { $0.id == context.pieceID && $0.isArchived && $0.deletedAt == nil }
                case .editDivision: guarded = true
                case .freePractice: guarded = runtime.activeID == nil
                default: guarded = false
                }
                if guarded {
                    if runtime.activeID == nil {
                        _ = try runtime.cancelBeforePlayback()
                    } else {
                        exitError = nil
                        try runtime.requestExit(.transition(route))
                        return
                    }
                }
            }
            switch route {
            case .settings:
                sheetRoute = route
            case .geoBeat:
                selectedTab = "GeoBeat"
            case .freePractice:
                guard runtime.activeID == nil && recovery == nil else { throw CoreIntegrationError.activeSession }
                selectedTab = "GeoBeat"
            case .analyze(let scope):
                if scope == .overall { selectedTab = "Analyze" }
                else { analyzeScope = scope }
            case .startPractice(let pieceID, let divisionID):
                guard recovery == nil, !pendingLegacySession else { throw CoreIntegrationError.activeSession }
                guard let division = events.first(where: { $0.id == divisionID && $0.songID == pieceID }),
                      let definition = division.coreDefinition else { throw CoreIntegrationError.wrongDestination }
                guard runtime.activeID == nil else { throw CoreIntegrationError.activeSession }
                guard definition.canStart(activation: settings.activation(isPro: subscription.isPro)) else {
                    throw CoreFlowError.invalidInput("开启速度阶梯并确认配置，或补充目标次数/目标速度。")
                }
                if definition.handMode.allowsHandSwitching { initialHandRoute = route }
                else { try startPractice(piece: pieceID, division: divisionID) }
            case .resumeSession(let id):
                guard runtime.activeID == id else {
                    throw CoreFlowError.invalidInput("此旧版或独立 Debug 草稿尚不能转为新 Session。选择“暂不恢复”可返回首页添加曲目；旧草稿仍保留，待兼容后处理。")
                }
                runtime.needsRecovery = false
                navigation.path = []
                selectedTab = "Practice"
                if runtime.session.reviewSummary != nil { runtime.continuePractice() }
                else { runtime.pause() }
            case .unarchivePiece(let pieceID):
                guard let piece = songs.first(where: {
                    $0.id == pieceID && $0.deletedAt == nil
                }) else {
                    throw CoreIntegrationError.wrongDestination
                }

                try CoreContracts.unarchivePiece(
                    piece: piece,
                    context: modelContext
                )

                sheetRoute = .archivedPieces
            default:
                guard runtime.activeID == nil && recovery == nil else { throw CoreIntegrationError.activeSession }
                sheetRoute = route
            }
        } catch { boundaryMessage = error.localizedDescription }
    }
    @ViewBuilder private var quickUndo: some View {
        if let id = recentlyDeletedUndoID {
            CoreQuickUndoView(restore: {
                guard let piece = songs.first(where: { $0.id == id && $0.deletedAt != nil }) else { return false }
                do {
                    try CoreContracts.restoreRecentlyDeletedPiece(piece: piece, context: modelContext, isPro: subscription.isPro)
                    return true
                } catch {
                    boundaryMessage = error.localizedDescription
                    return false
                }
            }, finish: { presentationID in
                if undoPresentationID == presentationID { recentlyDeletedUndoID = nil }
            }, presentationID: undoPresentationID)
            .id(undoPresentationID)
        }
    }

    private func startPractice(piece pieceID: UUID, division divisionID: UUID, initialHand: PracticeHand? = nil, confirmedStarts: [PracticeHand: Int]? = nil) throws {
        guard recovery == nil, !pendingLegacySession else { throw CoreIntegrationError.activeSession }
        guard let piece = songs.first(where: { $0.id == pieceID && $0.deletedAt == nil }),
              let division = events.first(where: { $0.id == divisionID && $0.songID == pieceID }) else {
            throw CoreIntegrationError.wrongDestination
        }
        let prepared = try CoreSessionRuntime.prepare(division: division, activation: settings.activation(isPro: subscription.isPro))
        if confirmedStarts == nil && !prepared.needsStart.isEmpty {
            cycleStartRequest = (pieceID, divisionID, initialHand, prepared.definition, prepared.needsStart)
            return
        }
        engine.stop()
        try runtime.begin(piece: piece, division: division, initialHand: initialHand, confirmedStarts: confirmedStarts ?? [:], activation: settings.activation(isPro: subscription.isPro), focusEnabled: settings.focusActivation(isPro: subscription.isPro))
        engine.apply(runtime.preset)
        navigation.enteredPractice(piece: pieceID, division: divisionID)
        selectedTab = "Practice"
    }
    private func loadInitialContext() {
        guard !loaded else { return }
        loaded = true
        engine.apply(runtime.preset)
        if let failure = runtime.failure { boundaryMessage = failure; return }
        if runtime.context != nil { return }
        if let fixture {
            navigation.path = fixture.path
            recovery = fixture.recovery
            return
        }
        let result = CoreDependencies.readRecovery(songs: songs, events: events)
        recovery = result.recovery
        if let gap = result.gap, !pendingLegacySession {
            pendingLegacySession = true
            boundaryMessage = gap
        }
    }
}

private struct CoreScreen<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            let margin: CGFloat = geometry.size.width < 600 ? 16 : geometry.size.width < 840 ? 24 : 32
            ScrollView {
                VStack(alignment: .leading, spacing: 0, content: content)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, margin).padding(.top, 16).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
            }.background(CorePalette.canvas).foregroundStyle(CorePalette.primary)
        }.toolbar(.hidden, for: .navigationBar)
    }
}

// One presentation owns its countdown and success task; removal cancels both.
struct CoreQuickUndoView: View {
    let restore: () -> Bool
    let finish: (UUID) -> Void
    let presentationID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum Focus: Hashable { case message, undo }
    @AccessibilityFocusState private var focus: Focus?
    @State private var bounds = CGSize.zero
    @State private var success = false
    @State private var visible = false
    @State private var exiting = false
    @State private var remaining: TimeInterval = 4
    private var paused: Bool { focus != nil }

    var body: some View {
        ZStack {
            HStack(spacing: 14) {
                Text("已移至最近删除")
                    .accessibilityFocused($focus, equals: .message)
                Button("撤销") {
                    guard !success && !exiting else { return }
                    if restore() {
                        success = true
                    }
                }
                .foregroundStyle(CorePalette.accent)
                .disabled(success || exiting)
                .accessibilityFocused($focus, equals: .undo)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if !success { bounds = size }
            }
            .opacity(success ? 0 : 1)
            .animation(.easeInOut(duration: 0.28), value: success)
            .accessibilityHidden(success)
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(CorePalette.accent)
                .opacity(success ? 1 : 0)
                .animation(.easeInOut(duration: 0.28), value: success)
                .accessibilityLabel("已恢复")
                .accessibilityHidden(!success)
        }
        .frame(width: success ? 32 : (bounds.width > 0 ? bounds.width : nil),
               height: success ? 32 : (bounds.height > 0 ? bounds.height : nil))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: success)
        .clipped()
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(CorePalette.accent.opacity(0.16), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        .opacity(visible ? 1 : 0)
        .offset(y: reduceMotion || visible ? 0 : 4)
        .frame(maxWidth: .infinity)
        .onChange(of: dynamicTypeSize) { _, _ in
            if !success { bounds = .zero }
        }
        .task {
            withAnimation(.easeOut(duration: 0.2)) { visible = true }
        }
        .task(id: success) {
            guard !success else { return }
            let clock = ContinuousClock()
            do {
                while remaining > 0 {
                    let start = clock.now
                    let wasPaused = paused
                    try await clock.sleep(for: .milliseconds(20))
                    guard !Task.isCancelled else { return }
                    if !wasPaused && !paused {
                        let elapsed = start.duration(to: clock.now).components
                        remaining = max(0, remaining - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18)
                    }
                }
                exiting = true
            } catch { }
        }
        .task(id: success) {
            guard success else { return }
            do {
                try await Task.sleep(for: .milliseconds(280))
                try await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                exiting = true
            } catch { }
        }
        .task(id: exiting) {
            guard exiting else { return }
            withAnimation(.easeOut(duration: 0.17)) { visible = false }
            do {
                try await Task.sleep(for: .milliseconds(170))
                guard !Task.isCancelled else { return }
                finish(presentationID)
            } catch { }
        }
    }
}
