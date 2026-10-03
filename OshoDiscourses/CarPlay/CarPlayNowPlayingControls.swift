#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import UIKit

/// Configures the shared Now Playing screen for one connection: a speed button,
/// a bookmark button and Up Next. Transport and seeking come from the phone's
/// `MPRemoteCommandCenter` registrations, which CarPlay must not replace.
@MainActor
final class CarPlayNowPlayingControls: NSObject, CPNowPlayingTemplateObserver {
    nonisolated static let supportedRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    /// Repeated taps inside this window add one bookmark, not several.
    static let bookmarkRepeatWindow: TimeInterval = 3
    static let bookmarkConfirmation: Duration = .seconds(2)

    enum BookmarkOutcome: Equatable { case added, repeated, nothingPlaying }

    private weak var source: (any CarPlayContentSource)?
    private var upNext: (@MainActor () -> Void)?
    private let now: @MainActor () -> Date
    private var generation = UUID()
    private var lastBookmark: (discourseID: String, at: Date)?
    private var confirmedDiscourseID: String?
    private var confirmationTask: Task<Void, Never>?
    private(set) var buttons: [CPNowPlayingButton] = []
    private(set) var isConnected = true

    var isShowingBookmarkConfirmation: Bool {
        confirmedDiscourseID != nil && confirmedDiscourseID == source?.currentDiscourseID
    }

    init(source: any CarPlayContentSource, upNext: @escaping @MainActor () -> Void,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.source = source
        self.upNext = upNext
        self.now = now
        super.init()
        let template = CPNowPlayingTemplate.shared
        template.upNextTitle = "Up Next"
        template.isAlbumArtistButtonEnabled = false
        template.add(self)
        update()
        rebuildButtons()
    }

    /// Cycles upward through the supported speeds and wraps to the slowest.
    nonisolated static func nextRate(after rate: Float) -> Float {
        supportedRates.first { $0 > rate + 0.01 } ?? supportedRates[0]
    }

    func update() {
        guard isConnected, let source else { return }
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = source.queue.count > 1
        if confirmedDiscourseID != nil, confirmedDiscourseID != source.currentDiscourseID {
            confirmedDiscourseID = nil
            rebuildButtons()
        }
    }

    func activateRate() {
        guard isConnected, let source, source.currentDiscourseID != nil else { return }
        source.setRate(Self.nextRate(after: source.playbackRate))
    }

    @discardableResult
    func activateBookmark() -> BookmarkOutcome {
        guard isConnected, let source, let id = source.currentDiscourseID else { return .nothingPlaying }
        let date = now()
        if let last = lastBookmark, last.discourseID == id, date.timeIntervalSince(last.at) < Self.bookmarkRepeatWindow {
            return .repeated
        }
        guard source.addBookmarkAtCurrentTime() else { return .nothingPlaying }
        lastBookmark = (id, date)
        confirmedDiscourseID = id
        rebuildButtons()
        confirmationTask?.cancel()
        let token = generation
        confirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.bookmarkConfirmation)
            guard let self, !Task.isCancelled, self.generation == token, self.isConnected else { return }
            self.confirmedDiscourseID = nil
            self.rebuildButtons()
        }
        return .added
    }

    func disconnect() {
        isConnected = false
        generation = UUID()
        confirmationTask?.cancel()
        confirmationTask = nil
        upNext = nil
        source = nil
        CPNowPlayingTemplate.shared.remove(self)
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in self?.upNext?() }
    }

    private func rebuildButtons() {
        generation = UUID()
        let token = generation
        let rate = CPNowPlayingPlaybackRateButton { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.activateRate()
            }
        }
        let confirmed = isShowingBookmarkConfirmation
        let symbol = confirmed ? "bookmark.fill" : "bookmark"
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)) ?? UIImage()
        let bookmark = CPNowPlayingImageButton(image: image.withRenderingMode(.alwaysTemplate)) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.activateBookmark()
            }
        }
        bookmark.isSelected = confirmed
        bookmark.accessibilityLabel = confirmed ? "Bookmark added" : "Add bookmark"
        buttons = [rate, bookmark]
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }
}
#endif
