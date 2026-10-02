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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var runtime: CoreSessionRuntime
    @StateObject private var engine = MetronomeEngine()
    @State private var selectedTab = "Practice"
    @State private var sheetRoute: CoreRoute?
    @State private var initialHandRoute: CoreRoute?
    @State private var analyzeScope: CoreAnalyzeContext?
    @State private var resultDestination: CoreResultDestination?
    @State private var loaded = false
    private let checkpoint = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    let fixture: CoreFixture?

    init(fixture: CoreFixture? = nil) {
        self.fixture = fixture
        let defaults = fixture == nil ? UserDefaults.standard : UserDefaults(suiteName: "CoreFixture.\(UUID())")!
        _runtime = StateObject(wrappedValue: CoreSessionRuntime(defaults: defaults, restore: fixture == nil))
    }

    private var currentPieces: [PracticeSong] { songs.filter { !$0.isArchived } }

    var body: some View {
        Group {
            if selectedTab == "GeoBeat" {
                CoreSessionView(runtime: runtime, engine: engine, isGeoBeat: true,
                    openGeoBeat: {}, finish: finishSession)
            } else if selectedTab == "Analyze" {
                NavigationStack { CoreAnalyzeView(scope: .overall) }
            } else {
                practiceStack
            }
        }
        .tint(CorePalette.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CoreBottomNavigation(activeSessionID: runtime.activeID ?? recovery?.sessionID,
                selectedTab: selectedTab, onPractice: { selectedTab = "Practice" }, onRoute: request)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if fixture != nil { Text("Debug 场景 · 数据不持久保存。真实流程测试请关闭启动参数。")
                .font(.caption).padding(8).frame(maxWidth: .infinity).background(.yellow.opacity(0.15)) }
        }
        .sheet(isPresented: Binding(get: { sheetRoute != nil }, set: { if !$0 { sheetRoute = nil; navigation.cancel() } })) {
            if let sheetRoute {
                CoreEditorView(route: sheetRoute, songs: songs, events: events,
                    activeSessionID: runtime.activeID ?? recovery?.sessionID, onSaved: returnFromEditor)
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
        .sheet(isPresented: Binding(get: { initialHandRoute != nil }, set: { if !$0 { initialHandRoute = nil; navigation.cancel() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择练习手型").coreType(.titleMedium).accessibilityAddTraits(.isHeader)
                Text("选择本次练习首先记录的手型。").coreType(.body).foregroundStyle(CorePalette.secondary)
                ForEach(CoreHandMode.all.hands) { hand in
                    CoreButton(title: hand.title, kind: .secondary) {
                        guard case .startPractice(let piece, let division) = initialHandRoute else { return }
                        do {
                            try startPractice(piece: piece, division: division, initialHand: hand)
                            initialHandRoute = nil
                        } catch { initialHandRoute = nil; boundaryMessage = error.localizedDescription }
                    }.accessibilityIdentifier("core.initialHand.\(hand.rawValue)")
                }
                CoreButton(title: "取消", kind: .tertiary) { initialHandRoute = nil; navigation.cancel() }
            }.padding(24).frame(maxWidth: 720).presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .accessibilityIdentifier("core.initialHand.sheet")
        }
        .sheet(item: $resultDestination) { destination in
            CoreResultView(runtime: runtime, destination: destination, onReturn: returnFromEditor)
        }
        .alert("操作提示", isPresented: Binding(get: { boundaryMessage != nil }, set: { if !$0 { boundaryMessage = nil } })) {
            if canDeferLegacyRecovery { Button("暂不恢复", action: deferLegacyRecovery) }
            Button("返回", role: .cancel) { boundaryMessage = nil; navigation.cancel() }
        } message: { Text(boundaryMessage ?? "") }
        .onAppear { loadInitialContext() }
        .onReceive(checkpoint) { _ in runtime.persist() }
        .onChange(of: engine.preset) { _, value in runtime.updatePreset(value) }
        .onChange(of: engine.isPlaying) { previous, current in
            if previous && !current { runtime.pause() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { engine.pause(); runtime.pause() }
        }
    }

    private var practiceStack: some View {
        NavigationStack(path: $navigation.path) {
            Group {
                if runtime.context != nil && !runtime.needsRecovery {
                    CoreSessionView(runtime: runtime, engine: engine, isGeoBeat: false,
                        openGeoBeat: { selectedTab = "GeoBeat" }, finish: finishSession)
                } else { CoreScreen { home } }
            }
            .navigationDestination(for: CorePage.self) { page in
                switch page {
                case .piece(let id):
                    if let piece = songs.first(where: { $0.id == id }), let structure = piece.coreStructure {
                        pieceDetail(piece, structure: structure)
                    }
                case .division(let pieceID, let divisionID):
                    if let piece = songs.first(where: { $0.id == pieceID }),
                       let structure = piece.coreStructure,
                       let division = events.first(where: { $0.id == divisionID && $0.songID == pieceID }),
                       let definition = division.coreDefinition {
                        divisionDetail(piece, division: division, definition: definition, structure: structure)
                    }
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
                        CoreEmptyState(title: "还没有练习划分", copy: "进入划分详情后可设置 Goal；建立有效 Goal 后即可开始计划练习。", button: "创建练习划分") {
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
        case .piece: navigation.path = [page]
        case .division(let piece, _): navigation.path = [.piece(piece), page]
        }
        navigation.cancel()
        recovery = nil
    }
    private func finishSession() {
        guard let context = runtime.context else { return }
        engine.stop()
        runtime.finish()
        resultDestination = CoreResultDestination(context: context)
    }
    private func request(_ route: CoreRoute) {
        navigation.request(route)
        do {
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
                if runtime.session.reviewSummary != nil, let context = runtime.context {
                    resultDestination = CoreResultDestination(context: context)
                } else { runtime.resume() }
            default:
                guard runtime.activeID == nil && recovery == nil else { throw CoreIntegrationError.activeSession }
                sheetRoute = route
            }
        } catch { boundaryMessage = error.localizedDescription }
    }
    private func startPractice(piece pieceID: UUID, division divisionID: UUID, initialHand: PracticeHand? = nil) throws {
        guard recovery == nil, !pendingLegacySession else { throw CoreIntegrationError.activeSession }
        guard let piece = songs.first(where: { $0.id == pieceID }),
              let division = events.first(where: { $0.id == divisionID && $0.songID == pieceID }) else {
            throw CoreIntegrationError.wrongDestination
        }
        try runtime.begin(piece: piece, division: division, initialHand: initialHand)
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
