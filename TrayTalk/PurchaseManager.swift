import Foundation
import OSLog
import StoreKit

enum PremiumVoicesEntitlementStatus {
    case checking
    case owned
    case notOwned
}

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()
    
    static let premiumVoicesProductID = "com.kriyak.smoothtalker.premiumvoices"
    private static let storefrontDiagnosticsLogger = Logger(
        subsystem: "com.cyberofficeindustries.smoothtalker",
        category: "StoreKitDiagnostics"
    )
    
    @Published private(set) var hasPremiumVoices = false
    @Published private(set) var premiumVoicesEntitlementStatus: PremiumVoicesEntitlementStatus = .checking
    @Published private(set) var premiumVoicesProduct: Product?
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    
    private var transactionUpdatesTask: Task<Void, Never>?
    private var hasStarted = false
    private var isRefreshing = false
    
    private init() {}
    
    deinit {
        transactionUpdatesTask?.cancel()
    }
    
    func start() async {
        startTransactionUpdatesIfNeeded()
        await refresh()
    }

    private func startTransactionUpdatesIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(transactionResult: result)
            }
        }
    }
    
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = true
        defer {
            isRefreshing = false
            isLoading = false
        }
        
        await refreshPremiumVoicesEntitlement()
        _ = try? await loadPremiumVoicesProduct()
    }
    
    func purchasePremiumVoices() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let product = try await premiumProduct()
            await logCurrentStorefront(context: "before Premium Voices purchase")
            let result = try await product.purchase()
            
            switch result {
            case .success(let verificationResult):
                let transaction = try checkVerified(verificationResult)
                guard transaction.productID == Self.premiumVoicesProductID else {
                    throw PurchaseError.unexpectedProduct
                }

                hasPremiumVoices = true
                premiumVoicesEntitlementStatus = .owned
                await transaction.finish()
                await refreshPremiumVoicesEntitlement()
                statusMessage = hasPremiumVoices ? "Premium voices unlocked." : "Purchase completed, but access is still pending."
            case .userCancelled:
                statusMessage = nil
            case .pending:
                statusMessage = "Purchase is pending approval."
            @unknown default:
                statusMessage = "Purchase could not be completed."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
    
    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            try await AppStore.sync()
            await refreshPremiumVoicesEntitlement()
            statusMessage = hasPremiumVoices ? "Purchases restored." : "No premium voice purchase was found."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
    
    func clearStatusMessage() {
        statusMessage = nil
    }
    
    private func handle(transactionResult: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(transactionResult),
              transaction.productID == Self.premiumVoicesProductID else {
            return
        }
        
        hasPremiumVoices = transaction.revocationDate == nil
        premiumVoicesEntitlementStatus = hasPremiumVoices ? .owned : .notOwned
        await transaction.finish()
        await refreshPremiumVoicesEntitlement()
    }
    
    @discardableResult
    private func loadPremiumVoicesProduct() async throws -> Product {
        await logCurrentStorefront(context: "before Premium Voices product load")
        let products = try await Product.products(for: [Self.premiumVoicesProductID])
        guard let product = products.first else {
            throw PurchaseError.productUnavailable
        }
        
        premiumVoicesProduct = product
        return product
    }
    
    private func premiumProduct() async throws -> Product {
        if let premiumVoicesProduct {
            return premiumVoicesProduct
        }
        
        return try await loadPremiumVoicesProduct()
    }
    
    private func refreshPremiumVoicesEntitlement() async {
        premiumVoicesEntitlementStatus = .checking
        var isUnlocked = false
        
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result),
                  transaction.productID == Self.premiumVoicesProductID,
                  transaction.revocationDate == nil else {
                continue
            }
            
            isUnlocked = true
            break
        }
        
        hasPremiumVoices = isUnlocked
        premiumVoicesEntitlementStatus = isUnlocked ? .owned : .notOwned
    }

    private func logCurrentStorefront(context: String) async {
        let countryCode = await Storefront.current?.countryCode ?? "nil"
        Self.storefrontDiagnosticsLogger.notice(
            "StoreKit storefront \(context): countryCode=\(countryCode, privacy: .public)"
        )
    }
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let verified):
            return verified
        case .unverified:
            throw PurchaseError.failedVerification
        }
    }
}

private enum PurchaseError: LocalizedError {
    case failedVerification
    case productUnavailable
    case unexpectedProduct
    
    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "The App Store could not verify this purchase."
        case .productUnavailable:
            return "Premium voices are not available yet."
        case .unexpectedProduct:
            return "The App Store returned a purchase that Smooth Talker could not recognize."
        }
    }
}
