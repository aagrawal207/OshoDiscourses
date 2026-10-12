import SwiftUI

/// The sleep timer choices, shared by the player and the translated narration reader.
struct SleepTimerControl: View {
    let dismiss: () -> Void
    private var sleepTimer: SleepTimerService { SleepTimerService.shared }

    var body: some View {
        VStack(spacing: 4) {
            Button {
                sleepTimer.startUntilEndOfDiscourse()
                dismiss()
            } label: {
                HStack {
                    Text("End of discourse")
                        .font(.body)
                    Spacer()
                    if sleepTimer.mode == .endOfDiscourse {
                        Image(systemName: "checkmark")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Divider()

            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    sleepTimer.start(minutes: minutes)
                    dismiss()
                } label: {
                    HStack {
                        Text("\(minutes) min")
                            .font(.body)
                        Spacer()
                        if sleepTimer.mode == .countdown {
                            let activeMinutes = Int(sleepTimer.remainingTime) / 60 + (Int(sleepTimer.remainingTime) % 60 > 0 ? 1 : 0)
                            if activeMinutes == minutes {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            if sleepTimer.isActive {
                Divider()

                Button {
                    sleepTimer.cancel()
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.body)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 160)
        .padding(.vertical, 8)
        .presentationCompactAdaptation(.popover)
    }
}
