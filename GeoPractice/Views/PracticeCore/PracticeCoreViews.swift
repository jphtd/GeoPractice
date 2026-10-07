import Combine
import SwiftData
import SwiftUI

struct PracticeCoreRootView: View {
    @Query(sort: [SortDescriptor(\PracticeSong.sortIndex), SortDescriptor(\PracticeSong.createdAt)]) private var songs: [PracticeSong]
    @Query private var events: [PracticeEvent]
    @StateObject private var navigation = CoreNavigation()
    @State private var boundaryMessage: String?
    @State private var recovery: CoreRecovery?
    @State private var pendingLegacySession = false
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var runtime: CoreSessionRuntime
    @StateObject private var engine = MetronomeEngine()
    @State private var selectedTab = "Practice"
    @State private var sheetRoute: CoreRoute?
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
    }

    private var currentPieces: [PracticeSong] {
        songs.filter { !$0.isArchived && $0.deletedAt == nil }
    }
    var body: some View {
        Group {
            if selectedTab == "GeoBeat" {
                NavigationStack {
                    CoreSessionView(
                        runtime: runtime,
                        engine: engine,
                        isGeoBeat: true,
                        openGeoBeat: {},
                        finish: finishSession,
                        onRoute: request
                    )
                }
            } else if selectedTab == "Analyze" {
                NavigationStack { CoreAnalyzeView(scope: .overall) }
            } else {
                practiceStack
            }
        }
        .tint(CorePalette.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if sheetRoute == nil { quickUndo }
                CoreBottomNavigation(
                    activeSessionID: runtime.activeID ?? recovery?.sessionID,
                    selectedTab: selectedTab,
                    onPractice: { selectedTab = "Practice" },
                    onRoute: request
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if fixture != nil { Text("Debug 场景 · 数据不持久保存。真实流程测试请关闭启动参数。")
                .font(.caption).padding(8).frame(maxWidth: .infinity).background(.yellow.opacity(0.15)) }
        }
        .sheet(isPresented: Binding(get: { sheetRoute != nil }, set: { if !$0 { sheetRoute = nil; navigation.cancel() } })) {
            if let sheetRoute {
                switch sheetRoute {
                case .archivedPieces:
                    CoreArchiveView(activeSessionID: runtime.activeID ?? recovery?.sessionID, onRoute: request)
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
                            case .archivePiece(let id), .deletePiece(let id):
                                self.sheetRoute = .pieceSettings(id)

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
        .onAppear { expireDeletedPieces(); loadInitialContext() }
        .onReceive(checkpoint) { _ in runtime.persist(); expireDeletedPieces() }
        .onChange(of: engine.preset) { _, value in runtime.updatePreset(value) }
        .onChange(of: engine.isPlaying) { previous, current in
            if previous && !current { runtime.pause() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { engine.pause(); runtime.pause() }
            else { expireDeletedPieces() }
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
                        openGeoBeat: { selectedTab = "GeoBeat" }, finish: finishSession, onRoute: request)
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
                       let division = events.first(where: { $0.id == divisionID && $0.songID == pieceID }),
                       let definition = division.coreDefinition {
                        divisionDetail(piece, division: division, definition: definition, structure: structure)
                    }
                case .recentlyDeleted:
                    if subscription.isPro { CoreRecentlyDeletedView() }
                }
            }
        }
    }

    @ViewBuilder private var home: some View {
        let state = CoreHomeState.resolve(pieceCount: currentPieces.count, recovery: currentRecovery)
        CorePageHeader(title: "Practice", trailing: currentRecovery == nil ? "plus" : nil, trailingLabel: "添加曲目") { request(.addPiece) }
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
                CoreEmptyState(title: "还没有曲目", copy: "添加你的第一首曲目，开始建立练习计划。", button: "添加曲目") {
                    request(.addPiece)
                }.padding(.top, 24).accessibilityIdentifier("practice.empty")
                if !songs.isEmpty {
                    CoreButton(title: "查看全部曲目", kind: .tertiary) { request(.allPieces) }
                }
            case .recovery(let session):
                VStack(alignment: .leading, spacing: 16) {
                    Text("练习已暂停").coreType(.caption).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(CorePalette.subtle, in: Capsule())
                    Text("继续练习").coreType(.titleMedium)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.pieceName).coreType(.titleSmall)
                        Text(session.divisionName).coreType(.body).foregroundStyle(CorePalette.secondary)
                    }
                    Text("恢复后继续当前练习").coreType(.body).foregroundStyle(CorePalette.secondary)
                    CoreButton(title: "继续练习") { request(.resumeSession(session.sessionID)) }
                    if canDeferLegacyRecovery {
                        CoreButton(title: "暂不恢复", kind: .secondary, action: deferLegacyRecovery)
                            .accessibilityIdentifier("practice.deferRecovery")
                        Text("旧草稿仍会保留。暂不恢复后，可返回首页添加曲目。").coreType(.caption).foregroundStyle(CorePalette.secondary)
                    }
                }.coreCard().accessibilityIdentifier("practice.recovery")
            }
        }.padding(.top, 24)
        if currentRecovery == nil {
            CoreButton(title: "已归档曲目", kind: .tertiary) { request(.archivedPieces) }
        }
    }

    private func pieceDetail(_ piece: PracticeSong, structure: CorePieceStructure) -> some View {
        let divisions = events.filter { $0.songID == piece.id }.sorted {
            ($0.coreDefinition?.first ?? Int.max) < ($1.coreDefinition?.first ?? Int.max)
        }
        return CoreScreen {
            CorePageHeader(title: "曲目详情", back: back, trailing: "gearshape", trailingLabel: "曲目设置") { request(.pieceSettings(piece.id)) }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(piece.name).coreType(.titleLarge).accessibilityAddTraits(.isHeader)
                    Text(structure.label).coreType(.body).foregroundStyle(CorePalette.secondary)
                }
                CoreNavigationRow { request(.analyze(.piece(piece.id))) }.padding(.top, 24)
                VStack(alignment: .leading, spacing: 12) {
                    section("练习划分")
                    if divisions.isEmpty {
                        CoreEmptyState(title: "还没有练习划分", copy: "创建练习划分时可同时设置 Goal，也可以稍后设置。", button: "创建练习划分") {
                            request(.createDivision(piece: piece.id, mode: structure.mode))
                        }.accessibilityIdentifier("piece.noDivision")
                    } else {
                        ForEach(divisions) { division in
                            CoreActionCard(title: division.coreDefinition?.label(mode: structure.mode) ?? division.name) {
                                guard let definition = division.coreDefinition, definition.fits(structure) else {
                                    boundaryMessage = CoreIntegrationError.missingMetadata.localizedDescription
                                    return
                                }
                                navigation.path.append(.division(piece: piece.id, division: division.id))
                            }
                        }
                        CoreButton(title: "创建练习划分", kind: .secondary) {
                            request(.createDivision(piece: piece.id, mode: structure.mode))
                        }
                    }
                }.padding(.top, 32)
            }.padding(.top, 20)
        }
    }

    private func divisionDetail(_ piece: PracticeSong, division: PracticeEvent,
                                definition: CoreDivisionDefinition, structure: CorePieceStructure) -> some View {
        CoreScreen {
            CorePageHeader(title: "练习划分详情", back: back)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("《\(piece.name)》").coreType(.body).foregroundStyle(CorePalette.secondary)
                    Text(definition.label(mode: structure.mode)).coreType(.titleLarge).accessibilityAddTraits(.isHeader)
                    Text("适用手型 · \(definition.handMode.label)").coreType(.body).foregroundStyle(CorePalette.secondary)
                }
                CoreNavigationRow(title: "编辑练习划分") {
                    request(.editDivision(piece: piece.id, division: division.id))
                }
                .padding(.top, 24)
                VStack(alignment: .leading, spacing: 12) {
                    section("Goal")
                    if definition.hasValidGoal {
                        CoreActionCard(title: "Goal", subtitle: "已设置") { request(.editGoal(piece: piece.id, division: division.id)) }
                            .accessibilityLabel("Goal，已设置，编辑 Goal")
                            .accessibilityIdentifier("division.validGoal")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("还没有设置 Goal").coreType(.titleSmall)
                            Text("建立有效 Goal 后即可开始计划练习。").coreType(.body).foregroundStyle(CorePalette.secondary)
                            CoreButton(title: "设置 Goal") { request(.editGoal(piece: piece.id, division: division.id)) }
                        }.coreCard().accessibilityIdentifier("division.noValidGoal")
                    }
                }.padding(.top, 24)
                VStack(alignment: .leading, spacing: 12) {
                    section("练习")
                    if definition.hasValidGoal {
                        CoreButton(title: "开始计划练习") {
                            do {
                                request(try CoreContracts.startRoute(piece: piece.id, division: division.id, definition: definition,
                                                                     activeSessionID: runtime.activeID ?? recovery?.sessionID))
                            } catch { boundaryMessage = error.localizedDescription }
                        }
                    }
                    CoreButton(title: "自由练习", kind: .secondary) { request(.freePractice) }
                }.padding(.top, 32)
                CoreNavigationRow { request(.analyze(.division(piece: piece.id, division: division.id))) }.padding(.top, 32)
            }.padding(.top, 20)
        }
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

        switch page {
        case .piece:
            navigation.path = [page]

        case .division(let piece, _):
            navigation.path = [.piece(piece), page]

        case .recentlyDeleted:
            navigation.path = [.recentlyDeleted]
        }

        navigation.cancel()
        recovery = nil
    }
    private func finishSession() {
        exitError = nil
        do { try runtime.requestExit(.ordinary) }
        catch { boundaryMessage = error.localizedDescription }
    }
    private func resolveExit(_ choice: CoreExitChoice) {
        guard let id = runtime.context?.divisionID, let division = events.first(where: { $0.id == id }) else { return }
        do {
            exitDestination = try runtime.resolveExit(choice, division: division, in: modelContext)
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
                    guarded = division != context.divisionID || piece != context.pieceID
                case .archivePiece(let piece), .deletePiece(let piece): guarded = piece == context.pieceID
                case .deleteAllArchivedPieces:
                    guarded = songs.contains { $0.id == context.pieceID && $0.isArchived && $0.deletedAt == nil }
                case .editDivision: guarded = true
                default: guarded = false
                }
                if guarded {
                    exitError = nil
                    try runtime.requestExit(.transition(route))
                    return
                }
            }
            switch route {
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
                guard definition.hasValidGoal else { throw CoreIntegrationError.invalidGoal }
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
                else { runtime.resume() }
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
        let prepared = try CoreSessionRuntime.prepare(division: division)
        if confirmedStarts == nil && !prepared.needsStart.isEmpty {
            cycleStartRequest = (pieceID, divisionID, initialHand, prepared.definition, prepared.needsStart)
            return
        }
        try runtime.begin(piece: piece, division: division, initialHand: initialHand, confirmedStarts: confirmedStarts ?? [:])
        engine.stop()
        engine.apply(runtime.preset)
        navigation.path = []
        navigation.cancel()
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
private struct CoreQuickUndoView: View {
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
