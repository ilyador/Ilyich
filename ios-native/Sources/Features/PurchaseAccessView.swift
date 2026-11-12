import StoreKit
import SwiftUI

private struct PurchaseStoreKey: EnvironmentKey {
    static let defaultValue: PurchaseStore? = nil
}

extension EnvironmentValues {
    var purchaseStore: PurchaseStore? {
        get { self[PurchaseStoreKey.self] }
        set { self[PurchaseStoreKey.self] = newValue }
    }
}

/// The same purchase controls stay available before sign-in and inside Settings. Server accounts
/// and App Store purchases are separate; this screen never opens an account runtime itself.
struct PurchaseAccessView: View {
    let store: PurchaseStore
    var session: AccountSession? = nil
    @State private var managingSubscriptions = false
    @State private var lifetimeConfirmation: Product?
    @State private var feedback: String?

    private var busy: Bool { store.isPurchasing || store.isRestoring }
    private var entitlement: PurchaseEntitlement? {
        if case .unlocked(let entitlement) = store.state { return entitlement }
        return nil
    }
    private var ownsLifetime: Bool { entitlement?.isLifetime == true }
    private var canPurchase: Bool {
        switch store.state {
        case .locked, .unlocked: !ownsLifetime
        case .checking, .unavailable: false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image("IlyichLogo").resizable().scaledToFit().frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 13)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Full access to Ilyich").font(.title2.bold())
                        Text("Browse, organize and back up your photo library.").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Your own photo server is required", systemImage: "server.rack").font(.headline)
                    Text("You need a compatible photo server running version 3.3.0 or later and an existing server account. This purchase unlocks the iPhone app; photo hosting is not included.")
                        .foregroundStyle(.secondary)
                    Link("Server setup and compatibility", destination: URL(string: "https://github.com/ilyador/Ilyich/blob/dev/ios-native/SUPPORT.md")!)
                        .font(.footnote)
                }
                accessStatus
                if let text = feedback ?? store.message {
                    Text(text).font(.callout).accessibilityIdentifier("purchase.message")
                }
                if !ownsLifetime { products }
                purchaseControls
                if !ownsLifetime { billingTerms }
                if let session {
                    NavigationLink {
                        SavedServerAccountView(session: session)
                    } label: {
                        Label("Server account", systemImage: "person.crop.circle")
                    }.accessibilityIdentifier("purchase.serverAccount")
                }
                PurchaseLegalLinks()
            }.padding(24).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Ilyich access")
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $managingSubscriptions)
        .onChange(of: managingSubscriptions) { _, shown in
            if !shown { Task { await store.refreshAccess() } }
        }
        .onChange(of: store.hasAccess) { _, _ in feedback = nil }
        .onChange(of: entitlement?.productID) { _, _ in feedback = nil }
        .task { if store.products.isEmpty { await store.loadProducts() } }
        .confirmationDialog("Buy lifetime access?", isPresented: Binding(
            get: { lifetimeConfirmation != nil },
            set: { if !$0 { lifetimeConfirmation = nil } }
        ), titleVisibility: .visible, presenting: lifetimeConfirmation) { product in
            Button("Buy lifetime for \(product.displayPrice)") { buy(product) }
            Button("Manage subscription") { managingSubscriptions = true }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Buying lifetime access does not cancel an existing Apple subscription. Manage your subscription with Apple to stop future renewals.")
        }
    }

    @ViewBuilder private var accessStatus: some View {
        switch store.state {
        case .checking:
            ProgressView("Checking App Store access…")
        case .unlocked(let entitlement):
            VStack(alignment: .leading, spacing: 7) {
                Label(entitlement.isLifetime ? "Lifetime access is active" : "Subscription access is active", systemImage: "checkmark.seal")
                    .font(.headline)
                if let expiration = entitlement.expirationDate, expiration > .now {
                    Text("Access is verified through \(expiration.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if entitlement.isLifetime {
                    Text("Already had a subscription? Lifetime access does not cancel it. Manage your Apple subscriptions to stop renewals.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .locked:
            Text("Choose a plan to continue, or restore a purchase made with your Apple Account.")
                .foregroundStyle(.secondary)
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label("Access could not be verified", systemImage: "wifi.exclamationmark").font(.headline)
                Text(reason).foregroundStyle(.secondary)
                Text("Restore or check your existing access before choosing another plan.").font(.footnote).foregroundStyle(.secondary)
                Button("Check access again") { refresh() }.disabled(busy)
            }
        }
    }

    @ViewBuilder private var products: some View {
        if store.isLoadingProducts && store.products.isEmpty {
            ProgressView("Loading App Store prices…")
        } else if store.products.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("App Store prices are unavailable. Connect to the App Store and try again. If you already purchased access, you can restore it below.")
                    .foregroundStyle(.secondary)
                Button("Reload prices") { Task { await store.loadProducts() } }.disabled(busy)
            }
        } else {
            VStack(spacing: 14) {
                ForEach(store.products, id: \.id) { product in
                    productCard(product)
                }
            }
        }
    }

    private func productCard(_ product: Product) -> some View {
        let lifetime = product.id == AccessProductID.lifetime.rawValue
        let current = entitlement?.productID == product.id
        let trial = eligibleTrial(product)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.displayName).font(.headline)
                Spacer(minLength: 12)
                Text(product.displayPrice).font(.title3.weight(.semibold))
            }
            if lifetime {
                Text("One-time purchase. No renewal and no free trial.")
                    .font(.footnote).foregroundStyle(.secondary)
                if entitlement != nil && !ownsLifetime {
                    Text("Buying lifetime does not cancel your current subscription. You must manage cancellation with Apple.")
                        .font(.footnote)
                }
            } else if let subscription = product.subscription {
                if let trial {
                    Text("Free for \(period(trial.period)), then \(product.displayPrice) every \(period(subscription.subscriptionPeriod)). Renews automatically until cancelled.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("\(product.displayPrice) every \(period(subscription.subscriptionPeriod)). Renews automatically until cancelled. Apple shows any available offer before you confirm.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                if lifetime && entitlement != nil && !ownsLifetime { lifetimeConfirmation = product }
                else { buy(product) }
            } label: {
                HStack {
                    if store.isPurchasing { ProgressView() }
                    Text(current ? "Current plan" : lifetime ? "Buy lifetime access" : trial.map { "Try free for \(period($0.period))" } ?? "Subscribe")
                        .frame(maxWidth: .infinity)
                }
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(busy || current || !canPurchase)
                .accessibilityIdentifier("purchase." + product.id)
        }.padding(18).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))
    }

    private var purchaseControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                feedback = nil
                Task { show(await store.restore()) }
            } label: {
                if store.isRestoring { ProgressView("Restoring purchases…") }
                else { Text("Restore purchases") }
            }.disabled(busy).accessibilityIdentifier("purchase.restore")
            Button("Manage Apple subscriptions") { managingSubscriptions = true }
                .disabled(busy).accessibilityIdentifier("purchase.manage")
        }
    }

    private var billingTerms: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscriptions are charged to your Apple Account and renew automatically unless cancelled at least 24 hours before the current period ends. Manage or cancel in your Apple subscription settings.")
            Text("Free trials are offered only when Apple confirms your eligibility. Unless cancelled at least 24 hours before the trial ends, the displayed subscription price is charged after the trial. Lifetime access is a separate one-time purchase.")
            Text("Signing out or deleting Ilyich does not cancel an Apple subscription.")
        }.font(.footnote).foregroundStyle(.secondary)
    }

    private func eligibleTrial(_ product: Product) -> Product.SubscriptionOffer? {
        guard case .locked = store.state,
              product.id != AccessProductID.lifetime.rawValue,
              store.introductoryOfferEligible.contains(product.id),
              let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        return offer
    }

    private func period(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: period.value == 1 ? "1 day" : "\(period.value) days"
        case .week: period.value == 1 ? "1 week" : "\(period.value) weeks"
        case .month: period.value == 1 ? "1 month" : "\(period.value) months"
        case .year: period.value == 1 ? "1 year" : "\(period.value) years"
        @unknown default: "the period shown by Apple"
        }
    }

    private func buy(_ product: Product) {
        feedback = nil
        Task { show(await store.purchase(product)) }
    }

    private func refresh() {
        feedback = nil
        Task { await store.refreshAccess(); await store.loadProducts() }
    }

    private func show(_ outcome: PurchaseOutcome) {
        switch outcome {
        case .purchased: feedback = nil
        case .cancelled: feedback = "Purchase cancelled."
        case .pending: feedback = "Your purchase is awaiting approval. Access will update after Apple confirms it."
        case .failed(let reason): feedback = reason
        }
    }
}

private struct SavedServerAccountView: View {
    let session: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var signingOut = false

    var body: some View {
        Form {
            if let account = session.savedAccount {
                Section("Saved server account") {
                    LabeledContent("Name", value: account.name)
                    LabeledContent("Server", value: account.server.host ?? account.server.absoluteString)
                    Link("Open your server", destination: account.server.deletingLastPathComponent())
                }
                Section {
                    Button("Sign out of server", role: .destructive) { confirmingSignOut = true }
                        .disabled(signingOut).accessibilityIdentifier("purchase.signOut")
                }
            } else if session.isRestoring {
                ProgressView("Reading saved account…")
            } else {
                Text("No server account is saved on this iPhone.")
            }
            Section {
                Text("Your server administrator manages your account and photos. App Store access is separate from your server account.")
                Text("Signing out does not delete your server account or cancel your Apple subscription.")
            }
            if let error = session.error { Text(error).foregroundStyle(.secondary) }
            PurchaseLegalLinks()
        }
        .navigationTitle("Server account")
        .confirmationDialog("Sign out of your server?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                signingOut = true
                Task {
                    await session.forgetSavedAccount()
                    signingOut = false
                    if session.error == nil { dismiss() }
                }
            }
        } message: {
            Text("Your server account and its photos remain on the server. Your Apple subscription is not cancelled.")
        }
    }
}

struct PurchaseLegalLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Link("Privacy Policy", destination: URL(string: "https://github.com/ilyador/Ilyich/blob/dev/ios-native/PRIVACY.md")!)
            Link("Terms of Use (Apple Standard EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            Link("Help and support", destination: URL(string: "https://github.com/ilyador/Ilyich/issues")!)
        }.font(.footnote)
    }
}
