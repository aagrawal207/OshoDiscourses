import SwiftUI

/// Menu bar and keyboard commands. Playback is process wide; navigation and
/// enablement come from the key window's `AppNavigation` and `CommandState`.
struct AppCommands: Commands {
    let player: AudioPlayerService
    @FocusedValue(\.appNavigation) private var navigation
    @FocusedValue(\.commandState) private var focusedState

    private var sleepTimer: SleepTimerService { SleepTimerService.shared }
    private var state: CommandState { focusedState ?? CommandState() }
    private var hasTrack: Bool { state.hasTrack }

    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static let sleepMinutes = [5, 10, 15, 30, 45, 60]

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { navigation?.select(.settings) }
                .keyboardShortcut(",")
                .disabled(navigation == nil)
        }

        // The system Format menu claims ⌘B and ⌘T for bold and fonts, which
        // this app never edits; the shortcuts belong to bookmarks and transcripts.
        CommandGroup(replacing: .textFormatting) {}

        // Not a document app: Duplicate, Rename, Move and Export have nothing to act on.
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}

        // The default Help item opens an empty help book.
        CommandGroup(replacing: .help) {
            Link("Osho Talks Support", destination: URL(string: "https://github.com/aagrawal207/OshoDiscourses/blob/main/SUPPORT.md")!)
        }

        CommandGroup(before: .sidebar) {
            // One inline section: loose items inserted before the sidebar group
            // land in reverse order on Mac.
            Section {
                ForEach(Array(AppTab.shortcutOrder.enumerated()), id: \.element) { index, tab in
                    Button(tab.title) { navigation?.select(tab) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                        .disabled(navigation == nil)
                }
                Button(AppTab.bookmarks.title) { navigation?.select(.bookmarks) }
                    .keyboardShortcut("5")
                    .disabled(navigation == nil)
            }
        }

        CommandMenu("Playback") {
            // Plain Space, like Music and Podcasts. Text fields keep the key:
            // UIKit offers it to the focused text input before key commands.
            Button(state.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!hasTrack)

            Divider()

            Button("Skip Forward 30 Seconds") { player.skipForward() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!hasTrack)
            Button("Skip Back 15 Seconds") { player.skipBackward() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!hasTrack)
            Button("Next Discourse") { player.skipToNext() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(!state.hasNext)
            Button("Previous Discourse") { player.skipToPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(!hasTrack)

            Divider()

            Menu("Speed") {
                ForEach(Self.speeds, id: \.self) { speed in
                    Toggle(Self.speedLabel(speed), isOn: Binding(
                        get: { abs(state.rate - speed) < 0.01 },
                        set: { if $0 { player.setRate(speed) } }
                    ))
                }
            }
            .disabled(!hasTrack)

            Menu("Sleep Timer") {
                Toggle("End of Discourse", isOn: Binding(
                    get: { state.sleepMode == .endOfDiscourse },
                    set: { $0 ? sleepTimer.startUntilEndOfDiscourse() : sleepTimer.cancel() }
                ))
                Divider()
                ForEach(Self.sleepMinutes, id: \.self) { minutes in
                    Button("\(minutes) Minutes") { sleepTimer.start(minutes: minutes) }
                }
                if state.sleepMode != .off {
                    Divider()
                    Button("Turn Off Sleep Timer") { sleepTimer.cancel() }
                }
            }
            .disabled(!hasTrack)

            Divider()

            Button("Add Bookmark…") { navigation?.addBookmark() }
                .keyboardShortcut("b")
                .disabled(!hasTrack || navigation == nil)
            Button("Show Transcript") { navigation?.showTranscript() }
                .keyboardShortcut("t")
                .disabled(!state.canShowTranscript || navigation == nil)
            Button("Show Player") { navigation?.showPlayer() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!hasTrack || navigation == nil || state.isPlayerPresented)
            // Escape is handled by the player itself (EscapeKeyHandler); a
            // menu key equivalent for it never reaches the full-window player.
            Button("Close Player") { navigation?.closePlayer() }
                .disabled(!state.canClosePlayer)
        }
    }

    static func speedLabel(_ speed: Float) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
