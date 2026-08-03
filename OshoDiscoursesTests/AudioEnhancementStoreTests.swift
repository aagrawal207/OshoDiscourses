import Foundation
import Testing
@testable import OshoDiscourses

/// Tests for the bookkeeping around rendered files: which one belongs to the
/// settings in force, and when a render stops counting.
@MainActor
struct AudioEnhancementStoreTests {

    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Osho Discourses/Enhanced")
    }

    /// Stands in for a finished render. The contents do not matter here; only the
    /// name carries the recipe.
    private func placeFile(discourseId: String, fingerprint: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(discourseId)__\(fingerprint).m4a")
        try Data("not really audio".utf8).write(to: url)
    }

    private func clean(discourseId: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("\(discourseId)__") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    @Test func aRenderCountsOnlyForTheSettingsThatProducedIt() throws {
        let id = "test-recipe-match-\(UUID().uuidString)"
        defer { clean(discourseId: id) }

        UserSettings.shared.noiseReductionMode = .deepFilterNet
        UserSettings.shared.denoiseStrength = "medium"
        UserSettings.shared.voiceFocusPreset = .focus

        let store = AudioEnhancementStore()
        #expect(store.readyURL(discourseId: id) == nil, "nothing rendered yet")

        try placeFile(discourseId: id, fingerprint: store.currentRecipe.fingerprint)
        store.refresh()
        #expect(store.isReady(discourseId: id))
        #expect(store.readyURL(discourseId: id) != nil)

        // Change a setting the audio depends on. The old render is now the wrong
        // audio, so it must stop being offered rather than be served silently.
        UserSettings.shared.denoiseStrength = "light"
        store.refresh()
        #expect(!store.isReady(discourseId: id), "a render must not survive a strength change")
        #expect(store.readyURL(discourseId: id) == nil)

        // Switching back finds the original render again, which is why the file is
        // named by recipe rather than overwritten.
        UserSettings.shared.denoiseStrength = "medium"
        store.refresh()
        #expect(store.isReady(discourseId: id))
    }

    @Test func removingClearsEveryRecipeNotJustTheCurrentOne() throws {
        let id = "test-remove-\(UUID().uuidString)"
        defer { clean(discourseId: id) }

        UserSettings.shared.noiseReductionMode = .deepFilterNet
        UserSettings.shared.denoiseStrength = "medium"
        UserSettings.shared.voiceFocusPreset = .focus
        let store = AudioEnhancementStore()

        try placeFile(discourseId: id, fingerprint: store.currentRecipe.fingerprint)
        try placeFile(discourseId: id, fingerprint: "some-older-recipe-r1")
        store.remove(discourseId: id)

        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("\(id)__") }
        #expect(leftovers.isEmpty, "left behind \(leftovers)")
    }

    @Test func storageUsedCountsRenderedFiles() throws {
        let id = "test-size-\(UUID().uuidString)"
        defer { clean(discourseId: id) }
        let store = AudioEnhancementStore()
        let before = store.storageUsed()
        try placeFile(discourseId: id, fingerprint: "sizing-r1")
        #expect(store.storageUsed() > before)
    }
}
