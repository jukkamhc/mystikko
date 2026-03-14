//
//  SubscriptionManager.swift
//  Narcissus
//
//  Created by Jukka Erätuli on 28.2.2026.
//

import StoreKit

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPremium = false

    static let monthlyId = "com.jukka.narcissus.pro.monthly"
    static let yearlyId  = "com.jukka.narcissus.pro.yearly"
    private let productIds: Set<String> = [monthlyId, yearlyId]

    private var updateTask: Task<Void, Never>?

    private init() {
        updateTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
        Task {
            await checkEntitlements()
            await loadProducts()
        }
    }

    deinit { updateTask?.cancel() }

    // MARK: - Load products from App Store / StoreKit config
    func loadProducts() async {
        do {
            products = try await Product.products(for: productIds)
                .sorted { $0.price < $1.price }  // monthly first
        } catch {
            print("[Store] Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase
    func purchase(_ productId: String? = nil) async throws -> Bool {
        if products.isEmpty { await loadProducts() }

        let target: Product?
        if let id = productId {
            target = products.first { $0.id == id }
        } else {
            // Default to monthly
            target = products.first { $0.id == Self.monthlyId } ?? products.first
        }

        guard let product = target else {
            throw StoreError.productNotFound
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await checkEntitlements()
            return true
        case .userCancelled:
            return false
        case .pending:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Restore
    func restorePurchases() async {
        try? await AppStore.sync()
        await checkEntitlements()
    }

    // MARK: - Entitlements
    func checkEntitlements() async {
        var hasPremium = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               productIds.contains(transaction.productID) {
                hasPremium = true
                break
            }
        }
        isPremium = hasPremium
    }

    // MARK: - Transaction listener (runs for lifetime of app)
    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
                await checkEntitlements()
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    enum StoreError: LocalizedError {
        case productNotFound
        var errorDescription: String? {
            switch self {
            case .productNotFound:
                return "Subscription product not available"
            }
        }
    }
}
