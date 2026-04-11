//
//  EntitlementManager.swift
//  VoiceFlow
//
//  StoreKit 2 glue. Tracks which tier the user is on, exposes a
//  `hasPro` Published property every gated feature checks, and owns
//  the free-tier daily word counter.
//
//  Products (must also be declared in App Store Connect AND in the
//  local StoreKit configuration file):
//    voiceflow.pro.monthly   - $12/mo  (7-day free trial on first
//                                       subscribe)
//    voiceflow.pro.yearly    - $96/yr
//    voiceflow.pro.lifetime  - $199 one-time non-consumable
//
//  For development before App Store Connect is set up, drop a
//  `Products.storekit` file into the project and point the scheme's
//  "StoreKit Configuration" at it so purchases run locally.
//

import Foundation
import StoreKit
import Combine

@MainActor
final class EntitlementManager: ObservableObject {

    // MARK: - Shared singleton

    /// Convenience singleton so callsites like
    /// `EntitlementManager.shared.hasPro` work from anywhere without
    /// threading it through the environment.
    static let shared = EntitlementManager()

    // MARK: - Published state

    @Published private(set) var tier: SubscriptionTier = .free
    @Published private(set) var hasPro: Bool = false

    /// StoreKit Products fetched from the App Store / local config.
    @Published private(set) var products: [SubscriptionProduct: Product] = [:]

    /// Whether we're currently fetching products or processing a
    /// purchase. Drives the paywall spinner.
    @Published private(set) var isLoading: Bool = false

    /// Error surfaced from the last purchase / restore attempt.
    @Published var lastError: String?

    /// Free-tier word cap accounting.
    @Published private(set) var freeWordsUsedToday: Int = 0

    /// Date string of the day `freeWordsUsedToday` is associated with.
    /// When `todayKey()` no longer matches this, we reset.
    @Published private(set) var usageDayKey: String = ""

    // MARK: - Persistence

    private let wordsUsedKey = "VoiceFlow.freeWordsUsedToday"
    private let wordsDayKey  = "VoiceFlow.freeWordsDayKey"
    private let trialUsedKey = "VoiceFlow.trialPresented"

    // MARK: - StoreKit transaction listener task

    private var transactionListenerTask: Task<Void, Never>?

    // MARK: - Init

    private init() {
        loadDailyUsageFromDefaults()
        transactionListenerTask = makeTransactionListener()
        Task { await refresh() }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Product loading & purchase

    /// Fetch product metadata from StoreKit. Safe to call repeatedly.
    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        let ids = SubscriptionProduct.allCases.map { $0.rawValue }
        do {
            let fetched = try await Product.products(for: ids)
            var map: [SubscriptionProduct: Product] = [:]
            for product in fetched {
                if let key = SubscriptionProduct(rawValue: product.id) {
                    map[key] = product
                }
            }
            self.products = map
        } catch {
            self.lastError = "Failed to load products: \(error.localizedDescription)"
        }
    }

    /// Kick off a purchase for the given plan.
    func purchase(_ plan: SubscriptionProduct) async {
        guard let product = products[plan] else {
            lastError = "Product \(plan.rawValue) not available."
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refresh()
                }
            case .userCancelled:
                break
            case .pending:
                lastError = "Purchase pending approval."
            @unknown default:
                break
            }
        } catch {
            lastError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    /// Restore purchases — used by the "Restore Purchases" button on
    /// the paywall.
    func restore() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refresh()
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Walk the user's current entitlements and flip `hasPro`.
    func refresh() async {
        await loadProducts()

        var pro = false
        for await verification in Transaction.currentEntitlements {
            if case .verified(let transaction) = verification {
                if SubscriptionProduct(rawValue: transaction.productID) != nil {
                    pro = true
                }
            }
        }
        self.hasPro = pro
        self.tier = pro ? .pro : .free
    }

    // MARK: - First-launch free trial

    var hasSeenTrialOffer: Bool {
        UserDefaults.standard.bool(forKey: trialUsedKey)
    }

    func markTrialOfferShown() {
        UserDefaults.standard.set(true, forKey: trialUsedKey)
    }

    // MARK: - Transaction listener

    private func makeTransactionListener() -> Task<Void, Never> {
        Task.detached {
            for await verification in Transaction.updates {
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await MainActor.run { [weak self] in
                        Task { await self?.refresh() }
                    }
                }
            }
        }
    }

    // MARK: - Free-tier word counting

    /// Returns `true` if the user has remaining free-tier word budget
    /// for today.
    func canConsumeFreeWords(_ n: Int) -> Bool {
        rolloverIfNewDay()
        return (freeWordsUsedToday + n) <= FreeTierLimits.dailyWordLimit
    }

    /// Consume N words from the free-tier daily budget. Call-site
    /// should have already checked `canConsumeFreeWords`.
    func consumeFreeWords(_ n: Int) {
        rolloverIfNewDay()
        freeWordsUsedToday += n
        UserDefaults.standard.set(freeWordsUsedToday, forKey: wordsUsedKey)
    }

    func freeWordsRemaining() -> Int {
        rolloverIfNewDay()
        return max(0, FreeTierLimits.dailyWordLimit - freeWordsUsedToday)
    }

    private func loadDailyUsageFromDefaults() {
        self.usageDayKey = UserDefaults.standard.string(forKey: wordsDayKey) ?? ""
        self.freeWordsUsedToday = UserDefaults.standard.integer(forKey: wordsUsedKey)
        rolloverIfNewDay()
    }

    private func rolloverIfNewDay() {
        let key = Self.todayKey()
        if usageDayKey != key {
            usageDayKey = key
            freeWordsUsedToday = 0
            UserDefaults.standard.set(key, forKey: wordsDayKey)
            UserDefaults.standard.set(0, forKey: wordsUsedKey)
        }
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }
}
