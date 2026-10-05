import Combine
import Foundation
import StoreKit

struct SubscriptionEntitlementSnapshot: Equatable, Sendable {
    let productID: String
    let expirationDate: Date?
    let revocationDate: Date?
    let isUpgraded: Bool
}

enum SubscriptionEntitlementResolver {
    static func grantsAccess(
        snapshots: [SubscriptionEntitlementSnapshot],
        supportedProductIDs: Set<String>,
        now: Date
    ) -> Bool {
        snapshots.contains { snapshot in
            guard supportedProductIDs.contains(snapshot.productID),
                  snapshot.revocationDate == nil,
                  !snapshot.isUpgraded
            else {
                return false
            }
            guard let expirationDate = snapshot.expirationDate else {
                return true
            }
            return expirationDate > now
        }
    }
}

enum SubscriptionProductCatalog {
    static let monthlyProductID = "com.geobeat.pro.monthly"
    static let yearlyProductID = "com.geobeat.pro.yearly"
    static let supportedProductIDs: Set<String> = [
        monthlyProductID,
        yearlyProductID
    ]
}

/// App-wide StoreKit 2 state. Apple-verified transactions are the only source
/// of truth; subscription access is intentionally not copied into app storage
/// or iCloud where it could become stale.
@MainActor
final class SubscriptionStore: ObservableObject {
    enum AccessState: Equatable {
        case checking
        case entitled
        case notEntitled
    }

    enum ProductLoadState: Equatable {
        case idle
        case loading
        case loaded
        case partial
        case failed
    }

    static let shared = SubscriptionStore()

    @Published private(set) var products: [Product] = []
    @Published private(set) var accessState: AccessState = .checking
    @Published private(set) var productLoadState: ProductLoadState = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    var effectiveAccessState: AccessState {
    #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-practice-core-pro") {
            return .entitled
        }
    #endif
        return accessState
    }

    var isPro: Bool { effectiveAccessState == .entitled }
    var canMakePayments: Bool { AppStore.canMakePayments }

    private var isPreparing = false
    private var updatesTask: Task<Void, Never>?
    private var entitlementRefreshTask: Task<Void, Never>?

    init(observesTransactions: Bool = true) {
        if observesTransactions {
            updatesTask = Task { [weak self] in
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    guard let self else { break }
                    await self.handleTransactionUpdate(result)
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
        entitlementRefreshTask?.cancel()
    }

    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        await refreshEntitlements()
        await loadProducts()
    }

    func purchase(_ product: Product) async {
        guard SubscriptionProductCatalog.supportedProductIDs.contains(product.id), !isBusy else {
            return
        }
        guard canMakePayments else {
            message = "此设备当前不允许 App Store 购买，请检查屏幕使用时间或账户限制。"
            return
        }

        isBusy = true
        message = nil
        defer { isBusy = false }

        do {
            switch try await product.purchase() {
            case .success(let result):
                switch result {
                case .verified(let transaction):
                    let purchasedEntitlement = SubscriptionEntitlementSnapshot(
                        productID: transaction.productID,
                        expirationDate: transaction.expirationDate,
                        revocationDate: transaction.revocationDate,
                        isUpgraded: transaction.isUpgraded
                    )
                    if SubscriptionEntitlementResolver.grantsAccess(
                        snapshots: [purchasedEntitlement],
                        supportedProductIDs: SubscriptionProductCatalog.supportedProductIDs,
                        now: .now
                    ) {
                        accessState = .entitled
                    }

                    await transaction.finish()
                    await refreshEntitlements()
                    message = isPro
                        ? "GeoBeat PRO 已启用。"
                        : "购买已完成，订阅状态正在由 App Store 更新。"
                case .unverified:
                    message = "这笔购买未能通过 App Store 验证，专业版功能尚未启用。"
                }
            case .pending:
                message = "购买正在等待批准，完成后会自动启用专业版功能。"
            case .userCancelled:
                break
            @unknown default:
                message = "购买状态暂时无法确认，请稍后重试。"
            }
        } catch {
            message = "购买未完成，请检查网络或 App Store 账户后重试。"
        }
    }

    /// `AppStore.sync()` can show an account prompt, so this method is called
    /// only from the user's explicit “恢复购买” action.
    func restorePurchases() async {
        guard !isBusy else { return }

        isBusy = true
        message = nil
        defer { isBusy = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = isPro ? "购买记录已恢复。" : "没有找到可恢复的 GeoBeat PRO 订阅。"
        } catch {
            message = "恢复购买未完成，请检查网络或 App Store 账户后重试。"
        }
    }

    func clearMessage() {
        message = nil
    }

    private func loadProducts() async {
        productLoadState = .loading
        do {
            let fetchedProducts = try await Product.products(
                for: Array(SubscriptionProductCatalog.supportedProductIDs)
            )
            products = fetchedProducts.sorted { lhs, rhs in
                lhs.price < rhs.price
            }
            if products.isEmpty {
                productLoadState = .failed
                message = "当前 App Store 暂未返回可购买的订阅方案，请稍后重试。"
            } else if Set(products.map(\.id)) != SubscriptionProductCatalog.supportedProductIDs {
                productLoadState = .partial
                message = "部分订阅方案暂不可用，已显示当前可购买的方案。"
            } else {
                productLoadState = .loaded
                message = nil
            }
        } catch {
            products = []
            productLoadState = .failed
            message = "暂时无法连接 App Store，请检查网络后重试。"
        }
    }

    /// Revalidates access against Apple's current entitlement stream. The app
    /// calls this at launch, after StoreKit events, and whenever it returns to
    /// the foreground so an expired or refunded subscription cannot leave a
    /// stale unlocked UI behind.
    func refreshEntitlements() async {
        var snapshots: [SubscriptionEntitlementSnapshot] = []
        var supportedExpirationDates: [Date] = []

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }

            // `currentEntitlements` already excludes expired auto-renewable
            // subscriptions while retaining subscriptions in grace period.
            // Do not re-check its expiration date here or grace-period users
            // would incorrectly lose access.
            snapshots.append(
                SubscriptionEntitlementSnapshot(
                    productID: transaction.productID,
                    expirationDate: nil,
                    revocationDate: transaction.revocationDate,
                    isUpgraded: transaction.isUpgraded
                )
            )
            if SubscriptionProductCatalog.supportedProductIDs.contains(transaction.productID),
               transaction.revocationDate == nil,
               !transaction.isUpgraded,
               let expirationDate = transaction.expirationDate {
                supportedExpirationDates.append(expirationDate)
            }
        }

        let now = Date.now
        accessState = SubscriptionEntitlementResolver.grantsAccess(
            snapshots: snapshots,
            supportedProductIDs: SubscriptionProductCatalog.supportedProductIDs,
            now: now
        ) ? .entitled : .notEntitled
        scheduleEntitlementRefresh(
            expirationDates: supportedExpirationDates,
            now: now
        )
    }

    private func scheduleEntitlementRefresh(
        expirationDates: [Date],
        now: Date
    ) {
        entitlementRefreshTask?.cancel()
        entitlementRefreshTask = nil
        guard isPro, !expirationDates.isEmpty else { return }

        // Recheck at the paid-through boundary. If StoreKit still reports the
        // entitlement with a past expiration date it is in a grace/retry state;
        // poll conservatively until StoreKit removes it or posts an update.
        let nextFutureExpiration = expirationDates
            .filter { $0 > now }
            .min()
        let delay = nextFutureExpiration.map {
            max(1, $0.timeIntervalSince(now) + 1)
        } ?? 15 * 60

        entitlementRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.refreshEntitlements()
        }
    }

    private func handleTransactionUpdate(
        _ result: VerificationResult<Transaction>
    ) async {
        switch result {
        case .verified(let transaction):
            guard SubscriptionProductCatalog.supportedProductIDs.contains(transaction.productID) else {
                return
            }
            await transaction.finish()
            await refreshEntitlements()
        case .unverified:
            message = "一笔订阅更新未能通过 App Store 验证，当前权益没有改变。"
            await refreshEntitlements()
        }
    }
}
