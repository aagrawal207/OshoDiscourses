import SwiftUI

/// One-shot launch splash. It is drawn to be pixel-identical to the launch
/// storyboard (same lotus, title, and purple background at the same positions),
/// so the storyboard — which iOS shows during the cold-start process spin-up —
/// hands off to this SwiftUI view with no visible change. The storyboard is
/// what shows the brand while the app boots; this view only smooths the exit
/// with a brief hold and a cross-fade into the app, so it adds almost no time
/// on top of the launch iOS already spent. ContentView is mounted beneath it,
/// so nothing functional is gated.
struct LaunchView: View {
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()

            // Matches the storyboard's centered vertical stack (spacing 22).
            VStack(spacing: 22) {
                Image("LaunchLotus")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)

                Text("Osho Talks")
                    // Fixed size (not Dynamic Type) to exactly match the launch
                    // storyboard's 22pt label, so the handoff shows no pop.
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Osho Talks")
        .onAppear {
            // No fade-in: the storyboard already showed this exact frame, so
            // animating in would make the content jump. The storyboard already
            // held the brand through the (slow) cold start, so keep this dwell
            // tiny — just long enough to avoid a jarring instant cut — then hand
            // back. The host cross-fades the whole splash out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                onComplete()
            }
        }
    }
}
