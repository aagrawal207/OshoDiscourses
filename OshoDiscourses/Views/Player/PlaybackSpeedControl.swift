import SwiftUI

/// Speed in 0.05 steps: drag for fine control, −/+ for a single step, presets for common speeds.
struct PlaybackSpeedControl: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The slider edits a local value so a drag never fights the player's rounding mid-gesture.
    @State private var draft: Float = 1
    @State private var isEditing = false

    private var accent: Color { UserSettings.shared.effectiveAccentTheme.color }
    private var rate: Float { isEditing ? PlaybackSpeed.normalized(draft) : player.playbackRate }

    /// Accessibility text sizes stack the controls; one row of five presets cannot fit.
    private var isStacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        VStack(spacing: 16) {
            if isStacked {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speed").font(.headline)
                    value
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                slider
                HStack {
                    slowerButton
                    Spacer()
                    fasterButton
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(PlaybackSpeed.presets, id: \.self) { presetButton($0) }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Speed").font(.headline)
                    Spacer()
                    value
                }
                HStack(spacing: 8) {
                    slowerButton
                    slider
                    fasterButton
                }
                HStack(spacing: 6) {
                    ForEach(PlaybackSpeed.presets, id: \.self) { presetButton($0) }
                }
            }
        }
        .padding(16)
        .frame(width: isStacked ? 320 : 300)
        .onAppear { draft = player.playbackRate }
        .onChange(of: player.playbackRate) { _, value in
            if !isEditing { draft = value }
        }
        .sensoryFeedback(.selection, trigger: rate)
        .presentationCompactAdaptation(.popover)
    }

    private var value: some View {
        Text(PlaybackSpeed.label(rate))
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(PlaybackSpeed.matches(rate, 1) ? Color.primary : accent)
            .accessibilityHidden(true)
    }

    private var slider: some View {
        Slider(
            value: Binding(get: { draft }, set: { draft = $0; apply($0) }),
            in: PlaybackSpeed.range,
            step: PlaybackSpeed.step,
            onEditingChanged: { isEditing = $0 }
        )
        .tint(accent)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(PlaybackSpeed.accessibilityLabel(rate))
        .accessibilityIdentifier("player.speedSlider")
    }

    private var slowerButton: some View {
        stepButton(systemImage: "minus", label: "Slower", steps: -1)
            .disabled(rate <= PlaybackSpeed.range.lowerBound)
    }

    private var fasterButton: some View {
        stepButton(systemImage: "plus", label: "Faster", steps: 1)
            .disabled(rate >= PlaybackSpeed.range.upperBound)
    }

    private func stepButton(systemImage: String, label: String, steps: Int) -> some View {
        Button {
            apply(PlaybackSpeed.stepped(player.playbackRate, by: steps))
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier("player.speed.\(label.lowercased())")
    }

    private func presetButton(_ preset: Float) -> some View {
        let selected = PlaybackSpeed.matches(rate, preset)
        return Button {
            apply(preset)
        } label: {
            Text(PlaybackSpeed.label(preset))
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    selected ? accent.opacity(0.18) : Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .foregroundStyle(selected ? accent : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PlaybackSpeed.accessibilityLabel(preset))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("player.speed.preset.\(PlaybackSpeed.label(preset))")
    }

    private func apply(_ value: Float) {
        let normalized = PlaybackSpeed.normalized(value)
        draft = normalized
        guard !PlaybackSpeed.matches(normalized, player.playbackRate) else { return }
        player.setRate(normalized)
    }
}
