import SwiftUI

@Observable
@MainActor
final class HomeSupportPresentation {
    let owner = UUID()
    let engagement = EngagementService.shared
    var context = EngagementService.SupportContext()
    var showsTipJar = false

    var showsCard: Bool {
        engagement.supportCardOwner == owner
            && engagement.canShowSupportCard(owner: owner, context: context)
    }

    func update(_ context: EngagementService.SupportContext) {
        self.context = context
        if !engagement.beginSupportPresentation(owner: owner, context: context) {
            engagement.endSupportPresentation(owner: owner)
        }
    }

    func refreshStatusIfNeeded() async {
        await engagement.refreshSupportStatusIfNeeded(context: context) {
            await AnnualSupportService.shared.refreshStatus()
        }
    }

    func openSupport() {
        if engagement.openSupportSheet(owner: owner, context: context) { showsTipJar = true }
    }

    func leaveHome() {
        context.isHomeVisible = false
        engagement.endSupportPresentation(owner: owner)
    }
}

struct HomeSupportCard: View {
    let presentation: HomeSupportPresentation

    var body: some View {
        if presentation.showsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional support helps me keep improving Osho Talks.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(alignment: .leading, spacing: 0) { actions }
                }
            }
            .padding(16)
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .accessibilityElement(children: .contain)
            .onScrollVisibilityChange(threshold: 0.5) { visible in
                if visible {
                    presentation.engagement.recordSupportExposure(owner: presentation.owner, context: presentation.context)
                }
            }
            .onDisappear { presentation.engagement.endSupportPresentation(owner: presentation.owner) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: presentation.openSupport) {
            Text("Support")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("home.supportDevelopment")

        Button { dismiss(permanently: false) } label: {
            Text("Not Now")
                .font(.subheadline)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("home.supportNotNow")

        Button { dismiss(permanently: true) } label: {
            Text("Don't Ask Again")
                .font(.subheadline)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("home.supportNever")
    }

    private func dismiss(permanently: Bool) {
        presentation.engagement.dismissSupport(
            owner: presentation.owner, context: presentation.context, permanently: permanently
        )
    }
}

struct HomeSupportObserver: ViewModifier {
    @Environment(AudioPlayerService.self) private var player
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var presentation: HomeSupportPresentation
    let isHomeRoot: Bool

    private var context: EngagementService.SupportContext {
        let tips = TipJarService.shared
        var context = EngagementService.SupportContext(
            activeDays: ListeningStatsService.shared.distinctActiveDays,
            totalListening: ListeningStatsService.shared.totalAllTime,
            tipCount: tips.tipCount,
            isForeground: scenePhase == .active,
            isHomeVisible: isHomeRoot && navigation?.selectedTab == .home,
            isPlaying: player.isPlaying,
            sleepTimerArmed: SleepTimerService.shared.isActive,
            playerPresented: navigation?.isPlayerPresented ?? false,
            otherPresentationActive: presentation.showsTipJar || navigation?.pendingBookmark != nil
                || player.isPlayingNarration || NarrationService.shared.preparationOwner != nil,
            storeIsBusy: tips.isLoading || tips.isPurchasing
        )
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-debugEstablishedListener") {
            context.activeDays = EngagementService.supportActiveDaysThreshold
            context.totalListening = EngagementService.supportListeningThreshold
        }
        #endif
        guard EngagementService.hasEstablishedUse(context), context.tipCount == 0 else { return context }
        let annual = AnnualSupportService.shared
        context.subscriptionStatus = annual.currentProductID != nil ? .subscribed : (annual.statusIsCurrent ? .notSubscribed : .unknown)
        context.storeIsBusy = context.storeIsBusy || annual.isBusy
        return context
    }

    private var statusCheckOpportunity: EngagementService.SupportContext {
        var opportunity = context
        // Status loading changes these fields itself; they must not restart a failed lookup.
        opportunity.subscriptionStatus = .unknown
        opportunity.storeIsBusy = false
        return opportunity
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: context, initial: true) { _, context in
                presentation.update(context)
            }
            .task(id: statusCheckOpportunity) {
                guard !Task.isCancelled else { return }
                presentation.update(context)
                await presentation.refreshStatusIfNeeded()
            }
            .onDisappear { presentation.leaveHome() }
            .sheet(isPresented: $presentation.showsTipJar, onDismiss: {
                presentation.engagement.endSupportSheet(owner: presentation.owner)
            }) {
                TipJarView()
            }
    }
}
