import SwiftUI

struct AudioEnhancementView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let boostLevels: [(gain: Float, label: String)] = [
        (1, "Off"), (1.5, "Low"), (2, "Medium"), (3, "High"), (4, "Max"),
    ]

    var body: some View {
        Form {
            enableSection
            modeSection
            if player.isNoiseReductionEnabled {
                reductionSection
            }
            boostSection
            if player.isNoiseReductionEnabled, player.noiseReductionMode == .deepFilterNet {
                voiceSection
            }
        }
        .reservesMiniPlayerSpace()
        .navigationTitle("DeNoise")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.accent)
    }

    private var enableSection: some View {
        @Bindable var player = player
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable DeNoise", isOn: $player.isNoiseReductionEnabled)
                    .font(.headline)
                    .accessibilityIdentifier("audioEnhancement.enabled")
                Text("Reduce recording noise and make quiet audio easier to hear.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(player.audioProcessingStatus.label)
                } icon: {
                    Image(systemName: statusIcon)
                        .accessibilityHidden(true)
                }
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("audioEnhancement.status")
                if player.audioProcessingStatus.isIssue {
                    Text(player.audioProcessingStatus.detail)
                }
            }
            .foregroundStyle(player.audioProcessingStatus.isIssue ? Color.orange : Color.secondary)
        }
    }

    private var modeSection: some View {
        Section {
            NavigationLink {
                AudioEnhancementModeView()
                    .environment(player)
            } label: {
                EnhancementModeLabel(mode: player.noiseReductionMode)
            }
            .accessibilityIdentifier("audioEnhancement.mode")
            .accessibilityLabel("Listening mode")
            .accessibilityValue("\(player.noiseReductionMode.displayName). \(player.noiseReductionMode.batteryNote)")
            .accessibilityHint("Shows the recommended mode and lighter alternatives")
        } header: {
            Text("Listening Mode")
        }
    }

    private var reductionSection: some View {
        Section {
            if dynamicTypeSize.isAccessibilitySize {
                strengthPicker.pickerStyle(.menu)
            } else {
                strengthPicker.pickerStyle(.segmented)
            }
        } header: {
            Text("Noise Reduction")
        } footer: {
            Text(player.denoiseStrength.detail)
        }
    }

    private var strengthPicker: some View {
        @Bindable var player = player
        return Picker("Amount", selection: $player.denoiseStrength) {
            ForEach(AudioPlayerService.DenoiseStrength.allCases, id: \.self) { strength in
                Text(strength.label).tag(strength)
            }
        }
        .accessibilityValue(player.denoiseStrength.label)
        .accessibilityIdentifier("audioEnhancement.strength")
    }

    private var boostSection: some View {
        Section {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    boostPicker.pickerStyle(.menu)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent(player.isBoostAvailable ? "Level" : "Saved level", value: Self.boostLevels[boostIndex].label)
                        boostPicker.pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                }
            }
            .disabled(!player.isNoiseReductionEnabled)
        } header: {
            Text("Volume Boost")
        } footer: {
            Text(boostExplanation)
                .accessibilityIdentifier("audioEnhancement.boostExplanation")
        }
    }

    private var boostPicker: some View {
        Picker(
            player.isBoostAvailable ? "Level" : "Saved level",
            selection: Binding(
                get: { boostIndex },
                set: { player.setVolume(Self.boostLevels[$0].gain) }
            )
        ) {
            ForEach(Self.boostLevels.indices, id: \.self) { index in
                Text(Self.boostLevels[index].label).tag(index)
            }
        }
        .accessibilityValue(Self.boostLevels[boostIndex].label)
        .accessibilityIdentifier("audioEnhancement.boost")
    }

    private var voiceSection: some View {
        Section {
            NavigationLink {
                AudioEnhancementVoiceView()
                    .environment(player)
            } label: {
                LabeledContent("Fine-tune the voice", value: player.voiceFocusPreset.displayName)
            }
            .accessibilityIdentifier("audioEnhancement.fineTune")
            .accessibilityValue(player.voiceFocusPreset.displayName)
        } footer: {
            Text("Your choices apply to all discourses. Results vary by recording.")
                .accessibilityIdentifier("audioEnhancement.footer")
        }
    }

    private var boostIndex: Int {
        Self.boostLevels.indices.min {
            abs(Self.boostLevels[$0].gain - player.volume) < abs(Self.boostLevels[$1].gain - player.volume)
        } ?? 0
    }

    private var boostExplanation: String {
        if !player.isNoiseReductionEnabled {
            return "Turn on DeNoise to use volume boost. It raises the volume after reducing noise."
        }
        if player.volume <= 1 {
            return "Boost is off. Choose a level to make quiet recordings louder."
        }
        if player.isBoostAvailable {
            return "Makes quiet recordings louder after reducing noise."
        }
        if player.audioProcessingStatus.isIssue {
            return "Your level is saved. Boost is paused until noise reduction is working again."
        }
        return "Your level is saved. Boost will apply when enhanced audio starts playing."
    }

    private var statusIcon: String {
        if player.audioProcessingStatus.isIssue { return "exclamationmark.circle" }
        switch player.audioProcessingStatus {
        case .active: return "checkmark.circle.fill"
        case .waitingForPlayback: return "play.circle"
        case .preparing, .loadingModel, .modelReady: return "hourglass"
        default: return "waveform"
        }
    }
}

private struct AudioEnhancementVoiceView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(VoiceFocusPreset.allCases) { preset in
                let isSelected = player.voiceFocusPreset == preset
                Button {
                    player.voiceFocusPreset = preset
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preset.displayName)
                                .font(.headline)
                            Text(preset.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accent : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    // Plain buttons hit only drawn content; wide iPad rows left the gap dead.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("audioEnhancement.voice.\(preset.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .reservesMiniPlayerSpace()
        .navigationTitle("Quiet Speech")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AudioEnhancementModeView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                modeButton(.deepFilterNet)
            } header: {
                Text("Recommended")
            }
            Section {
                ForEach(NoiseReductionMode.allCases.filter { $0 != .deepFilterNet }) { mode in
                    modeButton(mode)
                }
            } header: {
                Text("Other Options")
            } footer: {
                Text("Try a lighter option if you prefer its sound or want to save battery.")
            }
        }
        .reservesMiniPlayerSpace()
        .navigationTitle("Listening Mode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modeButton(_ mode: NoiseReductionMode) -> some View {
        let isSelected = player.noiseReductionMode == mode
        return Button {
            player.noiseReductionMode = mode
            dismiss()
        } label: {
            HStack(spacing: 12) {
                EnhancementModeLabel(mode: mode)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accent : Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("audioEnhancement.mode.\(mode.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EnhancementModeLabel: View {
    let mode: NoiseReductionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode.displayName)
                .font(.headline)
                .foregroundStyle(Color.primary)
            Text(mode.detail)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Label {
                Text(mode.batteryNote)
            } icon: {
                Image(systemName: "battery.50percent")
                    .accessibilityHidden(true)
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(mode == .deepFilterNet ? Color.accent : Color.secondary)
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}
