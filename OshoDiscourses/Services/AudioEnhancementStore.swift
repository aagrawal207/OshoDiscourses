import Foundation
import Observation
import os

/// Tracks which downloads have been rendered through the noise-reduction chain,
/// and runs the renders.
///
/// Kept separate from `AudioEnhancementService`, which is the pure renderer: this
/// half owns the on-disk layout, the progress the UI observes, and the decision
/// about whether a given render is still valid for the current settings.
@Observable
@MainActor
final class AudioEnhancementStore {

    private static let log = Logger(subsystem: "com.osho.discourses", category: "enhance")

    /// Discourse ids that have a render matching the current recipe.
    private(set) var readyIds: Set<String> = []
    /// The discourse being rendered right now, if any. Renders run one at a time:
    /// each one already saturates a core, and two would only make both slower.
    private(set) var renderingId: String?
    private(set) var progress: Double = 0
    /// Plain-language reason the last render stopped, shown in the row that asked
    /// for it rather than swallowed.
    private(set) var failure: (id: String, message: String)?

    private let renderer = AudioEnhancementService()
    private var task: Task<Void, Never>?

    /// The recipe in force right now. A render is only reusable while this
    /// matches what produced it.
    var currentRecipe: AudioEnhancementService.Recipe {
        AudioEnhancementService.Recipe(
            mode: UserSettings.shared.noiseReductionMode,
            strength: AudioPlayerService.DenoiseStrength(
                rawValue: UserSettings.shared.denoiseStrength
            ) ?? .medium,
            voiceFocus: UserSettings.shared.voiceFocusPreset
        )
    }

    init() {
        refresh()
    }

    // MARK: - Paths

    private var folderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Osho Discourses/Enhanced")
    }

    /// Renders are named with the recipe that made them, so a settings change
    /// simply stops matching instead of silently serving the wrong audio. The old
    /// file stays until it is cleaned up, which is also what makes switching a
    /// setting back instant.
    private func fileURL(discourseId: String, recipe: AudioEnhancementService.Recipe) -> URL {
        let safeId = discourseId.replacingOccurrences(of: "/", with: "-")
        return folderURL.appendingPathComponent("\(safeId)__\(recipe.fingerprint).m4a")
    }

    /// The rendered file to play instead of the download, if there is a usable one.
    func readyURL(discourseId: String) -> URL? {
        let url = fileURL(discourseId: discourseId, recipe: currentRecipe)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isReady(discourseId: String) -> Bool {
        readyIds.contains(discourseId)
    }

    /// Rescans the folder. Cheap: one directory listing, and a full library is a
    /// few thousand names at most.
    func refresh() {
        let suffix = "__\(currentRecipe.fingerprint).m4a"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        readyIds = Set(
            names
                .filter { $0.hasSuffix(suffix) }
                .map { String($0.dropLast(suffix.count)) }
        )
    }

    // MARK: - Rendering

    func enhance(discourseId: String, sourceURL: URL) {
        guard renderingId == nil else { return }
        let recipe = currentRecipe
        let destination = fileURL(discourseId: discourseId, recipe: recipe)
        renderingId = discourseId
        progress = 0
        failure = nil

        task = Task { [weak self, renderer] in
            let outcome: Result<AudioEnhancementService.Result, Error>
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let result = try await renderer.render(
                    source: sourceURL,
                    destination: destination,
                    recipe: recipe,
                    progress: { fraction in
                        Task { @MainActor in
                            self?.progress = fraction
                        }
                    }
                )
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.renderingId = nil
                self.progress = 0
                switch outcome {
                case .success(let result):
                    Self.log.info("""
                        Rendered \(discourseId, privacy: .public) in \
                        \(result.frames) frames
                        """)
                    self.refresh()
                case .failure(let error):
                    if error is CancellationError { return }
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    Self.log.error("Render of \(discourseId, privacy: .public) failed: \(message)")
                    self.failure = (id: discourseId, message: message)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        renderingId = nil
        progress = 0
    }

    func remove(discourseId: String) {
        // Every recipe's copy, not just the current one, so "remove" means gone.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        let safeId = discourseId.replacingOccurrences(of: "/", with: "-")
        for name in names where name.hasPrefix("\(safeId)__") {
            try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(name))
        }
        refresh()
    }

    /// Total bytes held by rendered audio, for the storage meter.
    func storageUsed() -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        return names.reduce(into: Int64(0)) { total, name in
            let url = folderURL.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
            total += size ?? 0
        }
    }
}
