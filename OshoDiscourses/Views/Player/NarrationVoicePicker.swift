import AVFoundation
import SwiftUI

struct NarrationVoicePicker: View {
    let voices: [NarrationVoice]
    @Binding var selectedVoiceID: String
    let sampleText: String?
    let pace: NarrationPace

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var preview = NarrationVoicePreview.shared
    @State private var ownerID = UUID()

    init(voices: [NarrationVoice], selectedVoiceID: Binding<String>, sampleText: String?, pace: NarrationPace) {
        self.voices = voices
        _selectedVoiceID = selectedVoiceID
        self.sampleText = sampleText
        self.pace = pace
    }

    var body: some View {
        List {
            if voices.isEmpty {
                ContentUnavailableView(
                    "No voices available", systemImage: "speaker.slash",
                    description: Text("Add a system voice in Settings, then check available voices again.")
                )
            } else {
                Section {
                    ForEach(voices) { voice in
                        VStack(alignment: .leading, spacing: 8) {
                            voiceRow(voice)
                            if let failure = preview.failure, failure.ownerID == ownerID, failure.voiceID == voice.id {
                                Label(failure.message, systemImage: "exclamationmark.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("narration.voicePreviewError.\(voice.id)")
                            }
                        }
                    }
                } header: {
                    Text("System voices")
                } footer: {
                    Text("Previews pause your current audio. Tap a voice name to choose it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { preview.stop(ownerID: ownerID) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { preview.stop(ownerID: ownerID) }
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying { preview.stop(ownerID: ownerID) }
        }
        .onChange(of: voices) { _, _ in preview.stop(ownerID: ownerID) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            preview.stop(ownerID: ownerID)
        }
    }

    private func voiceRow(_ voice: NarrationVoice) -> some View {
        let selected = selectedVoiceID == voice.id
        let isPreviewing = preview.ownerID == ownerID && preview.activeVoiceID == voice.id
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        return layout {
            Button {
                selectedVoiceID = voice.id
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(voice.name).foregroundStyle(.primary)
                        Text(voiceDetails(voice))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .opacity(selected ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("narration.voiceChoice.\(voice.id)")

            Button {
                if isPreviewing {
                    preview.stop(ownerID: ownerID)
                } else {
                    preview.play(voice: voice, sampleText: sampleText, pace: pace, ownerID: ownerID) {
                        player.setPlaying(false)
                    }
                }
            } label: {
                Label(isPreviewing ? "Stop" : "Preview", systemImage: isPreviewing ? "stop.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 72, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(scenePhase != .active)
            .accessibilityLabel("\(isPreviewing ? "Stop preview of" : "Preview") \(voice.name), \(voiceDetails(voice))")
            .accessibilityIdentifier("narration.voicePreview.\(voice.id)")
        }
    }

    private func voiceDetails(_ voice: NarrationVoice) -> String {
        let quality: String
        switch voice.quality {
        case AVSpeechSynthesisVoiceQuality.premium.rawValue: quality = "Premium"
        case AVSpeechSynthesisVoiceQuality.enhanced.rawValue: quality = "Enhanced"
        default: quality = "Standard"
        }
        return "\(NarrationLanguageSupport.displayName(for: voice.language)) · \(quality)"
    }
}
