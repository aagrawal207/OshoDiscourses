import SwiftUI
import StoreKit

struct TipJarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let tips: TipJarService
    private let annualSupport: AnnualSupportService
    private var settings = UserSettings.shared
    @State private var showingManageSubscriptions = false
    @State private var confirmingDeclinedRequest = false
    @State private var engagementOwner = UUID()

    init(tips: TipJarService = .shared, annualSupport: AnnualSupportService = .shared) {
        self.tips = tips
        self.annualSupport = annualSupport
    }

    private var accent: Color { settings.effectiveAccentTheme.color }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(accent)
                        Text("Osho Talks is free and has no ads or tracking. If it has become part of your days, an optional tip helps me keep improving it.")
                        Text("Choose a one-time tip or yearly support through Apple. Every feature stays free for everyone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                Section {
                    if tips.isLoading || annualSupport.isLoading {
                        HStack { ProgressView(); Text("Loading tips…").foregroundStyle(.secondary) }
                    }
                    ForEach(supportProducts, id: \.id) { product in
                        tipRow(product)
                    }
                    if let error = tips.loadError {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await tips.loadProducts() }
                        }
                        .disabled(tips.isLoading || tips.isPurchasing)
                        .accessibilityIdentifier("tipJar.retry")
                    }
                    if let error = annualSupport.loadError {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry Yearly Options") {
                            Task { await annualSupport.loadProducts() }
                        }
                        .disabled(annualSupport.isBusy || tips.isPurchasing)
                        .accessibilityIdentifier("tipJar.retryAnnual")
                    }
                } footer: {
                    if tips.tipCount > 0 {
                        Text(tips.tipCount == 1 ? "One tip recorded on this device. Thank you." : "\(tips.tipCount) tips recorded on this device. Thank you.")
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                Section {
                    if annualSupport.pendingProductID != nil {
                        Text("A yearly support request is awaiting approval. Another subscription can't be started until it is resolved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Check Pending Request") {
                            Task { await annualSupport.refreshStatus() }
                        }
                        .disabled(annualSupport.isBusy)
                        Button("Request Was Declined") { confirmingDeclinedRequest = true }
                            .accessibilityIdentifier("tipJar.clearDeclinedRequest")
                    }
                    if annualSupport.currentProductID != nil {
                        Label("Thank you for your yearly support", systemImage: "heart")
                        Text("Your Apple Account has a yearly support plan. You can change the amount, check its status, or cancel through Apple.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Manage Subscriptions") { showingManageSubscriptions = true }
                        .accessibilityIdentifier("tipJar.manageSubscriptions")
                    Button(annualSupport.isRestoring ? "Restoring…" : "Restore Subscription") {
                        Task { await annualSupport.restore() }
                    }
                    .disabled(annualSupport.isBusy || tips.isPurchasing)
                    .accessibilityIdentifier("tipJar.restoreSubscription")
                    if let error = annualSupport.statusError {
                        Text(error).foregroundStyle(.secondary)
                        Button("Check Subscription Status") {
                            Task { await annualSupport.refreshStatus() }
                        }
                        .disabled(annualSupport.isBusy)
                    }
                    if let message = annualSupport.restoreMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    Link("Privacy Policy", destination: URL(string: "https://github.com/aagrawal207/OshoDiscourses/blob/main/PRIVACY.md")!)
                } header: {
                    Text("Yearly support")
                } footer: {
                    Text("Yearly support is an auto-renewing subscription charged once a year unless cancelled at least 24 hours before renewal. Manage or cancel it in your App Store account. One-time tips do not renew. Neither option unlocks features or content.")
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Support Development")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                async let oneTime: () = tips.loadProducts()
                async let yearly: () = annualSupport.loadProducts()
                _ = await (oneTime, yearly)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await annualSupport.refreshStatus() } }
            }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
            .onAppear { EngagementService.shared.registerSupportSheet(owner: engagementOwner) }
            .onDisappear { EngagementService.shared.unregisterSupportSheet(owner: engagementOwner) }
            .confirmationDialog("Clear the pending request?", isPresented: $confirmingDeclinedRequest, titleVisibility: .visible) {
                Button("Clear Declined Request", role: .destructive) { annualSupport.clearDeclinedRequest() }
            } message: {
                Text("Only clear this if the App Store request was declined or cancelled. A request that is still pending may be approved and charged later.")
            }
            .onChange(of: showingManageSubscriptions) { _, isPresented in
                if !isPresented { Task { await annualSupport.refreshStatus() } }
            }
            // Pending stays inline so a later approval can present its own confirmation.
            .safeAreaInset(edge: .bottom) {
                if tips.state == .pending || annualSupport.state == .pending {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Purchase pending", systemImage: "clock")
                            .font(.headline)
                        Text("Your purchase is pending with the App Store. It may need approval, such as Ask to Buy. You don't need to try again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Got It") { dismissMessages() }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            }
            .alert(purchaseMessage?.title ?? "", isPresented: Binding(
                get: { purchaseMessage != nil },
                set: { if !$0 { dismissMessages() } }
            ), presenting: purchaseMessage) { _ in
                Button("OK") { dismissMessages() }
            } message: { message in
                Text(message.body)
            }
        }
    }

    private var purchaseMessage: (title: String, body: String)? {
        switch annualSupport.state {
        case .thanked:
            return ("Thank you", "Your yearly support helps me keep improving Osho Talks. Every feature stays free for everyone.")
        case .failed(let message):
            return ("Couldn't confirm subscription", message)
        default: break
        }
        switch tips.state {
        case .thanked:
            return ("Thank you", "Your tip keeps this app going. Enjoy the talks.")
        case .failed(let message):
            return ("Couldn't confirm tip", message)
        case .idle, .purchasing, .pending:
            return nil
        }
    }

    private var supportProducts: [Product] {
        Self.orderedProducts(tips.products + annualSupport.products)
    }

    static func orderedProducts(_ products: [Product]) -> [Product] {
        products.sorted {
            if $0.price != $1.price { return $0.price < $1.price }
            if $0.type != $1.type { return $0.type == .consumable }
            return $0.id < $1.id
        }
    }

    private func dismissMessages() {
        tips.dismissMessage()
        annualSupport.dismissMessage()
    }

    private func tipRow(_ product: Product) -> some View {
        let isAnnual = AnnualSupportService.isAnnualSupport(product)
        let isCurrent = annualSupport.currentProductID == product.id
        let annualLabel = isCurrent ? "Current yearly plan"
            : (annualSupport.pendingProductID == product.id ? "Awaiting approval" : "Renews yearly · Cancel anytime")
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
        return Button {
            Task {
                if isAnnual { await annualSupport.purchase(product) }
                else { await tips.purchase(product) }
            }
        } label: {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).foregroundStyle(.primary)
                    Text(isAnnual ? annualLabel : "One-time tip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !product.description.isEmpty {
                        Text(product.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if tips.state == .purchasing(product.id) || annualSupport.state == .purchasing(product.id) {
                    ProgressView()
                } else {
                    Text(isAnnual ? "\(product.displayPrice) / year" : product.displayPrice)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(isAnnual
            ? !annualSupport.canPurchase || tips.isPurchasing || tips.state != .idle
            : !tips.canPurchase || annualSupport.isBusy || annualSupport.state != .idle)
        .accessibilityIdentifier(product.id)
    }
}
